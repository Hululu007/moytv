import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'actress_generic_db.dart' show extractPlayUrl;
import 'actress_spreadsheet.dart';
import 'actress_sql_import.dart' show ActressSqlImportCancelled;

/// 数据库导出格式（管理页点导出时选）。
enum ActressExportFormat {
  sql('SQL 文件', '.sql'),
  sqlGz('SQL 压缩文件', '.sql.gz'),
  csv('CSV 表格', '.csv'),
  xlsx('Excel 表格', '.xlsx'),
  db('数据库原文件', '.db');

  const ActressExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

/// 导出读取层：导出引擎只认这组查询，生产用 sqflite 只读连接，
/// 验证用 FFI 实现（与导入器执行器同款分工）。
abstract class ActressExportStore {
  /// 全部用户表（按建立顺序，不含 sqlite_stat1 等内部表）。
  Future<List<String>> tableNames();

  /// 一张表的 CREATE TABLE 原文。
  Future<String?> tableSql(String table);

  /// 全部 CREATE INDEX 原文（建在数据之后，与源转储同布局）。
  Future<List<String>> indexSqls();

  Future<int> countRows(String table);

  /// 一页行（ORDER BY rowid），行是列名 → 值。
  Future<List<Map<String, Object?>>> rowsPage(
    String table,
    int offset,
    int limit,
  );

  Future<int> countWorks();

  /// 一页作品的表格导出行（地址/女优/分类/标签已拼好）。
  Future<List<SpreadsheetWorkRow>> worksPage(int offset, int limit);

  Future<void> close();
}

class ActressExportResult {
  const ActressExportResult({
    required this.ok,
    this.error,
    this.path,
    this.bytes = 0,
    this.rows = 0,
  });

  final bool ok;
  final String? error;

  /// 导出文件落点（应用文档目录内的完整路径）。
  final String? path;
  final int bytes;
  final int rows;
}

/// 数据库导出引擎（2026-11-25 用户令：「数据库可以支持导出
/// 选择格式」）。
///
/// - .sql/.sql.gz：全量转储（表结构 + 数据 + 索引），布局与
///   sqlite .dump 一致，能被自家 .sql 导入原样导回（往返验证
///   见报告）；sqlite_stat1 是统计内部表、不导出（重导时
///   ANALYZE 会自己再生，不算用户数据）。
/// - .csv/.xlsx：作品表，列与表格导入更新完全同一套（见
///   actress_spreadsheet），导出→改→导回的往返链成立。
/// - .db 不在这里：直接拷库文件，由调用方先关库再拷、拷完重开。
/// 全部流式写盘 + 按行数报进度 + 可取消；取消/失败删半成品。
class ActressDbExporter {
  const ActressDbExporter({this.pageSize = 1000});

  final int pageSize;

