import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'content_legado.dart';
import 'content_models.dart';
import 'content_py.dart';
import 'content_registry.dart';
import 'content_txt.dart';
import 'import_file_store.dart';

enum NovelImportKind { py, txt, json }

class NovelImportRecord {
  const NovelImportRecord({
    required this.id,
    required this.name,
    required this.fileName,
    this.kind = NovelImportKind.py,
    this.sourceType = 0,
  });

  final String id;
  final String name;
  final String fileName;
  final NovelImportKind kind;
  final int sourceType;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'fileName': fileName,
    'kind': kind.name,
    'sourceType': sourceType,
  };

  static NovelImportRecord? fromJson(Map<String, dynamic> map) {
    final id = map['id']?.toString() ?? '';
    final fileName = map['fileName']?.toString() ?? '';
    if (id.isEmpty || fileName.isEmpty) return null;
    final rawKind = map['kind']?.toString();
    final kind = rawKind == 'txt'
        ? NovelImportKind.txt
        : rawKind == 'json'
        ? NovelImportKind.json
        : rawKind == 'py'
        ? NovelImportKind.py
        : fileName.toLowerCase().endsWith('.txt')
        ? NovelImportKind.txt
        : fileName.toLowerCase().endsWith('.json')
        ? NovelImportKind.json
        : NovelImportKind.py;
    final rawType = map['sourceType'];
    final sourceType = rawType is num
        ? rawType.toInt()
        : int.tryParse(rawType?.toString() ?? '') ?? 0;
    return NovelImportRecord(
      id: id,
      name: map['name']?.toString() ?? id,
      fileName: fileName,
      kind: kind,
      sourceType: sourceType,
    );
  }

  ContentSource toSource() => switch (kind) {
    NovelImportKind.txt => TxtContentSource(
      id: id,
      name: name,
      importedFileName: fileName,
      section: ContentSection.novel,
    ),
    NovelImportKind.json => JsonContentSource(
      id: id,
      name: name,
      importedFileName: fileName,
      section: ContentSection.novel,
      sourceType: sourceType,
    ),
    NovelImportKind.py => PyContentSource(
      id: id,
      name: name,
      importedFileName: fileName,
      section: ContentSection.novel,
    ),
  };
}

class NovelSourceStore {
  NovelSourceStore._();

  static const prefsKey = 'novel_py_imports';

  /// 内置 JSON 书源的开关态（关掉可再开）与删除态（删了不复活）。
  static const hiddenBuiltinKey = 'novel_builtin_json_hidden';
  static const removedBuiltinKey = 'novel_builtin_json_removed';

