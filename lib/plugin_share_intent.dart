import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'import_center.dart';
import 'jar_import.dart';
import 'local_store.dart';
import 'plugin_manager.dart';
import 'shared_json_import.dart';
import 'zip_install.dart';
import 'zip_pick_screen.dart';

/// 外部插件文件“打开方式”安装：点 .jar/.py/.zip 文件选魔蚁打开时，
/// 原生侧把 URI 交到这里，读流后走与插件市场同一套安装路径
/// （ImportEngine.importAll），不另写安装实现。
///
/// 落盘位置与市场安装相同：ImportEngine 内部经 ImportFileStore
/// 写进应用文档目录下的 imported_spiders（py/js/json）或
/// JarBridgeHandoff（jar/zip 包），这里不自行拷文件。

/// 与原生侧约定的通道名，须与 MainActivity 的注册一致。
const pluginShareChannelName = 'moyi/plugin_share';

/// 原生侧排队的一个待安装文件：只有 URI 与显示名，没有文件路径，
/// Flutter 侧一律经 [PluginShareChannel.readBytes] 读流。
/// [kind] 是原生侧给的种类标记：JSON 文件为 'json'（走内容分流
/// 导入，不走插件安装）；py/jar/zip 不带标记，留空。
class PluginShareFile {
  const PluginShareFile({required this.uri, required this.name, this.kind = ''});

  final String uri;
  final String name;
  final String kind;

  factory PluginShareFile.fromJson(Map<String, dynamic> json) =>
      PluginShareFile(
        uri: json['uri'] as String? ?? '',
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
      );
}

/// URI/文件名到安装路由的判定结果。
enum PluginShareDecision { installJar, installPy, installZip, reject }

PluginShareDecision _decisionForExtension(String extension) {
  switch (extension) {
    case 'jar':
      return PluginShareDecision.installJar;
    case 'py':
      return PluginShareDecision.installPy;
    case 'zip':
      return PluginShareDecision.installZip;
    default:
      return PluginShareDecision.reject;
  }
}

bool _isPluginExtension(String extension) =>
    extension == 'jar' || extension == 'py' || extension == 'zip';

/// 取文件名的扩展名（小写）：无后缀、末尾是点、扩展名含非
/// 字母数字时返回空串。大小写不敏感。
String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  final extension = name.substring(dot + 1).toLowerCase();
  if (extension.contains(RegExp(r'[^a-z0-9]'))) return '';
  return extension;
}

/// 从 URI 取最后一段路径（去掉查询参数与 fragment，并解开百分号编码）。
String _fileNameFromUri(String uri) {
  var rest = uri;
  final query = rest.indexOf('?');
  if (query >= 0) rest = rest.substring(0, query);
  final fragment = rest.indexOf('#');
  if (fragment >= 0) rest = rest.substring(0, fragment);
  final slash = rest.lastIndexOf('/');
  final segment = slash >= 0 ? rest.substring(slash + 1) : rest;
  try {
    return Uri.decodeFull(segment);
  } catch (_) {
    return segment;
  }
}

/// 判定一个分享文件是否路由到安装：先看显示名后缀，显示名
/// 无插件后缀时再看 URI 路径后缀（content:// 不透明 URI 靠显示名，
/// 显示名缺失时靠 URI）。其余一律拒绝。
/// 内容合法性（jar 文件头、py 蜘蛛校验）由 ImportEngine 最终把关。
PluginShareDecision decidePluginShareRoute(String uri, {String? fileName}) {
  final nameExtension = _extensionOf((fileName ?? '').trim());
  if (_isPluginExtension(nameExtension)) {
    return _decisionForExtension(nameExtension);
  }
  final uriExtension = _extensionOf(_fileNameFromUri(uri));
  if (_isPluginExtension(uriExtension)) {
    return _decisionForExtension(uriExtension);
  }
  return PluginShareDecision.reject;
}

/// 安装时用的文件名：显示名带插件后缀就用显示名，否则用 URI
/// 最后一段（ImportEngine 靠文件名后缀分流，名字必须带后缀）。
String pluginShareInstallName(String uri, String? fileName) {
  final candidate = (fileName ?? '').trim();
  if (_isPluginExtension(_extensionOf(candidate))) return candidate;
  final segment = _fileNameFromUri(uri);
  if (segment.isNotEmpty) return segment;
  return candidate;
}

