import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'haikuo_codec.dart';
import 'haikuo_helpers.dart';
import 'haikuo_program.dart';
import 'haikuo_store.dart';

/// zip 备份导入的进度：当前阶段 + 已完成/总数（总数未知时为 0，
/// 调用方显示不定进度）。
class HaikuoZipImportProgress {
  const HaikuoZipImportProgress(this.phase, this.done, this.total);

  final String phase;
  final int done;
  final int total;
}

/// zip 备份导入的结果汇总：成功/跳过/失败都是规则条目数，
/// 模块文件另计；[firstError] 是首条失败原因。
class HaikuoZipImportResult {
  const HaikuoZipImportResult({
    required this.added,
    required this.skipped,
    required this.failed,
    required this.moduleFiles,
    this.firstError,
    this.notes = const [],
  });

  final int added;
  final int skipped;
  final int failed;
  final int moduleFiles;
  final String? firstError;
  final List<String> notes;

  String get summary {
    final parts = <String>['成功 $added 条', '跳过 $skipped 条', '失败 $failed 条'];
    if (moduleFiles > 0) parts.add('模块文件 $moduleFiles 个');
    var text = parts.join('、');
    final error = firstError;
    if (error != null && error.isNotEmpty) text += '\n首条错误：$error';
    return text;
  }
}

/// 备份数据库读取器：读出 `articlelistrule` 全表（测试注入假实现；
/// 默认走 sqflite 只读打开，表不存在时抛 [HaikuoFormatException]）。
typedef HaikuoZipDbReader =
    Future<List<Map<String, dynamic>>> Function(File dbFile);

/// 海阔备份 zip 导入器：整包备份（含数据库 + 嵌套压缩包 + 模块文件）
/// 一次性导入，规则入库、模块文件落盘到对应规则的私有文件区。
///
/// 备份实物形态（以磁盘上的 hiker_54.db + rules.zip + data.zip 为准）：
/// 外层 zip 里可能直接放着 `.db` 数据库、规则 JSON、以及嵌套的
/// `rules.zip` / `data.zip`；模块文件在 `files/<规则名>/`（rules.zip）
/// 与 `<规则名>/plugins/`、`<规则名>/template/`（data.zip）里；
/// 外层也可能多套一层文件夹。解析时按“数据库 → 规则 JSON →
/// 嵌套压缩包 → 模块文件”的顺序全试，不互斥；扫描是递归的，
/// 套一层文件夹能透视。
///
/// 安全与诚实：
/// - 大文件走流式解压：`InputFileStream` + 逐条目 `writeContent`
///   落临时目录，一次只驻留一个条目，不把整包读进内存；
///   解压总量与单条目大小封顶，防 zip 炸弹。
/// - 先全解析、后批量入库：解析阶段（解压/数据库/规则 JSON）出
///   致命错时零入库，已有规则不受污染；单个来源失败只记失败数，
///   其余继续。
/// - 去重：同标题已存在则跳过并计数，绝不覆盖（内置规则也在内）；
///   备份内同名重复只留第一份。
/// - 临时目录在 finally 里删除；损坏 zip / 坏数据库报明错，不闪崩。
class HaikuoZipImporter {
  HaikuoZipImporter(this._store, {HaikuoZipDbReader? dbReader})
    : _dbReader = dbReader ?? _defaultDbReader;

  final HaikuoStore _store;
  final HaikuoZipDbReader _dbReader;

  /// 单个 zip 里的条目数封顶。
  static const _maxEntries = 20000;

  /// 解压后总量封顶（1GB）：60MB 备份正常展开远不到这个数。
  static const _maxTotalBytes = 1024 * 1024 * 1024;

  /// 单条目大小封顶（256MB）。
  static const _maxEntryBytes = 256 * 1024 * 1024;

  /// 单个模块文件大小封顶（32MB）：模块都是脚本/文本，超了就不是模块。
  static const _maxModuleBytes = 32 * 1024 * 1024;

  /// 嵌套 zip 展开层数封顶。
  static const _maxNestDepth = 3;

