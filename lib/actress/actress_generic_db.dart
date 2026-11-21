import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_json_fallback.dart';

/// 通用读库层（2026-11-20 用户令）：用户往 MYTV/db 里放的 db 不一定
/// 是女优库结构——表名、字段名都可能不一样。本层打开 sqlite 文件后
/// 先动态探结构（sqlite_master 列出所有表，每张表 PRAGMA table_info
/// 列出字段），再按字段名启发式映射，不认死字段名。
///
/// 女优库结构继续走严格路径（ActressDatabase 的 persons/works 表，
/// 最快最准）；探不到女优库结构时走这里，不要直接报错、不要显示空白。
/// 换库后重读要重新探结构，不要沿用旧库的字段映射（探结果按文件
/// 指纹缓存，文件变了自动重探）。
///
/// 影视库那批的新分类以后也走这套层，接线入口：
/// - [ActressDatabase.genericReader]（actress_database.dart）：当前
///   库不是女优库结构时返回 [GenericDbReader]，是时返回 null；
/// - [probeGenericDbSchema]：给一个已打开的 [Database] 探结构；
/// - [GenericDbReader.works]/[GenericDbReader.countWorks]：读作品；
/// - [normalizeDbFieldName]/[roleForColumn]：字段名归一化与打分；
/// - [extractPlayUrl]/[resolveCoverUrl]：播放地址与封面取值容差。
///
/// 字段名匹配（2026-11-20 用户加码：字段名差得很多，不能只靠几个
/// 别名硬认）：先归一化（全小写、去下划线/中划线/空格），再按关键词
/// 打分——精确全名最高分，含关键词按权重加分；含 play/url/m3u8/
/// video 一类词优先当播放地址，含 pic/cover/img/thumb 当封面，
/// 含 title/name 当标题。实在认不出的表不猜、不静默丢数据，进
/// “数据库字段”查看入口由用户手动指定（见 actress_db_fields_page.dart，
/// 映射按库文件结构指纹存下来，下次换同结构的库直接用）。

/// 通用映射的字段角色。
enum GenericDbRole { title, cover, playUrl, actress, code, category, date }

