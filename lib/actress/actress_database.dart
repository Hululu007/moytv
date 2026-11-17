import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'actress_models.dart';

/// 同步断点：每源每阶段一条，记录下次接着跑的位置。
class ActressSyncCheckpoint {
  const ActressSyncCheckpoint({
    required this.source,
    required this.phase,
    this.cursor = '',
    this.total = 0,
    this.finished = false,
    this.error = '',
    this.updatedAt = 0,
  });

  /// 'roster' | 'films' | 'ranking'。
  final String source;
  final String phase;

  /// roster/ranking：下一页页码；films：最后完成的人物 localId。
  final String cursor;
  final int total;
  final bool finished;
  final String error;
  final int updatedAt;
}

/// 同步总览：列表页横幅与手动刷新判断用。
class ActressSyncOverview {
  const ActressSyncOverview({
    required this.persons,
    required this.works,
    required this.sources,
    required this.lastUpdatedAt,
  });

  final int persons;
  final int works;

  /// 每源：是否三阶段都完成。
  final Map<ActressRosterSourceId, bool> sources;
  final int lastUpdatedAt;

  bool get hasAnything => persons > 0;
  bool get allDone => sources.values.every((done) => done);
}

/// 女优本地库接口：名册 + 作品一次性全量存本地，打开只读本地。
/// sqflite 实现跑真机，内存实现跑测试与预览；两者语义必须一致。
abstract class ActressDatabase {
  /// 名册人物合并入库：按任一名字变体键命中即合并，否则新建。
  /// 名字含硬线词时返回 null（整人剔除）。
  Future<ActressPerson?> upsertRosterPerson(RosterPerson roster);

  Future<ActressPerson?> personById(int localId);

  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
  });

  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
  });

  /// 排行榜全量取数（榜内 Dart 侧按综合分排，读本地不联网）。
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  });

  /// 记录 MissAV 排行名次：只保留最好（最小）名次。
  Future<void> setMissavRank(int personId, int rank);

  /// 记录 whos 日榜名次：只保留最好（最小）名次；与 MissAV 列
  /// 互不覆盖（名气分主链 MissAV、后备 whos）。
  Future<void> setWhosRank(int personId, int rank);

  /// 写入 whos 人物页简介：与已有键值合并，已有键优先；含硬线词
  /// 的键或值整条丢弃（不写该键），不影响其它键。
  Future<void> setPersonAbout(int personId, Map<String, String> about);

  Future<List<ActressWork>> worksForPerson(
    int personId, {
    required int offset,
    required int limit,
  });

  Future<int> countWorks(int personId);

  /// 作品清单合并入库：番号键去重、无番号标题键去重；命中硬线词的
  /// 条目跳过；写完刷新人物的 works_count。
  Future<void> upsertWorks(int personId, List<RosterFilm> films);

  /// 全站搜索补封面：按番号键（无番号按标题键）命中则更新封面与
  /// 标题，命中不到则按 [insertIfMissing] 决定是否新增一条跨站发现
  /// 的作品行（名字搜索带番号的命中可新增，番号搜索只补已有行）。
  Future<void> attachCover({
    required int personId,
    required String codeKey,
    required String titleKey,
    String codeDisplay = '',
    String title = '',
    String date = '',
    required String coverSource,
    required String coverDramaId,
    required String coverUrl,
    bool insertIfMissing = true,
  });

  /// 某源作品清单待同步的人物（有该源身份、且该源 films 未完成）。
  Future<List<ActressPerson>> personsPendingFilms(ActressRosterSourceId source);

  /// films 进度：done = 已完成人数，total = 该源身份总人数。
  Future<({int done, int total})> filmsProgress(ActressRosterSourceId source);

  Future<void> markFilmsState(
    int personId,
    ActressRosterSourceId source, {
    required bool ok,
  });

  Future<void> markEnriched(int personId);

  Future<ActressSyncCheckpoint?> checkpoint(
    ActressRosterSourceId source,
    String phase,
  );

  Future<void> saveCheckpoint(ActressSyncCheckpoint checkpoint);

  Future<ActressSyncOverview> overview();

  Future<void> close();
}

String _sourceName(ActressRosterSourceId source) => source.name;

String _sourceIdColumn(ActressRosterSourceId source) => switch (source) {
  ActressRosterSourceId.chaoliu => 'chaoliu_id',
  ActressRosterSourceId.whos => 'whos_slug',
  ActressRosterSourceId.missav => 'missav_path',
};