/// 安装回调：与 ImportEngine.importAll 同签名，可注入假函数测试。
typedef PluginShareImportFn =
    Future<ImportReport> Function(List<ImportCandidate> candidates);

/// jar 同款已安装检查：返回已安装组的显示名，未安装返回 null。
typedef PluginShareJarDuplicateCheck = String? Function(List<int> jarBytes);

/// 插件分享安装执行器：单文件安装走这里；zip 经选择器勾选后，
/// 勾选的条目由 ZipPickInstaller 安装（本类的 zip 批量逻辑保留，
/// 供直接调用与测试）。行为与插件市场屏同款——单 jar 同款跳过、
/// zip 展开逐个安装逐个汇报、包内同款 jar 跳过；真正的校验、落盘
/// 与注册全交给注入的 [importCandidates]（默认 ImportEngine.importAll），
/// 这里不另写一套。
class PluginShareInstallRunner {
  PluginShareInstallRunner({
    required this.importCandidates,
    PluginShareJarDuplicateCheck? jarDuplicateCheck,
  }) : _jarDuplicateCheck = jarDuplicateCheck ?? _defaultJarDuplicateCheck;

  final PluginShareImportFn importCandidates;
  final PluginShareJarDuplicateCheck _jarDuplicateCheck;

  static String? _defaultJarDuplicateCheck(List<int> bytes) {
    final group = JarImport.groupForJarMd5(md5.convert(bytes).toString());
    return group?.displayName;
  }

  Future<ImportReport> install(String fileName, List<int> bytes) async {
    final decision = decidePluginShareRoute('', fileName: fileName);
    if (decision == PluginShareDecision.reject) {
      return ImportReport([
        ImportOutcome(
          fileName: fileName,
          status: ImportOutcomeStatus.failed,
          reason: '不是插件文件',
        ),
      ]);
    }
    if (decision == PluginShareDecision.installZip) {
      return _installZip(fileName, bytes);
    }
    if (decision == PluginShareDecision.installJar) {
      final installed = _jarDuplicateCheck(bytes);
      if (installed != null) {
        return ImportReport([
          ImportOutcome(
            fileName: fileName,
            status: ImportOutcomeStatus.duplicate,
            reason: '「$installed」已安装，跳过，不重复注册',
            siteName: installed,
          ),
        ]);
      }
    }
    return importCandidates([ImportCandidate(name: fileName, bytes: bytes)]);
  }

  Future<ImportReport> _installZip(String fileName, List<int> bytes) async {
    final List<PluginZipEntry> entries;
    try {
      entries = expandPluginZip(bytes);
    } catch (error) {
      return ImportReport([
        ImportOutcome(
          fileName: fileName,
          status: ImportOutcomeStatus.failed,
          reason: 'zip 解包失败：$error',
        ),
      ]);
    }
    if (entries.isEmpty) {
      return ImportReport([
        ImportOutcome(
          fileName: fileName,
          status: ImportOutcomeStatus.failed,
          reason: 'zip 里没有找到 .jar/.py 插件文件',
        ),
      ]);
    }
    if (entries.length == 1 && entries.first.isJar) {
      // 单 jar 包：走既有 zip 包路径（包内配置与附加文件语义不变），
      // 传原始 zip 字节与 zip 文件名，与市场屏同款。
      return importCandidates([ImportCandidate(name: fileName, bytes: bytes)]);
    }
    final outcomes = List<ImportOutcome?>.filled(entries.length, null);
    final candidates = <ImportCandidate>[];
    final candidateEntryIndex = <int>[];
    final seenJarMd5 = <String>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.isJar) {
        final digest = md5.convert(entry.bytes).toString();
        final installed = _jarDuplicateCheck(entry.bytes);
        if (installed != null) {
          outcomes[i] = ImportOutcome(
            fileName: entry.name,
            status: ImportOutcomeStatus.duplicate,
            reason: '与已安装的「$installed」相同，跳过',
            siteName: installed,
          );
          continue;
        }
        if (!seenJarMd5.add(digest)) {
          outcomes[i] = ImportOutcome(
            fileName: entry.name,
            status: ImportOutcomeStatus.duplicate,
            reason: '与包内另一同款 jar 相同，跳过',
          );
          continue;
        }
      }
      candidates.add(ImportCandidate(name: entry.name, bytes: entry.bytes));
      candidateEntryIndex.add(i);
    }
    if (candidates.isNotEmpty) {
      final report = await importCandidates(candidates);
      for (var k = 0; k < report.outcomes.length; k++) {
        outcomes[candidateEntryIndex[k]] = report.outcomes[k];
      }
    }
    return ImportReport([
      for (var i = 0; i < entries.length; i++)
        outcomes[i] ??
            ImportOutcome(
              fileName: entries[i].name,
              status: ImportOutcomeStatus.failed,
              reason: '未处理',
            ),
    ]);
  }
}

