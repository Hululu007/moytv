import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 女优库绑定手机根目录下的 MYTV 文件夹（2026-11-20 用户令）。
///
/// 落点（2026-11-20 19:24 落点冲突定版：MYTV/db 里有两个库）：
/// - `MYTV/db/女优库应用.db`：应用自己的女优库 sqflite 库
///   （persons / works 表，兜底库），取代原来 documents/actress.db
///   的位置；表结构、索引、Schema 版本与原来完全一致（works 唯一
///   键仍是 (person_id, site, code_key)），只是文件落点换了。
/// - `MYTV/db/女优库.db`：用户发来的视频结构库（videos /
///   video_actress / actresses 表），是用户要绑定的数据库，
///   应用库绝不写它；它由通用读库层探结构读、由数据库镜像按
///   合并规则递增追加进应用库（见 actress_db_mirror.dart）。
/// - `MYTV/db/mjv011.json`：本地 json 影子文件（现爬写盘入口，
///   与原来 documents/actress_json/mjv011.json 同一口径）。
/// - `MYTV/m3u/`：用户自己放 m3u 文件的地方（女优合集1.m3u～
///   9.m3u 这种），m3u 兜底先读这里，读不到再回退包里内置分片。
///
/// 权限与降级（targetSdk 36）：直接写根目录要“所有文件访问权限”
/// （MANAGE_EXTERNAL_STORAGE）。没拿到权限时不硬写、不崩——
/// 回退用原来的 documents/actress.db，女优库照常能用，界面给去
/// 设置的入口；用户授权后点“重新绑定”再切过去。
///
/// 鸿蒙 NEXT（卓易通容器）：外部存储实际路径可能与原生安卓不同，
/// 根目录解析不到、或建目录失败时一律优雅降级回 documents，
/// 不在本机上假装验过——手机待验清单见 REPORT.md。
///
/// 本模块只算路径、建目录、做迁移，不碰界面、不直接开库：
/// 真正开库的是 [SqfliteActressDatabase._openNow]，它第一次开库
/// 前调 [ensureBound] 拿路径；列表页在 bootstrap 里先调一次，
/// 为的是提前拿到结果显示绑定行、给 json/m3u 指目录。
/// 迁移只在库还没打开时做：首次绑定在开库前跑；授权后重新绑定
/// 时列表页先关库再调 [ensureBound]（refresh: true）。

/// MYTV 文件夹名（手机根目录下）。
const mytvFolderName = 'MYTV';

/// MYTV 下的两个子文件夹。
const mytvDbFolderName = 'db';
const mytvM3uFolderName = 'm3u';

/// 涩库引擎（py 的 SikuEngine.DB_DIRS）同款补充扫描目录：手机根
/// 目录下这 4 个目录里的 .db 都当女优库源读（递归扫，与 py 的
/// os.walk 一致）。MYTV/db 仍是主目录（绑定落点），这 4 个是
/// 补充——2026-11-21 用户令按 py 逻辑读库、改路径。
const sikuDbScanDirs = ['纯福利/db', '女优库', '私藏视频', 'lz/db'];

/// MYTV/db 里的应用库文件名（2026-11-20 19:24 落点冲突定版）：
/// `女优库.db` 这个名字归用户发来的视频结构库（videos /
/// video_actress / actresses 表，735MB 成品），应用自己的
/// persons / works 表 sqflite 库改落 `女优库应用.db`，别跟
/// 用户的库撞名、绝不能覆盖它。读库与迁移逻辑都跟这个常量走。
const mytvDbFileName = '女优库应用.db';

/// 老库文件名（documents 下，迁移后留着当备份，不删）。
const legacyDbFileName = 'actress.db';

/// 老 json 影子文件目录名（documents 下）。
const legacyJsonDirName = 'actress_json';

/// MYTV 根目录下的合并 JSON 导出落点（不碰 MYTV/db 里正在用的
/// 影子文件，导出只写这一份，用户拷走即用）。
const mytvMergedJsonFileName = 'mjv011.json';