Map<String, Object?> _personToRow(ActressPerson person, int now) => {
  if (person.localId > 0) 'id': person.localId,
  'display_name': person.displayName,
  'aliases': jsonEncode(person.aliases),
  'sex': person.sex,
  'avatar_url': person.avatarUrl,
  'tags': jsonEncode(person.tags),
  'works_count': person.worksCount,
  'roster_works': person.rosterWorks,
  'from_chaoliu': person.fromChaoliu ? 1 : 0,
  'from_whos': person.fromWhos ? 1 : 0,
  'from_missav': person.fromMissav ? 1 : 0,
  'chaoliu_id': person.chaoliuId,
  'whos_slug': person.whosSlug,
  'missav_path': person.missavPath,
  'missav_rank': person.missavRank,
  'recommended': person.recommended ? 1 : 0,
  'films_synced_at': person.filmsSyncedAt,
  'enriched_at': person.enrichedAt,
  'whos_rank': person.whosRank,
  'rating': person.rating,
  'exact_works': person.exactWorks,
  'about': jsonEncode(person.about),
  'updated_at': now,
};

Map<String, String> _decodeAbout(Object? value) {
  if (value is! String || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return const {};
    final out = <String, String>{};
    decoded.forEach((key, item) {
      if (item != null) out[key.toString()] = item.toString();
    });
    return out;
  } catch (_) {
    return const {};
  }
}

ActressPerson _personFromRow(Map<String, Object?> row) {
  List<String> decodeList(Object? value) {
    if (value is! String || value.isEmpty) return const [];
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return [for (final item in decoded) item.toString()];
  }

  return ActressPerson(
    localId: (row['id'] as num?)?.toInt() ?? 0,
    displayName: (row['display_name'] as String?) ?? '',
    aliases: decodeList(row['aliases']),
    sex: (row['sex'] as String?) ?? '',
    avatarUrl: (row['avatar_url'] as String?) ?? '',
    tags: decodeList(row['tags']),
    worksCount: (row['works_count'] as num?)?.toInt() ?? 0,
    rosterWorks: (row['roster_works'] as num?)?.toInt() ?? 0,
    fromChaoliu: (row['from_chaoliu'] as num?)?.toInt() == 1,
    fromWhos: (row['from_whos'] as num?)?.toInt() == 1,
    fromMissav: (row['from_missav'] as num?)?.toInt() == 1,
    chaoliuId: (row['chaoliu_id'] as String?) ?? '',
    whosSlug: (row['whos_slug'] as String?) ?? '',
    missavPath: (row['missav_path'] as String?) ?? '',
    missavRank: (row['missav_rank'] as num?)?.toInt(),
    recommended: (row['recommended'] as num?)?.toInt() == 1,
    filmsSyncedAt: (row['films_synced_at'] as num?)?.toInt(),
    enrichedAt: (row['enriched_at'] as num?)?.toInt(),
    whosRank: (row['whos_rank'] as num?)?.toInt(),
    rating: (row['rating'] as num?)?.toDouble(),
    exactWorks: (row['exact_works'] as num?)?.toInt() ?? 0,
    about: _decodeAbout(row['about']),
  );
}

ActressWork _workFromRow(Map<String, Object?> row) => ActressWork(
  id: (row['id'] as num?)?.toInt() ?? 0,
  personId: (row['person_id'] as num?)?.toInt() ?? 0,
  codeKey: (row['code_key'] as String?) ?? '',
  titleKey: (row['title_key'] as String?) ?? '',
  codeDisplay: (row['code_display'] as String?) ?? '',
  title: (row['title'] as String?) ?? '',
  date: (row['date'] as String?) ?? '',
  coverSource: (row['cover_source'] as String?) ?? '',
  coverDramaId: (row['cover_drama_id'] as String?) ?? '',
  coverUrl: (row['cover_url'] as String?) ?? '',
  fromCrossSite: (row['from_cross_site'] as num?)?.toInt() == 1,
);

/// sqflite 实现：独立 actress.db，不动 app.db 的版本与表结构。
class SqfliteActressDatabase implements ActressDatabase {
  SqfliteActressDatabase._();

  static final SqfliteActressDatabase instance = SqfliteActressDatabase._();

  Database? _db;

