import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'core_bridge.dart';
import 'import_file_store.dart';
import 'jar_bridge_handoff.dart';
import 'imported_site_record.dart';
import 'legado_gbk.dart';
import 'local_store.dart';
import 'py_bridge.dart';
import 'py_spider_validator.dart';

class ImportCandidate {
  const ImportCandidate({
    required this.name,
    required this.bytes,
    this.ext = '',
  });

  final String name;
  final List<int> bytes;
  final String ext;

  String get extension {
    final at = name.lastIndexOf('.');
    return at < 0 ? '' : name.substring(at + 1).toLowerCase();
  }

  String get baseName {
    final at = name.lastIndexOf('.');
    return at < 0 ? name : name.substring(0, at);
  }
}

enum ImportOutcomeStatus { success, duplicate, failed }

class ImportOutcome {
  const ImportOutcome({
    required this.fileName,
    required this.status,
    required this.reason,
    this.siteName = '',
    this.siteId = '',
  });

  final String fileName;
  final ImportOutcomeStatus status;
  final String reason;
  final String siteName;
  final String siteId;

  bool get ok => status == ImportOutcomeStatus.success;
}

class ImportReport {
  const ImportReport(this.outcomes);

  final List<ImportOutcome> outcomes;

  int get successCount => outcomes
      .where((item) => item.status == ImportOutcomeStatus.success)
      .length;
  int get duplicateCount => outcomes
      .where((item) => item.status == ImportOutcomeStatus.duplicate)
      .length;
  int get failedCount => outcomes
      .where((item) => item.status == ImportOutcomeStatus.failed)
      .length;

  String get summary =>
      '成功 $successCount · 重复跳过 $duplicateCount · 失败 $failedCount';
}

String importSlug(String value) {
  final slug = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (slug.isEmpty) return 'site';
  return slug.length > 40 ? slug.substring(0, 40) : slug;
}

String contentHashOf(List<int> bytes) => sha256.convert(bytes).toString();

class ImportEngine {
  ImportEngine({required this.store, required this.repository});

  final LocalStore store;
  final AppRepository repository;

  static const supportedExtensions = {'py', 'js', 'json', 'jar', 'zip'};

  Future<ImportReport> importAll(List<ImportCandidate> candidates) async {
    final records = List<ImportedSiteRecord>.of(store.importedSiteRecords);
    final outcomes = <ImportOutcome>[];
    var recordsChanged = false;
    for (final candidate in candidates) {
      final outcome = await _importOne(candidate, records, () {
        recordsChanged = true;
      });
      outcomes.add(outcome);
    }
    if (recordsChanged) await store.syncImportedSites(records);
    return ImportReport(outcomes);
  }

  Future<ImportOutcome> _importOne(
    ImportCandidate candidate,
    List<ImportedSiteRecord> records,
    void Function() markRecordsChanged,
  ) async {
    ImportOutcome fail(String reason) => ImportOutcome(
      fileName: candidate.name,
      status: ImportOutcomeStatus.failed,
      reason: reason,
    );
    try {
      final extension = candidate.extension;
      if (!supportedExtensions.contains(extension)) {
        return fail('不支持的文件类型：.$extension（仅支持 py/js/json/jar/zip）');
      }
      if (candidate.bytes.isEmpty) return fail('文件为空');
      final hash = contentHashOf(candidate.bytes);
      final sameHash = records
          .where((record) => record.contentHash == hash)
          .firstOrNull;
      if (sameHash != null) {
        return ImportOutcome(
          fileName: candidate.name,
          status: ImportOutcomeStatus.duplicate,
          reason: '内容与已导入的「${sameHash.name}」完全相同，跳过',
          siteName: sameHash.name,
          siteId: sameHash.id,
        );
      }
      switch (extension) {
        case 'py':
          return await _importPy(candidate, hash, records, markRecordsChanged);
        case 'js':
          return await _importJs(candidate, hash, records, markRecordsChanged);
        case 'json':
          return await _importJson(candidate, hash);
        case 'jar':
          return await _importJar(candidate);
        case 'zip':
          return await _importZip(candidate);
        default:
          return fail('不支持的文件类型');
      }
    } on AppFailure catch (error) {
      return fail(error.message);
    } catch (error) {
      return fail(error.toString());
    }
  }

  String _uniqueId(
    String prefix,
    String baseName,
    List<ImportedSiteRecord> records,
    String hash,
  ) {
    var id = '$prefix:${importSlug(baseName)}';
    if (records.any((record) => record.id == id)) {
      id = '$id-${hash.substring(0, 6)}';
    }
    return id;
  }

