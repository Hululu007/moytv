import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'actress_json_fallback.dart';

/// 字段名启发式映射层（2026-11-20 用户令，2026-11-25 改用途）：
/// 外来 .sql 的表名、字段名不一定是女优库结构——先动态探结构
/// （sqlite_master 列出所有表，每张表 PRAGMA table_info 列出字段），
/// 再按字段名启发式映射，不认死字段名。
///
/// 2026-11-25 起只留 .sql 导入：本层不再直接读用户放的 .db 文件，
/// 只给两处用——
/// - .sql 导入归一化（见 actress_sql_import.dart）：[classifyGenericTables]
///   探临时库结构、挑作品表，再按角色列读行建标准表；
/// - 影视库 open() 验严格结构：[probeGenericDbSchema]。
/// - [normalizeDbFieldName]/[roleForColumn]：字段名归一化与打分；
/// - [extractPlayUrl]/[resolveCoverUrl]：播放地址与封面取值容差；
/// - [GenericDbWork]：通用作品行（nvku 只出作品的站源也用它当展示模型）。
///
/// 字段名匹配（2026-11-20 用户加码：字段名差得很多，不能只靠几个
/// 别名硬认）：先归一化（全小写、去下划线/中划线/空格），再按关键词
/// 打分——精确全名最高分，含关键词按权重加分；含 play/url/m3u8/
/// video 一类词优先当播放地址，含 pic/cover/img/thumb 当封面，
/// 含 title/name 当标题。实在认不出的表不猜、不静默丢数据，
/// 导入时报“认不出作品表”。

/// 通用映射的字段角色。
enum GenericDbRole { title, cover, playUrl, actress, code, category, date }

/// 字段名归一化：全小写、去下划线/中划线/空格（中英文同义词都在
/// 归一化后的名字上比）。
String normalizeDbFieldName(String name) {
  return name.trim().toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
}

/// 精确全名（归一化后）：命中直接最高分。
const _exactNames = <GenericDbRole, List<String>>{
  GenericDbRole.title: [
    'vodname',
    'title',
    'name',
    'moviename',
    'videoname',
    'dramaname',
    'videotitle',
    '片名',
    '标题',
    'subject',
  ],
  GenericDbRole.cover: [
    'vodpic',
    'pic',
    'cover',
    'img',
    'poster',
    '海报',
    '封面',
    'thumb',
    'thumbnail',
    'image',
    'photo',
    'coverurl',
    'picurl',
    'vodpicurl',
    'imgurl',
    'posterurl',
  ],
  GenericDbRole.playUrl: [
    'vodplayurl',
    'playurl',
    'url',
    'm3u8',
    'play',
    'video',
    'videourl',
    '地址',
    '播放地址',
    'playaddress',
    'videopath',
    'filepath',
    'fileurl',
    'streamurl',
    'src',
    'playpath',
  ],
  GenericDbRole.actress: [
    'vodactor',
    'actor',
    'actress',
    '演员',
    '女优',
    'cast',
    'performer',
    'star',
    'artist',
    'actorname',
  ],
  GenericDbRole.code: [
    'vodcode',
    'code',
    '番号',
    'avcode',
    // 2026-11-22 用户报「所有数据库」都认不出番号：外来库的主键就叫
    // plain `id`（或 videoid/vid/vodid/movieid/workid），旧表里一个
    // 都没有，整库的番号角色全灭。精确全名只认整列名，`vid` 不会
    // 误伤 `video`（关键词里绝不加 `vid`，`video` 含 `vid`）。
    'id',
    'videoid',
    'vid',
    'vodid',
    'movieid',
    'workid',
  ],
  GenericDbRole.category: [
    'typename',
    'category',
    'categoryid',
    'type',
    '类别',
    '分类',
    'genre',
    'tag',
    'classname',
  ],
  GenericDbRole.date: [
    'vodpubdate',
    'pubdate',
    'date',
    'year',
    '时间',
    '日期',
    'addtime',
    'createtime',
    'updatetime',
  ],
};

