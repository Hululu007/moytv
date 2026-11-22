import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'haikuo_codec.dart';
import 'haikuo_helpers.dart';
import 'haikuo_program.dart';

/// 海阔小程序的本地仓库。
///
/// 导入的小程序统一落在一个 JSON 文件里（而不是每个小程序一个目录），
/// 因为海阔小程序本身就是一份 JSON，不需要解包执行目录；
/// 这样卸载、去重、导出都只动一个文件，出问题也好排查。
class HaikuoStore {
  HaikuoStore({
    Directory? rootOverride,
    http.Client? httpClient,
    Future<List<Map<String, dynamic>>> Function(List<int> bytes)? dbReader,
  }) : _rootOverride = rootOverride,
       _httpClient = httpClient,
       _dbReader = dbReader;

  final Directory? _rootOverride;
  final http.Client? _httpClient;

  /// 备份数据库读取器（测试注入假实现；默认走 sqflite 只读打开）。
  final Future<List<Map<String, dynamic>>> Function(List<int> bytes)? _dbReader;

  static const _fileName = 'programs.json';

  Future<Directory> get root async {
    final override = _rootOverride;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'haikuo'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> get _file async {
    final dir = await root;
    return File(p.join(dir.path, _fileName));
  }

  Future<List<HaikuoProgram>> list() async {
    final file = await _file;
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      final list = decoded is Map<String, dynamic>
          ? decoded['programs']
          : decoded;
      if (list is! List) return const [];
      final programs = <HaikuoProgram>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          programs.add(HaikuoProgram.fromJson(item));
        } else if (item is Map) {
          programs.add(
            HaikuoProgram.fromJson({
              for (final entry in item.entries) '${entry.key}': entry.value,
            }),
          );
        }
      }
      programs.sort((a, b) {
        final left = a.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
      return programs;
    } catch (_) {
      // 文件坏了不拖垮页面：当空库处理，下一次导入会覆盖成正常结构。
      return const [];
    }
  }

