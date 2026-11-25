import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_sql_import.dart';

/// 内存假执行器：真存表，真跑归一化要用的那几类 SQL（PRAGMA
/// table_info、CREATE TABLE、ALTER TABLE RENAME、INSERT OR
/// IGNORE、分页 SELECT、COUNT），不碰真 sqlite。断言时可直接读
/// 归一化后标准表里的行。
class _MemTable {
  _MemTable(this.columns, this.pk);

  final List<String> columns;
  final List<String> pk;
  final rows = <Map<String, Object?>>[];
}

class _MemoryExecutor implements SqlImportExecutor {
  final _tables = <String, _MemTable>{};
  var closed = false;

  _MemTable table(String name) => _tables[name.toLowerCase()]!;

  bool hasTable(String name) => _tables.containsKey(name.toLowerCase());

  @override
  Future<void> execute(String sql) async {
    final text = sql.trim();
    final upper = text.toUpperCase();
    if (upper.startsWith('PRAGMA')) return;
    if (upper.startsWith('CREATE TABLE')) {
      _createTable(text);
      return;
    }
    if (upper.startsWith('ALTER TABLE')) {
      final m = RegExp(
        r'ALTER TABLE\s+"?([\w]+)"?\s+RENAME TO\s+"?([\w]+)"?',
        caseSensitive: false,
      ).firstMatch(text);
      if (m == null) throw StateError('fake: 解析不了 $sql');
      final from = m.group(1)!.toLowerCase();
      final to = m.group(2)!.toLowerCase();
      final t = _tables.remove(from);
      if (t == null) throw StateError('fake: 没有表 $from');
      if (_tables.containsKey(to)) throw StateError('fake: $to 已存在');
      _tables[to] = t;
      return;
    }
    // CREATE INDEX 等其它 DDL：归一化不需要，忽略。
  }