/// 关键词打分（归一化后含该词即加分）：精确全名没命中时用。
/// 同一个字段名里多个关键词可叠加；'coverurl' 这类“封面 + url”
/// 的名字，封面分（cover 3）高于播放地址分（url 2），归封面。
const _keywordScores = <GenericDbRole, List<(String, int)>>{
  GenericDbRole.playUrl: [
    ('m3u8', 5),
    ('play', 3),
    ('stream', 3),
    ('地址', 3),
    ('播放', 3),
    ('url', 2),
    ('video', 2),
    ('链接', 2),
    ('link', 2),
    ('path', 1),
  ],
  GenericDbRole.cover: [
    ('pic', 3),
    ('cover', 3),
    ('img', 3),
    ('thumb', 3),
    ('poster', 3),
    ('海报', 3),
    ('封面', 3),
    ('image', 2),
    ('photo', 2),
  ],
  GenericDbRole.title: [
    ('title', 3),
    ('片名', 3),
    ('标题', 3),
    ('name', 2),
    ('subject', 2),
  ],
  GenericDbRole.actress: [
    ('actor', 3),
    ('actress', 3),
    ('演员', 3),
    ('女优', 3),
    ('cast', 2),
    ('performer', 2),
    ('star', 1),
  ],
  GenericDbRole.code: [('code', 3), ('番号', 3)],
  GenericDbRole.category: [
    ('category', 3),
    ('类别', 3),
    ('分类', 3),
    ('type', 2),
    ('genre', 2),
  ],
  GenericDbRole.date: [
    ('date', 3),
    ('时间', 3),
    ('日期', 3),
    ('time', 2),
    ('year', 2),
  ],
};

/// 平局时的角色优先序：封面 > 播放地址 > 女优 > 标题 > 番号 >
/// 分类 > 日期（'coverurl' 归封面不归播放地址就靠这一序）。
const _roleTieBreakOrder = [
  GenericDbRole.cover,
  GenericDbRole.playUrl,
  GenericDbRole.actress,
  GenericDbRole.title,
  GenericDbRole.code,
  GenericDbRole.category,
  GenericDbRole.date,
];

/// 一个字段名最像哪个角色：精确全名 10 分，否则关键词分累加；
/// 0 分（什么关键词都不含）返回 null——不猜。
(GenericDbRole, int)? roleForColumn(String columnName) {
  final normalized = normalizeDbFieldName(columnName);
  if (normalized.isEmpty) return null;
  GenericDbRole? best;
  var bestScore = 0;
  for (final role in GenericDbRole.values) {
    var score = 0;
    if (_exactNames[role]!.contains(normalized)) {
      score = 10;
    } else {
      for (final (keyword, weight) in _keywordScores[role]!) {
        if (normalized.contains(keyword)) score += weight;
      }
    }
    if (score <= 0) continue;
    if (score > bestScore ||
        (score == bestScore &&
            best != null &&
            _roleTieBreakOrder.indexOf(role) <
                _roleTieBreakOrder.indexOf(best))) {
      best = role;
      bestScore = score;
    }
  }
  if (best == null) return null;
  return (best, bestScore);
}

/// 分类类列的候选词（归一化后含该词即算）：多级筛选要把作品表里
/// 所有像分类/分类名/标签/系列/地区的列都当成可筛选维度，不能只
/// 用自动映射出来的那一个 category 列——库里常常同时有 type/class/
/// tags/series 好几级。
const _facetKeywords = <String>[
  'category',
  'class',
  'type',
  'genre',
  'tag',
  'series',
  'area',
  'kind',
  'group',
  'theme',
  '分类',
  '类别',
  '类型',
  '标签',
  '系列',
  '地区',
  '题材',
];

/// 归一化后含这些词的列不当分类维度（地址/图片/路径类，名字里
/// 带 type 也不算分类）。
const _facetExcludeKeywords = <String>[
  'url',
  'link',
  'pic',
  'img',
  'cover',
  'path',
  'file',
  'address',
  'mime',
];