  static Future<Set<String>> _loadIdSet(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toSet();
    } catch (_) {}
    return <String>{};
  }

  static Future<void> _saveIdSet(String key, Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(ids.toList()));
  }

  static bool _isBuiltinJsonId(String id) =>
      ContentRegistry.novelJsonBuiltins.any((source) => source.id == id);

  static Future<Set<String>> builtinHiddenIds() => _loadIdSet(hiddenBuiltinKey);

  static Future<Set<String>> builtinRemovedIds() =>
      _loadIdSet(removedBuiltinKey);

  static Future<void> setBuiltinHidden(String id, bool hidden) async {
    if (!_isBuiltinJsonId(id)) return;
    final ids = await _loadIdSet(hiddenBuiltinKey);
    if (hidden) {
      ids.add(id);
    } else {
      ids.remove(id);
    }
    await _saveIdSet(hiddenBuiltinKey, ids);
  }

  static Future<void> removeBuiltin(String id) async {
    if (!_isBuiltinJsonId(id)) return;
    final removed = await _loadIdSet(removedBuiltinKey);
    removed.add(id);
    await _saveIdSet(removedBuiltinKey, removed);
    final hidden = await _loadIdSet(hiddenBuiltinKey);
    if (hidden.remove(id)) await _saveIdSet(hiddenBuiltinKey, hidden);
  }

  static Future<void> restoreRemovedBuiltins() async {
    await _saveIdSet(removedBuiltinKey, <String>{});
  }

  static bool isNovelComicPyText(String text) =>
      text.contains('novel://') || text.contains('pics://');

  static Future<List<NovelImportRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final records = <NovelImportRecord>[];
      for (final row in decoded) {
        if (row is Map) {
          final record = NovelImportRecord.fromJson(
            Map<String, dynamic>.from(row),
          );
          if (record != null) records.add(record);
        }
      }
      return records;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<NovelImportRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
  }

  static Future<void> applyToRegistry() async {
    final records = await load();
    ContentRegistry.setNovelImports([
      for (final record in records) record.toSource(),
    ]);
    ContentRegistry.setNovelJsonVisibility(
      hidden: await _loadIdSet(hiddenBuiltinKey),
      removed: await _loadIdSet(removedBuiltinKey),
    );
  }

  static Future<NovelImportRecord?> importPicked() async {
    final result = await importPickedMany();
    return result.records.isEmpty ? null : result.records.first;
  }

  static Future<({List<NovelImportRecord> records, int skipped})>
  importPickedMany() async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['py', 'txt', 'json'],
      );
    } on PlatformException catch (e) {
      if (e.code != 'unknown_path') rethrow;
      picked = await FilePicker.pickFile(type: FileType.any);
      final ext = picked?.extension?.toLowerCase();
      if (picked != null && ext != 'py' && ext != 'txt' && ext != 'json') {
        throw const FormatException('不是 py、txt 或 json 文件');
      }
    }
    if (picked == null) return (records: <NovelImportRecord>[], skipped: 0);
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) throw const FormatException('空文件');
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final isTxt = picked.name.toLowerCase().endsWith('.txt');
    final isJson = picked.name.toLowerCase().endsWith('.json');
    dynamic decoded;
    var decodedJson = false;
    if (isJson || isTxt) {
      try {
        decoded = jsonDecode(text);
        decodedJson = true;
      } catch (_) {
        if (isJson) throw const FormatException('不是合法 JSON');
      }
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final records = await load();
    var added = 0;
    var skipped = 0;
    Future<NovelImportRecord?> saveJsonSource(
      Map<String, dynamic> map,
      String id,
    ) async {
      LegadoJsonInfo info;
      try {
        info = validateLegadoJson(jsonEncode(map));
      } catch (_) {
        return null;
      }
      final fileName = await ImportFileStore.save(
        id,
        'json',
        utf8.encode(jsonEncode(map)),
      );
      return NovelImportRecord(
        id: id,
        name: info.name,
        fileName: fileName,
        kind: NovelImportKind.json,
        sourceType: info.type,
      );
    }

    if (decodedJson && decoded is List) {
      for (var i = 0; i < decoded.length; i++) {
        final item = decoded[i];
        if (item is! Map) {
          skipped++;
          continue;
        }
        final record = await saveJsonSource(
          Map<String, dynamic>.from(item),
          'novel_${stamp}_$i',
        );
        if (record == null) {
          skipped++;
        } else {
          records.add(record);
          added++;
        }
      }
      if (added == 0) {
        throw FormatException('批量文件里没有可导入的书源，跳过 $skipped 条');
      }
      await _save(records);
      return (
        records: records.sublist(records.length - added),
        skipped: skipped,
      );
    }
    if (decodedJson && decoded is Map) {
      final record = await saveJsonSource(
        Map<String, dynamic>.from(decoded),
        'novel_$stamp',
      );
      if (record == null) {
        validateLegadoJson(text);
        throw const FormatException('不是书源 JSON');
      }
      records.add(record);
      await _save(records);
      return (records: [record], skipped: 0);
    }
    if (!isTxt && !isNovelComicPyText(text)) {
      throw const FormatException('不是小说漫画源');
    }
    final fileName = await ImportFileStore.save(
      'novel_$stamp',
      isTxt ? 'txt' : 'py',
      bytes,
    );
    final base = (picked.name.split('/').last.split('\\').last).replaceAll(
      RegExp(r'\.(py|txt|json)$', caseSensitive: false),
      '',
    );
    final record = NovelImportRecord(
      id: 'novel_$stamp',
      name: base.isEmpty ? '小说源$stamp' : base,
      fileName: fileName,
      kind: isTxt ? NovelImportKind.txt : NovelImportKind.py,
      sourceType: 0,
    );
    records.add(record);
    await _save(records);
    return (records: [record], skipped: 0);
  }

  static Future<void> remove(NovelImportRecord record) async {
    final records = await load();
    records.removeWhere((item) => item.id == record.id);
    await _save(records);
    await ImportFileStore.delete(record.fileName);
  }
}
