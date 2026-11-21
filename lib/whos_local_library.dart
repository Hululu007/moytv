import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// whos 本地兜底库的一条作品。
///
/// 只留目录/搜索/播放要用到的字段：在线 whos.tv 前面挂着 Cloudflare，
/// 取页通道一断整站就是空的，这时全靠这份本地行把内容撑起来。
class WhosLocalWork {
  const WhosLocalWork({
    required this.id,
    required this.title,
    this.cover = '',
    this.playUrl = '',
    this.code = '',
    this.brand = '',
    this.area = '',
    this.year = '',
  });

  final String id;
  final String title;
  final String cover;
  final String playUrl;
  final String code;
  final String brand;
  final String area;
  final String year;

  bool get playable =>
      playUrl.startsWith('http://') || playUrl.startsWith('https://');

  String get displayTitle => title.isNotEmpty ? title : code;

  /// 厂牌：番号里第一个 `-` 前面的字母段（fc2ppv-4913308 → fc2ppv，
  /// sdam-186 → sdam）。没有 `-` 时取开头的连续字母段。
  static String brandOfCode(String code) =>
      _brandFromCode(code.trim().toLowerCase());

  static String _brandFromCode(String code) {
    if (code.isEmpty) return '';
    // 番号形如 sdam-186 / fc2ppv-4913308 / ssis-001-uncensored：
    // 取第一个分隔符前的整段（可以是字母数字混合，FC2 这类就是要的）。
    var head = code;
    for (final sep in const ['-', '_', ' ', '.']) {
      final at = head.indexOf(sep);
      if (at > 0) head = head.substring(0, at);
    }
    if (head.isEmpty) return '';
    final first = head.codeUnitAt(0);
    final startsWithLetter = first >= 0x61 && first <= 0x7a;
    if (!startsWithLetter) return '';
    for (final rune in head.runes) {
      final ch = String.fromCharCode(rune);
      final isWord =
          (ch.codeUnitAt(0) >= 0x61 && ch.codeUnitAt(0) <= 0x7a) ||
          (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39);
      if (!isWord) return '';
    }
    return head.length >= 2 ? head : '';
  }
}

/// 站内分类 id：最新作品、排行榜、厂牌前缀。
const whosLocalNewCategory = 'new';
const whosLocalRankCategory = 'rank';
const whosLocalBrandPrefix = 'brand:';

/// 厂牌分类的展示名（不认识的按大写前缀显示）。
String whosBrandLabel(String brand) {
  const known = <String, String>{
    'fc2ppv': 'FC2',
    'fc2': 'FC2',
    'ssis': 'SSIS',
    'sdam': 'SDAM',
    'ipzz': 'IPZZ',
    'ipz': 'IPZ',
    'ipx': 'IPX',
    'midv': 'MIDV',
    'mide': 'MIDE',
    'miaa': 'MIAA',
    'sone': 'SONE',
    'soe': 'SOE',
    'sir': 'SIRO',
    'cnt': 'CNT',
    'sta': 'STARS',
    'prtd': 'PRTD',
    'hntd': 'HNTD',
    'cjvr': 'CJVR',
    'dsvr': 'DSVR',
    'vvvd': 'VVVD',
    'vr': 'VR',
    'juq': 'JUQ',
    'meyd': 'MEYD',
    'abw': 'ABW',
    'abp': 'ABP',
    'jul': 'JUL',
    'pred': 'PRED',
    'start': 'START',
    'fsts': 'FSTS',
    'gvh': 'GVH',
    'royd': 'ROYD',
    't28': 'T28',
  };
  final key = brand.toLowerCase();
  final label = known[key];
  if (label != null) return label;
  return brand.toUpperCase();
}

/// whos 本地兜底库。
///
/// 数据来自两处，去重后按「内置在前、本地影子在后」合并：
/// 1. `assets/actress_json/whos.json`（随包的 whos 条目）；
/// 2. `documents/actress_json/whos.json` 与现爬落库的 `mjv011.json`
///    里 `vod_play_from == whos` 的行（用户自己爬到的更新内容）。
///
/// 目录维度全在本地算（最新 / 排行榜 / 厂牌 + 关键词），所以在线取不到
/// 内容时，分类页、搜索、详情、直链播放都不至于空着。
class WhosLocalLibrary {
  WhosLocalLibrary._(this._works, {this.sourceNote = ''});

  /// 测试/注入用：直接拿现成条目建库。
  factory WhosLocalLibrary.fromWorks(
    List<WhosLocalWork> works, {
    String sourceNote = 'test',
  }) => WhosLocalLibrary._(List<WhosLocalWork>.of(works), sourceNote: sourceNote);