  /// 正在进行的开库 Future：并发调用共用同一份结果，不轮询自旋
  /// （旧的 10ms 自旋在开库挂起时越转越久，还会留 pending Timer）。
  Future<Database>? _openFuture;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    var pending = _openFuture;
    if (pending == null) {
      pending = _openNow();
      _openFuture = pending;
    }
    try {
      final db = await pending;
      _db = db;
      return db;
    } catch (_) {
      if (identical(_openFuture, pending)) _openFuture = null;
      rethrow;
    }
  }

  Future<Database> _openNow() async {
    final documents = await getApplicationDocumentsDirectory();
    final filePath = path.join(documents.path, 'actress.db');
    final db = await openDatabase(
      filePath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE persons('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'display_name TEXT NOT NULL, '
          'aliases TEXT NOT NULL DEFAULT \'[]\', '
          'sex TEXT NOT NULL DEFAULT \'\', '
          'avatar_url TEXT NOT NULL DEFAULT \'\', '
          'tags TEXT NOT NULL DEFAULT \'[]\', '
          'works_count INTEGER NOT NULL DEFAULT 0, '
          'roster_works INTEGER NOT NULL DEFAULT 0, '
          'from_chaoliu INTEGER NOT NULL DEFAULT 0, '
          'from_whos INTEGER NOT NULL DEFAULT 0, '
          'from_missav INTEGER NOT NULL DEFAULT 0, '
          'chaoliu_id TEXT NOT NULL DEFAULT \'\', '
          'whos_slug TEXT NOT NULL DEFAULT \'\', '
          'missav_path TEXT NOT NULL DEFAULT \'\', '
          'missav_rank INTEGER, '
          'recommended INTEGER NOT NULL DEFAULT 0, '
          'films_synced_at INTEGER, '
          'enriched_at INTEGER, '
          'whos_rank INTEGER, '
          'rating REAL, '
          'exact_works INTEGER NOT NULL DEFAULT 0, '
          'about TEXT NOT NULL DEFAULT \'{}\', '
          'updated_at INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE person_names('
          'name_key TEXT NOT NULL PRIMARY KEY, '
          'person_id INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE INDEX idx_persons_works ON persons(works_count DESC)',
        );
        await db.execute(
          'CREATE TABLE works('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'person_id INTEGER NOT NULL, '
          'code_key TEXT NOT NULL DEFAULT \'\', '
          'title_key TEXT NOT NULL DEFAULT \'\', '
          'code_display TEXT NOT NULL DEFAULT \'\', '
          'title TEXT NOT NULL DEFAULT \'\', '
          'date TEXT NOT NULL DEFAULT \'\', '
          'cover_source TEXT NOT NULL DEFAULT \'\', '
          'cover_drama_id TEXT NOT NULL DEFAULT \'\', '
          'cover_url TEXT NOT NULL DEFAULT \'\', '
          'from_cross_site INTEGER NOT NULL DEFAULT 0)',
        );
        // 番号去重与无番号标题去重：部分唯一索引各管一摊，互不冲突。
        await db.execute(
          'CREATE UNIQUE INDEX idx_works_code '
          'ON works(person_id, code_key) WHERE code_key <> \'\'',
        );
        await db.execute(
          'CREATE UNIQUE INDEX idx_works_title '
          'ON works(person_id, title_key) '
          'WHERE code_key = \'\' AND title_key <> \'\'',
        );
        await db.execute(
          'CREATE INDEX idx_works_person ON works(person_id, id)',
        );
        await db.execute(
          'CREATE TABLE source_films('
          'person_id INTEGER NOT NULL, '
          'source TEXT NOT NULL, '
          'synced_at INTEGER, '
          'failed INTEGER NOT NULL DEFAULT 0, '
          'PRIMARY KEY(person_id, source))',
        );
        await db.execute(
          'CREATE TABLE sync_state('
          'source TEXT NOT NULL, '
          'phase TEXT NOT NULL, '
          'cursor TEXT NOT NULL DEFAULT \'\', '
          'total INTEGER NOT NULL DEFAULT 0, '
          'finished INTEGER NOT NULL DEFAULT 0, '
          'error TEXT NOT NULL DEFAULT \'\', '
          'updated_at INTEGER NOT NULL, '
          'PRIMARY KEY(source, phase))',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 → v2：whos 兜底四列（排行后备、评分、精确作品数、简介）。
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE persons ADD COLUMN whos_rank INTEGER');
          await db.execute('ALTER TABLE persons ADD COLUMN rating REAL');
          await db.execute(
            'ALTER TABLE persons ADD COLUMN exact_works INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE persons ADD COLUMN about TEXT NOT NULL DEFAULT \'{}\'',
          );
        }
      },
    );
    return db;
  }

  @override
  Future<ActressPerson?> upsertRosterPerson(RosterPerson roster) async {
    final variants = actressNameVariants(roster.name);
    if (variants.isEmpty) return null;
    if (variants.any(actressTextBlocked) ||
        roster.tags.any(actressTextBlocked) ||
        roster.aliases.any(actressTextBlocked) ||
        roster.about.entries.any(
          (entry) =>
              actressTextBlocked(entry.key) || actressTextBlocked(entry.value),
        )) {
      return null;
    }
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      ActressPerson? existing;
      for (final variant in variants) {
        final rows = await txn.query(
          'person_names',
          columns: ['person_id'],
          where: 'name_key = ?',
          whereArgs: [actressNameKey(variant)],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final id = (rows.first['person_id'] as num).toInt();
        final personRows = await txn.query(
          'persons',
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (personRows.isNotEmpty) {
          existing = _personFromRow(personRows.first);
          break;
        }
      }
      final merged = mergeRosterIntoPerson(existing, roster);
      int personId;
      if (existing == null) {
        personId = await txn.insert('persons', _personToRow(merged, now));
      } else {
        personId = existing.localId;
        await txn.update(
          'persons',
          _personToRow(merged.copyWith(localId: personId), now),
          where: 'id = ?',
          whereArgs: [personId],
        );
      }
      final keys = <String>{
        actressNameKey(merged.displayName),
        for (final alias in merged.aliases) actressNameKey(alias),
        for (final variant in variants) actressNameKey(variant),
      };
      for (final key in keys) {
        if (key.isEmpty) continue;
        await txn.insert('person_names', {
          'name_key': key,
          'person_id': personId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final rows = await txn.query(
        'persons',
        where: 'id = ?',
        whereArgs: [personId],
        limit: 1,
      );
      return _personFromRow(rows.first);
    });
  }

  @override
  Future<ActressPerson?> personById(int localId) async {
    final db = await _open();
    final rows = await db.query(
      'persons',
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _personFromRow(rows.first);
  }

  String _sexWhere(ActressSexFilter sex, List<Object?> args) {
    switch (sex) {
      case ActressSexFilter.all:
        return '1 = 1';
      case ActressSexFilter.female:
        args.add('female');
        return 'sex = ?';
      case ActressSexFilter.male:
        args.add('male');
        return 'sex = ?';
    }
  }

  String _queryWhere(String query, List<Object?> args) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return '1 = 1';
    final like = '%$trimmed%';
    final keyLike = '%${actressNameKey(trimmed)}%';
    args.addAll([like, like, keyLike]);
    return '(display_name LIKE ? OR aliases LIKE ? OR id IN '
        '(SELECT person_id FROM person_names WHERE name_key LIKE ?))';
  }

  // 标签存为 JSON 数组文本，带引号匹配避免子串误中（'"有码"' 只中整标签）。
  String _tagWhere(String tag, List<Object?> args) {
    if (tag.isEmpty) return '1 = 1';
    args.add('%${jsonEncode(tag)}%');
    return 'tags LIKE ?';
  }

  String _sortOrder(ActressSort sort) => switch (sort) {
    ActressSort.worksDesc =>
      'MAX(works_count, roster_works) DESC, display_name ASC',
    ActressSort.nameAsc => 'display_name ASC',
  };

  @override
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
  }) async {
    final db = await _open();
    final args = <Object?>[];
    final where =
        '${_sexWhere(sex, args)} AND ${_queryWhere(query, args)} '
        'AND ${_tagWhere(tag, args)}';
    final rows = await db.query(
      'persons',
      where: where,
      whereArgs: args,
      orderBy: _sortOrder(sort),
      limit: limit,
      offset: offset,
    );
    return rows.map(_personFromRow).toList();
  }

  @override
  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
  }) async {
    final db = await _open();
    final args = <Object?>[];
    final where =
        '${_sexWhere(sex, args)} AND ${_queryWhere(query, args)} '
        'AND ${_tagWhere(tag, args)}';
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM persons WHERE $where',
      args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  }) async {
    final db = await _open();
    final args = <Object?>[];
    final rows = await db.query(
      'persons',
      where: _sexWhere(sex, args),
      whereArgs: args,
    );
    final persons = rows.map(_personFromRow).toList()..sort(compareActressRank);
    return persons;
  }

  @override
  Future<void> setMissavRank(int personId, int rank) async {
    final db = await _open();
    await db.rawUpdate(
      'UPDATE persons SET missav_rank = '
      'CASE WHEN missav_rank IS NULL OR ? < missav_rank THEN ? '
      'ELSE missav_rank END, updated_at = ? WHERE id = ?',
      [rank, rank, DateTime.now().millisecondsSinceEpoch, personId],
    );
  }

  @override
  Future<void> setWhosRank(int personId, int rank) async {
    final db = await _open();
    await db.rawUpdate(
      'UPDATE persons SET whos_rank = '
      'CASE WHEN whos_rank IS NULL OR ? < whos_rank THEN ? '
      'ELSE whos_rank END, updated_at = ? WHERE id = ?',
      [rank, rank, DateTime.now().millisecondsSinceEpoch, personId],
    );
  }

  @override
  Future<void> setPersonAbout(int personId, Map<String, String> about) async {
    final clean = <String, String>{};
    for (final entry in about.entries) {
      if (actressTextBlocked(entry.key) || actressTextBlocked(entry.value)) {
        continue;
      }
      clean[entry.key] = entry.value;
    }
    if (clean.isEmpty) return;
    final db = await _open();
    final rows = await db.query(
      'persons',
      columns: ['about'],
      where: 'id = ?',
      whereArgs: [personId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final merged = {...clean, ..._decodeAbout(rows.first['about'])};
    await db.update(
      'persons',
      {
        'about': jsonEncode(merged),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [personId],
    );
  }

  @override
  Future<List<ActressWork>> worksForPerson(
    int personId, {
    required int offset,
    required int limit,
  }) async {
    final db = await _open();
    final rows = await db.query(
      'works',
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'id ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_workFromRow).toList();
  }

  @override
  Future<int> countWorks(int personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM works WHERE person_id = ?',
      [personId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<void> _refreshWorksCount(
    DatabaseExecutor executor,
    int personId,
  ) async {
    await executor.rawUpdate(
      'UPDATE persons SET works_count = '
      '(SELECT COUNT(*) FROM works WHERE person_id = ?) WHERE id = ?',
      [personId, personId],
    );
  }

  @override
  Future<void> upsertWorks(int personId, List<RosterFilm> films) async {
    final db = await _open();
    await db.transaction((txn) async {
      for (final film in films) {
        if (actressTextBlocked(film.code) || actressTextBlocked(film.title)) {
          continue;
        }
        final codeKey = film.codeKey;
        final titleKey = film.titleKey;
        if (codeKey.isEmpty && titleKey.isEmpty) continue;
        final codeDisplay = film.code.trim();
        final title = film.title.trim();
        // whos XOR 封面（开关打开时才有）：只在新建行时写入，
        // 开关关闭时三字段恒为空，与此前行为一字不差。
        final coverFields = film.coverUrl.isEmpty
            ? const <String, Object?>{}
            : <String, Object?>{
                'cover_source': 'whos',
                'cover_drama_id': film.detailUrl,
                'cover_url': film.coverUrl,
              };
        if (codeKey.isNotEmpty) {
          await txn.insert('works', {
            'person_id': personId,
            'code_key': codeKey,
            'title_key': titleKey,
            'code_display': codeDisplay,
            'title': title == codeDisplay ? '' : title,
            'date': film.date.trim(),
            ...coverFields,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        } else {
          await txn.insert('works', {
            'person_id': personId,
            'code_key': '',
            'title_key': titleKey,
            'code_display': '',
            'title': title,
            'date': film.date.trim(),
            ...coverFields,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      await _refreshWorksCount(txn, personId);
    });
  }

  @override
  Future<void> attachCover({
    required int personId,
    required String codeKey,
    required String titleKey,
    String codeDisplay = '',
    String title = '',
    String date = '',
    required String coverSource,
    required String coverDramaId,
    required String coverUrl,
    bool insertIfMissing = true,
  }) async {
    if (actressTextBlocked(title) || actressTextBlocked(codeDisplay)) return;
    if (codeKey.isEmpty && titleKey.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final where = codeKey.isNotEmpty
          ? 'person_id = ? AND code_key = ?'
          : 'person_id = ? AND code_key = \'\' AND title_key = ?';
      final whereArgs = <Object?>[
        personId,
        codeKey.isNotEmpty ? codeKey : titleKey,
      ];
      final existing = await txn.query(
        'works',
        where: where,
        whereArgs: whereArgs,
        limit: 1,
      );
      if (existing.isEmpty) {
        if (!insertIfMissing) return;
        await txn.insert('works', {
          'person_id': personId,
          'code_key': codeKey,
          'title_key': titleKey,
          'code_display': codeDisplay,
          'title': title,
          'date': date,
          'cover_source': coverSource,
          'cover_drama_id': coverDramaId,
          'cover_url': coverUrl,
          'from_cross_site': 1,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        final row = _workFromRow(existing.first);
        final updates = <String, Object?>{
          if (row.coverUrl.isEmpty) 'cover_source': coverSource,
          if (row.coverUrl.isEmpty) 'cover_drama_id': coverDramaId,
          if (row.coverUrl.isEmpty) 'cover_url': coverUrl,
          if (row.title.isEmpty && title.isNotEmpty) 'title': title,
          if (row.date.isEmpty && date.isNotEmpty) 'date': date,
        };
        // 行已完整时不发空 UPDATE（空 SET 是 SQL 语法错）。
        if (updates.isNotEmpty) {
          await txn.update(
            'works',
            updates,
            where: 'id = ?',
            whereArgs: [row.id],
          );
        }
      }
      await _refreshWorksCount(txn, personId);
    });
  }

  @override
  Future<List<ActressPerson>> personsPendingFilms(
    ActressRosterSourceId source,
  ) async {
    final db = await _open();
    final column = _sourceIdColumn(source);
    final rows = await db.query(
      'persons',
      where:
          "$column <> '' AND NOT EXISTS (SELECT 1 FROM source_films f "
          'WHERE f.person_id = persons.id AND f.source = ? '
          'AND f.synced_at IS NOT NULL)',
      whereArgs: [_sourceName(source)],
      orderBy: 'id ASC',
    );
    return rows.map(_personFromRow).toList();
  }

  @override
  Future<({int done, int total})> filmsProgress(
    ActressRosterSourceId source,
  ) async {
    final db = await _open();
    final column = _sourceIdColumn(source);
    final totalRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM persons WHERE $column <> \'\'',
    );
    final doneRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM source_films '
      'WHERE source = ? AND synced_at IS NOT NULL',
      [_sourceName(source)],
    );
    return (
      done: (doneRows.first['c'] as num?)?.toInt() ?? 0,
      total: (totalRows.first['c'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> markFilmsState(
    int personId,
    ActressRosterSourceId source, {
    required bool ok,
  }) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.insert('source_films', {
        'person_id': personId,
        'source': _sourceName(source),
        'synced_at': ok ? now : null,
        'failed': ok ? 0 : 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (ok) {
        await txn.rawUpdate(
          'UPDATE persons SET films_synced_at = ? WHERE id = ? '
          'AND films_synced_at IS NULL',
          [now, personId],
        );
      }
    });
  }

  @override
  Future<void> markEnriched(int personId) async {
    final db = await _open();
    await db.update(
      'persons',
      {'enriched_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [personId],
    );
  }

  @override
  Future<ActressSyncCheckpoint?> checkpoint(
    ActressRosterSourceId source,
    String phase,
  ) async {
    final db = await _open();
    final rows = await db.query(
      'sync_state',
      where: 'source = ? AND phase = ?',
      whereArgs: [_sourceName(source), phase],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ActressSyncCheckpoint(
      source: row['source'] as String,
      phase: row['phase'] as String,
      cursor: (row['cursor'] as String?) ?? '',
      total: (row['total'] as num?)?.toInt() ?? 0,
      finished: (row['finished'] as num?)?.toInt() == 1,
      error: (row['error'] as String?) ?? '',
      updatedAt: (row['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> saveCheckpoint(ActressSyncCheckpoint checkpoint) async {
    final db = await _open();
    await db.insert('sync_state', {
      'source': checkpoint.source,
      'phase': checkpoint.phase,
      'cursor': checkpoint.cursor,
      'total': checkpoint.total,
      'finished': checkpoint.finished ? 1 : 0,
      'error': checkpoint.error,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<ActressSyncOverview> overview() async {
    final db = await _open();
    final personRows = await db.rawQuery('SELECT COUNT(*) AS c FROM persons');
    final workRows = await db.rawQuery('SELECT COUNT(*) AS c FROM works');
    final updatedRows = await db.rawQuery(
      'SELECT MAX(updated_at) AS m FROM persons',
    );
    final sources = <ActressRosterSourceId, bool>{};
    for (final source in ActressRosterSourceId.values) {
      var done = true;
      for (final phase in ['roster', 'films']) {
        final cp = await checkpoint(source, phase);
        if (cp == null || !cp.finished) {
          done = false;
          break;
        }
      }
      sources[source] = done;
    }
    return ActressSyncOverview(
      persons: (personRows.first['c'] as num?)?.toInt() ?? 0,
      works: (workRows.first['c'] as num?)?.toInt() ?? 0,
      sources: sources,
      lastUpdatedAt: (updatedRows.first['m'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }
}

/// 内存实现：测试与预览用，与 sqflite 实现同一语义（合并、去重、
/// 断点、进度口径一致；SQL 层本身只在真机上跑）。
class MemoryActressDatabase implements ActressDatabase {
  final _persons = <int, ActressPerson>{};
  final _nameIndex = <String, int>{};
  final _works = <int, ActressWork>{};
  final _filmsState = <String, bool>{};
  final _checkpoints = <String, ActressSyncCheckpoint>{};
  int _nextPersonId = 1;
  int _nextWorkId = 1;

  @override
  Future<ActressPerson?> upsertRosterPerson(RosterPerson roster) async {
    final variants = actressNameVariants(roster.name);
    if (variants.isEmpty) return null;
    if (variants.any(actressTextBlocked) ||
        roster.tags.any(actressTextBlocked) ||
        roster.aliases.any(actressTextBlocked) ||
        roster.about.entries.any(
          (entry) =>
              actressTextBlocked(entry.key) || actressTextBlocked(entry.value),
        )) {
      return null;
    }
    ActressPerson? existing;
    for (final variant in variants) {
      final id = _nameIndex[actressNameKey(variant)];
      if (id != null && _persons.containsKey(id)) {
        existing = _persons[id];
        break;
      }
    }
    final merged = mergeRosterIntoPerson(existing, roster);
    final stored = existing == null
        ? merged.copyWith(localId: _nextPersonId++)
        : merged.copyWith(localId: existing.localId);
    _persons[stored.localId] = stored;
    final keys = <String>{
      actressNameKey(stored.displayName),
      for (final alias in stored.aliases) actressNameKey(alias),
      for (final variant in variants) actressNameKey(variant),
    };
    for (final key in keys) {
      if (key.isNotEmpty) _nameIndex[key] = stored.localId;
    }
    return stored;
  }

  @override
  Future<ActressPerson?> personById(int localId) async => _persons[localId];

  bool _sexMatches(ActressPerson person, ActressSexFilter sex) => switch (sex) {
    ActressSexFilter.all => true,
    ActressSexFilter.female => person.sex == 'female',
    ActressSexFilter.male => person.sex == 'male',
  };

  bool _queryMatches(ActressPerson person, String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return true;
    if (person.displayName.contains(trimmed)) return true;
    if (person.aliases.any((alias) => alias.contains(trimmed))) return true;
    final key = actressNameKey(trimmed);
    if (key.isEmpty) return false;
    final keys = <String>{
      actressNameKey(person.displayName),
      for (final alias in person.aliases) actressNameKey(alias),
    };
    return keys.any((candidate) => candidate.contains(key));
  }

  List<ActressPerson> _filtered({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
  }) => _persons.values
      .where(
        (person) =>
            _sexMatches(person, sex) &&
            _queryMatches(person, query) &&
            (tag.isEmpty || person.tags.contains(tag)),
      )
      .toList();

  @override
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
  }) async {
    final filtered = _filtered(sex: sex, query: query, tag: tag);
    switch (sort) {
      case ActressSort.worksDesc:
        filtered.sort((a, b) {
          final works = b.displayWorks.compareTo(a.displayWorks);
          if (works != 0) return works;
          return a.displayName.compareTo(b.displayName);
        });
      case ActressSort.nameAsc:
        filtered.sort((a, b) => a.displayName.compareTo(b.displayName));
    }
    if (offset >= filtered.length) return const [];
    return filtered.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
  }) async => _filtered(sex: sex, query: query, tag: tag).length;

  @override
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  }) async {
    final filtered =
        _persons.values.where((person) => _sexMatches(person, sex)).toList()
          ..sort(compareActressRank);
    return filtered;
  }

  @override
  Future<void> setMissavRank(int personId, int rank) async {
    final person = _persons[personId];
    if (person == null) return;
    final current = person.missavRank;
    if (current == null || rank < current) {
      _persons[personId] = person.copyWith(missavRank: rank);
    }
  }

  @override
  Future<void> setWhosRank(int personId, int rank) async {
    final person = _persons[personId];
    if (person == null) return;
    final current = person.whosRank;
    if (current == null || rank < current) {
      _persons[personId] = person.copyWith(whosRank: rank);
    }
  }

  @override
  Future<void> setPersonAbout(int personId, Map<String, String> about) async {
    final person = _persons[personId];
    if (person == null) return;
    final clean = <String, String>{};
    for (final entry in about.entries) {
      if (actressTextBlocked(entry.key) || actressTextBlocked(entry.value)) {
        continue;
      }
      clean[entry.key] = entry.value;
    }
    if (clean.isEmpty) return;
    _persons[personId] = person.copyWith(
      about: {...clean, ...person.about},
    );
  }

  @override
  Future<List<ActressWork>> worksForPerson(
    int personId, {
    required int offset,
    required int limit,
  }) async {
    final works =
        _works.values.where((work) => work.personId == personId).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    if (offset >= works.length) return const [];
    return works.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countWorks(int personId) async =>
      _works.values.where((work) => work.personId == personId).length;

  void _refreshWorksCount(int personId) {
    final person = _persons[personId];
    if (person == null) return;
    final count = _works.values
        .where((work) => work.personId == personId)
        .length;
    _persons[personId] = person.copyWith(worksCount: count);
  }

  @override
  Future<void> upsertWorks(int personId, List<RosterFilm> films) async {
    for (final film in films) {
      if (actressTextBlocked(film.code) || actressTextBlocked(film.title)) {
        continue;
      }
      final codeKey = film.codeKey;
      final titleKey = film.titleKey;
      if (codeKey.isEmpty && titleKey.isEmpty) continue;
      final exists = _works.values.any((work) {
        if (work.personId != personId) return false;
        if (codeKey.isNotEmpty) return work.codeKey == codeKey;
        return work.codeKey.isEmpty && work.titleKey == titleKey;
      });
      if (exists) continue;
      final codeDisplay = film.code.trim();
      final title = film.title.trim();
      _works[_nextWorkId] = ActressWork(
        id: _nextWorkId++,
        personId: personId,
        codeKey: codeKey,
        titleKey: titleKey,
        codeDisplay: codeDisplay,
        title: title == codeDisplay ? '' : title,
        date: film.date.trim(),
        // whos XOR 封面（开关打开时才有）：开关关闭时三字段恒为空。
        coverSource: film.coverUrl.isEmpty ? '' : 'whos',
        coverDramaId: film.coverUrl.isEmpty ? '' : film.detailUrl,
        coverUrl: film.coverUrl,
      );
    }
    _refreshWorksCount(personId);
  }

  @override
  Future<void> attachCover({
    required int personId,
    required String codeKey,
    required String titleKey,
    String codeDisplay = '',
    String title = '',
    String date = '',
    required String coverSource,
    required String coverDramaId,
    required String coverUrl,
    bool insertIfMissing = true,
  }) async {
    if (actressTextBlocked(title) || actressTextBlocked(codeDisplay)) return;
    if (codeKey.isEmpty && titleKey.isEmpty) return;
    ActressWork? existing;
    for (final work in _works.values) {
      if (work.personId != personId) continue;
      if (codeKey.isNotEmpty
          ? work.codeKey == codeKey
          : work.codeKey.isEmpty && work.titleKey == titleKey) {
        existing = work;
        break;
      }
    }
    if (existing == null) {
      if (!insertIfMissing) return;
      _works[_nextWorkId] = ActressWork(
        id: _nextWorkId++,
        personId: personId,
        codeKey: codeKey,
        titleKey: titleKey,
        codeDisplay: codeDisplay,
        title: title,
        date: date,
        coverSource: coverSource,
        coverDramaId: coverDramaId,
        coverUrl: coverUrl,
        fromCrossSite: true,
      );
    } else {
      _works[existing.id] = existing.copyWith(
        coverSource: existing.coverUrl.isEmpty
            ? coverSource
            : existing.coverSource,
        coverDramaId: existing.coverUrl.isEmpty
            ? coverDramaId
            : existing.coverDramaId,
        coverUrl: existing.coverUrl.isEmpty ? coverUrl : existing.coverUrl,
        title: existing.title.isEmpty && title.isNotEmpty
            ? title
            : existing.title,
        date: existing.date.isEmpty && date.isNotEmpty ? date : existing.date,
      );
    }
    _refreshWorksCount(personId);
  }

  @override
  Future<List<ActressPerson>> personsPendingFilms(
    ActressRosterSourceId source,
  ) async {
    final pending =
        _persons.values
            .where(
              (person) =>
                  person.hasSource(source) &&
                  _filmsState['${person.localId}:${source.name}'] != true,
            )
            .toList()
          ..sort((a, b) => a.localId.compareTo(b.localId));
    return pending;
  }

  @override
  Future<({int done, int total})> filmsProgress(
    ActressRosterSourceId source,
  ) async {
    final total = _persons.values.where((p) => p.hasSource(source)).length;
    final done = _persons.values
        .where(
          (p) =>
              p.hasSource(source) &&
              _filmsState['${p.localId}:${source.name}'] == true,
        )
        .length;
    return (done: done, total: total);
  }

  @override
  Future<void> markFilmsState(
    int personId,
    ActressRosterSourceId source, {
    required bool ok,
  }) async {
    _filmsState['$personId:${source.name}'] = ok;
    if (ok) {
      final person = _persons[personId];
      if (person != null && person.filmsSyncedAt == null) {
        _persons[personId] = person.copyWith(
          filmsSyncedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
  }

  @override
  Future<void> markEnriched(int personId) async {
    final person = _persons[personId];
    if (person != null) {
      _persons[personId] = person.copyWith(
        enrichedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  @override
  Future<ActressSyncCheckpoint?> checkpoint(
    ActressRosterSourceId source,
    String phase,
  ) async => _checkpoints['${source.name}:$phase'];

  @override
  Future<void> saveCheckpoint(ActressSyncCheckpoint checkpoint) async {
    _checkpoints['${checkpoint.source}:${checkpoint.phase}'] = checkpoint;
  }

  @override
  Future<ActressSyncOverview> overview() async {
    final sources = <ActressRosterSourceId, bool>{};
    for (final source in ActressRosterSourceId.values) {
      var done = true;
      for (final phase in ['roster', 'films']) {
        final cp = _checkpoints['${source.name}:$phase'];
        if (cp == null || !cp.finished) {
          done = false;
          break;
        }
      }
      sources[source] = done;
    }
    return ActressSyncOverview(
      persons: _persons.length,
      works: _works.length,
      sources: sources,
      lastUpdatedAt: 0,
    );
  }

  @override
  Future<void> close() async {}
}
