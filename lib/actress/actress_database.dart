import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_generic_db.dart';
import 'actress_models.dart';
import 'actress_mytv_bind.dart';

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

/// 全站叠加断点在 sync_state 里的键：source 与 phase 均为 'stacking'，
/// 与三家名册源的检查点分键，互不干扰。
const actressStackingCheckpointSource = 'stacking';
const actressStackingCheckpointPhase = 'stacking';

/// 同步总览：列表页横幅与手动刷新判断用。
class ActressSyncOverview {
  const ActressSyncOverview({
    required this.persons,
    required this.works,
    required this.sources,
    required this.lastUpdatedAt,
    this.personsWithWorks = 0,
  });

  final int persons;
  final int works;

  /// 有入库作品的人数（SELECT COUNT(DISTINCT person_id) FROM
  /// works）：头顶人数只算这个（2026-11-20 用户令：要入库才算），
  /// 只有名册、还没入库作品的人不算；[persons] 仍是名册总人数，
  /// 供同步进度与叠加总量用，不改语义。
  final int personsWithWorks;

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

  /// 爬虫落库：按归一化名字合并人物（只补空字段、并标签与别名，
  /// 不认领任何名册源身份、不碰来源 id 列）；名字含硬线词返回 null。
  /// 爬到的女优名来自详情“演员：”行；mjv 站的演员记 sex 'female'，
  /// 其他站 sex 未知记空（不臆断）。
  Future<ActressPerson?> upsertCrawledPerson({
    required String name,
    String sex = '',
    List<String> tags = const [],
    String avatarUrl = '',
  });

  Future<ActressPerson?> personById(int localId);

  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
    String category = '',
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