  /// 全局单例：桥层在没有网络时拿它出内容。
  static final WhosLocalLibrary shared = WhosLocalLibrary._(
    <WhosLocalWork>[],
    sourceNote: 'shared',
  );

  static const assetPath = 'assets/actress_json/whos.json';
  static const localDirName = 'actress_json';

  final List<WhosLocalWork> _works;
  final String sourceNote;

  Map<String, List<WhosLocalWork>>? _byBrand;
  Map<String, WhosLocalWork>? _byCode;
  Future<bool>? _loading;

  bool get isLoaded => _works.isNotEmpty;

  int get count => _works.length;

  /// 首次调用时加载；已加载直接返回。失败（资源缺失之类）返回 false，
  /// 但不抛异常——降级失败也要让上层照常走在线报错，不掩盖真问题。
  Future<bool> ensureLoaded() {
    if (isLoaded) return Future.value(true);
    return _loading ??= _load().catchError((Object _) {
      _loading = null;
      return false;
    });
  }

  Future<bool> _load() async {
    final merged = <String, WhosLocalWork>{};
    void absorb(String? text, {required String origin}) {
      if (text == null || text.trim().isEmpty) return;
      for (final work in parseWorks(text, origin: origin)) {
        final key = work.id.toLowerCase();
        final existing = merged[key];
        if (existing == null) {
          merged[key] = work;
          continue;
        }
        // 同一条既有封面又有播放地址的版本优先。
        if (existing.cover.isEmpty && work.cover.isNotEmpty) {
          merged[key] = work;
        }
      }
    }

    try {
      absorb(await rootBundle.loadString(assetPath), origin: 'asset');
    } catch (_) {}

    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$localDirName');
      if (await dir.exists()) {
        final files = <String>['whos.json', 'mjv011.json'];
        for (final name in files) {
          final file = File('${dir.path}/$name');
          if (!await file.exists()) continue;
          absorb(
            await file.readAsString(),
            origin: name == 'mjv011.json' ? 'local-mjv' : 'local',
          );
        }
      }
    } catch (_) {}