  Future<ImportOutcome> _importPy(
    ImportCandidate candidate,
    String hash,
    List<ImportedSiteRecord> records,
    void Function() markRecordsChanged,
  ) async {
    String source;
    List<int> saveBytes;
    try {
      final decoded = utf8.decode(candidate.bytes);
      source = decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
      saveBytes = candidate.bytes;
    } catch (_) {
      final decoded = decodeGbkBytes(candidate.bytes);
      source = decoded;
      final head = decoded.split('\n').take(2).join('\n');
      final hasCookie = RegExp(r'coding[:=]\s*[-\w.]+').hasMatch(head);
      saveBytes = hasCookie
          ? candidate.bytes
          : [...utf8.encode('# -*- coding: gbk -*-\n'), ...candidate.bytes];
    }
    final validation = validatePySource(source);
    if (!validation.ok) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: validation.message,
      );
    }
    final hostValidation = await PyBridge.validate(source);
    if (hostValidation != null && !hostValidation.ok) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: '运行时校验未通过：${hostValidation.error}',
      );
    }
    final id = _uniqueId('py', candidate.baseName, records, hash);
    final fileName = await ImportFileStore.save(id, 'py', saveBytes);
    records.add(
      ImportedSiteRecord(
        id: id,
        name: candidate.baseName,
        type: ImportedSiteRecord.typePy,
        fileName: fileName,
        contentHash: hash,
        importedAtMs: DateTime.now().millisecondsSinceEpoch,
        ext: candidate.ext,
      ),
    );
    markRecordsChanged();
    var displayName = candidate.baseName;
    var nameNote = '';
    try {
      final path = await ImportFileStore.pathOf(fileName);
      final ping = await PyBridge.call(path, {'action': 'ping'});
      final spiderName = (ping['name'] as String? ?? '').trim();
      if (spiderName.isNotEmpty && spiderName != displayName) {
        final index = records.indexWhere((record) => record.id == id);
        if (index >= 0) {
          records[index] = records[index].copyWith(name: spiderName);
          markRecordsChanged();
          displayName = spiderName;
          nameNote = '；蜘蛛名为“$spiderName”，已同步';
        }
      }
    } catch (_) {}
    final filledNote = validation.filledNote;
    return ImportOutcome(
      fileName: candidate.name,
      status: ImportOutcomeStatus.success,
      reason: validation.playOnly
          ? '已注册为仅播放 Python 蜘蛛站（经 CPython 桥执行；首页只有一集正片，解析走 playerContent，缺失依赖已打桩）；$filledNote$nameNote'
          : filledNote.isEmpty
          ? '已注册为 Python 蜘蛛站（经 CPython 桥执行）$nameNote'
          : '已注册为 Python 蜘蛛站（经 CPython 桥执行）；$filledNote$nameNote',
      siteName: displayName,
      siteId: id,
    );
  }

  Future<ImportOutcome> _importJs(
    ImportCandidate candidate,
    String hash,
    List<ImportedSiteRecord> records,
    void Function() markRecordsChanged,
  ) async {
    final String source;
    try {
      source = utf8.decode(candidate.bytes);
    } catch (_) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: '文件不是有效的 UTF-8 文本，无法作为 JS 蜘蛛导入',
      );
    }
    final problem = identifyJsSource(source);
    if (problem != null) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: problem,
      );
    }
    final id = _uniqueId('js', candidate.baseName, records, hash);
    final fileName = await ImportFileStore.save(id, 'js', candidate.bytes);
    records.add(
      ImportedSiteRecord(
        id: id,
        name: candidate.baseName,
        type: ImportedSiteRecord.typeJs,
        fileName: fileName,
        contentHash: hash,
        importedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    markRecordsChanged();
    return ImportOutcome(
      fileName: candidate.name,
      status: ImportOutcomeStatus.success,
      reason: '已注册为 JS 蜘蛛站（经内置 Go 脚本引擎执行，安卓与 iOS 同一套引擎，不走网页视图）',
      siteName: candidate.baseName,
    );
  }

  bool _isXbpqRule(Map<String, dynamic> parsed) =>
      parsed.containsKey('主页url') ||
      (parsed.containsKey('分类url') && parsed.containsKey('数组')) ||
      (parsed.containsKey('分类') && parsed.containsKey('数组'));

  Future<ImportOutcome> _importJson(
    ImportCandidate candidate,
    String hash,
  ) async {
    final String text;
    try {
      text = utf8.decode(candidate.bytes);
    } catch (_) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: '文件不是有效的 UTF-8 文本',
      );
    }
    final dynamic parsed;
    try {
      parsed = jsonDecode(text);
    } catch (error) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: 'JSON 解析失败：$error',
      );
    }
    if (parsed is Map<String, dynamic> && _isXbpqRule(parsed)) {
      final ruleHash = contentHashOf(utf8.encode(text.trim()));
      final duplicate = store.customSources
          .where(
            (site) =>
                site.hasRule &&
                contentHashOf(utf8.encode(site.rule.trim())) == ruleHash,
          )
          .firstOrNull;
      if (duplicate != null) {
        return ImportOutcome(
          fileName: candidate.name,
          status: ImportOutcomeStatus.duplicate,
          reason: '内容与已导入的规则站「${duplicate.name}」相同，跳过',
          siteName: duplicate.name,
        );
      }
      final name =
          (parsed['站名'] as String?) ??
          (parsed['name'] as String?) ??
          candidate.baseName;
      final base = parsed['主页url'] as String? ?? '';
      await repository.addCustomSource(name: name, base: base, rule: text);
      await store.syncCustomSources(await repository.customSources());
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.success,
        reason: '已识别为 XBPQ 规则，注册到核心 XBPQ 引擎通道',
        siteName: name,
      );
    }
    if (parsed is Map<String, dynamic> &&
        (parsed.containsKey('sites') || parsed.containsKey('spider'))) {
      final summary = await JarBridgeHandoff.importTvBoxConfig(
        repository: repository,
        name: candidate.baseName,
        content: text,
      );
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.success,
        reason: summary,
        siteName: candidate.baseName,
      );
    }
    final looksCustom =
        parsed is List ||
        (parsed is Map<String, dynamic> &&
            (parsed['sources'] is List || parsed['items'] is List));
    if (looksCustom) {
      final result = await repository.importCustomSources(text);
      await store.syncCustomSources(await repository.customSources());
      final added = (result['added'] as List? ?? const []).length;
      final updated = (result['updated'] as List? ?? const []).length;
      if (added + updated > 0) {
        return ImportOutcome(
          fileName: candidate.name,
          status: ImportOutcomeStatus.success,
          reason: '已识别为自定义源 JSON，新增 $added 个、更新 $updated 个',
          siteName: candidate.baseName,
        );
      }
      final failed = (result['failed'] as List? ?? const [])
          .map((item) => item.toString())
          .join('；');
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: '自定义源通道未接受该文件${failed.isEmpty ? '' : '：$failed'}',
      );
    }
    return ImportOutcome(
      fileName: candidate.name,
      status: ImportOutcomeStatus.failed,
      reason:
          '无法识别的 JSON：既不是 XBPQ 规则（含主页url/分类/数组等字段）、'
          'TVBox 配置（含 sites/spider），也不是自定义源格式',
    );
  }

  Future<ImportOutcome> _importJar(ImportCandidate candidate) async {
    final bytes = candidate.bytes;
    if (bytes.length < 2 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: '不是有效的 jar 文件（缺少 zip 文件头）',
      );
    }
    final result = await JarBridgeHandoff.registerJar(
      name: candidate.baseName,
      bytes: bytes,
    );
    return ImportOutcome(
      fileName: candidate.name,
      status: ImportOutcomeStatus.success,
      reason: result.summary,
      siteName: result.siteNames.isEmpty
          ? candidate.baseName
          : result.siteNames.first,
      siteId: result.siteIds.isEmpty ? '' : result.siteIds.first,
    );
  }

  Future<ImportOutcome> _importZip(ImportCandidate candidate) async {
    final bytes = candidate.bytes;
    if (bytes.length < 2 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      return ImportOutcome(
        fileName: candidate.name,
        status: ImportOutcomeStatus.failed,
        reason: '不是有效的 zip 包（缺少 zip 文件头）',
      );
    }
    final result = await JarBridgeHandoff.registerZip(
      name: candidate.baseName,
      bytes: bytes,
    );
    return ImportOutcome(
      fileName: candidate.name,
      status: ImportOutcomeStatus.success,
      reason: result.summary,
      siteName: result.siteNames.isEmpty
          ? candidate.baseName
          : result.siteNames.first,
      siteId: result.siteIds.isEmpty ? '' : result.siteIds.first,
    );
  }
}