  /// 从 zip 文件导入（首选路径：文件流式解压，不整包进内存）。
  Future<HaikuoZipImportResult> importZipFile(
    File zipFile, {
    void Function(HaikuoZipImportProgress progress)? onProgress,
  }) async {
    if (!await zipFile.exists()) {
      throw const HaikuoFormatException('备份文件不存在');
    }
    final root = await _store.root;
    final work = Directory(
      p.join(
        root.path,
        'zip_import_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await work.create(recursive: true);
    try {
      return await _run(work, zipFile, p.basename(zipFile.path), onProgress);
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {
        // 临时目录删不掉也无妨，下次导入用新目录
      }
    }
  }

  /// 从内存字节导入（文件选择器拿不到路径时的兜底：先把字节暂存成
  /// 临时文件，再走同一条流式解压路径；60MB 级别会有一次内存驻留，
  /// 只有 content:// 选文件时才走到这里）。
  Future<HaikuoZipImportResult> importZipBytes(
    List<int> bytes, {
    required String fileName,
    void Function(HaikuoZipImportProgress progress)? onProgress,
  }) async {
    if (bytes.isEmpty) {
      throw const HaikuoFormatException('选到的文件是空的');
    }
    final root = await _store.root;
    final work = Directory(
      p.join(
        root.path,
        'zip_import_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await work.create(recursive: true);
    try {
      final staged = File(p.join(work.path, '__upload.zip'));
      await staged.writeAsBytes(bytes, flush: true);
      return await _run(work, staged, fileName, onProgress);
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {
        // 同上
      }
    }
  }

  Future<HaikuoZipImportResult> _run(
    Directory work,
    File zipFile,
    String displayName,
    void Function(HaikuoZipImportProgress progress)? onProgress,
  ) async {
    void report(String phase, [int done = 0, int total = 0]) {
      onProgress?.call(HaikuoZipImportProgress(phase, done, total));
    }

    await _checkZipMagic(zipFile);
    final extracted = Directory(p.join(work.path, 'extracted'));
    await extracted.create(recursive: true);
    final notes = <String>[];
    report('正在解压备份…');
    final skipped = await _extractZip(zipFile, extracted, (done, total) {
      report('正在解压备份…', done, total);
    });
    notes.addAll(skipped);
    report('正在解开嵌套压缩包…');
    notes.addAll(await _expandNestedZips(extracted, 0));

    // 扫描解压后的整棵树（套一层文件夹也能透视），分类处理。
    final allFiles = <File>[];
    await for (final entity in extracted.list(recursive: true)) {
      if (entity is File) allFiles.add(entity);
    }
    allFiles.sort((a, b) => a.path.compareTo(b.path));

    final failures = <String>[];
    final programs = <HaikuoProgram>[];
    final parsedRulePaths = <String>{};
    final failedPaths = <String>{};
    final origin = 'zip 备份：$displayName';
    final candidates = _classify(allFiles, extracted.path);
    report('正在解析规则…', 0, candidates.length);
    var parsed = 0;
    for (final candidate in candidates) {
      try {
        final found = await _parseCandidate(candidate, origin);
        if (found.isNotEmpty) {
          programs.addAll(found);
          parsedRulePaths.add(candidate.file.path);
        }
      } on HaikuoFormatException catch (error) {
        failures.add(error.message);
        failedPaths.add(candidate.file.path);
      }
      parsed++;
      report('正在解析规则…', parsed, candidates.length);
    }
    if (programs.isEmpty) {
      // 致命：什么都没解析出来，零入库，报首条错误（或通用原因）。
      throw HaikuoFormatException(
        failures.isNotEmpty
            ? failures.first
            : '压缩包里没有找到可导入的规则（没有规则数据库，也没有规则 JSON）',
      );
    }

    // 备份内同名重复只留第一份，其余记跳过。
    final deduped = <HaikuoProgram>[];
    final seenNames = <String>{};
    var batchSkipped = 0;
    for (final program in programs) {
      if (!seenNames.add(program.name)) {
        batchSkipped++;
        notes.add('备份内重复，已跳过：${program.name}');
        continue;
      }
      deduped.add(program);
    }

    report('正在入库…');
    final existing = await _store.list();
    final committed = await _store.addAllSkipExisting(
      deduped,
      origin: origin,
    );

    // 模块文件：只给入库后库里有的规则写（新增 + 已存在），无主模块不写。
    final libraryTitles = {
      for (final program in existing) program.name,
      for (final program in committed.added) program.name,
    };
    report('正在写入模块文件…', 0, allFiles.length);
    final moduleOutcome = await _writeModules(
      allFiles,
      extracted.path,
      libraryTitles,
      parsedRulePaths,
      failedPaths,
      (done) => report('正在写入模块文件…', done, allFiles.length),
    );
    notes.addAll(moduleOutcome.notes);

    final firstError = failures.isEmpty ? null : failures.first;
    return HaikuoZipImportResult(
      added: committed.added.length,
      skipped: committed.skipped.length + batchSkipped,
      failed: failures.length,
      moduleFiles: moduleOutcome.written,
      firstError: firstError,
      notes: notes,
    );
  }

  /// zip 魔数校验：PK\x03\x04（普通条目）或 PK\x05\x06（空包）；
  /// 不是 zip 直接报明错，不往下走。
  Future<void> _checkZipMagic(File zipFile) async {
    final handle = await zipFile.open();
    try {
      final head = await handle.read(4);
      if (head.length < 4 ||
          head[0] != 0x50 ||
          head[1] != 0x4B ||
          !((head[2] == 0x03 && head[3] == 0x04) ||
              (head[2] == 0x05 && head[3] == 0x06))) {
        throw const HaikuoFormatException('这个文件不是 zip 备份，请选择 .zip 文件');
      }
    } finally {
      await handle.close();
    }
  }

  /// 流式解压：中心目录只读索引，条目逐个 `writeContent` 落盘，
  /// 写完即释内存（freeMemory）；返回跳过条目的说明。
  Future<List<String>> _extractZip(
    File zipFile,
    Directory out,
    void Function(int done, int total) onEntry,
  ) async {
    final skipped = <String>[];
    final input = InputFileStream(zipFile.path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } catch (error) {
        throw HaikuoFormatException('zip 包解包失败：$error');
      }
      try {
        final files = [
          for (final entry in archive.files)
            if (entry.isFile) entry,
        ];
        if (files.length > _maxEntries) {
          throw const HaikuoFormatException('zip 包里条目太多，已停止解析');
        }
        var totalBytes = 0;
        var done = 0;
        for (final entry in files) {
          final rel = _safeRelativePath(entry.name);
          if (rel == null) {
            skipped.add('跳过危险路径条目：${entry.name}');
            continue;
          }
          if (entry.size > _maxEntryBytes) {
            skipped.add('跳过超大条目：${entry.name}');
            continue;
          }
          totalBytes += entry.size;
          if (totalBytes > _maxTotalBytes) {
            throw const HaikuoFormatException('解压后体积超过 1GB，已停止解析');
          }
          final target = File(p.join(out.path, rel));
          await target.parent.create(recursive: true);
          final output = OutputFileStream(target.path);
          try {
            entry.writeContent(output);
          } catch (error) {
            skipped.add('条目解压失败 ${entry.name}：$error');
            try {
              await target.delete();
            } catch (_) {
              // 残文件删不掉也无妨，临时目录最后统一清理
            }
            continue;
          } finally {
            await output.close();
          }
          done++;
          onEntry(done, files.length);
        }
      } finally {
        await archive.clear();
      }
    } finally {
      await input.close();
    }
    return skipped;
  }

  /// zip-slip 防护：反斜杠当分隔符，`.`/空段丢弃，`..` 直接拒掉整条目。
  String? _safeRelativePath(String name) {
    final parts = <String>[];
    for (final part in name.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') return null;
      parts.add(part);
    }
    if (parts.isEmpty) return null;
    return p.joinAll(parts);
  }

  /// 递归展开嵌套 zip（rules.zip / data.zip）：解到
  /// `<原名>__unzipped/` 后删掉嵌套包本身，层数封顶防自包含循环。
  Future<List<String>> _expandNestedZips(Directory root, int depth) async {
    final notes = <String>[];
    if (depth >= _maxNestDepth) return notes;
    final zips = <File>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.zip')) {
        zips.add(entity);
      }
    }
    if (zips.isEmpty) return notes;
    zips.sort((a, b) => a.path.compareTo(b.path));
    var expanded = false;
    for (final zip in zips) {
      var target = Directory(
        p.join(
          p.dirname(zip.path),
          '${p.basenameWithoutExtension(zip.path)}__unzipped',
        ),
      );
      var suffix = 1;
      while (await target.exists()) {
        suffix++;
        target = Directory('${target.path}_$suffix');
      }
      await target.create(recursive: true);
      try {
        await _extractZip(zip, target, (_, _) {});
        expanded = true;
      } catch (error) {
        notes.add('嵌套压缩包 ${p.basename(zip.path)} 解包失败：$error');
        try {
          await target.delete(recursive: true);
        } catch (_) {
          // 同上
        }
      } finally {
        // 嵌套包是临时目录里的副本，成败都删掉，避免下层重复扫描。
        try {
          await zip.delete();
        } catch (_) {
          // 同上
        }
      }
    }
    if (expanded) notes.addAll(await _expandNestedZips(root, depth + 1));
    return notes;
  }

  /// 扫描结果分类：数据库文件与规则 JSON 候选；模块区文件不在这里处理。
  List<_Candidate> _classify(List<File> files, String rootPath) {
    final out = <_Candidate>[];
    for (final file in files) {
      final rel = p.relative(file.path, from: rootPath);
      final segments = p.split(rel);
      final lower = file.path.toLowerCase();
      if (lower.endsWith('.db')) {
        out.add(_Candidate(file, rel, _CandidateKind.db));
        continue;
      }
      final isJson = lower.endsWith('.json');
      final isTxt = lower.endsWith('.txt');
      if (!isJson && !isTxt) continue;
      if (_isModuleArea(segments, p.basename(file.path))) continue;
      out.add(_Candidate(file, rel, _CandidateKind.ruleJson));
    }
    return out;
  }

  /// 模块区判定：`files/` 容器、`plugins/`/`template/` 子目录、
  /// `js/` 脚本目录，以及备份里的数据文件名——这些都不是规则 JSON。
  bool _isModuleArea(List<String> segments, String basename) {
    if (segments.contains('files') ||
        segments.contains('plugins') ||
        segments.contains('template') ||
        segments.contains('js')) {
      return true;
    }
    const dataNames = {'require.json', 'browser_proxy_rules.json'};
    return dataNames.contains(basename.toLowerCase());
  }

  Future<List<HaikuoProgram>> _parseCandidate(
    _Candidate candidate,
    String origin,
  ) async {
    if (candidate.kind == _CandidateKind.db) {
      return _parseDb(candidate, origin);
    }
    final bytes = await candidate.file.readAsBytes();
    final text = HaikuoCodec.decodeText(bytes).trim();
    // .txt 只在内容像 JSON 时才试（说明/数据文本直接放过，不是失败）。
    if (candidate.file.path.toLowerCase().endsWith('.txt') &&
        !HaikuoCodec.looksLikeJson(text)) {
      return const [];
    }
    try {
      final programs = _tryRuleJson(text, origin);
      return programs;
    } on HaikuoFormatException catch (error) {
      throw HaikuoFormatException('规则文件 ${candidate.rel}：${error.message}');
    }
  }

  /// 规则 JSON 解析：严格解析先行；失败时走宽容解析（注释/尾随逗号）；
  /// 合法 JSON 但没有规则条目时回空（那是数据文件，不是失败）。
  List<HaikuoProgram> _tryRuleJson(String text, String origin) {
    try {
      final decoded = jsonDecode(text);
      return HaikuoCodec.parseDecoded(decoded, origin: origin);
    } on FormatException {
      try {
        return HaikuoCodec.parseJsonText(text, origin: origin);
      } on HaikuoFormatException catch (error) {
        // parseJsonText 在“合法但无条目”时也抛错：那是数据文件，放过。
        if (error.message.contains('没有识别到')) return const [];
        rethrow;
      }
    }
  }

  /// 数据库候选：先验 SQLite 魔数，再只读读表，行转规则后归一解析。
  Future<List<HaikuoProgram>> _parseDb(
    _Candidate candidate,
    String origin,
  ) async {
    final handle = await candidate.file.open();
    try {
      final head = await handle.read(16);
      if (!isSqliteBytes(head)) {
        throw HaikuoFormatException('数据库 ${candidate.rel} 不是 SQLite 格式');
      }
    } finally {
      await handle.close();
    }
    List<Map<String, dynamic>> rows;
    try {
      rows = await _dbReader(candidate.file);
    } on HaikuoFormatException catch (error) {
      throw HaikuoFormatException('数据库 ${candidate.rel}：${error.message}');
    } catch (error) {
      throw HaikuoFormatException('数据库 ${candidate.rel} 读取失败：$error');
    }
    final rules = <Map<String, dynamic>>[];
    for (final row in rows) {
      final rule = haikuoDbRowToRule(row);
      if (rule != null) rules.add(rule);
    }
    if (rules.isEmpty) {
      throw HaikuoFormatException('数据库 ${candidate.rel} 里没有找到可导入的规则');
    }
    final programs = HaikuoCodec.parseDecoded(rules, origin: origin);
    if (programs.isEmpty) {
      throw HaikuoFormatException('数据库 ${candidate.rel} 里没有识别到海阔小程序条目');
    }
    return programs;
  }

  /// 默认数据库读取：sqflite 只读打开，读完即关（文件已在临时目录，
  /// 不需要再拷一份）。
  static Future<List<Map<String, dynamic>>> _defaultDbReader(
    File dbFile,
  ) async {
    final db = await openDatabase(dbFile.path, readOnly: true);
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='articlelistrule'",
      );
      if (tables.isEmpty) {
        throw const HaikuoFormatException('数据库里没有找到规则表 articlelistrule');
      }
      final rows = await db.query('articlelistrule');
      return [
        for (final row in rows)
          {for (final entry in row.entries) entry.key: entry.value},
      ];
    } finally {
      await db.close();
    }
  }

  /// 模块文件写盘：`files/<规则>/` 与 `<规则>/plugins|template/` 按规则
  /// 归属，其余脚本/数据文件进共享区；只写库里有对应规则的，
  /// 同规则同名文件先到先得，超大文件跳过并记注。
  Future<({int written, List<String> notes})> _writeModules(
    List<File> allFiles,
    String rootPath,
    Set<String> libraryTitles,
    Set<String> parsedRulePaths,
    Set<String> failedPaths,
    void Function(int done) onStep,
  ) async {
    final notes = <String>[];
    var written = 0;
    var done = 0;
    final claimed = <String>{};
    final root = await _store.root;
    for (final file in allFiles) {
      done++;
      onStep(done);
      if (parsedRulePaths.contains(file.path) ||
          failedPaths.contains(file.path)) {
        continue;
      }
      final lower = file.path.toLowerCase();
      if (lower.endsWith('.db') || lower.endsWith('.zip')) continue;
      final rel = p.relative(file.path, from: rootPath);
      final segments = p.split(rel);
      final basename = p.basename(file.path);
      if (basename.startsWith('.') || segments.contains('__MACOSX')) continue;
      final slot = _moduleSlot(segments);
      String? ruleTitle;
      if (slot != null) {
        ruleTitle = slot;
      } else {
        // 非模块布局的剩余文件：只收脚本/文本类进共享区，其余放过。
        if (!(lower.endsWith('.js') ||
            lower.endsWith('.json') ||
            lower.endsWith('.txt'))) {
          continue;
        }
        ruleTitle = null;
      }
      final size = await file.length();
      if (size > _maxModuleBytes) {
        notes.add('模块文件过大，已跳过：$rel');
        continue;
      }
      String folderTitle;
      if (ruleTitle == null) {
        folderTitle = HaikuoRuleFiles.sharedFolder;
      } else {
        final matched = matchRuleTitle(ruleTitle, libraryTitles);
        if (matched == null) {
          notes.add('模块无对应规则，已跳过：$rel');
          continue;
        }
        folderTitle = matched;
      }
      final key = '$folderTitle\u0000$basename';
      if (!claimed.add(key)) {
        notes.add('同名模块文件，已留第一份：$rel');
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        await HaikuoRuleFiles.writeRuleFile(root, folderTitle, basename, bytes);
        written++;
      } catch (error) {
        notes.add('模块文件写入失败 $rel：$error');
      }
    }
    return (written: written, notes: notes);
  }

  /// 模块归属判定：`files/<规则>/…` 取 files 后一段；`<规则>/plugins|template/`
  /// 取前一段；其余回 null（调用方按共享区处理）。
  /// `files/` 下直接放文件（无规则目录）时也回 null，走共享区。
  String? _moduleSlot(List<String> segments) {
    final filesIdx = segments.indexOf('files');
    if (filesIdx >= 0) {
      if (filesIdx + 1 < segments.length - 1) {
        return segments[filesIdx + 1];
      }
      return null;
    }
    for (final area in const ['plugins', 'template']) {
      final idx = segments.indexOf(area);
      if (idx > 0) return segments[idx - 1];
    }
    return null;
  }
}