/// 插件分享通道：takePending 取原生侧排队的 URI，readBytes 按 URI 读流。
/// readBytes 失败时抛 PlatformException（file_too_large/unreadable 等），
/// 由调用方转成提示；takePending 轮询失败时返回空，不惊动启动流程。
class PluginShareChannel {
  PluginShareChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(pluginShareChannelName);

  final MethodChannel _channel;

  Future<List<PluginShareFile>> takePending() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('takePending');
      if (raw == null) return const [];
      return [
        for (final item in raw)
          if (item is Map)
            PluginShareFile.fromJson(Map<String, dynamic>.from(item)),
      ].where((file) => file.uri.isNotEmpty).toList();
    } on MissingPluginException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<Uint8List> readBytes(String uri) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readBytes', {
      'uri': uri,
    });
    return bytes ?? Uint8List(0);
  }
}

/// 插件分享监听入口：main.dart 启动初始化时调一次 [start]，之后
/// 首帧与每次回到前台都排空原生侧队列（冷启动与热启动都覆盖）。
class PluginShareIntent {
  PluginShareIntent._();

  static _PluginShareController? _controller;

  static void start({
    required LocalStore store,
    required AppRepository repository,
    required GlobalKey<NavigatorState> navigatorKey,
    PluginShareChannel? channel,
    PluginShareInstallRunner? runner,
    ZipPickInstaller? zipInstaller,
    SharedJsonImportHandler? jsonHandler,
  }) {
    if (_controller != null) return;
    final controller = _PluginShareController(
      store: store,
      navigatorKey: navigatorKey,
      channel: channel ?? PluginShareChannel(),
      runner:
          runner ??
          PluginShareInstallRunner(
            importCandidates: (candidates) => ImportEngine(
              store: store,
              repository: repository,
            ).importAll(candidates),
          ),
      zipInstaller:
          zipInstaller ??
          ZipPickInstaller.forApp(store: store, repository: repository),
      jsonHandler:
          jsonHandler ?? SharedJsonImportHandler(repository: repository),
    );
    _controller = controller;
    controller.start();
  }

  @visibleForTesting
  static void resetForTest() {
    _controller?.dispose();
    _controller = null;
  }
}

class _PluginShareController with WidgetsBindingObserver {
  _PluginShareController({
    required this.store,
    required this.navigatorKey,
    required this.channel,
    required this.runner,
    required this.zipInstaller,
    required this.jsonHandler,
  });

