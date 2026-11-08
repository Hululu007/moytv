import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  Database? _db;
  bool _opening = false;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    while (_opening) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final ready = _db;
    if (ready != null && ready.isOpen) return ready;
    _opening = true;
    try {
      final documents = await getApplicationDocumentsDirectory();
      final filePath = path.join(documents.path, 'app.db');
      final db = await openDatabase(
        filePath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE history('
            'profile TEXT NOT NULL, '
            'id TEXT NOT NULL, '
            'drama_json TEXT NOT NULL, '
            'episode INTEGER NOT NULL, '
            'position REAL NOT NULL, '
            'duration REAL NOT NULL, '
            'updated_at INTEGER NOT NULL, '
            'PRIMARY KEY(profile, id))',
          );
          await db.execute(
            'CREATE TABLE favorites('
            'profile TEXT NOT NULL, '
            'id TEXT NOT NULL, '
            'drama_json TEXT NOT NULL, '
            'seq INTEGER NOT NULL, '
            'PRIMARY KEY(profile, id))',
          );
          await db.execute(
            'CREATE TABLE meta('
            'key TEXT PRIMARY KEY, '
            'value TEXT NOT NULL)',
          );
        },
      );
      _db = db;
      return db;
    } finally {
      _opening = false;
    }
  }

  Future<bool> isSynced(String profile) async {
    final db = await _open();
    final rows = await db.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['synced:$profile'],
    );
    return rows.isNotEmpty && rows.first['value'] == '1';
  }

  Future<void> replaceHistory(
    String profile,
    Iterable<WatchEntry> entries,
  ) async {
    final db = await _open();
    final batch = db.batch();
    batch.delete('history', where: 'profile = ?', whereArgs: [profile]);
    for (final entry in entries) {
      batch.insert('history', {
        'profile': profile,
        'id': entry.drama.id,
        'drama_json': jsonEncode(entry.drama.toJson()),
        'episode': entry.episode,
        'position': entry.position,
        'duration': entry.duration,
        'updated_at': entry.updatedAt.millisecondsSinceEpoch,
      });
    }
    batch.insert('meta', {
      'key': 'synced:$profile',
      'value': '1',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  }

  Future<void> replaceFavorites(String profile, Iterable<Drama> dramas) async {
    final db = await _open();
    final batch = db.batch();
    batch.delete('favorites', where: 'profile = ?', whereArgs: [profile]);
    var seq = 0;
    for (final drama in dramas) {
      batch.insert('favorites', {
        'profile': profile,
        'id': drama.id,
        'drama_json': jsonEncode(drama.toJson()),
        'seq': seq++,
      });
    }
    batch.insert('meta', {
      'key': 'synced:$profile',
      'value': '1',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  }

  Future<void> clearProfile(String profile) async {
    final db = await _open();
    final batch = db.batch();
    batch.delete('history', where: 'profile = ?', whereArgs: [profile]);
    batch.delete('favorites', where: 'profile = ?', whereArgs: [profile]);
    batch.delete('meta', where: 'key = ?', whereArgs: ['synced:$profile']);
    await batch.commit(noResult: true);
  }

  Future<List<WatchEntry>> loadHistory(String profile) async {
    final db = await _open();
    final rows = await db.query(
      'history',
      where: 'profile = ?',
      whereArgs: [profile],
      orderBy: 'updated_at DESC',
    );
    final entries = <WatchEntry>[];
    for (final row in rows) {
      try {
        final drama = Drama.fromJson(
          jsonDecode(row['drama_json'] as String) as Map<String, dynamic>,
        );
        entries.add(
          WatchEntry(
            drama: drama,
            episode: (row['episode'] as num?)?.toInt() ?? 0,
            position: (row['position'] as num?)?.toDouble() ?? 0,
            duration: (row['duration'] as num?)?.toDouble() ?? 0,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              (row['updated_at'] as num?)?.toInt() ?? 0,
            ),
          ),
        );
      } catch (_) {}
    }
    return entries;
  }

  Future<List<Drama>> loadFavorites(String profile) async {
    final db = await _open();
    final rows = await db.query(
      'favorites',
      where: 'profile = ?',
      whereArgs: [profile],
      orderBy: 'seq ASC',
    );
    final dramas = <Drama>[];
    for (final row in rows) {
      try {
        dramas.add(
          Drama.fromJson(
            jsonDecode(row['drama_json'] as String) as Map<String, dynamic>,
          ),
        );
      } catch (_) {}
    }
    return dramas;
  }

}
