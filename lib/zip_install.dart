import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'core_bridge.dart';
import 'import_center.dart';
import 'jar_import.dart';
import 'local_store.dart';
import 'm3u_subscriptions.dart';
import 'miniapp/mini_app_store.dart';
import 'zip_contents.dart';

/// 选择安装的执行器：只装选择器勾选的条目，逐个报成败。
///
/// 三条通道全部复用已有 machinery，不另写安装实现：
/// - 影视源 / 组件（py/jar/js/json/整包 zip）：ImportEngine.importAll，
///   jar 同款跳过语义与 PluginShareInstallRunner / 市场屏同款；
/// - 直播列表：M3uSubscriptionService.build + syncM3uSubscriptions，
///   与导入中心 m3u 文件导入同款；
/// - 组件（小程序）：MiniAppStore.installFromZipBytes /
///   installFromManifestJson，与小程序市场同款。

typedef ZipImportCandidatesFn =
    Future<ImportReport> Function(List<ImportCandidate> candidates);

typedef ZipJarDuplicateCheck = String? Function(List<int> jarBytes);

typedef ZipLiveInstallFn = Future<ImportOutcome> Function(ZipPickItem item);

typedef ZipMiniAppInstallFn = Future<ImportOutcome> Function(ZipPickItem item);

class ZipPickInstaller {
  ZipPickInstaller({
    required this.importCandidates,
    required this.installLiveList,
    required this.installMiniApp,
    ZipJarDuplicateCheck? jarDuplicateCheck,
  }) : _jarDuplicateCheck = jarDuplicateCheck ?? _defaultJarDuplicateCheck;

  final ZipImportCandidatesFn importCandidates;
  final ZipLiveInstallFn installLiveList;
  final ZipMiniAppInstallFn installMiniApp;
  final ZipJarDuplicateCheck _jarDuplicateCheck;

  static String? _defaultJarDuplicateCheck(List<int> bytes) {
    final group = JarImport.groupForJarMd5(md5.convert(bytes).toString());
    return group?.displayName;
  }

  /// 真机默认安装器：三条通道接应用内的 store / repository。
  factory ZipPickInstaller.forApp({
    required LocalStore store,
    required AppRepository repository,
  }) {
    return ZipPickInstaller(
      importCandidates: (candidates) =>
          ImportEngine(store: store, repository: repository).importAll(candidates),
      installLiveList: (item) => _installLiveList(store, item),
      installMiniApp: (item) => _installMiniApp(item),
    );
  }

  static Future<ImportOutcome> _installLiveList(
    LocalStore store,
    ZipPickItem item,
  ) async {
    try {
      final text = utf8.decode(item.bytes, allowMalformed: true);
      final name = item.installName.replaceAll(
        RegExp(r'\.(m3u8?|txt)$', caseSensitive: false),
        '',
      );
      final record = await M3uSubscriptionService.build(
        name: name.isEmpty ? '未命名订阅' : name,
        kind: M3uSubscription.kindFile,
        text: text,
        rawBytes: item.bytes,
      );
      await store.syncM3uSubscriptions([
        ...store.m3uSubscriptions,
        record,
      ]);
      return ImportOutcome(
        fileName: item.name,
        status: ImportOutcomeStatus.success,
        reason:
            '已导入直播列表：${record.channelCount} 个频道 / ${record.groupCount} 个分类，已进入直播区',
        siteName: record.name,
      );
    } catch (error) {
      return ImportOutcome(
        fileName: item.name,
        status: ImportOutcomeStatus.failed,
        reason: error.toString(),
      );
    }
  }

  static Future<ImportOutcome> _installMiniApp(ZipPickItem item) async {
    try {
      final manifest = item.installKind == ZipInstallKind.miniappManifest
          ? await MiniAppStore().installFromManifestJson(
              utf8.decode(item.bytes),
            )
          : await MiniAppStore().installFromZipBytes(item.bytes);
      return ImportOutcome(
        fileName: item.name,
        status: ImportOutcomeStatus.success,
        reason: '已安装小程序「${manifest.name}」',
        siteName: manifest.name,
      );
    } catch (error) {
      return ImportOutcome(
        fileName: item.name,
        status: ImportOutcomeStatus.failed,
        reason: error.toString(),
      );
    }
  }

  /// 安装勾选的条目：结果顺序与传入顺序一致，未勾选的绝不出现。
  /// 混入无法识别的条目时直接记失败，不调用任何安装通道。
  Future<ImportReport> install(List<ZipPickItem> selected) async {
    final outcomes = List<ImportOutcome?>.filled(selected.length, null);
    final candidates = <ImportCandidate>[];
    final candidateIndex = <int>[];
    final seenJarMd5 = <String>{};
    for (var i = 0; i < selected.length; i++) {
      final item = selected[i];
      if (!item.installable) {
        outcomes[i] = ImportOutcome(
          fileName: item.name,
          status: ImportOutcomeStatus.failed,
          reason: '无法识别，不安装',
        );
        continue;
      }
      switch (item.installKind) {
        case ZipInstallKind.importEngine:
          if (item.installName.toLowerCase().endsWith('.jar')) {
            final digest = md5.convert(item.bytes).toString();
            final installed = _jarDuplicateCheck(item.bytes);
            if (installed != null) {
              outcomes[i] = ImportOutcome(
                fileName: item.name,
                status: ImportOutcomeStatus.duplicate,
                reason: '与已安装的「$installed」相同，跳过',
                siteName: installed,
              );
              continue;
            }
            if (!seenJarMd5.add(digest)) {
              outcomes[i] = ImportOutcome(
                fileName: item.name,
                status: ImportOutcomeStatus.duplicate,
                reason: '与包内另一同款 jar 相同，跳过',
              );
              continue;
            }
          }
          candidates.add(
            ImportCandidate(name: item.installName, bytes: item.bytes),
          );
          candidateIndex.add(i);
        case ZipInstallKind.liveList:
          outcomes[i] = await installLiveList(item);
        case ZipInstallKind.miniappZip:
        case ZipInstallKind.miniappManifest:
          outcomes[i] = await installMiniApp(item);
      }
    }
    if (candidates.isNotEmpty) {
      final report = await importCandidates(candidates);
      for (var k = 0; k < report.outcomes.length; k++) {
        outcomes[candidateIndex[k]] = report.outcomes[k];
      }
    }
    return ImportReport([
      for (var i = 0; i < selected.length; i++)
        outcomes[i] ??
            ImportOutcome(
              fileName: selected[i].name,
              status: ImportOutcomeStatus.failed,
              reason: '未处理',
            ),
    ]);
  }
}
