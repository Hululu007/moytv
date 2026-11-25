import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 女优库绑定手机根目录下的 MYTV 文件夹（2026-11-20 用户令）。
///
/// 落点（2026-11-25 用户令：只留 .sql 导入，删本地 .db 读取——
/// MYTV/db/女优库.db 从此不再被读，内部工作库搬到应用私有目录
/// documents/女优库.db，见 actress_working_db.dart；绑定只剩
/// json/m3u 目录与合并 JSON 导出）：
/// - `MYTV/db/`：本地 json 影子文件目录（现爬写盘入口，
///   与原来 documents/actress_json/mjv011.json 同一口径）。
///   这里只放 .json，不再放数据库。
/// - `MYTV/m3u/`：用户自己放 m3u 文件的地方（女优合集1.m3u～
///   9.m3u 这种），m3u 兜底先读这里。
/// - `MYTV/mjv011.json`：合并 JSON 导出落点。
///
/// 权限与降级（targetSdk 36）：直接写根目录要“所有文件访问权限”
/// （MANAGE_EXTERNAL_STORAGE）。没拿到权限时不硬写、不崩——
/// 绑定失败，json/m3u 兜底走 documents 下的旧目录；用户授权后点
/// “重新绑定”再试一次。
///
/// 鸿蒙 NEXT（卓易通容器）：外部存储实际路径可能与原生安卓不同，
/// 根目录解析不到、或建目录失败时一律优雅降级，不在本机上假装
/// 验过——手机待验清单见 REPORT.md。
///
/// 本模块只算路径、建目录，不碰界面、不直接开库：
/// 真正开库的是 [SqfliteActressDatabase._openNow]，它开的是
/// 应用私有目录的内部工作库（不再调这里拿库路径）；列表页在
/// bootstrap 里先调一次，为的是给 json/m3u 指目录。

/// MYTV 文件夹名（手机根目录下）。
const mytvFolderName = 'MYTV';

/// MYTV 下的两个子文件夹：json 影子文件目录与 m3u 目录。
const mytvDbFolderName = 'db';
const mytvM3uFolderName = 'm3u';

/// 老 json 影子文件目录名（documents 下）。
const legacyJsonDirName = 'actress_json';

/// MYTV 根目录下的合并 JSON 导出落点（不碰 MYTV/db 里正在用的
/// 影子文件，导出只写这一份，用户拷走即用）。
const mytvMergedJsonFileName = 'mjv011.json';

/// 外部存储根目录解析：默认先走平台通道拿真根目录，拿不到再从
/// getExternalStorageDirectory 的应用专属目录往上推（去
/// `/Android/data/<包名>/files` 后缀）；两条路都走不通回 null，
/// 调用方按未绑定处理。
typedef MytvExternalRootResolver = Future<Directory?> Function();

/// “所有文件访问权限”是否已授予。
typedef MytvAllFilesAccessChecker = Future<bool> Function();

/// 打开系统“所有文件访问权限”设置页。
typedef MytvAllFilesSettingsOpener = Future<void> Function();

/// documents 目录解析。
typedef MytvDocumentsResolver = Future<Directory> Function();

/// 一次绑定解析的结果：给 json/m3u 指目录、导出合并 JSON 落点
/// 都用它。2026-11-25 起绑定不再管数据库（内部工作库在应用私有
/// 目录，见 actress_working_db.dart）。
class MytvBindResult {
  const MytvBindResult({
    required this.bound,
    required this.needsPermission,
    required this.m3uDir,
    required this.jsonDir,
    required this.mergedJsonExportPath,
    this.note,
  });

  /// true = MYTV 可用，json 与 m3u 都走 MYTV；false = 未绑定
  /// （原因见 [note]），json/m3u 兜底走 documents 下的旧目录。
  final bool bound;

  /// true = 没拿到所有文件访问权限，用户去设置授权后点
  /// “重新绑定”可再试一次。
  final bool needsPermission;

  /// m3u 目录：MYTV/m3u 或 documents。
  final Directory m3uDir;

