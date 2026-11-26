import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../actress/actress_working_db.dart';

/// fm.nvku 桥的查询函数形态：参数化 SQL + 参数列表，返回行列表。
/// 测试注入假实现，真机走 sqflite 只读连接。
typedef NvkuQuery = Future<List<Map<String, Object?>>> Function(
  String sql, [
  List<Object?>? arguments,
]);

/// 合并演员库页（assets/actress_library.html）的本地女优库兜底通道。
///
/// 页面侧协议（op 分发，全部只读）：
/// - list{kind:'latest', q=厂牌前缀, page, limit} / list{kind:'rank'}
///   → {ok, items:[{vodId,title,pic,play,actress,code,date,typeName}]}
/// - search{q,page,limit} → {ok, items:[...]}
/// - works{actress|tag,page,limit} → {ok, items:[...]}
/// - actresses{q?,page,limit} → {ok, actresses:[{name,avatar,count}]}
/// - tags{} → {ok, tags:[{name,count}]}
/// - detail{vodId} → {ok, item:{vodId,title,pic,play,playUrls,actresses,
///   tags,date,typeName,related:[...]}}
///
/// 查的是应用私有目录的工作库（actressWorkingDbPath()，.sql 导入
/// 落成），独立只读连接打开，不碰原生库页的读写连接。库文件不存
/// 在（还没导入）时返回 {ok:false}，页面据此只走在线路。
class HtmlNvkuService {
  HtmlNvkuService({required this._opener});

  /// 进程级共享实例（桥每次调用复用同一只读连接）。
  static final HtmlNvkuService shared = HtmlNvkuService(
    opener: _openWorkingDb,
  );

  final Future<NvkuQuery?> Function() _opener;
  Future<NvkuQuery?>? _opening;
  Set<String>? _tables;

  /// 硬线排除：该类型名明确指向未成年题材，查询层整体不返回
  /// （只过滤查询结果，不动库文件本体）。
  static const List<String> _excludedTypeNames = ['少女萝莉'];

  static Future<NvkuQuery?> _openWorkingDb() async {
    final dbPath = await actressWorkingDbPath();
    if (!await File(dbPath).exists()) return null;
    final db = await openDatabase(
      dbPath,
      readOnly: true,
      singleInstance: false,
    );
    return (sql, [arguments]) => db.rawQuery(sql, arguments);
  }

  Future<NvkuQuery?> _query() {
    final opening = _opening ??= _opener();
    return opening.then((query) {
      if (query == null) _opening = null; // 未导入时不缓存，下次重试
      return query;
    });
  }

  Future<Set<String>> _tableSet(NvkuQuery query) async {
    final cached = _tables;
    if (cached != null) return cached;
    final rows = await query(
      "SELECT name FROM sqlite_master WHERE type IN ('table','view')",
    );
    return _tables = {for (final row in rows) row['name']?.toString() ?? ''};
  }

  Future<Map<String, dynamic>> handle(Map<String, dynamic> params) async {
    try {
      final query = await _query();
      if (query == null) {
        return {'ok': false, 'error': '本地女优库尚未导入'};
      }
      final tables = await _tableSet(query);
      if (!tables.contains('videos')) {
        return {'ok': false, 'error': '本地女优库结构不完整（缺 videos 表）'};
      }
      final op = (params['op'] ?? '').toString();
      switch (op) {
        case 'list':
          return await _list(query, tables, params);
        case 'search':
          return await _search(query, params);
        case 'works':
          return await _works(query, tables, params);
        case 'actresses':
          return await _actresses(query, tables, params);
        case 'tags':
          return await _tags(query, tables);
        case 'detail':
          return await _detail(query, tables, params);
        default:
          return {'ok': false, 'error': '未知 op：$op'};
      }
    } catch (error) {
      _opening = null;
      _tables = null;
      return {'ok': false, 'error': '本地女优库不可用：$error'};
    }
  }