  void _createTable(String sql) {
    final m = RegExp(
      r'CREATE TABLE\s+"?([\w]+)"?\s*\((.*)\)\s*;?\s*$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(sql);
    if (m == null) throw StateError('fake: 解析不了 $sql');
    final name = m.group(1)!.toLowerCase();
    final body = m.group(2)!;
    final columns = <String>[];
    final pk = <String>[];
    for (final def in _splitTopLevel(body)) {
      final d = def.trim();
      if (d.isEmpty) continue;
      final up = d.toUpperCase();
      if (up.startsWith('PRIMARY KEY')) {
        final inner = RegExp(r'\((.*)\)', dotAll: true).firstMatch(d);
        if (inner != null) {
          for (final c in inner.group(1)!.split(',')) {
            pk.add(_bareIdent(c.trim()));
          }
        }
        continue;
      }
      if (up.startsWith('UNIQUE') ||
          up.startsWith('FOREIGN') ||
          up.startsWith('CHECK') ||
          up.startsWith('CONSTRAINT')) {
        continue;
      }
      final col = _bareIdent(d.split(RegExp(r'\s')).first);
      columns.add(col);
      if (RegExp(r'\bPRIMARY KEY\b', caseSensitive: false).hasMatch(d)) {
        pk.add(col);
      }
    }
    _tables[name] = _MemTable(columns, pk);
  }

  @override
  Future<void> executeBatch(List<String> statements) async {
    for (final s in statements) {
      _insert(s);
    }
  }

  void _insert(String sql) {
    final m = RegExp(
      r'INSERT\s+(OR IGNORE\s+)?INTO\s+"?([\w]+)"?\s*(?:\(([^)]*)\))?\s*VALUES\s*\((.*)\)\s*;?\s*$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(sql.trim());
    if (m == null) throw StateError('fake: 解析不了 $sql');
    final orIgnore = m.group(1) != null;
    final tableName = m.group(2)!.toLowerCase();
    final table = _tables[tableName];
    if (table == null) throw StateError('fake: 没有表 $tableName');
    final colList = m.group(3);
    final columns = colList == null
        ? table.columns
        : [for (final c in colList.split(',')) _bareIdent(c.trim())];
    final values = _splitTopLevel(m.group(4)!).map(_parseValue).toList();
    if (values.length != columns.length) {
      throw StateError('fake: 列数与值数不符 $sql');
    }
    final row = <String, Object?>{};
    for (var i = 0; i < columns.length; i++) {
      row[columns[i]] = values[i];
    }
    if (orIgnore && table.pk.isNotEmpty) {
      final clash = table.rows.any(
        (r) => table.pk.every((c) => r[c] == row[c]),
      );
      if (clash) return;
    }
    table.rows.add(row);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    final text = sql.trim();
    final upper = text.toUpperCase();
    if (upper.contains('SQLITE_MASTER')) {
      return [for (final name in _tables.keys) {'name': name}];
    }
    final pragma = RegExp(
      r'''PRAGMA\s+table_info\("?([^"]+)"?\)''',
      caseSensitive: false,
    ).firstMatch(text);
    if (pragma != null) {
      final table = _tables[pragma.group(1)!.toLowerCase()];
      if (table == null) return const [];
      return [
        for (final c in table.columns)
          {'name': c, 'pk': table.pk.contains(c) ? 1 : 0},
      ];
    }
    final count = RegExp(
      r'SELECT COUNT\(\*\) FROM\s+"?([\w]+)"?(?:\s+WHERE\s+(.+))?$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(text);
    if (count != null) {
      final table = _tables[count.group(1)!.toLowerCase()];
      if (table == null) return const [
        {'COUNT(*)': 0},
      ];
      var rows = table.rows;
      final where = count.group(2);
      if (where != null) {
        // 只认 _validate 的形状：c IS NOT NULL AND c <> ''
        final col = RegExp(
          r'''(\w+)\s+IS NOT NULL''',
          caseSensitive: false,
        ).firstMatch(where)?.group(1);
        if (col != null) {
          rows = rows
              .where((r) {
                final v = r[col];
                return v != null && v.toString().isNotEmpty;
              })
              .toList();
        }
      }
      return [
        {'COUNT(*)': rows.length},
      ];
    }
    final page = RegExp(
      r'SELECT\s+(.+?)\s+FROM\s+"?([\w]+)"?\s+ORDER BY rowid LIMIT (\d+) OFFSET (\d+)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(text);
    if (page != null) {
      final table = _tables[page.group(2)!.toLowerCase()];
      if (table == null) return const [];
      final cols = [for (final c in page.group(1)!.split(',')) c.trim()];
      final limit = int.parse(page.group(3)!);
      final offset = int.parse(page.group(4)!);
      final out = <Map<String, Object?>>[];
      for (var i = offset; i < table.rows.length && out.length < limit; i++) {
        final row = <String, Object?>{};
        for (final c in cols) {
          if (c.toLowerCase() == 'rowid') {
            row['rowid'] = i + 1;
          } else {
            row[_bareIdent(c)] = table.rows[i][_bareIdent(c)];
          }
        }
        out.add(row);
      }
      return out;
    }
    throw StateError('fake: 答不了 $sql');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 顶层逗号切分：括号里与单引号字符串里的逗号不切。
List<String> _splitTopLevel(String s) {
  final out = <String>[];
  var depth = 0;
  var inString = false;
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inString) {
      buf.write(c);
      if (c == "'") {
        if (i + 1 < s.length && s[i + 1] == "'") {
          buf.write("'");
          i++;
        } else {
          inString = false;
        }
      }
      continue;
    }
    if (c == "'") {
      inString = true;
      buf.write(c);
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == ',' && depth == 0) {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(c);
  }
  final rest = buf.toString();
  if (rest.trim().isNotEmpty) out.add(rest);
  return out;
}

Object? _parseValue(String s) {
  s = s.trim();
  if (s.toUpperCase() == 'NULL') return null;
  if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) {
    return s.substring(1, s.length - 1).replaceAll("''", "'");
  }
  return num.tryParse(s) ?? s;
}

String _bareIdent(String s) {
  s = s.trim();
  if (s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith('`') && s.endsWith('`')) ||
          (s.startsWith('[') && s.endsWith(']')))) {
    return s.substring(1, s.length - 1);
  }
  return s;
}

void main() {
  group('ActressSqlImporter 宽容映射导入', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sql_norm_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<SqlImportExecutor> Function(String) factoryFor(
      _MemoryExecutor executor,
    ) {
      return (tempPath) async {
        await File(tempPath).writeAsString('NEWDB');
        return executor;
      };
    }

    Future<ActressSqlImportResult> runImport(
      _MemoryExecutor executor,
      String sqlText,
    ) async {
      final sqlFile = File('${tempDir.path}/in.sql');
      await sqlFile.writeAsString(sqlText);
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      return importer.importFile(
        sqlPath: sqlFile.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
    }

    test('列名不一样：作品表 + 人物表都能归一化', () async {
      final executor = _MemoryExecutor();
      final result = await runImport(executor, '''
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE movies(id INTEGER PRIMARY KEY, moviename TEXT, cover_url TEXT, play_url TEXT, actor TEXT, typename TEXT, pubdate TEXT);
CREATE TABLE stars(star_id INTEGER PRIMARY KEY, star_name TEXT, avatar TEXT);
INSERT INTO movies VALUES(1,'片名一','https://img.example.com/1.jpg','https://cdn.example.com/1.m3u8','佐藤花','有码','2024-01-01');
INSERT INTO movies VALUES(2,'片名二','https://img.example.com/2.jpg','https://cdn.example.com/2.m3u8','佐藤花、铃木美','无码','2024-02-01');
INSERT INTO movies VALUES(3,'没地址的片','https://img.example.com/3.jpg','','佐藤花','有码','2024-03-01');
INSERT INTO stars VALUES(101,'佐藤花','https://img.example.com/av101.jpg');
INSERT INTO stars VALUES(102,'铃木美','https://img.example.com/av102.jpg');
COMMIT;
''');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 2);
      expect(result.actresses, 2);
      expect(result.playUrls, 2);
      expect(result.covers, 2);
      expect(result.avatars, 2);
      expect(result.skipped, 1);
      expect(result.warnings, contains('跳过 1 行（没有播放地址）'));

      // 归一化后的标准表：列表能出、封面/播放链接都在。
      final videos = executor.table('videos').rows;
      expect(videos, hasLength(2));
      final first = videos.firstWhere((r) => r['vod_id'] == '1');
      expect(first['title'], '片名一');
      expect(first['pic_url'], 'https://img.example.com/1.jpg');
      expect(first['m3u8_url'], 'https://cdn.example.com/1.m3u8');
      expect(first['vod_play_url'], 'https://cdn.example.com/1.m3u8');
      expect(first['type_name'], '有码');
      expect(first['vod_play_from'], 'movies');
      // 首页分类从 video_category 取。
      final categories = executor.table('video_category').rows;
      expect(categories, hasLength(2));
      expect(
        categories.map((r) => '${r['vod_id']}:${r['main_category']}'),
        containsAll(['1:有码', '2:无码']),
      );
      // 人物：头像在，作品挂在人名下。
      final actresses = executor.table('actresses').rows;
      expect(actresses, hasLength(2));
      final sato = actresses.firstWhere((r) => r['name'] == '佐藤花');
      expect(sato['cate_id'], '101');
      expect(sato['avatar'], 'https://img.example.com/av101.jpg');
      final links = executor.table('video_actress').rows;
      expect(links, hasLength(3));
      expect(
        links.map((r) => '${r['vod_id']}:${r['cate_id']}'),
        containsAll(['1:101', '2:101', '2:102']),
      );
      // 播放地址表：两条都能播。
      final urls = executor.table('video_play_urls').rows;
      expect(urls, hasLength(2));
      expect(
        urls.map((r) => r['play_url']),
        containsAll([
          'https://cdn.example.com/1.m3u8',
          'https://cdn.example.com/2.m3u8',
        ]),
      );
    });

    test('缺可选字段：只有番号/标题/地址也能导', () async {
      final executor = _MemoryExecutor();
      final result = await runImport(executor, '''
CREATE TABLE movies(videoid TEXT, videoname TEXT, videourl TEXT);
INSERT INTO movies VALUES('A001','只有三列的片','https://cdn.example.com/a.m3u8');
INSERT INTO movies VALUES('A002','第二部','https://cdn.example.com/b.m3u8');
''');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 2);
      expect(result.actresses, 0);
      expect(result.playUrls, 2);
      expect(result.covers, 0);
      expect(result.avatars, 0);
      expect(result.skipped, 0);
      expect(result.warnings, contains('导入的库里没有演员信息'));
      final videos = executor.table('videos').rows;
      expect(videos.first['vod_id'], 'A001');
      expect(videos.first['pic_url'], '');
      expect(videos.first['vod_play_url'], 'https://cdn.example.com/a.m3u8');
    });

    test('标准表名但结构不对：改名后重建标准表', () async {
      final executor = _MemoryExecutor();
      final result = await runImport(executor, '''
CREATE TABLE videos(id INTEGER PRIMARY KEY, name TEXT, url TEXT);
INSERT INTO videos VALUES(1,'标准名错结构','https://cdn.example.com/x.m3u8');
''');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 1);
      expect(result.playUrls, 1);
      expect(executor.hasTable('videos_source'), isTrue);
      final videos = executor.table('videos').rows;
      expect(videos.single['vod_id'], '1');
      expect(videos.single['title'], '标准名错结构');
      expect(
        videos.single['vod_play_url'],
        'https://cdn.example.com/x.m3u8',
      );
    });

    test('播放地址容差：正片\$地址与 JSON 数组都取到真地址', () async {
      final executor = _MemoryExecutor();
      final result = await runImport(executor, '''
CREATE TABLE vods(vodid TEXT, vodname TEXT, vodplayurl TEXT);
INSERT INTO vods VALUES('B001','分段地址','正片\$https://cdn.example.com/c.m3u8');
INSERT INTO vods VALUES('B002','数组地址','["https://cdn.example.com/d.m3u8"]');
''');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 2);
      expect(result.playUrls, 2);
      final videos = executor.table('videos').rows;
      expect(
        videos.firstWhere((r) => r['vod_id'] == 'B001')['vod_play_url'],
        'https://cdn.example.com/c.m3u8',
      );
      expect(
        videos.firstWhere((r) => r['vod_id'] == 'B002')['vod_play_url'],
        'https://cdn.example.com/d.m3u8',
      );
    });

    test('认不出作品表：没有标题 + 地址的表就报错', () async {
      final executor = _MemoryExecutor();
      final result = await runImport(executor, '''
CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);
INSERT INTO notes VALUES(1,'hello');
''');
      expect(result.ok, isFalse);
      expect(result.error, contains('认不出作品表'));
    });

    test('没有播放地址的行全跳过：库里一部都不剩就校验不过', () async {
      final executor = _MemoryExecutor();
      final result = await runImport(executor, '''
CREATE TABLE movies(id INTEGER PRIMARY KEY, moviename TEXT, play_url TEXT);
INSERT INTO movies VALUES(1,'空地址','');
''');
      expect(result.ok, isFalse);
      expect(result.error, contains('没有作品'));
    });
  });
}