  /// json 影子文件目录：MYTV/db 或 documents/actress_json。
  final Directory jsonDir;

  /// 合并 JSON 导出落点：MYTV/mjv011.json（只在 bound 时用）。
  final String mergedJsonExportPath;

  /// 未绑定的原因（给界面提示用）；正常时为空。
  final String? note;
}

/// MYTV 绑定解析：路径、建目录。
///
/// 平台调用全部包在 try/catch 里：测试环境没有平台通道、
/// 鸿蒙容器路径与原生不同，任何一步拿不到都按未绑定处理，
/// 绝不抛错。
class ActressMytvBind {
  ActressMytvBind({
    MytvExternalRootResolver? externalRoot,
    MytvAllFilesAccessChecker? hasAllFilesAccess,
    MytvAllFilesSettingsOpener? requestAllFilesAccess,
    MytvDocumentsResolver? documentsDir,
  }) : _externalRoot = externalRoot ?? _defaultExternalRoot,
       _hasAllFilesAccess = hasAllFilesAccess ?? _defaultHasAllFilesAccess,
       _requestAllFilesAccess =
           requestAllFilesAccess ?? _defaultRequestAllFilesAccess,
       _documentsDir = documentsDir ?? _defaultDocumentsDir;

  static final instance = ActressMytvBind._();

  ActressMytvBind._()
    : _externalRoot = _defaultExternalRoot,
      _hasAllFilesAccess = _defaultHasAllFilesAccess,
      _requestAllFilesAccess = _defaultRequestAllFilesAccess,
      _documentsDir = _defaultDocumentsDir;

  static const _deviceChannel = MethodChannel('moyi/device');

  final MytvExternalRootResolver _externalRoot;
  final MytvAllFilesAccessChecker _hasAllFilesAccess;
  final MytvAllFilesSettingsOpener _requestAllFilesAccess;
  final MytvDocumentsResolver _documentsDir;

  MytvBindResult? _cached;
  Future<MytvBindResult>? _pending;

  /// 上次解析结果（首次解析前为空）。
  MytvBindResult? get current => _cached;

  /// 解析一次绑定（结果缓存，并发调用共用同一份）。
  /// [refresh] 为 true 时重新解析（授权后重新绑定时用）。
  Future<MytvBindResult> ensureBound({bool refresh = false}) {
    if (!refresh && _cached != null) return Future.value(_cached);
    var pending = _pending;
    if (!refresh && pending != null) return pending;
    pending = _resolve();
    _pending = pending;
    return pending.then((result) {
      _cached = result;
      _pending = null;
      return result;
    });
  }

  /// 启动时自动生成 MYTV/db 与 MYTV/m3u（2026-11-24 用户令）：
  /// 以前只在进演员库时才调 ensureBound 顺带建目录，不进演员库
  /// 文件夹就一直没有；现在启动先建一次。任何失败自己吞掉，
  /// 不阻塞启动、不抛错（没权限时等用户授权后点“重新绑定”再建）。
  /// [bind] 仅供测试注入，正常调用传空、用单例。
  static Future<void> ensureFoldersAtStartup([
    ActressMytvBind? bind,
  ]) async {
    try {
      await (bind ?? instance).ensureBound();
    } catch (_) {}
  }

  /// 打开系统“所有文件访问权限”设置页（走平台通道；打不开
  /// 也不抛错，列表页只弹提示）。
  Future<void> requestPermission() async {
    try {
      await _requestAllFilesAccess();
    } catch (_) {
      // 打不开设置页也不崩：用户手动去设置里找也行。
    }
  }