/// 外部存储根目录解析：默认先走平台通道拿真根目录，拿不到再从
/// getExternalStorageDirectory 的应用专属目录往上推（去
/// `/Android/data/<包名>/files` 后缀）；两条路都走不通回 null，
/// 调用方降级回 documents。
typedef MytvExternalRootResolver = Future<Directory?> Function();

/// “所有文件访问权限”是否已授予。
typedef MytvAllFilesAccessChecker = Future<bool> Function();

/// 打开系统“所有文件访问权限”设置页。
typedef MytvAllFilesSettingsOpener = Future<void> Function();

/// documents 目录解析。
typedef MytvDocumentsResolver = Future<Directory> Function();

/// 读一个 sqlite 文件里 persons/works 两张表的行数（只读打开，
/// 读完即关）。表不存在或文件不是合法库时抛错，调用方按迁移
/// 失败处理（不丢数据、不切库）。
typedef MytvDbRowCounter =
    Future<({int persons, int works})> Function(String dbPath);

/// 一次绑定解析的结果：列表页显示绑定行、给 json/m3u 指目录、
/// 导出合并 JSON 落点都用它。
class MytvBindResult {
  const MytvBindResult({
    required this.bound,
    required this.needsPermission,
    required this.root,
    this.externalRoot,
    required this.dbDir,
    required this.m3uDir,
    required this.jsonDir,
    required this.dbPath,
    required this.displayPath,
    required this.mergedJsonExportPath,
    required this.legacyDbPath,
    this.note,
    this.migrated = false,
    this.migratedPersons = 0,
    this.migratedWorks = 0,
  });

  /// true = MYTV 可用，库与 json 都走 MYTV；false = 降级回
  /// documents（原因见 [note]），女优库照常能用。
  final bool bound;

  /// true = 没拿到所有文件访问权限，用户去设置授权后点
  /// “重新绑定”可再试一次。
  final bool needsPermission;

  /// MYTV 根目录（未绑定时是 documents 目录，仅作展示与
  /// 导出路径拼接用）。
  final Directory root;

  /// 外部存储根目录（/storage/emulated/0，绑定成功时才有）：
  /// 补充扫描目录（[sikuDbScanDirs]）从这里拼。未绑定/降级时
  /// 为 null，镜像只扫主目录。
  final Directory? externalRoot;

  /// 库目录：MYTV/db 或 documents。
  final Directory dbDir;

  /// m3u 目录：MYTV/m3u 或 documents（未绑定时 m3u 兜底只走
  /// 包里内置分片，这个目录不用）。
  final Directory m3uDir;

  /// json 影子文件目录：MYTV/db 或 documents/actress_json。
  final Directory jsonDir;

  /// 实际开库路径：MYTV/db/女优库应用.db 或 documents/actress.db。
  final String dbPath;

  /// 界面显示的库落点：'MYTV/db/女优库应用.db' 或
  /// '内部存储/actress.db'。
  final String displayPath;

  /// 合并 JSON 导出落点：MYTV/mjv011.json（只在 bound 时用）。
  final String mergedJsonExportPath;

  /// 内置回退库路径：documents/actress.db。开库时 MYTV 库损坏/
  /// 打不开就回退到这里（2026-11-20 用户令“全部使用数据库
  /// 兜底”），与 [dbPath] 不同时才有意义；未绑定时等于 [dbPath]。
  final String legacyDbPath;

  /// 降级/迁移失败的原因（给界面提示用）；正常绑定时为空。
  final String? note;

  /// 本次是否迁移了老数据。
  final bool migrated;

  /// 迁移核对的行数（persons/works，迁移成功时才有意义）。
  final int migratedPersons;
  final int migratedWorks;
}