/// 一张表里哪些列能当分类筛选维度（保持表内字段顺序，自动识别的
/// category 列排第一）。
List<String> categoryFacetColumns(GenericDbTableMapping mapping) {
  final out = <String>[];
  final category = mapping.columnFor(GenericDbRole.category);
  if (category != null) out.add(category);
  for (final column in mapping.allColumns) {
    if (out.contains(column)) continue;
    final normalized = normalizeDbFieldName(column);
    if (normalized.isEmpty) continue;
    if (_facetExcludeKeywords.any(normalized.contains)) continue;
    if (_facetKeywords.any(normalized.contains)) out.add(column);
  }
  return out;
}

/// 一个分类维度里的一个取值：值 + 该值下的作品数。
class GenericDbFacetValue {
  const GenericDbFacetValue({
    required this.value,
    required this.count,
    this.coverUrl = '',
  });

  final String value;
  final int count;

  /// 这个取值下首张作品封面：给「分类按视频卡片显示」用，取不到就空着。
  final String coverUrl;
}

/// 一个分类维度（库里的某个人工列，如 type/class/tags/series）：
/// 列名 + 该列的实际取值（按作品数从多到少）。
class GenericDbFacet {
  const GenericDbFacet({required this.column, required this.values});

  final String column;
  final List<GenericDbFacetValue> values;

  bool get isEmpty => values.isEmpty;
}

/// 跨表关联：作品表本身没存播放地址/封面时，地址常常在另一张表
/// （movie_id → url）。这里记下副表、指回作品表的外键、作品表的
/// 被指向列，以及副表里能提供哪些角色（播放地址/封面）。
class GenericDbRelation {
  const GenericDbRelation({
    required this.table,
    required this.foreignKey,
    required this.primaryKey,
    required this.columns,
  });

  final String table;
  final String foreignKey;
  final String primaryKey;
  final Map<GenericDbRole, String> columns;

  String? columnFor(GenericDbRole role) => columns[role];
}

/// 一张表的字段映射：角色 → 实际字段名（+ 行 id 列）。
class GenericDbTableMapping {
  const GenericDbTableMapping({
    required this.table,
    required this.columns,
    required this.allColumns,
    this.idColumn,
  });

  final String table;

  /// 角色 → 该表里实际的字段名（每角色只留得分最高的一列）。
  final Map<GenericDbRole, String> columns;

  /// 该表的全部字段名（含未识别的）：手动指定映射时下拉要列全，
  /// 只列已识别的就选不到没被认出来的列。
  final List<String> allColumns;

  /// 行 id 列（主键优先，其次是名字像 id 的列，再其次用 rowid）。
  final String? idColumn;

  String? columnFor(GenericDbRole role) => columns[role];

  bool get hasTitleAndPlayUrl =>
      columns.containsKey(GenericDbRole.title) &&
      columns.containsKey(GenericDbRole.playUrl);
}

/// 探结构结果：所有表 + 认出的作品表/人物表 + 未识别的表。
class GenericDbSchema {
  const GenericDbSchema({
    required this.tables,
    required this.fingerprint,
    this.worksTable,
    this.personsTable,
    this.manualTable,
    this.manualColumns,
    this.relations = const [],
    this.facetRelations = const [],
  });

  /// 全部表（每张表的字段角色映射）。
  final List<GenericDbTableMapping> tables;

  /// 结构指纹：表名 + 字段名拼起来（手动映射按它存，下次换同
  /// 结构的库直接用；文件换了结构、指纹就变了，不沿用旧映射）。
  final String fingerprint;

  /// 作品表（同时有标题类字段与播放地址类字段的那张；没有为 null）。
  final GenericDbTableMapping? worksTable;

  /// 人物表（有人名类字段、没有播放地址的那张；没有为 null）。
  final GenericDbTableMapping? personsTable;

  /// 手动指定的作品表（有值时以它为准）。
  final String? manualTable;

  /// 手动指定的字段映射（角色 → 字段名）。
  final Map<GenericDbRole, String>? manualColumns;

  /// 跨表关联：作品表本身没有播放地址/封面时，从副表按外键补。
  final List<GenericDbRelation> relations;

  /// 跨表分类维度：作品表本身没有分类列（或分类在另一张表里）时，
  /// 按外键把副表的分类列做成筛选维度。女优库就是这样——videos
  /// 只有 type_name（值全是「成人影片」），真正的「有码/无码/4K」
  /// 在 video_category(vod_id, main_category) 里，不跨表就一个都读不到。
  ///
  /// 每项的 [GenericDbRelation.columns] 里只放 category 一条角色映射。
  final List<GenericDbRelation> facetRelations;