  int _page(Map<String, dynamic> params) {
    final page = int.tryParse('${params['page'] ?? 1}') ?? 1;
    return page < 1 ? 1 : page;
  }

  int _limit(Map<String, dynamic> params) {
    final limit = int.tryParse('${params['limit'] ?? 24}') ?? 24;
    return limit < 1 ? 1 : (limit > 50 ? 50 : limit);
  }

  String get _exclusionSql =>
      '(v.type_name IS NULL OR v.type_name NOT IN '
      '(${List.filled(_excludedTypeNames.length, '?').join(',')}))';

  List<Object?> get _exclusionArgs => [..._excludedTypeNames];

  static const String _itemColumns =
      'v.vod_id AS vodId, v.title AS title, v.pic_url AS pic, '
      'v.m3u8_url AS play, v.vod_pubdate AS date, v.type_name AS typeName';

  Map<String, dynamic> _itemRow(Map<String, Object?> row) {
    final vodId = row['vodId']?.toString() ?? '';
    return {
      'vodId': vodId,
      'title': row['title']?.toString() ?? '',
      'pic': row['pic']?.toString() ?? '',
      'play': row['play']?.toString() ?? '',
      'actress': row['actress']?.toString() ?? '',
      'code': vodId,
      'date': row['date']?.toString() ?? '',
      'typeName': row['typeName']?.toString() ?? '',
    };
  }

  /// 列表查询：带主演名的作品行（主演取关联第一位）。
  Future<List<Map<String, dynamic>>> _videoRows(
    NvkuQuery query,
    Set<String> tables, {
    required String where,
    required List<Object?> whereArgs,
    required String orderBy,
    required int limit,
    required int offset,
  }) async {
    final actressJoin = tables.contains('video_actress') &&
            tables.contains('actresses')
        ? '(SELECT a.name FROM video_actress va '
              'JOIN actresses a ON a.cate_id = va.cate_id '
              'WHERE va.vod_id = v.vod_id LIMIT 1) AS actress'
        : "'' AS actress";
    final rows = await query(
      'SELECT $_itemColumns, $actressJoin FROM videos v '
      'WHERE $where ORDER BY $orderBy LIMIT ? OFFSET ?',
      [...whereArgs, limit, offset],
    );
    var items = [for (final row in rows) _itemRow(row)];
    // m3u8_url 为空的行用播放地址表的第一条兜底。
    if (tables.contains('video_play_urls')) {
      for (final item in items) {
        if ((item['play'] as String).isEmpty) {
          final urls = await query(
            'SELECT play_url FROM video_play_urls WHERE vod_id = ? '
            'ORDER BY rowid LIMIT 1',
            [item['vodId']],
          );
          if (urls.isNotEmpty) {
            item['play'] = urls.first['play_url']?.toString() ?? '';
          }
        }
      }
    }
    return items;
  }

  Future<Map<String, dynamic>> _list(
    NvkuQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    final kind = (params['kind'] ?? 'latest').toString();
    if (kind == 'rank') {
      if (!tables.contains('video_ranking')) {
        return {'ok': false, 'error': '本地库无排行榜数据'};
      }
      final rows = await query(
        'SELECT $_itemColumns FROM video_ranking r '
        'JOIN videos v ON v.vod_id = r.vod_id '
        'WHERE $_exclusionSql ORDER BY r.rowid LIMIT 50',
        _exclusionArgs,
      );
      return {
        'ok': true,
        'items': [for (final row in rows) _itemRow(row)],
      };
    }
    final page = _page(params);
    final limit = _limit(params);
    final prefix = (params['q'] ?? '').toString().trim().toLowerCase();
    var where = _exclusionSql;
    final args = [..._exclusionArgs];
    if (prefix.isNotEmpty) {
      where += " AND v.vod_id LIKE ? ESCAPE '\\'";
      args.add('${_escapeLike(prefix)}%');
    }
    final items = await _videoRows(
      query,
      tables,
      where: where,
      whereArgs: args,
      orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
      limit: limit,
      offset: (page - 1) * limit,
    );
    return {'ok': true, 'items': items};
  }