/// MYTV 绑定解析：路径、建目录、迁移老数据。
///
/// 平台调用全部包在 try/catch 里：测试环境没有平台通道、
/// 鸿蒙容器路径与原生不同，任何一步拿不到都降级回 documents，
/// 绝不抛错、绝不让女优库打不开。
class ActressMytvBind {
  ActressMytvBind({
    MytvExternalRootResolver? externalRoot,
    MytvAllFilesAccessChecker? hasAllFilesAccess,
    MytvAllFilesSettingsOpener? requestAllFilesAccess,
    MytvDocumentsResolver? documentsDir,
    MytvDbRowCounter? countDbRows,
  }) : _externalRoot = externalRoot ?? _defaultExternalRoot,
       _hasAllFilesAccess = hasAllFilesAccess ?? _defaultHasAllFilesAccess,
       _requestAllFilesAccess =
           requestAllFilesAccess ?? _defaultRequestAllFilesAccess,
       _documentsDir = documentsDir ?? _defaultDocumentsDir,
       _countDbRows = countDbRows ?? _defaultCountDbRows;

  static final instance = ActressMytvBind._();

  ActressMytvBind._()
    : _externalRoot = _defaultExternalRoot,
      _hasAllFilesAccess = _defaultHasAllFilesAccess,
      _requestAllFilesAccess = _defaultRequestAllFilesAccess,
      _documentsDir = _defaultDocumentsDir,
      _countDbRows = _defaultCountDbRows;

  static const _deviceChannel = MethodChannel('moyi/device');

  final MytvExternalRootResolver _externalRoot;
  final MytvAllFilesAccessChecker _hasAllFilesAccess;
  final MytvAllFilesSettingsOpener _requestAllFilesAccess;
  final MytvDocumentsResolver _documentsDir;
  final MytvDbRowCounter _countDbRows;

  MytvBindResult? _cached;
  Future<MytvBindResult>? _pending;

  /// 上次解析结果（首次解析前为空）。
  MytvBindResult? get current => _cached;

  /// 解析一次绑定（结果缓存，并发调用共用同一份）。
  /// [refresh] 为 true 时重新解析（授权后重新绑定用；调用前
  /// 列表页须先关库——迁移要拷老库文件，开着库拷不干净）。
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