    _works.addAll(merged.values);
    _byBrand = null;
    _byCode = null;
    return _works.isNotEmpty;
  }

  /// 解析一份 json 文本（数组，或 `{'list': [...]}` 包装）。
  ///
  /// 兼容 whos.json 的 `vod_*` 键与 m3u 条目的简写键；没有标题的行丢掉。
  static List<WhosLocalWork> parseWorks(String text, {String origin = ''}) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const [];
    }
    List<Object?> rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map) {
      final list = decoded['list'] ?? decoded['items'] ?? decoded['data'];
      rows = list is List ? list : const [];
    } else {
      return const [];
    }

    final out = <WhosLocalWork>[];
    var index = 0;
    for (final row in rows) {
      if (row is! Map) continue;
      index++;
      final map = Map<String, dynamic>.from(row);
      final playFrom = (map['vod_play_from'] ?? map['play_from'] ?? '')
          .toString()
          .toLowerCase();
      final playUrl = _extractPlayUrl(
        (map['vod_play_url'] ?? map['play_url'] ?? map['url'] ?? '').toString(),
      );
      // mjv011.json 是混站大表：只收 whos 的行；没写来源又没地址的也丢。
      if (origin == 'local-mjv' && playFrom.isNotEmpty && playFrom != 'whos') {
        continue;
      }
      final code = (map['vod_code'] ?? map['code'] ?? '').toString().trim();
      final title = (map['vod_name'] ?? map['name'] ?? map['title'] ?? '')
          .toString()
          .trim();
      if (title.isEmpty && code.isEmpty) continue;
      final cover = (map['vod_pic'] ?? map['pic'] ?? map['cover'] ?? '')
          .toString()
          .trim();
      if (playUrl.isEmpty && cover.isEmpty) continue;
      final id =
          (map['vod_id'] ??
                  map['id'] ??
                  map['hash'] ??
                  (code.isNotEmpty ? code : 'local-$index'))
              .toString();
      out.add(
        WhosLocalWork(
          id: id,
          title: title,
          cover: cover,
          playUrl: playUrl,
          code: code.isNotEmpty ? code : _codeFromTitle(title),
          brand: WhosLocalWork.brandOfCode(
            code.isNotEmpty ? code : _codeFromTitle(title),
          ),
          area: (map['vod_area'] ?? map['area'] ?? '').toString(),
          year: (map['vod_year'] ?? map['year'] ?? '').toString(),
        ),
      );
    }
    return out;
  }

  /// `正片$https://…m3u8` / `第1集$url#第2集$url` 里取第一条 http 地址。
  static String _extractPlayUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    for (final entry in text.split('#')) {
      var part = entry;
      final dollar = part.lastIndexOf(r'$');
      if (dollar >= 0) part = part.substring(dollar + 1);
      part = part.trim();
      if (part.startsWith('http://') || part.startsWith('https://')) {
        return part;
      }
    }
    return '';
  }

  /// 标题里带番号（全大写 2-6 字母 + 数字）时当番号用。
  static String _codeFromTitle(String title) {
    final match = RegExp(r'([A-Za-z]{2,6})[-_ ]?(\d{2,6})').firstMatch(title);
    if (match == null) return '';
    return '${match.group(1)}-${match.group(2)}'.toLowerCase();
  }

  List<WhosLocalWork> get _all => _works
      .where((work) => work.playable || work.cover.isNotEmpty)
      .toList(growable: false);

  Map<String, List<WhosLocalWork>> get _brands {
    final cached = _byBrand;
    if (cached != null) return cached;
    final map = <String, List<WhosLocalWork>>{};
    for (final work in _all) {
      if (work.brand.isEmpty) continue;
      map.putIfAbsent(work.brand, () => <WhosLocalWork>[]).add(work);
    }
    _byBrand = map;
    return map;
  }

  Map<String, WhosLocalWork> get _codes {
    final cached = _byCode;
    if (cached != null) return cached;
    final map = <String, WhosLocalWork>{};
    for (final work in _all) {
      final code = work.code.toLowerCase();
      if (code.isEmpty) continue;
      map.putIfAbsent(code, () => work);
    }
    _byCode = map;
    return map;
  }

  /// 厂牌分类：按条目数从多到少。
  List<({String brand, int count})> brandFacets({int limit = 40}) {
    final entries = _brands.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return [
      for (final entry in entries.take(limit))
        if (entry.value.length >= 2)
          (brand: entry.key, count: entry.value.length),
    ];
  }

  /// 分类里有多少条（不含分页）。category 支持
  /// `new` / `rank` / `brand:<前缀>` / 空（= 全部）。
  int countFor({String category = '', String query = ''}) =>
      _match(category: category, query: query).length;

  /// 取一页。page 从 1 开始。
  List<WhosLocalWork> page({
    String category = '',
    String query = '',
    int page = 1,
    int pageSize = 24,
  }) {
    if (page < 1 || pageSize <= 0) return const [];
    final rows = _match(category: category, query: query);
    final start = (page - 1) * pageSize;
    if (start >= rows.length) return const [];
    final end = start + pageSize > rows.length ? rows.length : start + pageSize;
    return rows.sublist(start, end);
  }

  List<WhosLocalWork> _match({String category = '', String query = ''}) {
    var rows = _all;
    if (category.startsWith(whosLocalBrandPrefix)) {
      final brand = category
          .substring(whosLocalBrandPrefix.length)
          .trim()
          .toLowerCase();
      rows = _brands[brand] ?? const <WhosLocalWork>[];
    }
    final keyword = query.trim().toLowerCase();
    if (keyword.isEmpty) return rows;
    final tokens = keyword
        .split(RegExp(r'[\s,，]+'))
        .where((token) => token.isNotEmpty)
        .toList();
    return rows.where((work) {
      final haystack =
          '${work.title} ${work.code} ${work.brand} ${work.area} ${work.year}'
              .toLowerCase();
      return tokens.every(haystack.contains);
    }).toList(growable: false);
  }

  WhosLocalWork? byId(String id) {
    final key = id.trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final work in _all) {
      if (work.id.toLowerCase() == key) return work;
    }
    return _codes[key];
  }

  /// 目录分类（本地维度）：最新、排行榜、厂牌前缀。
  ///
  /// 排行榜没有离线数据，按「有封面优先 + 条目顺序」顶上——离线时至少
  /// 有内容可看，不显示成空列表。
  List<({String id, String name, int count})> categories({int brandLimit = 30}) {
    final newCount = _all.length;
    final out = <({String id, String name, int count})>[
      (id: whosLocalNewCategory, name: '最新作品', count: newCount),
      (id: whosLocalRankCategory, name: '排行榜', count: newCount),
    ];
    for (final facet in brandFacets(limit: brandLimit)) {
      out.add((
        id: '$whosLocalBrandPrefix${facet.brand}',
        name: whosBrandLabel(facet.brand),
        count: facet.count,
      ));
    }
    return out;
  }
}