  GenericDbRelation? relationFor(GenericDbRole role) {
    for (final relation in relations) {
      if (relation.columnFor(role) != null) return relation;
    }
    return null;
  }

  bool get hasWorks => worksTable != null;

  /// 未识别的表（既不是作品表也不是人物表）：进“数据库字段”
  /// 查看入口列出来，不静默丢数据。
  List<GenericDbTableMapping> get unmappedTables => [
    for (final table in tables)
      if (table != worksTable && table != personsTable) table,
  ];

  /// 应用手动映射（用户在“数据库字段”页指定）：标题与播放地址
  /// 两个必填角色缺一不可，缺了返回原 schema 不改。
  GenericDbSchema withManualMapping({
    required String table,
    required Map<GenericDbRole, String> columns,
  }) {
    if (!columns.containsKey(GenericDbRole.title) ||
        !columns.containsKey(GenericDbRole.playUrl)) {
      return this;
    }
    GenericDbTableMapping? known;
    for (final item in tables) {
      if (item.table == table) known = item;
    }
    if (known == null) return this;
    final mapping = GenericDbTableMapping(
      table: table,
      columns: Map.of(columns),
      allColumns: known.allColumns,
      idColumn: known.idColumn,
    );
    final nextTables = [
      for (final item in tables) item.table == table ? mapping : item,
    ];
    return GenericDbSchema(
      tables: nextTables,
      fingerprint: fingerprint,
      worksTable: mapping,
      personsTable: personsTable == known ? null : personsTable,
      manualTable: table,
      manualColumns: Map.of(columns),
      relations: relations,
      facetRelations: facetRelations,
    );
  }
}

/// 表名 → 字段名列表，按字段名启发式映射、再按表分类（纯函数，
/// 不碰数据库，测试直接验）。
GenericDbSchema classifyGenericTables(
  Map<String, List<String>> tableColumns, {
  Map<String, String> pkColumns = const {},
}) {
  final mappings = <GenericDbTableMapping>[];
  for (final entry in tableColumns.entries) {
    final table = entry.key;
    final columns = entry.value;
    final byRole = <GenericDbRole, (String, int)>{};
    for (final column in columns) {
      final scored = roleForColumn(column);
      if (scored == null) continue;
      final (role, score) = scored;
      final current = byRole[role];
      if (current == null || score > current.$2) {
        byRole[role] = (column, score);
      }
    }
    String? idColumn = pkColumns[table];
    if (idColumn == null || !columns.contains(idColumn)) {
      idColumn = null;
      for (final column in columns) {
        final normalized = normalizeDbFieldName(column);
        if (normalized == 'id' || normalized.endsWith('id')) {
          idColumn = column;
          break;
        }
      }
    }
    mappings.add(
      GenericDbTableMapping(
        table: table,
        columns: {for (final kv in byRole.entries) kv.key: kv.value.$1},
        allColumns: List.of(columns),
        idColumn: idColumn,
      ),
    );
  }
  // 作品表：优先挑同时有标题与播放地址的表；没有这样的表时退一步，
  // 挑有标题、且能找到“地址在副表”关联的表（很多库是 movies 元数据
  // 表 + files 地址表分开的，不能因为主表没有 url 列就报认不出）。
  GenericDbTableMapping? worksTable;
  var relations = const <GenericDbRelation>[];
  final strictCandidates = mappings.where((m) => m.hasTitleAndPlayUrl).toList()
    ..sort((a, b) {
      final byRoles = b.columns.length.compareTo(a.columns.length);
      if (byRoles != 0) return byRoles;
      return a.table.compareTo(b.table);
    });
  if (strictCandidates.isNotEmpty) {
    worksTable = strictCandidates.first;
  } else {
    final loose =
        mappings
            .where((m) => m.columns.containsKey(GenericDbRole.title))
            .toList()
          ..sort((a, b) {
            final byRoles = b.columns.length.compareTo(a.columns.length);
            if (byRoles != 0) return byRoles;
            return a.table.compareTo(b.table);
          });
    for (final candidate in loose) {
      final found = _relationsFor(
        primary: candidate,
        mappings: mappings,
        roles: const [GenericDbRole.playUrl, GenericDbRole.cover],
      );
      if (found.any((r) => r.columnFor(GenericDbRole.playUrl) != null)) {
        worksTable = candidate;
        relations = found;
        break;
      }
    }
  }
  // 主表自己有地址时，封面仍可能在副表（封面表单独一张），补上关系。
  if (worksTable != null && relations.isEmpty) {
    relations = _relationsFor(
      primary: worksTable,
      mappings: mappings,
      roles: const [GenericDbRole.cover],
    );
  }
  // 人物表：有人名（标题角色）但没有播放地址；多张时同上排序。
  // 分类字典表（`categories` / `category`：id + 名字）不是人物表：
  // 它也有 `name`（→标题角色），不排除会被当成人物表读，分类名
  // 全跑到人物列表里去（2026-11-22 截图：categories 被标成人物表）。
  final personsCandidates =
      mappings
          .where(
            (m) =>
                m != worksTable &&
                !_isCategoryDictionaryTable(m.table) &&
                m.columns.containsKey(GenericDbRole.title) &&
                !m.columns.containsKey(GenericDbRole.playUrl),
          )
          .toList()
        ..sort((a, b) {
          final byRoles = b.columns.length.compareTo(a.columns.length);
          if (byRoles != 0) return byRoles;
          return a.table.compareTo(b.table);
        });
  final personsTable = personsCandidates.isEmpty
      ? null
      : personsCandidates.first;
  final fingerprint =
      tableColumns.entries.map((e) => '${e.key}(${e.value.join(',')})').toList()
        ..sort();
  // 分类副表（2026-11-22）：主表没有分类列时分类常常在副表里
  // （video_category / video_tag 这种两列表），不跨表就一个维度都读不到。
  final facetRelations = worksTable == null
      ? const <GenericDbRelation>[]
      : _facetRelationsFor(primary: worksTable, mappings: mappings);
  return GenericDbSchema(
    tables: mappings,
    fingerprint: fingerprint.join(';'),
    worksTable: worksTable,
    personsTable: personsTable,
    relations: relations,
    facetRelations: facetRelations,
  );
}