  static Future<({int persons, int works})> _defaultCountDbRows(
    String dbPath,
  ) async {
    final db = await openDatabase(dbPath, readOnly: true);
    try {
      final persons = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM persons',
      );
      final works = await db.rawQuery('SELECT COUNT(*) AS c FROM works');
      return (
        persons: (persons.first['c'] as num?)?.toInt() ?? 0,
        works: (works.first['c'] as num?)?.toInt() ?? 0,
      );
    } finally {
      await db.close();
    }
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
      return _fallbackResult(docs, '外部存储不可用，仍用内部存储');
    }
    final mytvRoot = Directory(path.join(externalRoot.path, mytvFolderName));
    final dbDir = Directory(path.join(mytvRoot.path, mytvDbFolderName));
    final m3uDir = Directory(path.join(mytvRoot.path, mytvM3uFolderName));
    // 建目录：没权限时这里就抛 EACCES（Android 11+ 根目录写要
    // 所有文件访问权限），进下面的权限分支。
    try {
      dbDir.createSync(recursive: true);
      m3uDir.createSync(recursive: true);
      // 写探针：目录建得出来不等于写得进去，实写一次才算数。
      final probe = File(path.join(dbDir.path, '.mytv_probe'));
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
        final result = _fallbackResult(docs, '没有所有文件访问权限');
        return MytvBindResult(
          bound: result.bound,
          needsPermission: true,
          root: result.root,
          externalRoot: result.externalRoot,
          dbDir: result.dbDir,
          m3uDir: result.m3uDir,
          jsonDir: result.jsonDir,
          dbPath: result.dbPath,
          displayPath: result.displayPath,
          mergedJsonExportPath: result.mergedJsonExportPath,
          legacyDbPath: result.legacyDbPath,
          note: result.note,
        );
      }
      return _fallbackResult(docs, 'MYTV 文件夹写不进去，仍用内部存储');
    }
    // 迁移老数据（只在目标库还没建好时做一次）。
    final targetDb = File(path.join(dbDir.path, mytvDbFileName));
    var migrated = false;
    var migratedPersons = 0;
    var migratedWorks = 0;
    String? note;
    var useTarget = true;
    final legacyDb = File(path.join(docs.path, legacyDbFileName));
    final targetReady = targetDb.existsSync() && targetDb.lengthSync() > 0;
    if (!targetReady && legacyDb.existsSync() && legacyDb.lengthSync() > 0) {
      try {
        await legacyDb.copy(targetDb.path);
        final before = await _countDbRows(legacyDb.path);
        final after = await _countDbRows(targetDb.path);
        if (before.persons == after.persons &&
            before.works == after.works) {
          migrated = true;
          migratedPersons = after.persons;
          migratedWorks = after.works;
        } else {
          // 行数对不上：删掉拷过去的半成品，留在旧库继续用，
          // 老文件不动，不丢数据。
          await targetDb.delete();
          useTarget = false;
          note =
              '迁移核对行数不一致（旧库 ${before.persons} 人 / '
              '${before.works} 部），仍用旧库';
        }
      } catch (_) {
        try {
          if (targetDb.existsSync()) await targetDb.delete();
        } catch (_) {
          // 删不掉半成品也不崩：下次绑定目标库是空文件会重拷。
        }
        useTarget = false;
        note = '迁移老数据失败，仍用旧库';
      }
    }
    // 老 json 影子文件拷进 MYTV/db（只补没有的，不覆盖已有的；
    // 拷失败不影响绑定，json 读时本来就有内置兜底）。
    try {
      final legacyJsonDir = Directory(
        path.join(docs.path, legacyJsonDirName),
      );
      if (legacyJsonDir.existsSync()) {
        for (final entity in legacyJsonDir.listSync()) {
          if (entity is! File) continue;
          if (!path.basename(entity.path).endsWith('.json')) continue;
          final target = File(path.join(dbDir.path, path.basename(entity.path)));
          if (!target.existsSync()) {
            await entity.copy(target.path);
          }
        }
      }
    } catch (_) {
      // json 拷失败不影响绑定。
    }
    if (!useTarget) {
      final result = _fallbackResult(docs, note);
      return result;
    }
    return MytvBindResult(
      bound: true,
      needsPermission: false,
      root: mytvRoot,
      externalRoot: externalRoot,
      dbDir: dbDir,
      m3uDir: m3uDir,
      jsonDir: dbDir,
      dbPath: targetDb.path,
      displayPath: '$mytvFolderName/$mytvDbFolderName/$mytvDbFileName',
      mergedJsonExportPath: path.join(
        mytvRoot.path,
        mytvMergedJsonFileName,
      ),
      legacyDbPath: path.join(docs.path, legacyDbFileName),
      note: note,
      migrated: migrated,
      migratedPersons: migratedPersons,
      migratedWorks: migratedWorks,
    );
  }

  /// 降级结果：库与 json 都走原来的 documents 位置，m3u 兜底
  /// 只走包里内置分片。
  MytvBindResult _fallbackResult(Directory docs, String? note) {
    return MytvBindResult(
      bound: false,
      needsPermission: false,
      root: docs,
      dbDir: docs,
      m3uDir: Directory(path.join(docs.path, legacyJsonDirName)),
      jsonDir: Directory(path.join(docs.path, legacyJsonDirName)),
      dbPath: path.join(docs.path, legacyDbFileName),
      displayPath: '内部存储/$legacyDbFileName',
      mergedJsonExportPath: path.join(docs.path, mytvMergedJsonFileName),
      legacyDbPath: path.join(docs.path, legacyDbFileName),
      note: note,
    );
  }
}