  Future<ActressExportResult> exportSql({
    required ActressExportStore store,
    required String outPath,
    required bool compressed,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final outFile = File(outPath);
    IOSink? rawSink;
    StreamController<List<int>>? pipe;
    try {
      final tables = await store.tableNames();
      if (tables.isEmpty) {
        return const ActressExportResult(ok: false, error: '库里没有表');
      }
      var total = 0;
      final counts = <String, int>{};
      for (final table in tables) {
        counts[table] = await store.countRows(table);
        total += counts[table]!;
      }
      rawSink = outFile.openWrite();
      pipe = StreamController<List<int>>();
      Stream<List<int>> outStream = pipe.stream;
      if (compressed) outStream = outStream.transform(gzip.encoder);
      final writeDone = rawSink.addStream(outStream);
      final buffer = StringBuffer();
      var done = 0;
      void flush() {
        if (buffer.isEmpty) return;
        pipe!.add(utf8.encode(buffer.toString()));
        buffer.clear();
      }

      buffer.writeln('PRAGMA foreign_keys=OFF;');
      buffer.writeln('BEGIN TRANSACTION;');
      for (final table in tables) {
        final ddl = await store.tableSql(table);
        if (ddl != null && ddl.isNotEmpty) buffer.writeln('$ddl;');
        var offset = 0;
        while (true) {
          if (isCancelled != null && isCancelled()) {
            throw ActressSqlImportCancelled();
          }
          final rows = await store.rowsPage(table, offset, pageSize);
          if (rows.isEmpty) break;
          for (final row in rows) {
            final values = row.values.map(_sqlLiteral).join(',');
            buffer.writeln('INSERT INTO ${_ident(table)} VALUES($values);');
          }
          offset += rows.length;
          done += rows.length;
          onProgress?.call(done, total);
          if (buffer.length > 1 << 20) flush();
          if (rows.length < pageSize) break;
        }
      }
      for (final indexSql in await store.indexSqls()) {
        buffer.writeln('$indexSql;');
      }
      buffer.writeln('COMMIT;');
      flush();
      await pipe.close();
      pipe = null;
      await writeDone;
      await rawSink.close();
      rawSink = null;
      return ActressExportResult(
        ok: true,
        path: outPath,
        bytes: await outFile.length(),
        rows: done,
      );
    } on ActressSqlImportCancelled {
      await _cleanup(pipe, rawSink, outFile);
      return const ActressExportResult(ok: false, error: '已取消导出');
    } catch (e) {
      await _cleanup(pipe, rawSink, outFile);
      return ActressExportResult(
        ok: false,
        error: e.toString().split('\n').first,
      );
    }
  }

  Future<ActressExportResult> exportSpreadsheet({
    required ActressExportStore store,
    required String outPath,
    required bool xlsx,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final outFile = File(outPath);
    try {
      final total = await store.countWorks();
      if (total == 0) {
        return const ActressExportResult(
          ok: false,
          error: '库是空的，先导入数据库再导出',
        );
      }
      final grid = <List<String>>[spreadsheetExportHeaders];
      var done = 0;
      var offset = 0;
      while (true) {
        if (isCancelled != null && isCancelled()) {
          throw ActressSqlImportCancelled();
        }
        final page = await store.worksPage(offset, pageSize);
        if (page.isEmpty) break;
        grid.addAll(spreadsheetGridFromRows(page).skip(1));
        done += page.length;
        offset += page.length;
        onProgress?.call(done, total);
        if (page.length < pageSize) break;
      }
      if (xlsx) {
        await outFile.writeAsBytes(encodeXlsx(grid));
      } else {
        await outFile.writeAsString(encodeCsv(grid));
      }
      return ActressExportResult(
        ok: true,
        path: outPath,
        bytes: await outFile.length(),
        rows: done,
      );
    } on ActressSqlImportCancelled {
      try {
        if (await outFile.exists()) await outFile.delete();
      } catch (_) {}
      return const ActressExportResult(ok: false, error: '已取消导出');
    } catch (e) {
      try {
        if (await outFile.exists()) await outFile.delete();
      } catch (_) {}
      return ActressExportResult(
        ok: false,
        error: e.toString().split('\n').first,
      );
    }
  }

  Future<void> _cleanup(
    StreamController<List<int>>? pipe,
    IOSink? rawSink,
    File file,
  ) async {
    try {
      await pipe?.close();
    } catch (_) {}
    try {
      await rawSink?.close();
    } catch (_) {}
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// SQL 字面量：与导入器 _q 同口径（字符串单引号翻倍）。
  static String _sqlLiteral(Object? value) {
    if (value == null) return 'NULL';
    if (value is num) return value.toString();
    if (value is Uint8List) {
      final hex = StringBuffer("X'");
      for (final byte in value) {
        hex.write(byte.toRadixString(16).padLeft(2, '0'));
      }
      hex.write("'");
      return hex.toString();
    }
    return "'${value.toString().replaceAll("'", "''")}'";
  }

  static String _ident(String name) => '"${name.replaceAll('"', '""')}"';
}

/// sqflite 只读实现。
class SqfliteActressExportStore implements ActressExportStore {
  SqfliteActressExportStore(this._db);

  final Database _db;

  static Future<SqfliteActressExportStore> openPath(String dbPath) async {
    final db = await openDatabase(
      dbPath,
      readOnly: true,
      singleInstance: false,
    );
    return SqfliteActressExportStore(db);
  }

  @override
  Future<List<String>> tableNames() async {
    final rows = await _db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY rowid",
    );
    return [for (final row in rows) '${row['name']}'];
  }

  @override
  Future<String?> tableSql(String table) async {
    final rows = await _db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    );
    if (rows.isEmpty) return null;
    final sql = rows.first['sql'];
    return sql?.toString();
  }

  @override
  Future<List<String>> indexSqls() async {
    final rows = await _db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='index' "
      'AND sql IS NOT NULL ORDER BY rowid',
    );
    return [for (final row in rows) '${row['sql']}'];
  }