enum _CandidateKind { db, ruleJson }

class _Candidate {
  const _Candidate(this.file, this.rel, this.kind);

  final File file;
  final String rel;
  final _CandidateKind kind;
}

/// 规则私有文件区：备份导入的模块文件落盘位置，供运行时
/// `$.require` / `readFile` 经 `/__files/` 按名取用。
///
/// 布局：`<haikuo 根>/rule_files/<encodeComponent(规则标题)>/<文件名>`；
/// 无归属的共享模块放 `rule_files/__shared__/<文件名>`。
/// 文件名只取基名（运行时取文件时也只认基名），`..` 与分隔符一律拒掉。
abstract final class HaikuoRuleFiles {
  static const _dirName = 'rule_files';

  /// 共享模块文件夹名（规则标题几乎不会撞上这个名字）。
  static const sharedFolder = '__shared__';

  static String? _safeBaseName(String fileName) {
    final base = p.basename(fileName.replaceAll('\\', '/'));
    if (base.isEmpty || base == '.' || base == '..') return null;
    return base;
  }

  /// 写一个规则的私有文件（[ruleTitle] 为 [sharedFolder] 时写共享区）。
  static Future<void> writeRuleFile(
    Directory root,
    String ruleTitle,
    String fileName,
    List<int> bytes,
  ) async {
    final base = _safeBaseName(fileName);
    if (base == null) {
      throw const HaikuoFormatException('模块文件名不对');
    }
    final dir = Directory(
      p.join(root.path, _dirName, Uri.encodeComponent(ruleTitle)),
    );
    await dir.create(recursive: true);
    await File(p.join(dir.path, base)).writeAsBytes(bytes, flush: true);
  }

  /// 读一个规则的私有文件：精确标题目录优先，其次归一化标题匹配
  /// （去 🔞/花体折叠），最后共享区；都没有返回 null。
  static Future<Uint8List?> readRuleFile(
    Directory root,
    String ruleTitle,
    String fileName,
  ) async {
    final base = _safeBaseName(fileName);
    if (base == null || ruleTitle.trim().isEmpty) return null;
    final dir = Directory(p.join(root.path, _dirName));
    if (!await dir.exists()) return null;
    final exact = File(
      p.join(dir.path, Uri.encodeComponent(ruleTitle), base),
    );
    if (await exact.exists()) return exact.readAsBytes();
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final folderName = p.basename(entity.path);
      if (folderName == sharedFolder) continue;
      String decoded;
      try {
        decoded = Uri.decodeComponent(folderName);
      } catch (_) {
        continue;
      }
      if (matchRuleTitle(ruleTitle, [decoded]) == null) continue;
      final candidate = File(p.join(entity.path, base));
      if (await candidate.exists()) return candidate.readAsBytes();
    }
    final shared = File(p.join(dir.path, sharedFolder, base));
    if (await shared.exists()) return shared.readAsBytes();
    return null;
  }
}