  static Future<Directory> _defaultDocumentsDir() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      // 测试环境没有平台通道：用系统临时目录兜底，路径只作
      // 展示与拼接，不会在这里真开库（测试都注入内存库）。
      return Directory.systemTemp;
    }
  }

  static Future<Directory?> _defaultExternalRoot() async {
    // 1）平台通道拿真根目录（MainActivity 的 moyi/device 通道）。
    try {
      final root = await _deviceChannel.invokeMethod<String>(
        'externalStorageRoot',
      );
      if (root != null && root.isNotEmpty) {
        final dir = Directory(root);
        if (dir.existsSync()) return dir;
      }
    } catch (_) {
      // 通道没有/旧包没实现：走下面的推导。
    }
    // 2）从应用专属目录往上推：/storage/emulated/0/Android/data/
    // <包名>/files → /storage/emulated/0。鸿蒙卓易通容器里这条
    // 路径可能没有 /Android/data/ 标记，推导失败回 null 降级。
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return null;
      const marker = '/Android/data/';
      final idx = ext.path.indexOf(marker);
      if (idx <= 0) return null;
      final dir = Directory(ext.path.substring(0, idx));
      if (dir.existsSync()) return dir;
    } catch (_) {
      return null;
    }
    return null;
  }

  static Future<bool> _defaultHasAllFilesAccess() async {
    try {
      return await _deviceChannel.invokeMethod<bool>('hasAllFilesAccess') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _defaultRequestAllFilesAccess() async {
    await _deviceChannel.invokeMethod<void>('openAllFilesSettings');
  }

  Future<MytvBindResult> _resolve() async {
    final docs = await _documentsDir();
    Directory? externalRoot;
    try {
      externalRoot = await _externalRoot();
    } catch (_) {
      externalRoot = null;
    }
    if (externalRoot == null) {
      return _fallbackResult(docs, '外部存储不可用');
    }
    final mytvRoot = Directory(path.join(externalRoot.path, mytvFolderName));
    final jsonDir = Directory(path.join(mytvRoot.path, mytvDbFolderName));
    final m3uDir = Directory(path.join(mytvRoot.path, mytvM3uFolderName));
    // 建目录：没权限时这里就抛 EACCES（Android 11+ 根目录写要
    // 所有文件访问权限），进下面的权限分支。
    try {
      jsonDir.createSync(recursive: true);
      m3uDir.createSync(recursive: true);
      // 写探针：目录建得出来不等于写得进去，实写一次才算数。
      final probe = File(path.join(jsonDir.path, '.mytv_probe'));
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      var granted = false;
      try {
        granted = await _hasAllFilesAccess();
      } catch (_) {
        granted = false;
      }
      if (!granted) {
        return _fallbackResult(
          docs,
          '没有所有文件访问权限',
          needsPermission: true,
        );
      }
      return _fallbackResult(docs, 'MYTV 文件夹写不进去');
    }
    // 老 json 影子文件拷进 MYTV/db（只补没有的，不覆盖已有的；
    // 拷失败不影响绑定；用户自己的现爬文件，不是内置数据）。
    try {
      final legacyJsonDir = Directory(
        path.join(docs.path, legacyJsonDirName),
      );
      if (legacyJsonDir.existsSync()) {
        for (final entity in legacyJsonDir.listSync()) {
          if (entity is! File) continue;
          if (!path.basename(entity.path).endsWith('.json')) continue;
          final target = File(path.join(jsonDir.path, path.basename(entity.path)));
          if (!target.existsSync()) {
            await entity.copy(target.path);
          }
        }
      }
    } catch (_) {
      // json 拷失败不影响绑定。
    }
    return MytvBindResult(
      bound: true,
      needsPermission: false,
      m3uDir: m3uDir,
      jsonDir: jsonDir,
      mergedJsonExportPath: path.join(
        mytvRoot.path,
        mytvMergedJsonFileName,
      ),
    );
  }

  /// 未绑定结果：json/m3u 兜底走 documents 下的旧目录。
  MytvBindResult _fallbackResult(
    Directory docs,
    String? note, {
    bool needsPermission = false,
  }) {
    return MytvBindResult(
      bound: false,
      needsPermission: needsPermission,
      m3uDir: Directory(path.join(docs.path, legacyJsonDirName)),
      jsonDir: Directory(path.join(docs.path, legacyJsonDirName)),
      mergedJsonExportPath: path.join(docs.path, mytvMergedJsonFileName),
      note: note,
    );
  }
}