  @override
  Future<int> countRows(String table) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM "${_escape(table)}"',
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<Map<String, Object?>>> rowsPage(
    String table,
    int offset,
    int limit,
  ) {
    return _db.rawQuery(
      'SELECT * FROM "${_escape(table)}" ORDER BY rowid LIMIT ? OFFSET ?',
      [limit, offset],
    );
  }

  @override
  Future<int> countWorks() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM videos');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<SpreadsheetWorkRow>> worksPage(int offset, int limit) async {
    final rows = await _db.rawQuery(
      'SELECT v.vod_id, v.title, v.pic_url, v.m3u8_url, v.vod_play_url, '
      'v.type_name, '
      '(SELECT main_category FROM video_category '
      ' WHERE vod_id = v.vod_id) AS category, '
      '(SELECT GROUP_CONCAT(DISTINCT cate_id) FROM video_actress '
      ' WHERE vod_id = v.vod_id) AS actresses, '
      "(SELECT GROUP_CONCAT(tag_name, '、') FROM video_tag "
      ' WHERE vod_id = v.vod_id) AS tags '
      'FROM videos v ORDER BY v.vod_id LIMIT ? OFFSET ?',
      [limit, offset],
    );
    if (rows.isEmpty) return const [];
    final ids = [for (final row in rows) '${row['vod_id']}'];
    final inList = List.filled(ids.length, '?').join(',');
    final urlRows = await _db.rawQuery(
      'SELECT vod_id, play_url FROM video_play_urls '
      'WHERE vod_id IN ($inList) ORDER BY vod_id, play_url',
      ids,
    );
    final urlsById = <String, List<String>>{};
    for (final row in urlRows) {
      urlsById
          .putIfAbsent('${row['vod_id']}', () => [])
          .add('${row['play_url']}');
    }
    final avatarRows = await _db.rawQuery(
      'SELECT va.vod_id AS vod_id, a.avatar AS avatar '
      'FROM video_actress va JOIN actresses a ON a.cate_id = va.cate_id '
      "WHERE va.vod_id IN ($inList) AND a.avatar <> ''",
      ids,
    );
    final avatarById = <String, String>{};
    for (final row in avatarRows) {
      avatarById.putIfAbsent('${row['vod_id']}', () => '${row['avatar']}');
    }
    return [
      for (final row in rows)
        () {
          final code = '${row['vod_id']}';
          var urls = urlsById[code] ?? const <String>[];
          if (urls.isEmpty) {
            // 地址表没行时用作品行上的有效地址兜底（播放链口径）。
            final m3u8 = row['m3u8_url']?.toString() ?? '';
            final fallback = extractPlayUrl(
              m3u8.isNotEmpty ? m3u8 : (row['vod_play_url'] ?? ''),
            );
            if (fallback.isNotEmpty) urls = [fallback];
          }
          final actressesRaw = row['actresses']?.toString() ?? '';
          final category = row['category']?.toString() ?? '';
          final typeName = row['type_name']?.toString() ?? '';
          return SpreadsheetWorkRow()
            ..code = code
            ..title = row['title']?.toString()
            ..cover = row['pic_url']?.toString()
            ..category = category.isNotEmpty ? category : typeName
            ..actressAvatar = avatarById[code]
            ..playUrls = urls
            ..actresses = actressesRaw.isEmpty
                ? const []
                : actressesRaw.split(',')
            ..tags = splitNamesCell(row['tags']?.toString() ?? '');
        }(),
    ];
  }

  @override
  Future<void> close() => _db.close();

  static String _escape(String name) => name.replaceAll('"', '""');
}