  Future<Map<String, dynamic>> _search(
    NvkuQuery query,
    Map<String, dynamic> params,
  ) async {
    final tables = await _tableSet(query);
    final q = (params['q'] ?? '').toString().trim();
    if (q.isEmpty) return {'ok': true, 'items': const []};
    final page = _page(params);
    final limit = _limit(params);
    final like = '%${_escapeLike(q)}%';
    final items = await _videoRows(
      query,
      tables,
      where: "$_exclusionSql AND (v.vod_id LIKE ? ESCAPE '\\' "
          "OR v.title LIKE ? ESCAPE '\\')",
      whereArgs: [..._exclusionArgs, like, like],
      orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
      limit: limit,
      offset: (page - 1) * limit,
    );
    return {'ok': true, 'items': items};
  }

  Future<Map<String, dynamic>> _works(
    NvkuQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    final page = _page(params);
    final limit = _limit(params);
    final actress = (params['actress'] ?? '').toString().trim();
    final tag = (params['tag'] ?? '').toString().trim();
    if (actress.isNotEmpty) {
      if (!tables.contains('video_actress') ||
          !tables.contains('actresses')) {
        return {'ok': false, 'error': '本地库无演员关联数据'};
      }
      final items = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id IN '
            '(SELECT va.vod_id FROM video_actress va '
            'JOIN actresses a ON a.cate_id = va.cate_id '
            'WHERE a.name = ?)',
        whereArgs: [..._exclusionArgs, actress],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: limit,
        offset: (page - 1) * limit,
      );
      return {'ok': true, 'items': items};
    }
    if (tag.isNotEmpty) {
      if (!tables.contains('video_tag')) {
        return {'ok': false, 'error': '本地库无标签关联数据'};
      }
      final items = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id IN '
            '(SELECT vod_id FROM video_tag WHERE tag_name = ?)',
        whereArgs: [..._exclusionArgs, tag],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: limit,
        offset: (page - 1) * limit,
      );
      return {'ok': true, 'items': items};
    }
    return {'ok': false, 'error': 'works 需要 actress 或 tag 参数'};
  }

  Future<Map<String, dynamic>> _actresses(
    NvkuQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    if (!tables.contains('actresses')) {
      return {'ok': false, 'error': '本地库无演员表'};
    }
    final page = _page(params);
    final limit = _limit(params);
    final q = (params['q'] ?? '').toString().trim();
    final hasCounts = tables.contains('index_categories');
    final countExpr = hasCounts
        ? '(SELECT ic.video_count FROM index_categories ic '
              "WHERE ic.category_type = 'actress' "
              'AND ic.category_name = a.name)'
        : null;
    final where = q.isEmpty ? '' : "WHERE a.name LIKE ? ESCAPE '\\'";
    final args = <Object?>[
      if (q.isNotEmpty) '%${_escapeLike(q)}%',
      limit,
      (page - 1) * limit,
    ];
    final rows = await query(
      'SELECT a.name AS name, a.avatar AS avatar'
      '${countExpr == null ? '' : ', $countExpr AS cnt'} '
      'FROM actresses a $where '
      'ORDER BY ${countExpr == null ? 'a.name ASC' : 'cnt DESC, a.name ASC'} '
      'LIMIT ? OFFSET ?',
      args,
    );
    return {
      'ok': true,
      'actresses': [
        for (final row in rows)
          {
            'name': row['name']?.toString() ?? '',
            'avatar': row['avatar']?.toString() ?? '',
            'count': (row['cnt'] as num?)?.toInt() ?? 0,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _tags(
    NvkuQuery query,
    Set<String> tables,
  ) async {
    final excluded = _excludedTypeNames;
    if (tables.contains('index_categories')) {
      final rows = await query(
        'SELECT category_name AS name, video_count AS cnt '
        'FROM index_categories '
        "WHERE category_type = 'tag' AND category_name NOT IN "
        '(${List.filled(excluded.length, '?').join(',')}) '
        'ORDER BY video_count DESC LIMIT 120',
        [...excluded],
      );
      return {
        'ok': true,
        'tags': [
          for (final row in rows)
            {
              'name': row['name']?.toString() ?? '',
              'count': (row['cnt'] as num?)?.toInt() ?? 0,
            },
        ],
      };
    }
    if (tables.contains('video_tag')) {
      final rows = await query(
        'SELECT tag_name AS name, COUNT(*) AS cnt FROM video_tag '
        'WHERE tag_name NOT IN '
        '(${List.filled(excluded.length, '?').join(',')}) '
        'GROUP BY tag_name ORDER BY cnt DESC LIMIT 120',
        [...excluded],
      );
      return {
        'ok': true,
        'tags': [
          for (final row in rows)
            {
              'name': row['name']?.toString() ?? '',
              'count': (row['cnt'] as num?)?.toInt() ?? 0,
            },
        ],
      };
    }
    return {'ok': false, 'error': '本地库无标签数据'};
  }

  Future<Map<String, dynamic>> _detail(
    NvkuQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    final vodId = (params['vodId'] ?? '').toString().trim().toLowerCase();
    if (vodId.isEmpty) return {'ok': false, 'error': '缺少 vodId'};
    final rows = await query(
      'SELECT $_itemColumns FROM videos v WHERE v.vod_id = ? '
      'AND $_exclusionSql LIMIT 1',
      [vodId, ..._exclusionArgs],
    );
    if (rows.isEmpty) return {'ok': false, 'error': '本地库无此番号'};
    final item = _itemRow(rows.first);

    final playUrls = <String>[];
    void addUrl(String url) {
      if (url.isNotEmpty && !playUrls.contains(url)) playUrls.add(url);
    }

    addUrl(item['play'] as String);
    if (tables.contains('video_play_urls')) {
      final urls = await query(
        'SELECT play_url FROM video_play_urls WHERE vod_id = ? '
        'ORDER BY rowid LIMIT 8',
        [vodId],
      );
      for (final row in urls) {
        addUrl(row['play_url']?.toString() ?? '');
      }
    }

    var actresses = <String>[];
    if (tables.contains('video_actress') && tables.contains('actresses')) {
      final names = await query(
        'SELECT a.name AS name FROM video_actress va '
        'JOIN actresses a ON a.cate_id = va.cate_id '
        'WHERE va.vod_id = ? ORDER BY a.name',
        [vodId],
      );
      actresses = [for (final row in names) row['name']?.toString() ?? ''];
    }

    var tags = <String>[];
    if (tables.contains('video_tag')) {
      final names = await query(
        'SELECT tag_name AS name FROM video_tag WHERE vod_id = ? '
        'ORDER BY tag_name LIMIT 20',
        [vodId],
      );
      tags = [for (final row in names) row['name']?.toString() ?? ''];
    }

    var related = <Map<String, dynamic>>[];
    if (actresses.isNotEmpty) {
      related = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id <> ? AND v.vod_id IN '
            '(SELECT va.vod_id FROM video_actress va '
            'JOIN actresses a ON a.cate_id = va.cate_id '
            'WHERE a.name = ?)',
        whereArgs: [..._exclusionArgs, vodId, actresses.first],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: 12,
        offset: 0,
      );
    }
    if (related.isEmpty && (item['typeName'] as String).isNotEmpty) {
      related = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id <> ? AND v.type_name = ?',
        whereArgs: [..._exclusionArgs, vodId, item['typeName']],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: 12,
        offset: 0,
      );
    }

    return {
      'ok': true,
      'item': {
        ...item,
        'playUrls': playUrls,
        'actresses': actresses,
        'tags': tags,
        'related': related,
      },
    };
  }

  static String _escapeLike(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll(
        '_',
        '\\_',
      );
}