    /// 只取该分类的作品：null/空 = 全部（头顶总数与旧调用同一口径）。
    String? category,
  });

  Future<int> countWorks(int personId, {String? category});

  /// 该人物作品里实际存在的分类（只含 category 非空的行），按作品
  /// 数从多到少、同数按名字排；没有分类的作品不产生标签、不丢数据
  /// （它们只在“全部”里显示）。详情页分类筛选的标签来源。
  Future<List<({String name, int count})>> workCategories(int personId);

  /// 作品清单合并入库：按（站，番号键）去重、无番号按（站，标题键）
  /// 去重——同番号两站各留一条，各算一条可播线路；命中硬线词的
  /// 条目跳过；写完刷新人物的 works_count。
  /// [site] 是这批作品的站（名册源名或蜘蛛站 id，如 'chaoliu'/
  /// 'whos'/'missav'）：去重键的一部分；不传时为空（旧调用与旧库
  /// 行同一口径）。[coverSource] 是这批作品封面的来源站（见
  /// [actressRosterCoverSource]）：有封面的新建行按它写
  /// cover_source；不传时默认 'whos'（与旧行为一致）；传空表示
  /// 该源不带可用封面，有封面地址的条目也不认站源、不写封面。
  Future<void> upsertWorks(
    int personId,
    List<RosterFilm> films, {
    String coverSource = 'whos',
    String site = '',
  });

  /// 全站搜索补封面：按（站，番号键）命中则更新封面与标题（同站
  /// 行优先；同站没有时退到该番号任意站的行只补封面，不挪行；
  /// 找到的行没记站（旧库 site 为空）时认领到本次命中站名下，不
  /// 新增第二行），命中不到则按 [insertIfMissing] 决定是否新增
  /// 一条跨站发现的作品行（名字搜索带番号的命中可新增，番号搜索
  /// 只补已有行；新增行的站记 [site]，同番号两站各留一条）。
  /// [site] 是命中来源站 id；不传时为空（旧调用同一口径）。
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
    String site = '',
  });

  /// 数据库镜像“任一不同就更新替换”（2026-11-20 用户令）：按
  /// （人，站，番号键/标题键）找到已有的作品行，把播放链接
  /// （cover_drama_id）与封面（cover_source/cover_url）换成
  /// 新值；标题/日期只在调用方给了非空值时才换；分类不动（与
  /// upsertWorks 的“只补空分类”同一口径）。找到并更新了返回
  /// true，没找到返回 false（调用方随后再按新建行处理）。
  Future<bool> updateWorkPlayLink({
    required int personId,
    required String site,
    required String codeKey,
    required String titleKey,
    String title = '',
    String date = '',
    required String coverSource,
    required String coverDramaId,
    required String coverUrl,
  });

  /// 某源作品清单待同步的人物（有该源身份、且该源 films 未完成）。
  Future<List<ActressPerson>> personsPendingFilms(ActressRosterSourceId source);

  /// 一次性修复候选人：该源 films 已记完成、但作品行数为 0 的人
  /// （旧版空结果记 ok 的中毒状态），供修复检查点重取一次。
  Future<List<ActressPerson>> personsNeedingFilmsRepair(
    ActressRosterSourceId source,
  );

  /// films 进度：done = 已完成人数，total = 该源身份总人数。
  Future<({int done, int total})> filmsProgress(ActressRosterSourceId source);

  Future<void> markFilmsState(
    int personId,
    ActressRosterSourceId source, {
    required bool ok,
  });

  Future<void> markEnriched(int personId);

  /// 按 localId 升序取人（全站叠加逐人轮询用）：只要 id 大于
  /// [afterId] 的前 [limit] 人，与列表排序无关，断点 cursor 即最后
  /// 一人的 localId。
  Future<List<ActressPerson>> personsAfterId({
    required int afterId,
    required int limit,
  });

  /// 全站叠加断点（独立键，与三家名册源的检查点分开，各记各的）。
  Future<ActressSyncCheckpoint?> stackingCheckpoint();

  Future<void> saveStackingCheckpoint(ActressSyncCheckpoint checkpoint);

  Future<ActressSyncCheckpoint?> checkpoint(
    ActressRosterSourceId source,
    String phase,
  );

  Future<void> saveCheckpoint(ActressSyncCheckpoint checkpoint);

  /// 内置 json 版本戳（sync_state 里 source='actress_json'、
  /// phase='version'，cursor 存合并后的 last_update）：列表页用它
  /// 判断新版 json 到没到——只在新版到达时触发一次同步，
  /// 不自动爬取网站。
  Future<String?> jsonVersionStamp();

  Future<void> saveJsonVersionStamp(String version);

  Future<ActressSyncOverview> overview();

  /// 热换库（2026-11-20 用户令）：比对当前绑定路径下数据库文件的
  /// 大小与修改时间，变了先验新库（能打开、结构对）再关旧连接重开；
  /// 验不过留旧库并回原因，不崩、不丢数据。没变回
  /// (reloaded: false, error: null)。[force] 为 true 时不管指纹
  /// 都重读一次（手动“重新加载数据库”用）。实现落在共用的打开
  /// 路径上（SqfliteActressDatabase），同步/现爬/叠加读库都走
  /// 同一个实例，换库后它们读到的都是新库。
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  });

  /// 通用读库（2026-11-20 用户令）：当前打开的库不是女优库结构
  /// 时返回通用读取器（动态探结构 + 字段映射，见
  /// actress_generic_db.dart）；是女优库结构时返回 null，走严格
  /// 路径。每次调用都按当前文件指纹重探，不沿用旧库的字段映射。
  Future<GenericDbReader?> genericReader();

  /// 开库回退提示（2026-11-20 用户令“全部使用数据库兜底”）：
  /// MYTV 库损坏/打不开时自动回退到 app 内置 actress.db，
  /// 本字段记下回退原因（供列表页绑定行显示）；正常打开时为 null。
  String? get openFallbackNote;

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
  site: (row['site'] as String?) ?? '',
  codeDisplay: (row['code_display'] as String?) ?? '',
  title: (row['title'] as String?) ?? '',
  date: (row['date'] as String?) ?? '',
  coverSource: (row['cover_source'] as String?) ?? '',
  coverDramaId: (row['cover_drama_id'] as String?) ?? '',
  coverUrl: (row['cover_url'] as String?) ?? '',
  fromCrossSite: (row['from_cross_site'] as num?)?.toInt() == 1,
  category: (row['category'] as String?) ?? '',
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
    // 2026-11-20 MYTV 绑定：库落点由绑定模块定。已绑定时是
    // MYTV/db/女优库应用.db；没权限/外部存储不可用时降级回原来的
    // documents/actress.db，表结构与 Schema 版本都不变。
    final bind = await ActressMytvBind.instance.ensureBound();
    final filePath = bind.dbPath;
    _openFallbackNote = null;
    try {
      final db = await _openDbAt(filePath);
      _openedPath = filePath;
      _openedSignature = _signatureOf(File(filePath));
      _genericReaderCache = null;
      _genericReaderKey = null;
      return db;
    } catch (e) {
      // 2026-11-20 用户令“全部使用数据库兜底”：MYTV 库损坏/
      // 打不开时回退 app 内置 actress.db，女优库照常能用，原因
      // 记在 openFallbackNote 里供列表页显示。两条路都打不开
      // 时抛原错（不在这里吞掉）。
      final legacyPath = bind.legacyDbPath;
      if (legacyPath == filePath) rethrow;
      final db = await _openDbAt(legacyPath);
      _openFallbackNote = 'MYTV 库打不开（${_shortDbError(e)}），'
          '已回退内部存储库';
      _openedPath = legacyPath;
      _openedSignature = _signatureOf(File(legacyPath));
      _genericReaderCache = null;
      _genericReaderKey = null;
      return db;
    }
  }

  @override
  String? get openFallbackNote => _openFallbackNote;

  /// 按文件探结构再开库（2026-11-20 通用读库）：不存在/空文件走
  /// 女优库建库路径；是女优库结构走建库/迁移路径；外来库直接打开，
  /// 不跑女优库迁移、不动用户的文件结构，读走通用映射层。
  Future<Database> _openDbAt(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      return _openActressDb(filePath);
    }
    final db = await _looksLikeActressDb(filePath)
        ? await _openActressDb(filePath)
        : await openDatabase(filePath);
    // 强制读一次文件头：损坏文件 open 时不一定报错，第一次查询
    // 才抛；这里验出来就关掉重抛，让 _openNow 走回退分支。
    try {
      await db.rawQuery('SELECT COUNT(*) FROM sqlite_master');
    } catch (_) {
      await db.close();
      rethrow;
    }
    return db;
  }

  /// 女优库建库/迁移路径：version 4 + onCreate 建五张表 +
  /// onUpgrade v1→v2、v2→v3、v3→v4。只对女优库结构的文件跑。
  Future<Database> _openActressDb(String filePath) {
    return openDatabase(
      filePath,
      version: 4,
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
          'site TEXT NOT NULL DEFAULT \'\', '
          'code_display TEXT NOT NULL DEFAULT \'\', '
          'title TEXT NOT NULL DEFAULT \'\', '
          'date TEXT NOT NULL DEFAULT \'\', '
          'cover_source TEXT NOT NULL DEFAULT \'\', '
          'cover_drama_id TEXT NOT NULL DEFAULT \'\', '
          'cover_url TEXT NOT NULL DEFAULT \'\', '
          'category TEXT NOT NULL DEFAULT \'\', '
          'from_cross_site INTEGER NOT NULL DEFAULT 0)',
        );
        // 番号去重与无番号标题去重：部分唯一索引各管一摊，互不冲突；
        // 去重键是（人，站，番号/标题）：同番号两站各留一条。
        await db.execute(
          'CREATE UNIQUE INDEX idx_works_code '
          'ON works(person_id, site, code_key) WHERE code_key <> \'\'',
        );
        await db.execute(
          'CREATE UNIQUE INDEX idx_works_title '
          'ON works(person_id, site, title_key) '
          'WHERE code_key = \'\' AND title_key <> \'\'',
        );
        await db.execute(
          'CREATE INDEX idx_works_person ON works(person_id, id)',
        );
        await db.execute(
          'CREATE INDEX idx_works_person_category '
          'ON works(person_id, category)',
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
        // v2 → v3：作品行加站列，去重键改成（人，站，番号/标题）；
        // 旧行站为空，与新口径一致（旧库本就按番号去重，站空即一站）。
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE works ADD COLUMN site TEXT NOT NULL DEFAULT \'\'',
          );
          await db.execute('DROP INDEX IF EXISTS idx_works_code');
          await db.execute('DROP INDEX IF EXISTS idx_works_title');
          await db.execute(
            'CREATE UNIQUE INDEX idx_works_code '
            'ON works(person_id, site, code_key) WHERE code_key <> \'\'',
          );
          await db.execute(
            'CREATE UNIQUE INDEX idx_works_title '
            'ON works(person_id, site, title_key) '
            'WHERE code_key = \'\' AND title_key <> \'\'',
          );
        }
        // v3 → v4：作品行加分类列（爬取/镜像时的列表分类，如
        // “中文字幕”/“国产自拍”；旧行与无分类来源的行留空，只在
        // “全部”里显示，不丢数据；下次镜像经过时由 upsertWorks
        // 的回填把空分类补上）。
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE works ADD COLUMN category TEXT NOT NULL DEFAULT \'\'',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_works_person_category '
            'ON works(person_id, category)',
          );
        }
      },
    );
  }

  /// 当前打开库的文件指纹（大小 + 修改时间毫秒）：开库时记一次，
  /// 热换库比对它，变了才重开。
  String? _openedPath;
  ({int length, int modifiedMs})? _openedSignature;

  /// 开库回退提示（见 openFallbackNote）：MYTV 库损坏/打不开时
  /// 回退内置库的原因；正常打开时为 null。
  String? _openFallbackNote;

  /// 通用读取器缓存：按（路径，文件指纹）缓存，文件变了自动重探，
  /// 不沿用旧库的字段映射。
  GenericDbReader? _genericReaderCache;
  String? _genericReaderKey;

  static ({int length, int modifiedMs})? _signatureOf(File file) {
    try {
      final stat = file.statSync();
      return (
        length: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  /// 只读探一下：是不是女优库结构（persons + works 表，且 works
  /// 有 code_key 列）。文件损坏/不是 sqlite 时返回 false（调用方
  /// 再按外来库直接打开，同样打不开就报错，不静默当空库）。
  Future<bool> _looksLikeActressDb(String filePath) async {
    Database? probe;
    try {
      probe = await openDatabase(filePath, readOnly: true);
      return await _isActressSchemaDb(probe);
    } catch (_) {
      return false;
    } finally {
      await probe?.close();
    }
  }

  /// 已打开的库是不是女优库结构（persons + works 表，且 works 有
  /// code_key 列）：严格路径只认这一套；表名撞上、字段不对的按
  /// 外来库走通用映射。
  Future<bool> _isActressSchemaDb(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = {for (final row in tables) row['name'].toString()};
    if (!names.contains('persons') || !names.contains('works')) {
      return false;
    }
    final cols = await db.rawQuery('PRAGMA table_info("works")');
    final colNames = {for (final row in cols) row['name'].toString()};
    return colNames.contains('code_key') &&
        colNames.contains('person_id');
  }

  /// 验一个已打开的候选库：女优库结构核对 works.code_key；外来库
  /// 至少要有一张能认出作品的表（标题 + 播放地址），否则抛错——
  /// 调用方留旧库并报原因。空库（0 张表）也接受（后面自动生成
  /// 会灌种子；通用模式下列表为空，不报错）。
  Future<void> _validateOpenDb(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    if (tables.isEmpty) return;
    if (await _isActressSchemaDb(db)) return;
    final schema = await probeGenericDbSchema(db);
    if (schema.worksTable == null) {
      throw StateError('没有找到带标题与播放地址的作品表');
    }
  }

  static String _shortDbError(Object error) {
    final first = error.toString().split('\n').first.trim();
    return first.length > 120 ? '${first.substring(0, 120)}…' : first;
  }

  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async {
    final bind = await ActressMytvBind.instance.ensureBound();
    final currentPath = bind.dbPath;
    final file = File(currentPath);
    FileStat? stat;
    try {
      stat = await file.stat();
    } catch (_) {
      stat = null;
    }
    if (stat == null || stat.type == FileSystemEntityType.notFound) {
      return (reloaded: false, error: '数据库文件不存在：$currentPath');
    }
    final signature = (
      length: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
    // 在途的开库先等它落定（不然它完成后会把 _db 指回旧文件，
    // 盖掉这次换库）。
    final pending = _openFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // 开库失败：下面按没开过库走。
      }
    }
    final opened = _db;
    if (!force &&
        opened != null &&
        opened.isOpen &&
        _openedPath == currentPath &&
        _openedSignature == signature) {
      return (reloaded: false, error: null);
    }
    if (opened == null) {
      // 还没开过库：下次 _open 会按当前文件开；手动重载时在这里
      // 开一次就算重载。
      if (!force) return (reloaded: false, error: null);
      try {
        await _open();
        _openedPath = currentPath;
        _openedSignature = signature;
        _genericReaderCache = null;
        _genericReaderKey = null;
        return (reloaded: true, error: null);
      } catch (e) {
        return (reloaded: false, error: '数据库打不开：${_shortDbError(e)}');
      }
    }
    // 先在新连接上打开并验结构（旧库还开着）：验不过留旧库。
    Database? candidate;
    try {
      candidate = await _openDbAt(currentPath);
      await _validateOpenDb(candidate);
    } catch (e) {
      await candidate?.close();
      return (reloaded: false, error: '新数据库打不开：${_shortDbError(e)}');
    }
    // 验过：换连接（旧连接关掉；_openFuture 指向新库）。
    final old = _db;
    _db = candidate;
    _openFuture = Future.value(candidate);
    _openedPath = currentPath;
    _openedSignature = signature;
    _genericReaderCache = null;
    _genericReaderKey = null;
    await old?.close();
    return (reloaded: true, error: null);
  }

  @override
  Future<GenericDbReader?> genericReader() async {
    final db = await _open();
    if (await _isActressSchemaDb(db)) return null;
    final key =
        '$_openedPath|${_openedSignature?.length}|'
        '${_openedSignature?.modifiedMs}';
    final cached = _genericReaderCache;
    if (cached != null && _genericReaderKey == key) return cached;
    final schema = await probeGenericDbSchema(db);
    // 手动映射文件与库文件放一起（MYTV/db/字段映射.json；未绑定
    // 时在 documents 下），换同结构库直接复用。
    final bind = await ActressMytvBind.instance.ensureBound();
    final store = GenericDbMappingStore(
      file: File(path.join(path.dirname(bind.dbPath), '字段映射.json')),
    );
    var resolvedSchema = schema;
    final saved = await store.loadMapping(schema.fingerprint);
    if (saved != null) {
      resolvedSchema = schema.withManualMapping(
        table: saved.table,
        columns: saved.columns,
      );
    }
    final reader = GenericDbReader(
      db: db,
      schema: resolvedSchema,
      mappingStore: store,
    );
    _genericReaderCache = reader;
    _genericReaderKey = key;
    return reader;
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
  Future<ActressPerson?> upsertCrawledPerson({
    required String name,
    String sex = '',
    List<String> tags = const [],
    String avatarUrl = '',
  }) async {
    final variants = actressNameVariants(name);
    if (variants.isEmpty) return null;
    if (variants.any(actressTextBlocked) ||
        tags.any(actressTextBlocked)) {
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
      // 只补空字段、并标签与别名：不认领任何名册源身份（fromX 与
      // 来源 id 列一律不动），名册跑过之后再合也不会被爬虫覆盖。
      ActressPerson merged;
      if (existing == null) {
        merged = ActressPerson(
          displayName: variants.first,
          aliases: variants.skip(1).toList(),
          sex: sex,
          avatarUrl: avatarUrl,
          tags: tags,
        );
      } else {
        final aliasKeys = <String>{
          actressNameKey(existing.displayName),
          for (final alias in existing.aliases) actressNameKey(alias),
        };
        final extra = <String>[];
        for (final variant in variants) {
          if (aliasKeys.add(actressNameKey(variant))) extra.add(variant);
        }
        merged = existing.copyWith(
          aliases: [...existing.aliases, ...extra],
          sex: existing.sex.isNotEmpty ? existing.sex : sex,
          avatarUrl: existing.avatarUrl.isNotEmpty
              ? existing.avatarUrl
              : avatarUrl,
          tags: <String>{...existing.tags, ...tags}.toList(),
        );
      }
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
    return (await _withLiveWorksCounts([_personFromRow(rows.first)])).first;
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
    var where =
        '(display_name LIKE ? OR aliases LIKE ? OR id IN '
        '(SELECT person_id FROM person_names WHERE name_key LIKE ?)';
    // 番号搜索：输入像番号时，另按作品番号键模糊匹配（SSIS-12 能命中
    // SSIS123）；键只含大写字母与数字，拼进 LIKE 无通配符风险。
    final codeKey = actressCodeQueryKey(trimmed);
    if (codeKey != null) {
      args.add('%$codeKey%');
      where +=
          ' OR id IN (SELECT person_id FROM works WHERE code_key LIKE ?)';
    }
    return '$where)';
  }

  // 标签存为 JSON 数组文本，带引号匹配避免子串误中（'"有码"' 只中整标签）。
  String _tagWhere(String tag, List<Object?> args) {
    if (tag.isEmpty) return '1 = 1';
    args.add('%${jsonEncode(tag)}%');
    return 'tags LIKE ?';
  }

  // 数据库分类：只留该分类里有作品的人（video_category 主分类
  // 经同步写进 works.category；见 upsertWorks）。
  String _categoryWhere(String category, List<Object?> args) {
    if (category.isEmpty) return '1 = 1';
    args.add(category);
    return 'EXISTS (SELECT 1 FROM works w '
        'WHERE w.person_id = persons.id AND w.category = ?)';
  }

  String _sortOrder(ActressSort sort) => switch (sort) {
    // 作品数只算入库数（2026-11-20 用户令：要入库才算），
    // 不再拿 MAX(works_count, roster_works) 充数。
    ActressSort.worksDesc => 'works_count DESC, display_name ASC',
    ActressSort.nameAsc => 'display_name ASC',
    // 最近更新：每人入库作品里最新作品日期倒序；COALESCE 把
    // 无入库作品的人的空值当 ''，倒序时沉底；同日按名字。
    // 只算 works 表里实际有的日期，不用站方宣称的更新时间。
    ActressSort.recentDesc =>
      "COALESCE((SELECT MAX(date) FROM works WHERE works.person_id = persons.id), '') DESC, display_name ASC",
  };

  @override
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
    String category = '',
  }) async {
    final db = await _open();
    final args = <Object?>[];
    final where =
        '${_sexWhere(sex, args)} AND ${_queryWhere(query, args)} '
        'AND ${_tagWhere(tag, args)} AND ${_categoryWhere(category, args)}';
    final rows = await db.query(
      'persons',
      where: where,
      whereArgs: args,
      orderBy: _sortOrder(sort),
      limit: limit,
      offset: offset,
    );
    return _withLiveWorksCounts(rows.map(_personFromRow).toList());
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
    final persons =
        await _withLiveWorksCounts(rows.map(_personFromRow).toList())
          ..sort(compareActressRank);
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
    String? category,
  }) async {
    final db = await _open();
    final useCategory = category != null && category.isNotEmpty;
    final rows = await db.query(
      'works',
      where: useCategory ? 'person_id = ? AND category = ?' : 'person_id = ?',
      whereArgs: useCategory ? [personId, category] : [personId],
      orderBy: 'id ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_workFromRow).toList();
  }

  @override
  Future<int> countWorks(int personId, {String? category}) async {
    final db = await _open();
    final useCategory = category != null && category.isNotEmpty;
    final rows = await db.rawQuery(
      useCategory
          ? 'SELECT COUNT(*) AS c FROM works '
                'WHERE person_id = ? AND category = ?'
          : 'SELECT COUNT(*) AS c FROM works WHERE person_id = ?',
      useCategory ? [personId, category] : [personId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<({String name, int count})>> workCategories(
    int personId,
  ) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT category AS name, COUNT(*) AS c FROM works '
      'WHERE person_id = ? AND category <> \'\' '
      'GROUP BY category ORDER BY c DESC, category ASC',
      [personId],
    );
    return [
      for (final row in rows)
        (
          name: (row['name'] as String?) ?? '',
          count: (row['c'] as num?)?.toInt() ?? 0,
        ),
    ];
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

  /// 读数口径（2026-11-20 计数修复）：列表卡片与详情头顶的
  /// worksCount 一律以 works 表实时行数为准——单次聚合查询覆盖
  /// 本批全部人，覆盖掉 persons.works_count 缓存列的值。
  /// 缓存列仍由各写路径维护、只供 SQL 排序用；显示数与
  /// countWorks() 从此永远是同一份数，不存在“列表一个数、
  /// 详情另一个数”。
  Future<List<ActressPerson>> _withLiveWorksCounts(
    List<ActressPerson> persons,
  ) async {
    if (persons.isEmpty) return persons;
    final db = await _open();
    final ids = persons.map((person) => person.localId).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT person_id, COUNT(*) AS c FROM works '
      'WHERE person_id IN ($placeholders) GROUP BY person_id',
      ids,
    );
    final counts = <int, int>{
      for (final row in rows)
        (row['person_id'] as num).toInt(): (row['c'] as num).toInt(),
    };
    return [
      for (final person in persons)
        person.copyWith(worksCount: counts[person.localId] ?? 0),
    ];
  }

  @override
  Future<void> upsertWorks(
    int personId,
    List<RosterFilm> films, {
    String coverSource = 'whos',
    String site = '',
  }) async {
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
        // 同步时已取到的封面（whos XOR 开关打开时、MissAV 人物页
        // 直取）：只在新建行时写入；开关关闭/无图时三字段恒为空。
        // 封面来源站按调用方传入的 [coverSource] 写，不再写死。
        final coverFields = film.coverUrl.isEmpty || coverSource.isEmpty
            ? const <String, Object?>{}
            : <String, Object?>{
                'cover_source': coverSource,
                'cover_drama_id': film.detailUrl,
                'cover_url': film.coverUrl,
              };
        // 去重键是（人，站，番号/标题）：同站同番号冲突即丢弃，
        // 换站同番号不冲突，各留一条。
        if (codeKey.isNotEmpty) {
          await txn.insert('works', {
            'person_id': personId,
            'code_key': codeKey,
            'title_key': titleKey,
            'site': site,
            'code_display': codeDisplay,
            'title': title == codeDisplay ? '' : title,
            'date': film.date.trim(),
            'category': film.category,
            ...coverFields,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        } else {
          await txn.insert('works', {
            'person_id': personId,
            'code_key': '',
            'title_key': titleKey,
            'site': site,
            'code_display': '',
            'title': title,
            'date': film.date.trim(),
            'category': film.category,
            ...coverFields,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        // 分类回填：这部已在库里（同步先写了空分类的行、或旧库行）、
        // 本次带真实分类时，只把空分类补上；已有分类的行不动，
        // 不覆盖。老用户库里的旧行下次镜像经过时自动补上分类。
        if (film.category.isNotEmpty) {
          if (codeKey.isNotEmpty) {
            await txn.rawUpdate(
              'UPDATE works SET category = ? WHERE person_id = ? '
              'AND site = ? AND code_key = ? AND category = \'\'',
              [film.category, personId, site, codeKey],
            );
          } else {
            await txn.rawUpdate(
              'UPDATE works SET category = ? WHERE person_id = ? '
              'AND site = ? AND code_key = \'\' AND title_key = ? '
              'AND category = \'\'',
              [film.category, personId, site, titleKey],
            );
          }
        }
      }
      await _refreshWorksCount(txn, personId);
    });
  }

  @override
  Future<bool> updateWorkPlayLink({
    required int personId,
    required String site,
    required String codeKey,
    required String titleKey,
    String title = '',
    String date = '',
    required String coverSource,
    required String coverDramaId,
    required String coverUrl,
  }) async {
    if (codeKey.isEmpty && titleKey.isEmpty) return false;
    final db = await _open();
    final values = <String, Object?>{
      'cover_source': coverSource,
      'cover_drama_id': coverDramaId,
      'cover_url': coverUrl,
    };
    // 标题/日期只在调用方给了非空值时才换（不拿空值盖掉已有标题）。
    if (title.isNotEmpty) values['title'] = title;
    if (date.isNotEmpty) values['date'] = date;
    final changed = codeKey.isNotEmpty
        ? await db.update(
            'works',
            values,
            where: 'person_id = ? AND site = ? AND code_key = ?',
            whereArgs: [personId, site, codeKey],
          )
        : await db.update(
            'works',
            values,
            where: 'person_id = ? AND site = ? AND code_key = \'\' '
                'AND title_key = ?',
            whereArgs: [personId, site, titleKey],
          );
    return changed > 0;
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
    String site = '',
  }) async {
    if (actressTextBlocked(title) || actressTextBlocked(codeDisplay)) return;
    if (codeKey.isEmpty && titleKey.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      // 1）同站行优先：按（人，站，番号/标题）查。
      final where = codeKey.isNotEmpty
          ? 'person_id = ? AND site = ? AND code_key = ?'
          : 'person_id = ? AND site = ? AND code_key = \'\' AND title_key = ?';
      final whereArgs = <Object?>[
        personId,
        site,
        codeKey.isNotEmpty ? codeKey : titleKey,
      ];
      final sameSite = await txn.query(
        'works',
        where: where,
        whereArgs: whereArgs,
        limit: 1,
      );
      if (sameSite.isNotEmpty) {
        final row = _workFromRow(sameSite.first);
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
        await _refreshWorksCount(txn, personId);
        return;
      }
      // 2）同站没有：退到该番号任意站的行，只补封面，不挪行、
      // 不改标题与日期（那是别站行的字段）。
      final anyWhere = codeKey.isNotEmpty
          ? 'person_id = ? AND code_key = ?'
          : 'person_id = ? AND code_key = \'\' AND title_key = ?';
      final anyArgs = <Object?>[
        personId,
        codeKey.isNotEmpty ? codeKey : titleKey,
      ];
      final anySite = await txn.query(
        'works',
        where: anyWhere,
        whereArgs: anyArgs,
        limit: 1,
      );
      if (anySite.isNotEmpty) {
        final row = _workFromRow(anySite.first);
        if (row.site.isEmpty) {
          // 旧库行没记站（站未知）：认领到本次命中站名下，封面/
          // 标题/日期只补空位，不新增第二行（名字路只附已有行）。
          final updates = <String, Object?>{
            'site': site,
            if (row.coverUrl.isEmpty) 'cover_source': coverSource,
            if (row.coverUrl.isEmpty) 'cover_drama_id': coverDramaId,
            if (row.coverUrl.isEmpty) 'cover_url': coverUrl,
            if (row.title.isEmpty && title.isNotEmpty) 'title': title,
            if (row.date.isEmpty && date.isNotEmpty) 'date': date,
          };
          await txn.update(
            'works',
            updates,
            where: 'id = ?',
            whereArgs: [row.id],
          );
        } else {
          if (row.coverUrl.isEmpty) {
            await txn.update(
              'works',
              {
                'cover_source': coverSource,
                'cover_drama_id': coverDramaId,
                'cover_url': coverUrl,
              },
              where: 'id = ?',
              whereArgs: [row.id],
            );
          }
          // 找到的行站 ≠ 传入站且允许新增时，按传入站新增一行：
          // 同番号两站各留一条，各算一条可播线路。
          if (insertIfMissing && site.isNotEmpty && row.site != site) {
            await txn.insert('works', {
              'person_id': personId,
              'code_key': codeKey,
              'title_key': titleKey,
              'site': site,
              'code_display': codeDisplay,
              'title': title,
              'date': date,
              'cover_source': coverSource,
              'cover_drama_id': coverDramaId,
              'cover_url': coverUrl,
              'from_cross_site': 1,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        await _refreshWorksCount(txn, personId);
        return;
      }
      // 3）无行：按 insertIfMissing 决定是否按传入站新增一行。
      if (!insertIfMissing) return;
      await txn.insert('works', {
        'person_id': personId,
        'code_key': codeKey,
        'title_key': titleKey,
        'site': site,
        'code_display': codeDisplay,
        'title': title,
        'date': date,
        'cover_source': coverSource,
        'cover_drama_id': coverDramaId,
        'cover_url': coverUrl,
        'from_cross_site': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
  Future<List<ActressPerson>> personsNeedingFilmsRepair(
    ActressRosterSourceId source,
  ) async {
    final db = await _open();
    final column = _sourceIdColumn(source);
    final rows = await db.query(
      'persons',
      where:
          "$column <> '' AND EXISTS (SELECT 1 FROM source_films f "
          'WHERE f.person_id = persons.id AND f.source = ? '
          'AND f.synced_at IS NOT NULL) '
          'AND NOT EXISTS (SELECT 1 FROM works w '
          'WHERE w.person_id = persons.id)',
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
  Future<List<ActressPerson>> personsAfterId({
    required int afterId,
    required int limit,
  }) async {
    final db = await _open();
    final rows = await db.query(
      'persons',
      where: 'id > ?',
      whereArgs: [afterId],
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows.map(_personFromRow).toList();
  }

  @override
  Future<ActressSyncCheckpoint?> stackingCheckpoint() async {
    final db = await _open();
    final rows = await db.query(
      'sync_state',
      where: 'source = ? AND phase = ?',
      whereArgs: [
        actressStackingCheckpointSource,
        actressStackingCheckpointPhase,
      ],
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
  Future<void> saveStackingCheckpoint(ActressSyncCheckpoint checkpoint) async {
    final db = await _open();
    await db.insert('sync_state', {
      'source': actressStackingCheckpointSource,
      'phase': actressStackingCheckpointPhase,
      'cursor': checkpoint.cursor,
      'total': checkpoint.total,
      'finished': checkpoint.finished ? 1 : 0,
      'error': checkpoint.error,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
  Future<String?> jsonVersionStamp() async {
    final db = await _open();
    final rows = await db.query(
      'sync_state',
      columns: ['cursor'],
      where: 'source = ? AND phase = ?',
      whereArgs: ['actress_json', 'version'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['cursor'] as String?;
  }

  @override
  Future<void> saveJsonVersionStamp(String version) async {
    final db = await _open();
    await db.insert('sync_state', {
      'source': 'actress_json',
      'phase': 'version',
      'cursor': version,
      'total': 0,
      'finished': 1,
      'error': '',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<ActressSyncOverview> overview() async {
    final db = await _open();
    final personRows = await db.rawQuery('SELECT COUNT(*) AS c FROM persons');
    final workRows = await db.rawQuery('SELECT COUNT(*) AS c FROM works');
    final withWorksRows = await db.rawQuery(
      'SELECT COUNT(DISTINCT person_id) AS c FROM works',
    );
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
      personsWithWorks: (withWorksRows.first['c'] as num?)?.toInt() ?? 0,
      sources: sources,
      lastUpdatedAt: (updatedRows.first['m'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    // 2026-11-20 MYTV 绑定：close 后再开必须重新走 _openNow
    // 拿新路径（授权后重新绑定换库用）。原来只清 _db 不清
    // _openFuture，close 后再开会拿到已关闭的旧库。
    _openFuture = null;
    // 2026-11-20 热换库：指纹与通用缓存也清掉，下次开库重探。
    _openedPath = null;
    _openedSignature = null;
    _genericReaderCache = null;
    _genericReaderKey = null;
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

  /// 全站叠加断点在检查点表里的键（与三家名册源的键分开）。
  static const _stackingCheckpointKey =
      '$actressStackingCheckpointSource:$actressStackingCheckpointPhase';
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
  Future<ActressPerson?> upsertCrawledPerson({
    required String name,
    String sex = '',
    List<String> tags = const [],
    String avatarUrl = '',
  }) async {
    final variants = actressNameVariants(name);
    if (variants.isEmpty) return null;
    if (variants.any(actressTextBlocked) ||
        tags.any(actressTextBlocked)) {
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
    final ActressPerson merged;
    if (existing == null) {
      merged = ActressPerson(
        displayName: variants.first,
        aliases: variants.skip(1).toList(),
        sex: sex,
        avatarUrl: avatarUrl,
        tags: tags,
      );
    } else {
      final aliasKeys = <String>{
        actressNameKey(existing.displayName),
        for (final alias in existing.aliases) actressNameKey(alias),
      };
      final extra = <String>[];
      for (final variant in variants) {
        if (aliasKeys.add(actressNameKey(variant))) extra.add(variant);
      }
      merged = existing.copyWith(
        aliases: [...existing.aliases, ...extra],
        sex: existing.sex.isNotEmpty ? existing.sex : sex,
        avatarUrl: existing.avatarUrl.isNotEmpty
            ? existing.avatarUrl
            : avatarUrl,
        tags: <String>{...existing.tags, ...tags}.toList(),
      );
    }
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
  Future<ActressPerson?> personById(int localId) async {
    final person = _persons[localId];
    return person == null ? null : _withLiveWorksCount(person);
  }

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
    if (key.isNotEmpty) {
      final keys = <String>{
        actressNameKey(person.displayName),
        for (final alias in person.aliases) actressNameKey(alias),
      };
      if (keys.any((candidate) => candidate.contains(key))) return true;
    }
    // 番号搜索：与 SQL 版同一口径，作品番号键模糊匹配。
    final codeKey = actressCodeQueryKey(trimmed);
    if (codeKey != null) {
      return _works.values.any(
        (work) =>
            work.personId == person.localId &&
            work.codeKey.contains(codeKey),
      );
    }
    return false;
  }

  List<ActressPerson> _filtered({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
    String category = '',
  }) => _persons.values
      .where(
        (person) =>
            _sexMatches(person, sex) &&
            _queryMatches(person, query) &&
            (tag.isEmpty || person.tags.contains(tag)) &&
            (category.isEmpty ||
                _works.values.any(
                  (work) =>
                      work.personId == person.localId &&
                      work.category == category,
                )),
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
    String category = '',
  }) async {
    final filtered = _filtered(
      sex: sex,
      query: query,
      tag: tag,
      category: category,
    );
    switch (sort) {
      case ActressSort.worksDesc:
        filtered.sort((a, b) {
          final works = b.displayWorks.compareTo(a.displayWorks);
          if (works != 0) return works;
          return a.displayName.compareTo(b.displayName);
        });
      case ActressSort.nameAsc:
        filtered.sort((a, b) => a.displayName.compareTo(b.displayName));
      case ActressSort.recentDesc:
        // 最近更新：每人入库作品里最新作品日期倒序，无入库作品的
        // 人日期为空串、倒序沉底；同日按名字。只算库里实际有的。
        final latest = <int, String>{};
        for (final work in _works.values) {
          final current = latest[work.personId] ?? '';
          if (work.date.compareTo(current) > 0) {
            latest[work.personId] = work.date;
          }
        }
        filtered.sort((a, b) {
          final cmp = (latest[b.localId] ?? '').compareTo(
            latest[a.localId] ?? '',
          );
          if (cmp != 0) return cmp;
          return a.displayName.compareTo(b.displayName);
        });
    }
    if (offset >= filtered.length) return const [];
    return filtered
        .skip(offset)
        .take(limit)
        .map(_withLiveWorksCount)
        .toList();
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
        _persons.values
            .where((person) => _sexMatches(person, sex))
            .map(_withLiveWorksCount)
            .toList()
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
    String? category,
  }) async {
    final useCategory = category != null && category.isNotEmpty;
    final works = _works.values
        .where((work) => work.personId == personId)
        .where((work) => !useCategory || work.category == category)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (offset >= works.length) return const [];
    return works.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countWorks(int personId, {String? category}) async {
    final useCategory = category != null && category.isNotEmpty;
    return _works.values
        .where((work) => work.personId == personId)
        .where((work) => !useCategory || work.category == category)
        .length;
  }

  @override
  Future<List<({String name, int count})>> workCategories(
    int personId,
  ) async {
    final counts = <String, int>{};
    for (final work in _works.values) {
      if (work.personId != personId) continue;
      if (work.category.isEmpty) continue;
      counts[work.category] = (counts[work.category] ?? 0) + 1;
    }
    final out = [
      for (final entry in counts.entries)
        (name: entry.key, count: entry.value),
    ];
    out.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  void _refreshWorksCount(int personId) {
    final person = _persons[personId];
    if (person == null) return;
    final count = _works.values
        .where((work) => work.personId == personId)
        .length;
    _persons[personId] = person.copyWith(worksCount: count);
  }

  /// 读数口径（2026-11-20 计数修复，与 sqflite 实现同一口径）：
  /// 列表卡片与详情头顶的 worksCount 一律以 works 表实时行数为准，
  /// 读时现算，不拿存着的 worksCount 字段充数；显示数与
  /// countWorks() 永远是同一份数。
  ActressPerson _withLiveWorksCount(ActressPerson person) =>
      person.copyWith(
        worksCount: _works.values
            .where((work) => work.personId == person.localId)
            .length,
      );

  @override
  Future<void> upsertWorks(
    int personId,
    List<RosterFilm> films, {
    String coverSource = 'whos',
    String site = '',
  }) async {
    for (final film in films) {
      if (actressTextBlocked(film.code) || actressTextBlocked(film.title)) {
        continue;
      }
      final codeKey = film.codeKey;
      final titleKey = film.titleKey;
      if (codeKey.isEmpty && titleKey.isEmpty) continue;
      // 去重键是（人，站，番号/标题）：同站同番号冲突即丢弃，
      // 换站同番号不冲突，各留一条；冲突行只做分类回填（旧行没记
      // 分类、新数据带真实分类时补上，已有分类的不覆盖）。
      ActressWork? existing;
      for (final work in _works.values) {
        if (work.personId != personId) continue;
        if (work.site != site) continue;
        if (codeKey.isNotEmpty) {
          if (work.codeKey == codeKey) existing = work;
        } else if (work.codeKey.isEmpty && work.titleKey == titleKey) {
          existing = work;
        }
        if (existing != null) break;
      }
      if (existing != null) {
        if (existing.category.isEmpty && film.category.isNotEmpty) {
          _works[existing.id] = existing.copyWith(
            category: film.category,
          );
        }
        continue;
      }
      final codeDisplay = film.code.trim();
      final title = film.title.trim();
      _works[_nextWorkId] = ActressWork(
        id: _nextWorkId++,
        personId: personId,
        codeKey: codeKey,
        titleKey: titleKey,
        site: site,
        codeDisplay: codeDisplay,
        title: title == codeDisplay ? '' : title,
        date: film.date.trim(),
        category: film.category,
        // 同步时已取到的封面：开关关闭/无图/来源站为空时三字段恒为空；
        // 封面来源站按调用方传入的 [coverSource] 写，不再写死。
        coverSource: film.coverUrl.isEmpty || coverSource.isEmpty
            ? ''
            : coverSource,
        coverDramaId: film.coverUrl.isEmpty || coverSource.isEmpty
            ? ''
            : film.detailUrl,
        coverUrl: film.coverUrl.isEmpty || coverSource.isEmpty
            ? ''
            : film.coverUrl,
      );
    }
    _refreshWorksCount(personId);
  }

  @override
  Future<bool> updateWorkPlayLink({
    required int personId,
    required String site,
    required String codeKey,
    required String titleKey,
    String title = '',
    String date = '',
    required String coverSource,
    required String coverDramaId,
    required String coverUrl,
  }) async {
    if (codeKey.isEmpty && titleKey.isEmpty) return false;
    for (final work in _works.values) {
      if (work.personId != personId) continue;
      if (work.site != site) continue;
      final matches = codeKey.isNotEmpty
          ? work.codeKey == codeKey
          : work.codeKey.isEmpty && work.titleKey == titleKey;
      if (!matches) continue;
      _works[work.id] = work.copyWith(
        title: title.isNotEmpty ? title : work.title,
        date: date.isNotEmpty ? date : work.date,
        coverSource: coverSource,
        coverDramaId: coverDramaId,
        coverUrl: coverUrl,
      );
      return true;
    }
    return false;
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
    String site = '',
  }) async {
    if (actressTextBlocked(title) || actressTextBlocked(codeDisplay)) return;
    if (codeKey.isEmpty && titleKey.isEmpty) return;
    bool matches(ActressWork work) {
      if (work.personId != personId) return false;
      if (codeKey.isNotEmpty) return work.codeKey == codeKey;
      return work.codeKey.isEmpty && work.titleKey == titleKey;
    }

    ActressWork? sameSite;
    ActressWork? anySite;
    for (final work in _works.values) {
      if (!matches(work)) continue;
      anySite ??= work;
      if (work.site == site) {
        sameSite = work;
        break;
      }
    }
    // 1）同站行优先：封面/标题/日期只补空位。
    if (sameSite != null) {
      _works[sameSite.id] = sameSite.copyWith(
        coverSource: sameSite.coverUrl.isEmpty
            ? coverSource
            : sameSite.coverSource,
        coverDramaId: sameSite.coverUrl.isEmpty
            ? coverDramaId
            : sameSite.coverDramaId,
        coverUrl: sameSite.coverUrl.isEmpty ? coverUrl : sameSite.coverUrl,
        title: sameSite.title.isEmpty && title.isNotEmpty
            ? title
            : sameSite.title,
        date: sameSite.date.isEmpty && date.isNotEmpty
            ? date
            : sameSite.date,
      );
      _refreshWorksCount(personId);
      return;
    }
    // 2）同站没有：退到该番号任意站的行，只补封面，不挪行。
    if (anySite != null) {
      if (anySite.site.isEmpty) {
        // 旧库行没记站（站未知）：认领到本次命中站名下，封面/
        // 标题/日期只补空位，不新增第二行（名字路只附已有行）。
        _works[anySite.id] = anySite.copyWith(
          site: site,
          coverSource: anySite.coverUrl.isEmpty
              ? coverSource
              : anySite.coverSource,
          coverDramaId: anySite.coverUrl.isEmpty
              ? coverDramaId
              : anySite.coverDramaId,
          coverUrl: anySite.coverUrl.isEmpty ? coverUrl : anySite.coverUrl,
          title: anySite.title.isEmpty && title.isNotEmpty
              ? title
              : anySite.title,
          date: anySite.date.isEmpty && date.isNotEmpty
              ? date
              : anySite.date,
        );
      } else {
        if (anySite.coverUrl.isEmpty) {
          _works[anySite.id] = anySite.copyWith(
            coverSource: coverSource,
            coverDramaId: coverDramaId,
            coverUrl: coverUrl,
          );
        }
        // 找到的行站 ≠ 传入站且允许新增时，按传入站新增一行：
        // 同番号两站各留一条，各算一条可播线路。
        if (insertIfMissing && site.isNotEmpty && anySite.site != site) {
          _works[_nextWorkId] = ActressWork(
            id: _nextWorkId++,
            personId: personId,
            codeKey: codeKey,
            titleKey: titleKey,
            site: site,
            codeDisplay: codeDisplay,
            title: title,
            date: date,
            coverSource: coverSource,
            coverDramaId: coverDramaId,
            coverUrl: coverUrl,
            fromCrossSite: true,
          );
        }
      }
      _refreshWorksCount(personId);
      return;
    }
    // 3）无行：按 insertIfMissing 决定是否按传入站新增一行。
    if (!insertIfMissing) return;
    _works[_nextWorkId] = ActressWork(
      id: _nextWorkId++,
      personId: personId,
      codeKey: codeKey,
      titleKey: titleKey,
      site: site,
      codeDisplay: codeDisplay,
      title: title,
      date: date,
      coverSource: coverSource,
      coverDramaId: coverDramaId,
      coverUrl: coverUrl,
      fromCrossSite: true,
    );
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
  Future<List<ActressPerson>> personsNeedingFilmsRepair(
    ActressRosterSourceId source,
  ) async {
    final repair =
        _persons.values
            .where(
              (person) =>
                  person.hasSource(source) &&
                  _filmsState['${person.localId}:${source.name}'] == true &&
                  !_works.values.any(
                    (work) => work.personId == person.localId,
                  ),
            )
            .toList()
          ..sort((a, b) => a.localId.compareTo(b.localId));
    return repair;
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
  Future<List<ActressPerson>> personsAfterId({
    required int afterId,
    required int limit,
  }) async {
    final persons =
        _persons.values.where((person) => person.localId > afterId).toList()
          ..sort((a, b) => a.localId.compareTo(b.localId));
    return persons.take(limit).toList();
  }

  @override
  Future<ActressSyncCheckpoint?> stackingCheckpoint() async =>
      _checkpoints[_stackingCheckpointKey];

  @override
  Future<void> saveStackingCheckpoint(ActressSyncCheckpoint checkpoint) async {
    _checkpoints[_stackingCheckpointKey] = ActressSyncCheckpoint(
      source: actressStackingCheckpointSource,
      phase: actressStackingCheckpointPhase,
      cursor: checkpoint.cursor,
      total: checkpoint.total,
      finished: checkpoint.finished,
      error: checkpoint.error,
      updatedAt: checkpoint.updatedAt,
    );
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
  Future<String?> jsonVersionStamp() async =>
      _checkpoints['actress_json:version']?.cursor;

  @override
  Future<void> saveJsonVersionStamp(String version) async {
    _checkpoints['actress_json:version'] = ActressSyncCheckpoint(
      source: 'actress_json',
      phase: 'version',
      cursor: version,
      finished: true,
    );
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
      personsWithWorks: {
        for (final work in _works.values) work.personId,
      }.length,
      sources: sources,
      lastUpdatedAt: 0,
    );
  }

  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async => (reloaded: false, error: null);

  @override
  Future<GenericDbReader?> genericReader() async => null;

  @override
  String? get openFallbackNote => null;

  @override
  Future<void> close() async {}
}