/// 找主表的跨表关联：副表里要有目标角色列（播放地址/封面），还要
/// 有一个能指回主表的外键列。外键判定不认死名字：
/// - `movie_id`/`videoid` 这类「主表名 + id」；
/// - 与主表主键同名的列（`movie_id` 对 `movie_id`）；
/// - `vid/mid/pid/workid/itemid/filmid/vodid/subjectid/parentid` 这类
///   通用短外键。
/// 单列 `id` 不算外键（那是副表自己的主键，会自连接拿错行）。
/// 结果按表名稳定排序，同一角色只认一张副表。
/// 外键关系（公开版，给「数据库字段」页与纯函数测试用）：按主表 +
/// 全部表的字段清单推每张副表补哪个角色。参数与库内探结构用法保持
/// 一致，内部走 [_relationsFor]。
List<GenericDbRelation> relationsFor({
  required String worksTable,
  required String? worksIdColumn,
  required List<String> worksColumns,
  required List<GenericDbTableMapping> tables,
  List<GenericDbRole> roles = GenericDbRole.values,
}) {
  final primary = GenericDbTableMapping(
    table: worksTable,
    columns: const {},
    allColumns: worksColumns,
    idColumn: worksIdColumn,
  );
  return _relationsFor(primary: primary, mappings: tables, roles: roles);
}

List<GenericDbRelation> _relationsFor({
  required GenericDbTableMapping primary,
  required List<GenericDbTableMapping> mappings,
  required List<GenericDbRole> roles,
}) {
  final out = <GenericDbRelation>[];
  final ordered = List.of(mappings)..sort((a, b) => a.table.compareTo(b.table));
  for (final role in roles) {
    GenericDbRelation? found;
    for (final sub in ordered) {
      if (sub.table == primary.table) continue;
      final column = sub.columnFor(role);
      if (column == null) continue;
      final foreignKey = _foreignKeyFor(primary: primary, sub: sub);
      if (foreignKey == null) continue;
      found = GenericDbRelation(
        table: sub.table,
        foreignKey: foreignKey,
        primaryKey: primary.idColumn!,
        columns: sub.columns,
      );
      break;
    }
    if (found != null) out.add(found);
  }
  return out;
}