GenericDbRole? _roleByName(String name) {
  for (final role in GenericDbRole.values) {
    if (role.name == name) return role;
  }
  return null;
}

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
  GenericDbRole.code: ['vodcode', 'code', '番号', 'avcode'],
  GenericDbRole.category: [
    'typename',
    'category',
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
  const GenericDbFacetValue({required this.value, required this.count});

  final String value;
  final int count;
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
  final personsCandidates =
      mappings
          .where(
            (m) =>
                m != worksTable &&
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
  return GenericDbSchema(
    tables: mappings,
    fingerprint: fingerprint.join(';'),
    worksTable: worksTable,
    personsTable: personsTable,
    relations: relations,
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
  final pk = primary.idColumn;
  if (pk == null) return const [];
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
  final out = <GenericDbRelation>[];
  final ordered = List.of(mappings)..sort((a, b) => a.table.compareTo(b.table));
  for (final role in roles) {
    GenericDbRelation? found;
    for (final sub in ordered) {
      if (sub.table == primary.table) continue;
      final column = sub.columnFor(role);
      if (column == null) continue;
      String? foreignKey;
      for (final candidate in sub.allColumns) {
        final normalized = normalizeDbFieldName(candidate);
        if (normalized.isEmpty || normalized == 'id') continue;
        if (normalized == '${tableNormalized}id' ||
            normalized == pkNormalized ||
            genericForeignKeys.contains(normalized)) {
          foreignKey = candidate;
          break;
        }
      }
      if (foreignKey == null) continue;
      found = GenericDbRelation(
        table: sub.table,
        foreignKey: foreignKey,
        primaryKey: pk,
        columns: sub.columns,
      );
      break;
    }
    if (found != null) out.add(found);
  }
  return out;
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
  final text = value.toString().trim();
  if (text.isEmpty) return '';
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
class GenericDbPerson {
  const GenericDbPerson({
    required this.id,
    required this.name,
    this.avatarUrl = '',
  });

  final Object? id;
  final String name;
  final String avatarUrl;
}

/// 手动映射存取：按结构指纹存在库文件夹里的 `字段映射.json`
///（MYTV/db/字段映射.json；未绑定时在 documents 下）。下次换同
/// 结构的库直接用，不用再手动指定。文件坏了只当没有，不崩。
class GenericDbMappingStore {
  GenericDbMappingStore({required this.file});

  final File file;

  Future<({String table, Map<GenericDbRole, String> columns})?> loadMapping(
    String fingerprint,
  ) async {
    try {
      if (!file.existsSync()) return null;
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map) return null;
      final entry = doc[fingerprint];
      if (entry is! Map) return null;
      final table = entry['table']?.toString();
      final columns = entry['columns'];
      if (table == null || table.isEmpty || columns is! Map) return null;
      final mapped = <GenericDbRole, String>{};
      for (final kv in columns.entries) {
        final role = _roleByName(kv.key.toString());
        final column = kv.value?.toString() ?? '';
        if (role != null && column.isNotEmpty) mapped[role] = column;
      }
      if (mapped.isEmpty) return null;
      return (table: table, columns: mapped);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMapping(
    String fingerprint,
    String table,
    Map<GenericDbRole, String> columns,
  ) async {
    Map<String, dynamic> doc = {};
    try {
      if (file.existsSync()) {
        final parsed = jsonDecode(await file.readAsString());
        if (parsed is Map<String, dynamic>) {
          doc = parsed;
        } else if (parsed is Map) {
          doc = Map<String, dynamic>.from(parsed);
        }
      }
    } catch (_) {
      doc = {};
    }
    doc[fingerprint] = {
      'table': table,
      'columns': {for (final kv in columns.entries) kv.key.name: kv.value},
    };
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(doc));
    } catch (_) {
      // 映射存不下来不崩：本次仍用内存里的映射。
    }
  }
}

/// 通用读取器：包着已打开的 [Database] 与探出来的 [schema]，
/// 读作品/人物；手动映射改了就地生效并存下来。
/// 测试用 [GenericDbReader.test]：不碰数据库，直接返回给定的作品。
class GenericDbReader {
  GenericDbReader({
    required Database db,
    required this.schema,
    required this.mappingStore,
  }) : _db = db,
       _testWorks = null;

  GenericDbReader.test({
    required List<GenericDbWork> works,
    GenericDbSchema? schema,
  }) : _db = null,
       schema =
           schema ?? const GenericDbSchema(tables: [], fingerprint: 'test'),
       mappingStore = GenericDbMappingStore(
         file: File('/tmp/actress_generic_db_test_mapping.json'),
       ),
       _testWorks = works;

  final Database? _db;
  GenericDbSchema schema;
  final GenericDbMappingStore mappingStore;
  final List<GenericDbWork>? _testWorks;

  static String _quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';

  List<String> _selectColumns(GenericDbTableMapping mapping) {
    final columns = <String>[
      for (final column in mapping.columns.values) _quote(column),
    ];
    if (mapping.idColumn != null) columns.add(_quote(mapping.idColumn!));
    return columns;
  }

  GenericDbWork _rowToWork(
    GenericDbTableMapping mapping,
    Map<String, Object?> row,
  ) {
    String text(GenericDbRole role) {
      final column = mapping.columnFor(role);
      if (column == null) return '';
      return row[column]?.toString().trim() ?? '';
    }

    return GenericDbWork(
      id: mapping.idColumn == null ? null : row[mapping.idColumn],
      title: text(GenericDbRole.title),
      coverUrl: resolveCoverUrl(
        mapping.columnFor(GenericDbRole.cover) == null
            ? ''
            : row[mapping.columnFor(GenericDbRole.cover)],
      ),
      playUrl: extractPlayUrl(
        mapping.columnFor(GenericDbRole.playUrl) == null
            ? ''
            : row[mapping.columnFor(GenericDbRole.playUrl)],
      ),
      actress: text(GenericDbRole.actress),
      code: text(GenericDbRole.code),
      category: text(GenericDbRole.category),
      date: text(GenericDbRole.date),
    );
  }

  /// 统一的 WHERE 组装：关键词搜（标题/番号 LIKE）+ 分类筛选
  /// （每列 IN 一组值，跨列 AND、同列 OR）。
  (String?, List<Object?>) _where(
    String query,
    Map<String, List<String>> filters,
  ) {
    final mapping = schema.worksTable;
    if (mapping == null) return (null, const []);
    final clauses = <String>[];
    final args = <Object?>[];
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      final like = '%${trimmed.replaceAll('%', '').replaceAll('_', '')}%';
      // 关键词同时搜标题/番号/女优/分类：外来库的标题常常是编号，
      // 用户搜「素人」这类分类词、或搜女优名时也得搜得出来。
      final searchable = <String>[
        for (final role in const [
          GenericDbRole.title,
          GenericDbRole.code,
          GenericDbRole.actress,
          GenericDbRole.category,
        ])
          if (mapping.columnFor(role) != null) _quote(mapping.columnFor(role)!),
      ];
      if (searchable.isNotEmpty) {
        clauses.add('(${searchable.map((c) => '$c LIKE ?').join(' OR ')})');
        args.addAll([for (final _ in searchable) like]);
      }
    }
    for (final entry in filters.entries) {
      final values = [
        for (final value in entry.value)
          if (value.trim().isNotEmpty) value,
      ];
      if (values.isEmpty) continue;
      if (!mapping.allColumns.contains(entry.key)) continue;
      // CAST 成文本比较：库里的分类列可能是 INTEGER 型 id，而筛选
      // 值是从列表里点出来的字符串，不 CAST 会一个都匹配不上。
      clauses.add(
        'CAST(${_quote(entry.key)} AS TEXT) IN '
        '(${List.filled(values.length, '?').join(',')})',
      );
      args.addAll(values);
    }
    if (clauses.isEmpty) return (null, const []);
    return (clauses.join(' AND '), args);
  }

  /// 读一页作品（关键词搜 + 分类筛选；rowid 顺序翻页）。
  /// 主表没存播放地址/封面时，自动从关联副表补（见 [GenericDbRelation]）。
  Future<List<GenericDbWork>> works({
    required int offset,
    required int limit,
    String query = '',
    Map<String, List<String>> filters = const {},
  }) async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      final q = query.trim().toLowerCase();
      var filtered = testWorks.where((w) {
        if (q.isNotEmpty &&
            !w.title.toLowerCase().contains(q) &&
            !w.code.toLowerCase().contains(q) &&
            !w.actress.toLowerCase().contains(q) &&
            !w.category.toLowerCase().contains(q)) {
          return false;
        }
        return true;
      }).toList();
      if (filters.isNotEmpty) {
        filtered = filtered.where((w) => _testWorkMatches(w, filters)).toList();
      }
      return filtered.skip(offset).take(limit).toList();
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    final (where, args) = _where(query, filters);
    final rows = await db.query(
      mapping.table,
      columns: _selectColumns(mapping),
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'rowid',
      limit: limit,
      offset: offset,
    );
    final works = [for (final row in rows) _rowToWork(mapping, row)];
    return _attachRelated(works);
  }

  bool _testWorkMatches(GenericDbWork work, Map<String, List<String>> filters) {
    for (final entry in filters.entries) {
      if (entry.value.isEmpty) continue;
      if (!entry.value.contains(work.category)) return false;
    }
    return true;
  }

  /// 作品总数（与 [works] 同一过滤条件）。
  Future<int> countWorks({
    String query = '',
    Map<String, List<String>> filters = const {},
  }) async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      final list = await works(
        offset: 0,
        limit: testWorks.length + 1,
        query: query,
        filters: filters,
      );
      return list.length;
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return 0;
    final (where, args) = _where(query, filters);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${_quote(mapping.table)}'
      '${where == null ? '' : ' WHERE $where'}',
      args.isEmpty ? null : args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 按人名取作品（名册对接库索引用）：SQL 侧先粗筛（女优列/标题
  /// 含这个名字），Dart 侧再按归一化名精确比对——库里的女优名可能
  /// 带空格/大小写差异，只靠 SQL = 会漏。
  Future<List<GenericDbWork>> worksForActress(
    String name, {
    int limit = 300,
  }) async {
    final normalized = name.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (normalized.isEmpty) return const [];
    final testWorks = _testWorks;
    if (testWorks != null) {
      return [
        for (final work in testWorks)
          if (work.actress
              .replaceAll(RegExp(r'\s+'), '')
              .toLowerCase()
              .contains(normalized))
            work,
      ].take(limit).toList();
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    final actressCol = mapping.columnFor(GenericDbRole.actress);
    final titleCol = mapping.columnFor(GenericDbRole.title);
    final tokens = <String>[
      if (actressCol != null) 'CAST(${_quote(actressCol)} AS TEXT) LIKE ?',
      if (titleCol != null) 'CAST(${_quote(titleCol)} AS TEXT) LIKE ?',
    ];
    if (tokens.isEmpty) return const [];
    final like = '%${_escapeLike(name.trim())}%';
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        mapping.table,
        columns: _selectColumns(mapping),
        where: tokens.join(' OR '),
        whereArgs: [for (final _ in tokens) like],
        orderBy: 'rowid',
        limit: limit * 3,
      );
    } catch (_) {
      return const [];
    }
    final out = <GenericDbWork>[];
    for (final row in rows) {
      final work = _rowToWork(mapping, row);
      final candidate = work.actress
          .replaceAll(RegExp(r'\s+'), '')
          .toLowerCase();
      if (candidate.isEmpty) continue;
      if (!candidate.contains(normalized) && !normalized.contains(candidate)) {
        continue;
      }
      out.add(work);
      if (out.length >= limit) break;
    }
    return _attachRelated(out);
  }

  /// 按番号取作品（名册/搜索对接库索引用）：SQL 侧把番号列的
  /// 连字符、下划线、空格去掉再比（库里 "JUL-893"、查询 "jul893"
  /// 都能对上），Dart 侧再按归一化番号精确比对。
  Future<List<GenericDbWork>> worksForCode(
    String codeKey, {
    int limit = 200,
  }) async {
    final normalized = _normalizeCodeKey(codeKey);
    if (normalized.isEmpty) return const [];
    final testWorks = _testWorks;
    if (testWorks != null) {
      return [
        for (final work in testWorks)
          if (_normalizeCodeKey(work.code) == normalized) work,
      ].take(limit).toList();
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    final codeCol = mapping.columnFor(GenericDbRole.code);
    final titleCol = mapping.columnFor(GenericDbRole.title);
    final columns = <String>[
      if (codeCol != null) codeCol,
      if (titleCol != null) titleCol,
    ];
    if (columns.isEmpty) return const [];
    final tokens = [for (final column in columns) _normalizedColumn(column)];
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        mapping.table,
        columns: _selectColumns(mapping),
        where: tokens.map((t) => "$t LIKE ?").join(' OR '),
        whereArgs: [for (final _ in tokens) '%$normalized%'],
        orderBy: 'rowid',
        limit: limit * 4,
      );
    } catch (_) {
      return const [];
    }
    final out = <GenericDbWork>[];
    for (final row in rows) {
      final work = _rowToWork(mapping, row);
      final codeMatch = _normalizeCodeKey(work.code) == normalized;
      final titleMatch = _normalizeCodeKey(work.title).contains(normalized);
      if (!codeMatch && !titleMatch) continue;
      out.add(work);
      if (out.length >= limit) break;
    }
    return _attachRelated(out);
  }

  /// 番号列去掉分隔符后的 SQL 表达式（归一化口径与 Dart 侧一致）。
  String _normalizedColumn(String column) {
    var expr = 'CAST(${_quote(column)} AS TEXT)';
    for (final sep in const ['-', '_', ' ', '.']) {
      expr = "REPLACE($expr, '$sep', '')";
    }
    return 'UPPER($expr)';
  }

  static String _escapeLike(String value) =>
      value.replaceAll('%', '').replaceAll('_', '').replaceAll("'", '');

  static String _normalizeCodeKey(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// 分类维度：作品表里像分类/分类名/标签/系列/地区的列，每列出
  /// 现过的值 + 每个值下的作品数（按作品数从多到少，[maxValues] 封顶）。
  /// 这就是「点进库以后按库内部的多级分类筛选」的数据来源。
  Future<List<GenericDbFacet>> facets({int maxValues = 30}) async {
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null || _testWorks != null) return const [];
    final columns = categoryFacetColumns(mapping).take(6);
    final out = <GenericDbFacet>[];
    for (final column in columns) {
      final quoted = _quote(column);
      final rows = await db.rawQuery(
        'SELECT CAST($quoted AS TEXT) AS v, COUNT(*) AS c '
        'FROM ${_quote(mapping.table)} '
        'WHERE $quoted IS NOT NULL AND TRIM(CAST($quoted AS TEXT)) <> '
        ' '
        'GROUP BY CAST($quoted AS TEXT) '
        'ORDER BY c DESC, v ASC LIMIT ?',
        [maxValues],
      );
      final values = <GenericDbFacetValue>[];
      for (final row in rows) {
        final value = row['v']?.toString().trim() ?? '';
        if (value.isEmpty) continue;
        values.add(
          GenericDbFacetValue(
            value: value,
            count: (row['c'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      if (values.isEmpty) continue;
      out.add(GenericDbFacet(column: column, values: values));
    }
    return out;
  }

  /// 主表行缺地址/封面时，按关联副表一次性补上（每个主表 id 取副表
  /// 里第一条非空值）。
  Future<List<GenericDbWork>> _attachRelated(List<GenericDbWork> works) async {
    final db = _db;
    if (db == null || works.isEmpty || schema.relations.isEmpty) return works;
    var out = works;
    for (final relation in schema.relations) {
      final needsPlay = relation.columnFor(GenericDbRole.playUrl) != null;
      final needsCover = relation.columnFor(GenericDbRole.cover) != null;
      if (!needsPlay && !needsCover) continue;
      final keys = <Object?>{};
      for (final work in out) {
        final missing =
            (needsPlay && !work.playable) ||
            (needsCover && work.coverUrl.isEmpty);
        if (!missing) continue;
        final id = work.id;
        if (id != null) keys.add(id);
      }
      if (keys.isEmpty) continue;
      final values = await _relatedValues(relation, keys.toList());
      if (values.isEmpty) continue;
      out = [
        for (final work in out)
          if (values[work.id?.toString() ?? ''] == null)
            work
          else
            _withRelated(work, values[work.id?.toString() ?? '']!),
      ];
    }
    return out;
  }

  GenericDbWork _withRelated(
    GenericDbWork work,
    Map<GenericDbRole, String> related,
  ) {
    final play = work.playable
        ? work.playUrl
        : (related[GenericDbRole.playUrl] ?? '');
    final cover = work.coverUrl.isNotEmpty
        ? work.coverUrl
        : (related[GenericDbRole.cover] ?? '');
    if (play == work.playUrl && cover == work.coverUrl) return work;
    return work.copyWith(playUrl: play, coverUrl: cover);
  }

  Future<Map<String, Map<GenericDbRole, String>>> _relatedValues(
    GenericDbRelation relation,
    List<Object?> keys,
  ) async {
    final db = _db;
    final playCol = relation.columnFor(GenericDbRole.playUrl);
    final coverCol = relation.columnFor(GenericDbRole.cover);
    if (db == null || (playCol == null && coverCol == null)) return const {};
    final columns = <String>[relation.foreignKey, ?playCol, ?coverCol];
    final placeholders = List.filled(keys.length, '?').join(',');
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.rawQuery(
        'SELECT ${columns.map(_quote).join(',')} '
        'FROM ${_quote(relation.table)} '
        'WHERE ${_quote(relation.foreignKey)} IN ($placeholders)',
        keys,
      );
    } catch (_) {
      // 副表结构跟探测时不一致（脏库/视图）：补不上就不补，不让整页挂。
      return const {};
    }
    final out = <String, Map<GenericDbRole, String>>{};
    for (final row in rows) {
      final key = row[relation.foreignKey]?.toString() ?? '';
      if (key.isEmpty) continue;
      final slot = out.putIfAbsent(key, () => <GenericDbRole, String>{});
      if (playCol != null && (slot[GenericDbRole.playUrl] ?? '').isEmpty) {
        final url = extractPlayUrl(row[playCol]);
        if (url.isNotEmpty) slot[GenericDbRole.playUrl] = url;
      }
      if (coverCol != null && (slot[GenericDbRole.cover] ?? '').isEmpty) {
        final cover = resolveCoverUrl(row[coverCol]);
        if (cover.isNotEmpty) slot[GenericDbRole.cover] = cover;
      }
    }
    return out;
  }

  /// 读人物（有人物表时才有；没有返回空列表）。
  Future<List<GenericDbPerson>> persons({
    required int offset,
    required int limit,
  }) async {
    final mapping = schema.personsTable;
    if (mapping == null || _db == null) return const [];
    final rows = await _db.query(
      mapping.table,
      columns: _selectColumns(mapping),
      orderBy: 'rowid',
      limit: limit,
      offset: offset,
    );
    return [
      for (final row in rows)
        GenericDbPerson(
          id: mapping.idColumn == null ? null : row[mapping.idColumn],
          name:
              row[mapping.columnFor(GenericDbRole.title)]?.toString().trim() ??
              '',
          avatarUrl: resolveCoverUrl(
            mapping.columnFor(GenericDbRole.cover) == null
                ? ''
                : row[mapping.columnFor(GenericDbRole.cover)],
          ),
        ),
    ];
  }

  /// 用户在“数据库字段”页手动指定映射：就地生效（下次读即用）
  /// 并按结构指纹存下来，下次换同结构的库直接用。
  Future<void> applyManualMapping({
    required String table,
    required Map<GenericDbRole, String> columns,
  }) async {
    final next = schema.withManualMapping(table: table, columns: columns);
    if (identical(next, schema)) return;
    schema = next;
    await mappingStore.saveMapping(schema.fingerprint, table, columns);
  }
}
