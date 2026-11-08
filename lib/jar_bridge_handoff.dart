import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'jar_import.dart';
import 'jar_site_config.dart';
import 'jar_zip.dart';
import 'tvbox_config.dart';

class JarBridgeHandoff {
  JarBridgeHandoff._();

  static const bool available = true;

  static Future<String> importTvBoxConfig({
    required AppRepository repository,
    required String name,
    required String content,
  }) async {
    final report = await TvBoxImporter(
      repository,
    ).importFromText(content, sourceIdentity: 'file:$name');
    if (report.apiSites + report.jarSites + report.pySites == 0) {
      throw AppFailure(
        'TVBox 配置未注册任何站点'
        '${report.notes.isEmpty ? '' : '：${report.notes.join('；')}'}',
      );
    }
    return '已导入 TVBox 配置「${report.name}」：${report.summary}';
  }

  static String _jarSummary({
    required int registered,
    required int enumerated,
    required List<String> updated,
    required List<String> configured,
    required List<String> missing,
    List<String> extraJsonNames = const [],
    List<String> skippedJarNames = const [],
  }) {
    final parts = <String>[
      'jar 新增注册 $registered 个站点（枚举 $enumerated 个类）',
    ];
    if (updated.isNotEmpty) parts.add('已更新 ${updated.length} 个已注册站点的配置');
    if (configured.isNotEmpty) {
      parts.add('已自动带上站点配置：${configured.join('、')}');
    }
    if (missing.isNotEmpty) {
      parts.add(
        '提醒：以下站点未找到站点配置，注册后可能跑不起来：${missing.join('、')}'
        '；可在导入中心条目上手动补填 ext',
      );
    }
    if (extraJsonNames.isNotEmpty) {
      parts.add('已随包保存附加 JSON：${extraJsonNames.join('、')}');
    }
    if (skippedJarNames.isNotEmpty) {
      parts.add('包内其余 jar 未导入：${skippedJarNames.join('、')}');
    }
    return parts.join('；');
  }

  static Future<List<JarSiteConfig>> siblingConfigsForJarFile(
    String jarPath,
  ) async {
    try {
      final directory = Directory(path.dirname(jarPath));
      if (!await directory.exists()) return const [];
      final configs = <JarSiteConfig>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.json')) continue;
        try {
          final text = await entity.readAsString();
          configs.addAll(parseJarSiteConfigs(text));
        } catch (_) {}
      }
      return configs;
    } catch (_) {
      return const [];
    }
  }

  static Future<
      ({String summary, List<String> siteIds, List<String> siteNames})>
      registerJar({
    required String name,
    required List<int> bytes,
    List<JarSiteConfig> configs = const [],
  }) async {
    final digest = md5.convert(bytes).toString();
    final directory = await getApplicationSupportDirectory();
    final jarDir = Directory(path.join(directory.path, 'imported_jars'));
    if (!await jarDir.exists()) await jarDir.create(recursive: true);
    final file = File(path.join(jarDir.path, '$digest.jar'));
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    final jarId = 'imp${digest.substring(0, 10)}';
    final result = await JarImport.scanAndRegister(
      jarId: jarId,
      jarUrl: file.path,
      jarMd5: digest,
      configs: configs,
      displayName: name,
    );
    final classes = result.all;
    final registered = result.newly.length;
    if (classes.where((info) => info.instantiable).isEmpty) {
      final details = [
        for (final info in classes)
          if (info.reason.isNotEmpty) '${info.simpleName}：${info.reason}',
      ];
      throw AppFailure(
        'jar 内未发现可实例化的 Spider 类（共枚举 ${classes.length} 个类）'
        '${details.isEmpty ? '' : '：${details.join('；')}'}',
      );
    }
    return (
      summary: _jarSummary(
        registered: registered,
        enumerated: classes.length,
        updated: result.updated,
        configured: result.configured,
        missing: result.missing,
      ),
      siteIds: result.newSiteIds,
      siteNames: [
        for (final id in result.newSiteIds)
          JarImport.siteFor(id)?.name ?? '',
      ],
    );
  }

  static Future<
      ({String summary, List<String> siteIds, List<String> siteNames})>
      registerZip({
    required String name,
    required List<int> bytes,
  }) async {
    final package = decodeJarZipPackage(bytes);
    final jarBytes = package.jarBytes;
    final digest = md5.convert(jarBytes).toString();
    final directory = await getApplicationSupportDirectory();
    final jarDir = Directory(path.join(directory.path, 'imported_jars'));
    if (!await jarDir.exists()) await jarDir.create(recursive: true);
    final file = File(path.join(jarDir.path, '$digest.jar'));
    if (!await file.exists()) await file.writeAsBytes(jarBytes, flush: true);
    final savedExtras = <String>[];
    for (final entry in package.extraJsonFiles.entries) {
      var target = File(path.join(jarDir.path, entry.key));
      if (await target.exists()) {
        final existing = await target.readAsBytes();
        if (existing.length != entry.value.length ||
            !_bytesEqual(existing, entry.value)) {
          target = File(
            path.join(jarDir.path, '${digest.substring(0, 6)}_${entry.key}'),
          );
        }
      }
      if (!await target.exists()) {
        await target.writeAsBytes(entry.value, flush: true);
      }
      savedExtras.add(path.basename(target.path));
    }
    final jarId = 'imp${digest.substring(0, 10)}';
    final result = await JarImport.scanAndRegister(
      jarId: jarId,
      jarUrl: file.path,
      jarMd5: digest,
      configs: package.configs,
      displayName: name,
    );
    final classes = result.all;
    if (classes.where((info) => info.instantiable).isEmpty) {
      final details = [
        for (final info in classes)
          if (info.reason.isNotEmpty) '${info.simpleName}：${info.reason}',
      ];
      throw AppFailure(
        'zip 包的 jar 内未发现可实例化的 Spider 类（共枚举 ${classes.length} 个类）'
        '${details.isEmpty ? '' : '：${details.join('；')}'}',
      );
    }
    return (
      summary: _jarSummary(
        registered: result.newly.length,
        enumerated: classes.length,
        updated: result.updated,
        configured: result.configured,
        missing: result.missing,
        extraJsonNames: savedExtras,
        skippedJarNames: package.skippedJarNames,
      ),
      siteIds: result.newSiteIds,
      siteNames: [
        for (final id in result.newSiteIds)
          JarImport.siteFor(id)?.name ?? '',
      ],
    );
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