/// 副表里哪一个列能指回作品表（外键）。判定不认死名字：
/// - `movie_id`/`videoid` 这类「主表名 + id」；
/// - 与主表主键同名的列（`movie_id` 对 `movie_id`）；
/// - `vid/mid/pid/workid/itemid/filmid/vodid/subjectid/parentid` 这类
///   通用短外键。
/// 单列 `id` 不算外键（那是副表自己的主键，会自连接拿错行）。
String? _foreignKeyFor({
  required GenericDbTableMapping primary,
  required GenericDbTableMapping sub,
}) {
  final pk = primary.idColumn;
  if (pk == null) return null;
  final pkNormalized = normalizeDbFieldName(pk);
  final tableNormalized = normalizeDbFieldName(primary.table);
  const genericForeignKeys = {
    'movieid',
    'videoid',
    'filmid',
    'vodid',
    'workid',
    'itemid',
    'subjectid',
    'parentid',
    'vid',
    'mid',
    'pid',
  };
  for (final candidate in sub.allColumns) {
    final normalized = normalizeDbFieldName(candidate);
    if (normalized.isEmpty || normalized == 'id') continue;
    if (normalized == '${tableNormalized}id' ||
        normalized == pkNormalized ||
        genericForeignKeys.contains(normalized)) {
      return candidate;
    }
  }
  return null;
}

/// 分类副表最多收几张（每张一个 chip，太多挤满一屏）。
const _maxFacetTables = 3;

/// 表名是不是分类字典表（`categories` / `category`：主键 + 名字）。
bool _isCategoryDictionaryTable(String table) {
  final normalized = normalizeDbFieldName(table);
  return normalized == 'categories' || normalized == 'category';
}

/// 找「分类在副表」的维度：副表里有一列像分类（category 角色，或者
/// 列名像分类/标签/类型），并且有一个能指回作品表的外键，才算一个
/// 可筛选维度。女优库：video_category(vod_id → main_category)、
/// video_tag(vod_id → tag_name) 都会命中。
///
/// 另有一类反方向的字典表（`categories`：id + name，作品表拿
/// `category_id` 指过去）：副表里没有指回作品表的外键，`_foreignKeyFor`
/// 明确不认裸 `id`（那是字典表自己的主键）。这里单独认：按
/// [GenericDbRelation] 现成的字段装——`primaryKey` 放作品表里那列
/// 外键（`category_id`）、`foreignKey` 放字典表的主键列（`id`）、
/// category 放字典表的名字列——`_where` 与 `facets()` 拼出来的 SQL
/// 正好就是 `works.category_id IN (SELECT id FROM categories
/// WHERE name IN (...))`，读库层不用改。
List<GenericDbRelation> _facetRelationsFor({
  required GenericDbTableMapping primary,
  required List<GenericDbTableMapping> mappings,
}) {
  final out = <GenericDbRelation>[];
  final ordered = List.of(mappings)..sort((a, b) => a.table.compareTo(b.table));
  // 第一相（副表指回作品表）要作品表有主键列；没有就跳过这一相，
  // 第二相（字典表反方向查表）不需要主键列，照做。
  if (primary.idColumn != null) {
    for (final sub in ordered) {
      if (out.length >= _maxFacetTables) break;
      if (sub.table == primary.table) continue;
      // 自带播放地址的表是另一套作品表，不是分类副表。
      if (sub.columns.containsKey(GenericDbRole.playUrl)) continue;
      final column = _facetColumnOf(sub);
      if (column == null) continue;
      final foreignKey = _foreignKeyFor(primary: primary, sub: sub);
      if (foreignKey == null) continue;
      out.add(
        GenericDbRelation(
          table: sub.table,
          foreignKey: foreignKey,
          primaryKey: primary.idColumn!,
          columns: {GenericDbRole.category: column},
        ),
      );
    }
  }
  // 分类字典表（反方向查表）。
  for (final sub in ordered) {
    if (out.length >= _maxFacetTables) break;
    if (sub.table == primary.table) continue;
    if (!_isCategoryDictionaryTable(sub.table)) continue;
    if (out.any((r) => r.table == sub.table)) continue;
    final nameColumn = sub.columnFor(GenericDbRole.title);
    final keyColumn = sub.idColumn;
    if (nameColumn == null || keyColumn == null) continue;
    // 作品表里指过去的那列：`category_id`（归一化后 `categoryid`）。
    const wantFk = 'categoryid';
    String? worksFk;
    for (final column in primary.allColumns) {
      if (normalizeDbFieldName(column) == wantFk) {
        worksFk = column;
        break;
      }
    }
    if (worksFk == null) continue;
    out.add(
      GenericDbRelation(
        table: sub.table,
        foreignKey: keyColumn,
        primaryKey: worksFk,
        columns: {GenericDbRole.category: nameColumn},
      ),
    );
  }
  return out;
}