  Future<void> _writeAll(List<HaikuoProgram> programs) async {
    final file = await _file;
    final payload = {
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'programs': programs.map((program) => program.toJson()).toList(),
    };
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(payload), flush: true);
    await temp.rename(file.path);
  }

  /// 把一批小程序写进本地库。
  ///
  /// 同 id（同名同内容）重复导入只更新，不堆叠；新 id 但与库里已有条目
  /// 同名时属于重复：经 [onDuplicates] 问用户一次（替换 / 保留两者 /
  /// 取消），不传 [onDuplicates] 时默认保留两者（新条目改名 _2、_3…）。
  /// 选取消则整批都不写入。
  Future<HaikuoImportResult> addAll(
    List<HaikuoProgram> incoming, {
    String origin = '',
    List<String> notes = const [],
    Future<HaikuoDuplicateDecision> Function(List<HaikuoDuplicate> duplicates)?
    onDuplicates,
  }) async {
    final existing = await list();
    final byId = {for (final program in existing) program.id: program};
    final byName = <String, HaikuoProgram>{};
    for (final program in existing) {
      byName.putIfAbsent(program.name, () => program);
    }
    final added = <HaikuoProgram>[];
    final updated = <HaikuoProgram>[];
    final duplicates = <HaikuoDuplicate>[];
    for (final program in incoming) {
      final tagged = program.copyWith(
        origin: origin.isEmpty ? program.origin : origin,
      );
      final previous = byId[tagged.id];
      if (previous != null) {
        updated.add(tagged);
        byId[tagged.id] = tagged;
        byName[tagged.name] = tagged;
        continue;
      }
      final sameName = byName[tagged.name];
      if (sameName != null) {
        duplicates.add(HaikuoDuplicate(incoming: tagged, existing: sameName));
        continue;
      }
      added.add(tagged);
      byId[tagged.id] = tagged;
      byName[tagged.name] = tagged;
    }
    if (duplicates.isNotEmpty) {
      // 同一批里同一名字的多个新版只留最后一个，避免替换/保留时
      // 互相覆盖后仍剩同名项。
      final byDuplicateName = <String, HaikuoDuplicate>{};
      for (final duplicate in duplicates) {
        byDuplicateName[duplicate.incoming.name] = duplicate;
      }
      final effective = byDuplicateName.values.toList();
      final decision =
          await onDuplicates?.call(effective) ??
          HaikuoDuplicateDecision.keepBoth;
      switch (decision) {
        case HaikuoDuplicateDecision.cancel:
          return HaikuoImportResult(
            added: const [],
            updated: const [],
            cancelled: true,
            notes: ['已取消导入', ...notes],
          );
        case HaikuoDuplicateDecision.replace:
          for (final duplicate in effective) {
            final tagged = duplicate.incoming;
            // 按名字清掉全部同名旧项（含旧逻辑无提示堆出的重复项），
            // 只留新导入的这一份。
            byId.removeWhere(
              (id, program) => program.name == tagged.name && id != tagged.id,
            );
            byId[tagged.id] = tagged;
            byName[tagged.name] = tagged;
            updated.add(tagged);
          }
        case HaikuoDuplicateDecision.keepBoth:
          final taken = byName.keys.toSet();
          for (final duplicate in effective) {
            final renamed = _renameForKeepBoth(duplicate.incoming, taken);
            taken.add(renamed.name);
            byId[renamed.id] = renamed;
            byName[renamed.name] = renamed;
            added.add(renamed);
          }
      }
    }
    if (added.isEmpty && updated.isEmpty) {
      return HaikuoImportResult(
        added: const [],
        updated: const [],
        notes: notes,
      );
    }
    final merged = byId.values.toList()
      ..sort((a, b) {
        final left = a.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    await _writeAll(merged);
    return HaikuoImportResult(added: added, updated: updated, notes: notes);
  }

  /// 批量入库（跳过式，zip 备份导入专用）：同 id 或同标题已存在时
  /// 跳过并计数，绝不覆盖——内置规则（origin 为“内置规则”）也在内，
  /// 不弹重复对话框。同一批里同名重复只留第一份。
  /// 返回实际新增与跳过的条目；全部跳过时不写文件。
  Future<({List<HaikuoProgram> added, List<HaikuoProgram> skipped})>
  addAllSkipExisting(List<HaikuoProgram> incoming, {String origin = ''}) async {
    final existing = await list();
    final takenIds = {for (final program in existing) program.id};
    final takenNames = {for (final program in existing) program.name};
    final added = <HaikuoProgram>[];
    final skipped = <HaikuoProgram>[];
    for (final program in incoming) {
      final tagged = program.copyWith(
        origin: origin.isEmpty ? program.origin : origin,
      );
      if (takenIds.contains(tagged.id) || takenNames.contains(tagged.name)) {
        skipped.add(tagged);
        continue;
      }
      takenIds.add(tagged.id);
      takenNames.add(tagged.name);
      added.add(tagged);
    }
    if (added.isEmpty) {
      return (added: added, skipped: skipped);
    }
    final merged = [...existing, ...added]
      ..sort((a, b) {
        final left = a.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    await _writeAll(merged);
    return (added: added, skipped: skipped);
  }

  /// 保留两者时的改名：原名 + _2，_2 已被占就往后顺延（_3、_4…）；
  /// id 按新名重算，避免改名后的条目与原名条目 id 撞车。
  HaikuoProgram _renameForKeepBoth(HaikuoProgram program, Set<String> taken) {
    var suffix = 2;
    var name = '${program.name}_$suffix';
    while (taken.contains(name)) {
      suffix++;
      name = '${program.name}_$suffix';
    }
    final body = program.rawJson.isNotEmpty
        ? program.rawJson
        : program.script.isNotEmpty
        ? program.script
        : program.url;
    return program.copyWith(name: name, id: HaikuoProgram.makeId(name, body));
  }

  Future<void> remove(String id) async {
    final programs = await list();
    final remaining = programs.where((program) => program.id != id).toList();
    await _writeAll(remaining);
  }

  Future<void> clear() async {
    await _writeAll(const []);
  }

  // ---------- 收藏 / 历史 / 书签（独立文件 collections.json） ----------

  static const _collectionsFileName = 'collections.json';

  Future<File> get _collectionsFile async {
    final dir = await root;
    return File(p.join(dir.path, _collectionsFileName));
  }

  Future<Map<String, List<Map<String, dynamic>>>> _readCollections() async {
    final empty = <String, List<Map<String, dynamic>>>{
      'favorites': [],
      'history': [],
      'bookmarks': [],
    };
    try {
      final file = await _collectionsFile;
      if (!await file.exists()) return empty;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return empty;
      for (final key in empty.keys) {
        final list = decoded[key];
        if (list is List) {
          empty[key] = [
            for (final item in list)
              if (item is Map)
                {for (final e in item.entries) '${e.key}': e.value},
          ];
        }
      }
      return empty;
    } catch (_) {
      return empty;
    }
  }

  Future<void> _writeCollections(
    Map<String, List<Map<String, dynamic>>> data,
  ) async {
    final file = await _collectionsFile;
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(file.path);
  }

  bool _sameEntry(Map<String, dynamic> a, Map<String, dynamic> b) {
    return normalizeRuleTitle('${a['rule'] ?? ''}') ==
            normalizeRuleTitle('${b['rule'] ?? ''}') &&
        '${a['url'] ?? ''}' == '${b['url'] ?? ''}';
  }

  /// 记一条浏览历史：同规则同地址去重置顶，最新在前，上限 200 条。
  Future<void> recordHistory({
    required String rule,
    required String url,
    String title = '',
    String pic = '',
  }) async {
    if (url.isEmpty) return;
    final data = await _readCollections();
    final entry = <String, dynamic>{
      'rule': rule,
      'url': url,
      'title': title,
      'pic': pic,
      'at': DateTime.now().toIso8601String(),
    };
    final history = data['history']!
      ..removeWhere((item) => _sameEntry(item, entry));
    history.insert(0, entry);
    if (history.length > 200) history.removeRange(200, history.length);
    await _writeCollections(data);
  }

  Future<List<Map<String, dynamic>>> listHistory({String? rule}) async {
    final data = await _readCollections();
    final wanted = rule == null ? null : normalizeRuleTitle(rule);
    return [
      for (final item in data['history']!)
        if (wanted == null ||
            normalizeRuleTitle('${item['rule'] ?? ''}') == wanted)
          item,
    ];
  }

  /// 收藏开关：已收藏则取消并回 false，否则收藏并回 true。
  Future<bool> toggleFavorite(Map<String, dynamic> entry) async {
    final data = await _readCollections();
    final favorites = data['favorites']!;
    final existing = favorites.indexWhere((item) => _sameEntry(item, entry));
    if (existing >= 0) {
      favorites.removeAt(existing);
      await _writeCollections(data);
      return false;
    }
    favorites.insert(0, {...entry, 'at': DateTime.now().toIso8601String()});
    await _writeCollections(data);
    return true;
  }

  Future<bool> isFavorite({required String rule, required String url}) async {
    final data = await _readCollections();
    return data['favorites']!.any(
      (item) =>
          normalizeRuleTitle('${item['rule'] ?? ''}') ==
              normalizeRuleTitle(rule) &&
          '${item['url'] ?? ''}' == url,
    );
  }

  Future<List<Map<String, dynamic>>> listFavorites({
    String? rule,
    String? group,
  }) async {
    final data = await _readCollections();
    final wanted = rule == null ? null : normalizeRuleTitle(rule);
    return [
      for (final item in data['favorites']!)
        if ((wanted == null ||
                normalizeRuleTitle('${item['rule'] ?? ''}') == wanted) &&
            (group == null || '${item['group'] ?? ''}' == group))
          item,
    ];
  }

  Future<List<String>> listFavoriteGroups() async {
    final data = await _readCollections();
    final groups = <String>{};
    for (final item in data['favorites']!) {
      final group = '${item['group'] ?? ''}';
      if (group.isNotEmpty) groups.add(group);
    }
    return groups.toList()..sort();
  }

  Future<void> addBookmark(Map<String, dynamic> entry) async {
    final data = await _readCollections();
    final bookmarks = data['bookmarks']!
      ..removeWhere((item) => _sameEntry(item, entry));
    bookmarks.insert(0, {...entry, 'at': DateTime.now().toIso8601String()});
    await _writeCollections(data);
  }

  Future<void> removeBookmark({
    required String rule,
    required String url,
  }) async {
    final data = await _readCollections();
    data['bookmarks']!.removeWhere(
      (item) =>
          normalizeRuleTitle('${item['rule'] ?? ''}') ==
              normalizeRuleTitle(rule) &&
          '${item['url'] ?? ''}' == url,
    );
    await _writeCollections(data);
  }

  Future<List<Map<String, dynamic>>> listBookmarks({String? rule}) async {
    final data = await _readCollections();
    final wanted = rule == null ? null : normalizeRuleTitle(rule);
    return [
      for (final item in data['bookmarks']!)
        if (wanted == null ||
            normalizeRuleTitle('${item['rule'] ?? ''}') == wanted)
          item,
    ];
  }

  /// 导入本地 JSON 文件（.json / .txt / .zip / 口令文本都能吃）。
  Future<HaikuoImportResult> importFile(
    File file, {
    Future<HaikuoDuplicateDecision> Function(List<HaikuoDuplicate> duplicates)?
    onDuplicates,
  }) async {
    final bytes = await file.readAsBytes();
    return importBytes(
      bytes,
      origin: '文件：${p.basename(file.path)}',
      onDuplicates: onDuplicates,
    );
  }

  /// 从内存字节导入：文件选择器在部分机型上拿不到路径时，
  /// 页面层用选到的字节走这里兜底，不再只报“没拿到文件路径”。
  /// `.db` 备份数据库与含 `.db` 的 zip 包也在这里分流进数据库导入。
  Future<HaikuoImportResult> importBytes(
    List<int> bytes, {
    String origin = '文件',
    Future<HaikuoDuplicateDecision> Function(List<HaikuoDuplicate> duplicates)?
    onDuplicates,
  }) async {
    final outcome = await _programsFromBytes(bytes, origin: origin);
    return addAll(
      outcome.programs,
      origin: origin,
      notes: outcome.notes,
      onDuplicates: onDuplicates,
    );
  }

  /// 字节 → 小程序列表：先看是不是 SQLite 数据库，再看 zip 包里
  /// 有没有 `.db` 条目，最后走 JSON/口令解析。返回的 notes 里是
  /// 跳过/损坏的条目说明，页面层展示给用户。
  Future<({List<HaikuoProgram> programs, List<String> notes})>
  _programsFromBytes(List<int> bytes, {required String origin}) async {
    final notes = <String>[];
    if (isSqliteBytes(bytes)) {
      final programs = await _programsFromDbBytes(bytes, origin: origin);
      return (programs: programs, notes: notes);
    }
    final dbEntries = HaikuoCodec.zipDbEntries(bytes);
    if (dbEntries.isNotEmpty) {
      final programs = <HaikuoProgram>[];
      for (final entry in dbEntries) {
        try {
          programs.addAll(
            await _programsFromDbBytes(entry.bytes, origin: origin),
          );
        } on HaikuoFormatException catch (error) {
          notes.add('数据库条目 ${entry.name} 导入失败：${error.message}');
        }
      }
      // zip 里其余 JSON 条目照常解析；只有 JSON 时的 .db 跳过提示
      // 由数据库导入结果代替，不再重复报。
      final dropped = <String>[];
      try {
        programs.addAll(
          HaikuoCodec.parseBytes(bytes, origin: origin, dropped: dropped),
        );
      } on HaikuoFormatException {
        // 只有数据库、没有 JSON 时这里必然报错，数据库结果为准。
      }
      notes.addAll(dropped.where((note) => !note.contains('数据库条目')));
      if (programs.isEmpty) {
        throw const HaikuoFormatException('压缩包里没有找到小程序 JSON 或规则数据库');
      }
      return (programs: programs, notes: notes);
    }
    final programs = HaikuoCodec.parseBytes(
      bytes,
      origin: origin,
      dropped: notes,
    );
    return (programs: programs, notes: notes);
  }

  /// 一份 `.db` 字节 → 规则列表：读 `articlelistrule` 全表，
  /// 行转规则对象后走同一套归一解析。
  Future<List<HaikuoProgram>> _programsFromDbBytes(
    List<int> bytes, {
    required String origin,
  }) async {
    final rows = await _readDbRows(bytes);
    final rules = <Map<String, dynamic>>[];
    for (final row in rows) {
      final rule = haikuoDbRowToRule(row);
      if (rule == null) continue;
      rules.add(rule);
    }
    if (rules.isEmpty) {
      throw const HaikuoFormatException('数据库里没有找到可导入的规则');
    }
    final programs = HaikuoCodec.parseDecoded(rules, origin: origin);
    if (programs.isEmpty) {
      throw const HaikuoFormatException('数据库里没有识别到海阔小程序条目');
    }
    return programs;
  }

  /// 读备份数据库的 `articlelistrule` 全表（只读打开，读完就删临时文件）。
  Future<List<Map<String, dynamic>>> _readDbRows(List<int> bytes) async {
    final reader = _dbReader;
    if (reader != null) return reader(bytes);
    final dir = await root;
    final tmp = File(
      p.join(
        dir.path,
        'haikuo_import_${DateTime.now().microsecondsSinceEpoch}.db',
      ),
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      final db = await openDatabase(tmp.path, readOnly: true);
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
    } finally {
      try {
        await tmp.delete();
      } catch (_) {
        // 临时文件删不掉也无妨，下次导入会覆盖
      }
    }
  }

  /// 导入一段文本：可能是 JSON 正文，也可能是口令。
  Future<HaikuoImportResult> importText(
    String text, {
    String origin = '文本',
    Future<HaikuoDuplicateDecision> Function(List<HaikuoDuplicate> duplicates)?
    onDuplicates,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const HaikuoFormatException('内容为空');
    }
    // 云口令短码（云6oooole/xxxxxx/xxx）：先联网取回口令文本，
    // 再按普通口令走；未知云编号在这里直接报明原因。
    final cloudUrl = HaikuoCodec.cloudApiUrl(trimmed);
    if (cloudUrl != null) {
      final bytes = await _fetch(cloudUrl);
      final resolved = HaikuoCodec.parseCloudApiResponse(
        HaikuoCodec.decodeText(bytes),
      );
      return importText(resolved, origin: origin, onDuplicates: onDuplicates);
    }
    // 纯 JSON 直接走解析，不需要联网。
    if (HaikuoCodec.looksLikeJson(trimmed)) {
      final programs = HaikuoCodec.parseText(trimmed, origin: origin);
      return addAll(programs, origin: origin, onDuplicates: onDuplicates);
    }
    final candidates = HaikuoCodec.extractCandidates(trimmed);
    final errors = <String>[];
    for (final candidate in candidates) {
      try {
        final programs = await _importCandidate(candidate, origin);
        if (programs.isNotEmpty) {
          return await addAll(
            programs,
            origin: origin,
            onDuplicates: onDuplicates,
          );
        }
      } on HaikuoFormatException catch (error) {
        errors.add(error.message);
      } catch (error) {
        errors.add('$error');
      }
    }
    throw HaikuoFormatException(
      errors.isEmpty ? '口令里没有可用的海阔小程序' : '口令解析失败：${errors.first}',
    );
  }

  Future<List<HaikuoProgram>> _importCandidate(
    String candidate,
    String origin,
  ) async {
    final value = candidate.trim();
    if (value.isEmpty) return const [];
    if (value.toLowerCase().startsWith('http://') ||
        value.toLowerCase().startsWith('https://')) {
      final bytes = await _fetch(value);
      return HaikuoCodec.parseBytes(bytes, origin: origin);
    }
    if (HaikuoCodec.looksLikeJson(value)) {
      return HaikuoCodec.parseText(value, origin: origin);
    }
    final decoded = HaikuoCodec.tryBase64(value);
    if (decoded != null && decoded.isNotEmpty) {
      return HaikuoCodec.parseBytes(decoded, origin: origin);
    }
    return HaikuoCodec.parseText(value, origin: origin);
  }

  /// 从链接导入：可以是 JSON 直链、zip 包，也可以是口令页面。
  Future<HaikuoImportResult> importUrl(
    String url, {
    Future<HaikuoDuplicateDecision> Function(List<HaikuoDuplicate> duplicates)?
    onDuplicates,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw const HaikuoFormatException('链接为空');
    }
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      throw const HaikuoFormatException('链接需要以 http:// 或 https:// 开头');
    }
    final bytes = await _fetch(trimmed);
    List<HaikuoProgram> programs;
    var notes = const <String>[];
    try {
      final outcome = await _programsFromBytes(bytes, origin: '链接');
      programs = outcome.programs;
      notes = outcome.notes;
    } on HaikuoFormatException {
      // 拿回来的可能是 HTML 页面，页面上写着口令：退一步按文本再认一次。
      final text = HaikuoCodec.decodeText(bytes);
      final candidates = HaikuoCodec.extractCandidates(text);
      programs = const [];
      for (final candidate in candidates) {
        if (candidate == trimmed) continue;
        try {
          final parsed = await _importCandidate(candidate, '链接');
          if (parsed.isNotEmpty) {
            programs = parsed;
            break;
          }
        } catch (_) {
          continue;
        }
      }
      if (programs.isEmpty) {
        throw const HaikuoFormatException('这个链接里没有找到小程序 JSON');
      }
    }
    return addAll(
      programs,
      origin: '链接',
      notes: notes,
      onDuplicates: onDuplicates,
    );
  }

  Future<List<int>> _fetch(String url) async {
    final client = _httpClient ?? http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(url),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
              'Accept': 'application/json, text/plain, */*',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HaikuoFormatException('下载失败：HTTP ${response.statusCode}');
      }
      return response.bodyBytes;
    } on HaikuoFormatException {
      rethrow;
    } catch (error) {
      throw HaikuoFormatException('下载失败：$error');
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  /// 导出成一份 JSON，方便换机或备份。
  Future<String> exportJson(List<HaikuoProgram> programs) async {
    final payload = {
      'name': '海阔小程序导出',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': programs.map((program) => program.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 内置规则包版本：assets/haikuo_builtin_rules.json 每次更新内容时 +1。
  /// 只有版本变化时才重新播种；用户删掉的内置规则在版本不变时不再自动补回。
  /// v2：2026-11-16 合并批（35 条 → 164 条：3 条原地摘除、6 条替换、129 条新增），
  /// 同日用户令删没验过的 34 条、短剧one 恢复旧版（164 条 → 130 条），版本仍为 2
  ///（164 条包尚未随任何构建发出，v2 首次播种即 130 条）。
  /// v3：2026-11-16 用户令新版另加，🔞91成人短剧(新) 追加，130 → 131 条。
  /// v4：2026-11-16 用户令 26 条工具规则进包，实加 24 条（131 → 155 条；
  /// JMComic2本地缺 erji 模块、规则生成器Pro 含 3 处正则内“立即播放”撞包
  /// 测试，两条 HOLD 未进，原样未改、等定夺）。
  /// v5：2026-11-16 两条同批追加（155 → 157 条）：🔞MissAV 修复版（用户手机
  /// 实测可播）与规则生成器Pro（HOLD 解除：包测试已排除正则字面量内出现）。
  /// v6：2026-11-16 JMComic2本地修复版追加（157 → 158 条；HOLD 解除：用户令
  /// “会蹦就修”，搜索卡片 url 改用同页现成的 csdown.erji 写法，只动一处）。
  /// v7：2026-11-16 用户令删 26 条用不了的工具规则（158 条 → 132 条）；
  /// 播种新增撤包清理：升版时按上一版标记里的标题清掉已撤包的内置副
  /// 本（只清来源为“内置规则”的，用户导入的同名规则不动）。
  /// v8：2026-11-17 海阔 132 条全面检查修复（81 条修复版入包，条数与顺
  /// 序不变，MissAV 一字未动）；播种清理行为与 v7 相同。
  /// v9：2026-11-17 Apollo 3 条重写为普通自包含规则入包（条数与顺序
  /// 不变，MissAV 一字未动）。
  /// v10：2026-11-17 zip 修复规则 14 条追加入包（132 → 146 条，现有
  /// 132 条顺序标题不动；2879 摘除详情播放文字行）。
  /// v13：2026-11-18 Phase 3，Jav精品规则同步模块文件（规则本体未动，
  /// 仅 fixlog 与 version；模块文件换成与内嵌页同一份代码）。
  /// v14：2026-11-19 MissAV 规则 v6 多域名回落（条数与顺序不变，其余
  /// 145 条一字未动；MissAV 模块新增 hosts 回落表与 get/ok/origin）。
  /// v15：2026-11-19 MissAV 规则 v7 取流验盾（条数与顺序不变，其余
  /// 145 条一字未动；videoParse 两处 lazyRule 取流后先验播放列表，
  /// 盾页直接报提示、不再把死地址交给播放器转圈）。
  /// v16：2026-11-22 用户令删 MissAV 全部旧站，🔞MissAV 规则撤包
  /// （146 → 145 条；已装设备升版重播种时按 v7 机制清掉旧的内置副本）。
  static const builtinBundleVersion = 16;
  static const builtinAssetPath = 'assets/haikuo_builtin_rules.json';
  static const _builtinMarkerFile = 'builtin_seeded.json';

  /// 把 App 自带的海阔规则播种进本地库（首次打开海阔页时调用一次）。
  ///
  /// 与用户导入的规则并列存放、互不覆盖：同名内置规则出新版时按标题替换
  /// 旧版（规则全文一变 id 就变，只按 id 去重会留重复项，所以按标题去重）；
  /// 若用户已导入同名规则，播种时以内置版为准（同名只留一份）；
  /// 用户删掉的内置规则只有版本升级或手动“恢复内置规则”时才补回。
  /// v7 起升版时按上一版标记清理已撤包的内置副本（只清来源为“内置规则”
  /// 的，用户导入的同名规则不动）。
  /// 返回新增/更新的条数；任何异常都吞掉返回 0，绝不拖垮页面加载。
  /// [bundleText] 仅供测试注入；[force] 为 true 时忽略版本标记重新播种。
  Future<int> ensureBuiltinRules({
    String? bundleText,
    bool force = false,
  }) async {
    try {
      final dir = await root;
      final marker = File(p.join(dir.path, _builtinMarkerFile));
      // 上一版播种记下的内置标题：升版后据此清理已撤包的内置副本。
      var previousNames = <String>{};
      var markerCurrent = false;
      if (await marker.exists()) {
        try {
          final saved = jsonDecode(await marker.readAsString());
          if (saved is Map) {
            final names = saved['names'];
            if (names is List) {
              previousNames = names.map((name) => '$name').toSet();
            }
            markerCurrent = saved['version'] == builtinBundleVersion;
          }
        } catch (_) {
          // 标记损坏就当没播种过，继续往下走（上一版标题未知，不做撤包清理）。
          previousNames = <String>{};
        }
      }
      if (!force && markerCurrent) return 0;
      final text = bundleText ?? await rootBundle.loadString(builtinAssetPath);
      final programs = HaikuoCodec.parseText(text, origin: '内置规则');
      if (programs.isEmpty) return 0;
      final existing = await list();
      final byId = {for (final program in existing) program.id: program};
      final incoming = <HaikuoProgram>[];
      for (final program in programs) {
        if (byId.containsKey(program.id)) continue;
        incoming.add(program);
      }
      // 撤包标题 = 上一版有、新包里没有的标题。
      final removedNames = previousNames.difference(
        programs.map((program) => program.name).toSet(),
      );
      // 同名旧版（全文变了、id 不同）先摘掉，再写入新版，避免重复项；
      // 已撤包的内置副本一并摘掉（只认来源“内置规则”，用户导入的同名
      // 规则即使同名也保留）。
      final merged = existing
          .where(
            (old) =>
                !incoming.any((next) => next.name == old.name) &&
                !(old.origin == '内置规则' && removedNames.contains(old.name)),
          )
          .toList();
      merged.addAll(incoming);
      merged.sort((a, b) {
        final left = a.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
      await _writeAll(merged);
      await marker.writeAsString(
        jsonEncode({
          'version': builtinBundleVersion,
          'seededAt': DateTime.now().toIso8601String(),
          'names': programs.map((program) => program.name).toList(),
        }),
        flush: true,
      );
      return incoming.length;
    } catch (_) {
      return 0;
    }
  }
}

/// E38：saveFile 落盘持久化（扁平 basename 键空间，与内存 `_savedFiles`
/// 同键、明文存储、flag 忽略——混用读回不断裂）。
///
/// 布局：`<haikuo 根>/saved_files/<basename>`，与 `rule_files/`（备份
/// 导入的规则私有文件）分目录，不与其它存储键冲突。**不做规则名隔离**：
/// 语料里同族规则有意共享同一文件（JavDB v3/v5 共用 `cookie.txt`、
/// Supjav 两条共用 `supjav_cookie.txt`），隔离会拆散共享；扁平落盘
/// 保持现有共享语义。规则删除时不清理（扁平键空间无归属可查，且
/// 共享文件误删会伤及其它规则；与 `rule_files/` 现状一致）。
/// 坏名（空/`.`/`..`）静默跳过，不抛错（saveFile 语义本就宽容）。
abstract final class HaikuoSavedFiles {
  static const _dirName = 'saved_files';

  static String? _safeBaseName(String fileName) {
    final base = p.basename(fileName.replaceAll('\\', '/'));
    if (base.isEmpty || base == '.' || base == '..') return null;
    return base;
  }

  static Future<void> writeSavedFile(
    Directory root,
    String fileName,
    List<int> bytes,
  ) async {
    final base = _safeBaseName(fileName);
    if (base == null) return;
    final dir = Directory(p.join(root.path, _dirName));
    await dir.create(recursive: true);
    await File(p.join(dir.path, base)).writeAsBytes(bytes, flush: true);
  }

  static Future<Uint8List?> readSavedFile(
    Directory root,
    String fileName,
  ) async {
    final base = _safeBaseName(fileName);
    if (base == null) return null;
    final file = File(p.join(root.path, _dirName, base));
    try {
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteSavedFile(Directory root, String fileName) async {
    final base = _safeBaseName(fileName);
    if (base == null) return;
    final file = File(p.join(root.path, _dirName, base));
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉也不拦规则
    }
  }
}