  final LocalStore store;
  final GlobalKey<NavigatorState> navigatorKey;
  final PluginShareChannel channel;
  final PluginShareInstallRunner runner;
  final ZipPickInstaller zipInstaller;
  final SharedJsonImportHandler jsonHandler;
  final _processing = <String>{};
  bool _draining = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_drain()));
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_drain());
  }

  BuildContext? get _context => navigatorKey.currentContext;

  Future<void> _drain() async {
    if (_draining) return;
    // 界面未就绪或用户未解锁时不取队列，留待下次回到前台再排空。
    if (_context == null || store.locked) return;
    _draining = true;
    try {
      final pending = await channel.takePending();
      for (final file in pending) {
        if (_processing.contains(file.uri)) continue;
        _processing.add(file.uri);
        try {
          await _handle(file);
        } finally {
          _processing.remove(file.uri);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _handle(PluginShareFile file) async {
    // JSON 文件不走插件安装：按内容分流到小程序/书源/配置导入。
    if (file.kind == 'json') {
      await _handleJson(file);
      return;
    }
    final decision = decidePluginShareRoute(file.uri, fileName: file.name);
    if (decision == PluginShareDecision.reject) {
      _showSnack('文件「${file.name}」不是插件文件');
      return;
    }
    final installName = pluginShareInstallName(file.uri, file.name);
    Uint8List bytes;
    try {
      bytes = await channel.readBytes(file.uri);
    } on PlatformException catch (error) {
      _showSnack('文件「$installName」无法读取：${error.message ?? error.code}');
      return;
    } catch (_) {
      _showSnack('文件「$installName」无法读取');
      return;
    }
    if (bytes.isEmpty) {
      _showSnack('文件「$installName」无法导入：文件为空');
      return;
    }
    if (decision == PluginShareDecision.installZip) {
      // zip 不再自动批量全装：先开选择器，列出识别到的影视源 /
      // 直播列表 / 组件，用户勾选后再装（结果弹窗由选择器自己出）。
      final context = _context;
      if (context == null || !context.mounted) return;
      final changed = await openZipPicker(
        context: context,
        zipName: installName,
        zipBytes: bytes,
        installer: zipInstaller,
      );
      if (changed) store.refreshSiteRegistry();
      return;
    }
    final report = await runner.install(installName, bytes);
    // 与市场屏 _afterRegistryChange 同款：通知全部站点列表立即刷新。
    store.refreshSiteRegistry();
    _showReport(report);
  }

  /// JSON 分享：读流后按内容分流，提示文案由分流器按各路
  /// 应用内导入的口径返回。读流上限与插件文件同一条
  /// （原生侧 32MB），这里不另设。
  Future<void> _handleJson(PluginShareFile file) async {
    final displayName = file.name.trim().isNotEmpty
        ? file.name.trim()
        : (_fileNameFromUri(file.uri).isNotEmpty
              ? _fileNameFromUri(file.uri)
              : 'import.json');
    Uint8List bytes;
    try {
      bytes = await channel.readBytes(file.uri);
    } on PlatformException catch (error) {
      _showSnack('文件「$displayName」无法读取：${error.message ?? error.code}');
      return;
    } catch (_) {
      _showSnack('文件「$displayName」无法读取');
      return;
    }
    if (bytes.isEmpty) {
      _showSnack('文件「$displayName」无法导入：文件为空');
      return;
    }
    final message = await jsonHandler.handle(bytes, fileName: displayName);
    _showSnack(message);
  }

  void _showSnack(String message) {
    final context = _context;
    if (context == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _outcomeLabel(ImportOutcomeStatus status) {
    switch (status) {
      case ImportOutcomeStatus.success:
        return '成功';
      case ImportOutcomeStatus.duplicate:
        return '跳过';
      case ImportOutcomeStatus.failed:
        return '失败';
    }
  }

  void _showReport(ImportReport report) {
    if (report.outcomes.length > 1) {
      final context = _context;
      if (context != null) {
        // 批量安装结果弹窗：与市场屏 _showBatchReport 同款内容。
        unawaited(
          showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('批量安装结果'),
              content: SizedBox(
                width: double.maxFinite,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final outcome in report.outcomes)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            outcome.status == ImportOutcomeStatus.success
                                ? Icons.check_circle_outline
                                : outcome.status ==
                                      ImportOutcomeStatus.duplicate
                                ? Icons.skip_next_rounded
                                : Icons.error_outline,
                          ),
                          title: Text(outcome.fileName),
                          subtitle: Text(
                            '${_outcomeLabel(outcome.status)}：${outcome.reason}',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('知道了'),
                ),
              ],
            ),
          ),
        );
        return;
      }
    }
    // 单文件结果提示：与市场屏 _showReport 同款文案。
    final firstFailure = report.outcomes
        .where((item) => !item.ok)
        .map((item) => '${item.fileName}：${item.reason}')
        .join('\n');
    _showSnack(
      '成功 ${report.successCount} · 重复 ${report.duplicateCount} · '
      '失败 ${report.failedCount}'
      '${firstFailure.isEmpty ? '' : '\n$firstFailure'}',
    );
  }
}
