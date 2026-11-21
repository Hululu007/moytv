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
enum GenericDbRole {
  title,
  cover,
  playUrl,
  actress,
  code,
  category,
  date,
}

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
        columns: {
          for (final kv in byRole.entries) kv.key: kv.value.$1,
        },
        allColumns: List.of(columns),
        idColumn: idColumn,
      ),
    );
  }
  // 作品表：同时有标题与播放地址；多张时按认出的角色数排，
  // 再按表名排（稳定，不随机）。
  final worksCandidates =
      mappings.where((m) => m.hasTitleAndPlayUrl).toList()
        ..sort((a, b) {
          final byRoles = b.columns.length.compareTo(a.columns.length);
          if (byRoles != 0) return byRoles;
          return a.table.compareTo(b.table);
        });
  final worksTable = worksCandidates.isEmpty ? null : worksCandidates.first;
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
  final personsTable =
      personsCandidates.isEmpty ? null : personsCandidates.first;
  final fingerprint = tableColumns.entries
      .map((e) => '${e.key}(${e.value.join(',')})')
      .toList()
    ..sort();
  return GenericDbSchema(
    tables: mappings,
    fingerprint: fingerprint.join(';'),
    worksTable: worksTable,
    personsTable: personsTable,
  );
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

  Future<({String table, Map<GenericDbRole, String> columns})?>
  loadMapping(String fingerprint) async {
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
      'columns': {
        for (final kv in columns.entries) kv.key.name: kv.value,
      },
    };
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(doc),
      );
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

  GenericDbReader.test({required List<GenericDbWork> works, GenericDbSchema? schema})
      : _db = null,
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

  (String?, List<Object?>) _worksWhere(String query) {
    final mapping = schema.worksTable;
    final trimmed = query.trim();
    if (mapping == null || trimmed.isEmpty) return (null, const []);
    final like =
        '%${trimmed.replaceAll('%', '').replaceAll('_', '')}%';
    final titleCol = mapping.columnFor(GenericDbRole.title);
    final codeCol = mapping.columnFor(GenericDbRole.code);
    if (titleCol != null && codeCol != null) {
      return (
        '(${_quote(titleCol)} LIKE ? OR ${_quote(codeCol)} LIKE ?)',
        [like, like],
      );
    }
    if (titleCol != null) {
      return ('${_quote(titleCol)} LIKE ?', [like]);
    }
    return (null, const []);
  }

  /// 读作品（标题/番号 LIKE 搜，rowid 顺序翻页）。
  Future<List<GenericDbWork>> works({
    required int offset,
    required int limit,
    String query = '',
  }) async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      final q = query.trim().toLowerCase();
      final filtered =
          q.isEmpty
              ? testWorks
              : testWorks
                  .where(
                    (w) =>
                        w.title.toLowerCase().contains(q) ||
                        w.code.toLowerCase().contains(q),
                  )
                  .toList();
      return filtered.skip(offset).take(limit).toList();
    }
    final mapping = schema.worksTable;
    if (mapping == null || _db == null) return const [];
    final (where, args) = _worksWhere(query);
    final rows = await _db.query(
      mapping.table,
      columns: _selectColumns(mapping),
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'rowid',
      limit: limit,
      offset: offset,
    );
    return [for (final row in rows) _rowToWork(mapping, row)];
  }

  /// 作品总数（与 [works] 同一过滤条件）。
  Future<int> countWorks({String query = ''}) async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      if (query.trim().isEmpty) return testWorks.length;
      final q = query.trim().toLowerCase();
      return testWorks
          .where(
            (w) =>
                w.title.toLowerCase().contains(q) ||
                w.code.toLowerCase().contains(q),
          )
          .length;
    }
    final mapping = schema.worksTable;
    if (mapping == null || _db == null) return 0;
    final (where, args) = _worksWhere(query);
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${_quote(mapping.table)}'
      '${where == null ? '' : ' WHERE $where'}',
      args.isEmpty ? null : args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
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
    await mappingStore.saveMapping(
      schema.fingerprint,
      table,
      columns,
    );
  }
}