/// 副表里当分类维度的那一列：先用自动映射出来的 category 列，
/// 没有再看列名像不像分类/标签/类型（tag_name 这类映射会给到标题，
/// 但它本质是分类维度）。
String? _facetColumnOf(GenericDbTableMapping mapping) {
  final category = mapping.columnFor(GenericDbRole.category);
  if (category != null) return category;
  final facets = categoryFacetColumns(mapping);
  return facets.isEmpty ? null : facets.first;
}

/// 给一个已打开的 [Database] 探结构：sqlite_master 列所有表，
/// 每张表 PRAGMA table_info 列字段（含主键信息）。
Future<GenericDbSchema> probeGenericDbSchema(Database db) async {
  final tableRows = await db.rawQuery(
    "SELECT name FROM sqlite_master "
    "WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  final tableColumns = <String, List<String>>{};
  final pkColumns = <String, String>{};
  for (final row in tableRows) {
    final table = row['name'].toString();
    final escaped = table.replaceAll('"', '""');
    final cols = await db.rawQuery('PRAGMA table_info("$escaped")');
    final names = <String>[];
    for (final col in cols) {
      final name = col['name'].toString();
      names.add(name);
      if (col['pk'] == 1) pkColumns[table] = name;
    }
    tableColumns[table] = names;
  }
  return classifyGenericTables(tableColumns, pkColumns: pkColumns);
}

/// 播放地址取值容差（纯函数）：
///
/// - `正片$地址`（TVBox 分段格式，也可能是 `标题$地址`）：取第一
///   个 `$` 后面的真地址；
/// - JSON 数组：`["地址1", "地址2"]` 取第一个能播的；
/// - JSON 对象：`{"url": "地址"}` 取 url/playUrl/play_url/src 键；
/// - 多个地址用 `$$$`、`#`、换行、`|`、`;` 隔开：取第一个像地址的
///   （http(s) 开头、含 .m3u8、或 `/` 开头），都没有像地址的取
///   第一个非空段；
/// - 裸地址：原样返回；空/不认的值返回 ''（调用方按不可播处理）。
String extractPlayUrl(dynamic value) {
  if (value == null) return '';
  if (value is List) {
    for (final item in value) {
      final url = extractPlayUrl(item);
      if (url.isNotEmpty) return url;
    }
    return '';
  }
  var text = value.toString().trim();
  if (text.isEmpty) return '';
  // 有的库把地址存成 JSON 转义态（`https:\/\/host\/a\/index.m3u8`），
  // 不还原就是废地址：播放器打不开，体检时还会被当死链整库删掉。
  if (text.contains(r'\/')) {
    text = text.replaceAll(r'\/', '/').trim();
  }
  if (text.startsWith('[')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return extractPlayUrl(decoded);
    } catch (_) {
      // 不是合法 JSON：往下按分隔符继续拆。
    }
  }
  if (text.startsWith('{')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        for (final key in ['url', 'playUrl', 'play_url', 'src', 'video']) {
          if (decoded[key] != null) {
            final url = extractPlayUrl(decoded[key]);
            if (url.isNotEmpty) return url;
          }
        }
      }
    } catch (_) {
      // 不是合法 JSON：往下按分隔符继续拆。
    }
  }
  // 分隔符拆：'正片$地址'、'$$$'、'#'、换行、'|'、';' 都按“取第一
  // 个像地址的段”处理——先拆再选，单 '$' 不能抢在 '$$$' 前面
  // （'a.m3u8$$$b.m3u8' 按第一个 $ 切会切出 '$$b.m3u8' 的错地址）。
  final parts = text.split(RegExp(r'[\$#\n|;]+'));
  for (final part in parts) {
    final candidate = part.trim();
    if (_looksLikePlayAddress(candidate)) return candidate;
  }
  for (final part in parts) {
    if (part.trim().isNotEmpty) return part.trim();
  }
  return text;
}

bool _looksLikePlayAddress(String value) =>
    value.startsWith('http://') ||
    value.startsWith('https://') ||
    value.contains('.m3u8') ||
    value.startsWith('/');

/// 封面取值容差（纯函数）：完整地址原样返回；`//` 开头补 https:；
/// `/` 开头的绝对路径有 baseUrl 时拼成完整地址，没 baseUrl 原样
/// 返回；相对路径原样返回（调用方按站拼或直接加载）。
String resolveCoverUrl(dynamic value, {String? baseUrl}) {
  if (value == null) return '';
  var text = value.toString().trim();
  if (text.isEmpty) return '';
  if (text.contains(r'\/')) {
    text = text.replaceAll(r'\/', '/').trim();
  }
  if (text.startsWith('http://') || text.startsWith('https://')) {
    return text;
  }
  if (text.startsWith('//')) return 'https:$text';
  if (text.startsWith('/')) {
    if (baseUrl != null && baseUrl.isNotEmpty) {
      final uri = Uri.tryParse(baseUrl);
      if (uri != null && uri.hasAuthority) {
        return '${uri.scheme}://${uri.authority}$text';
      }
    }
    return text;
  }
  return text;
}

/// 通用作品行：从任意结构的作品表里按映射读出来的。
class GenericDbWork {
  const GenericDbWork({
    required this.id,
    required this.title,
    this.coverUrl = '',
    this.playUrl = '',
    this.actress = '',
    this.code = '',
    this.category = '',
    this.date = '',
  });

  final Object? id;
  final String title;
  final String coverUrl;
  final String playUrl;
  final String actress;
  final String code;
  final String category;
  final String date;

  bool get playable =>
      playUrl.startsWith('http://') || playUrl.startsWith('https://');

  /// 跨表补地址/封面时用：只换这两个字段，其余照原样。
  GenericDbWork copyWith({String? coverUrl, String? playUrl}) => GenericDbWork(
    id: id,
    title: title,
    coverUrl: coverUrl ?? this.coverUrl,
    playUrl: playUrl ?? this.playUrl,
    actress: actress,
    code: code,
    category: category,
    date: date,
  );

  String get displayTitle => title.isNotEmpty ? title : code;

  String get displaySubtitle {
    final parts = <String>[];
    if (date.isNotEmpty) parts.add(date);
    if (code.isNotEmpty && code != title) parts.add(code);
    if (category.isNotEmpty) parts.add(category);
    return parts.join(' · ');
  }

  /// 转成兜底条目走现有播放链：站走 chaoliu（潮流蜘蛛的
  /// playerContent 对 http 地址直接 parse=0 回流），与 mjv/whos
  /// 兜底条目同一条路，不另写播放器。
  ActressJsonEntry toJsonEntry() => ActressJsonEntry(
    site: 'chaoliu',
    vodId: 'generic:${id ?? title}',
    vodName: title,
    vodPic: coverUrl,
    vodActor: actress,
    vodDirector: '',
    vodRemarks: '高清',
    vodPubdate: date,
    vodArea: '',
    vodYear: '',
    vodContent: '',
    vodPlayFrom: 'chaoliu',
    vodPlayUrl: '正片\$$playUrl',
    typeName: category,
    vodCode: code,
    vodActressPic: coverUrl,
    directPlay: playable,
  );
}

/// 通用人行：从任意结构的人物表里按映射读出来的。