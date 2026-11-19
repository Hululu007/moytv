import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'actress_m3u_index.dart';
import 'actress_models.dart';

/// 女优库 JSON 兜底：工作台爬取循环产出的 mjv011.json / whos.json。
///
/// 格式照 UPDATE_RULES.md（~/workspace/mjv_whos_crawl_20261119/）：
/// 13 个 hsck 字段同顺序 + 末尾 vod_code、vod_actress_pic；
/// 顶层 list/parse/jx/last_update；indent=2；简介单段 <p>；
/// 备注一律“高清”；值照实数。两站各管各，不跨站合并。
///
/// 落法：随包带版本化 asset（assets/actress_json/，构建时从工作目录
/// 拷最新版）+ 本地现爬文件叠加（documents/actress_json/，现爬服务
/// 写，新于随包版时按更新规则覆盖：番号相同且播放链接相同跳过，
/// 任一字段不同就替换；同一部在不同分类各留一条，按（分类，番号）留）。
/// 没有服务端托管，不编下载地址。

/// hsck 13 字段顺序 + 末尾 vod_code、vod_actress_pic。
const actressJsonFieldOrder = <String>[
  'vod_id',
  'vod_name',
  'vod_pic',
  'vod_actor',
  'vod_director',
  'vod_remarks',
  'vod_pubdate',
  'vod_area',
  'vod_year',
  'vod_content',
  'vod_play_from',
  'vod_play_url',
  'type_name',
  'vod_code',
  'vod_actress_pic',
];

const actressJsonTopKeys = <String>{'list', 'parse', 'jx', 'last_update'};

/// 校验一份 JSON 文档是否合 hsck 格式：顶层四键齐、每行 15 字段
/// 同顺序、播放地址为空或 `正片$http(s)://...`。不对就抛 FormatException，
/// 说明里写清哪一行哪一项坏了。
void validateActressJsonDocument(Map<String, dynamic> doc, String label) {
  final problems = <String>[];
  if (!actressJsonTopKeys.every(doc.containsKey)) {
    problems.add('顶层缺键（要 list/parse/jx/last_update）');
  }
  final list = doc['list'];
  if (list is! List) {
    problems.add('顶层 list 不是数组');
  } else {
    for (var i = 0; i < list.length; i++) {
      final row = list[i];
      if (row is! Map) {
        problems.add('第 $i 行不是对象');
        continue;
      }
      final keys = row.keys.map((e) => e.toString()).toList();
      if (!_sameOrder(keys, actressJsonFieldOrder)) {
        problems.add('第 $i 行字段顺序不对（要 13 字段 + vod_code + vod_actress_pic）');
      }
      final playUrl = row['vod_play_url']?.toString() ?? '';
      if (playUrl.isNotEmpty &&
          !(playUrl.startsWith('正片\$http://') ||
              playUrl.startsWith('正片\$https://'))) {
        problems.add('第 $i 行 vod_play_url 不是“正片\$地址”');
      }
    }
  }
  if (problems.isNotEmpty) {
    throw FormatException('$label 格式不对：${problems.take(3).join('；')}');
  }
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 名字归一化（仅兜底匹配用）：去空白、全小写。
String normalizeActressJsonName(String name) =>
    name.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// JSON 里的一条视频：一个站的一条，不跨站合并。
class ActressJsonEntry {
  ActressJsonEntry({
    required this.site,
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.vodActor,
    required this.vodDirector,
    required this.vodRemarks,
    required this.vodPubdate,
    required this.vodArea,
    required this.vodYear,
    required this.vodContent,
    required this.vodPlayFrom,
    required this.vodPlayUrl,
    required this.typeName,
    required this.vodCode,
    required this.vodActressPic,
  });

  factory ActressJsonEntry.fromRow(Map<String, dynamic> row, String site) {
    String text(String key) => row[key]?.toString() ?? '';
    return ActressJsonEntry(
      site: site,
      vodId: text('vod_id'),
      vodName: text('vod_name'),
      vodPic: text('vod_pic'),
      vodActor: text('vod_actor'),
      vodDirector: text('vod_director'),
      vodRemarks: text('vod_remarks'),
      vodPubdate: text('vod_pubdate'),
      vodArea: text('vod_area'),
      vodYear: text('vod_year'),
      vodContent: text('vod_content'),
      vodPlayFrom: text('vod_play_from'),
      vodPlayUrl: text('vod_play_url'),
      typeName: text('type_name'),
      vodCode: text('vod_code'),
      vodActressPic: text('vod_actress_pic'),
    );
  }

  /// 站：mjv / whos（取自文件名，不跨站）。
  final String site;
  final String vodId;
  final String vodName;
  final String vodPic;
  final String vodActor;
  final String vodDirector;
  final String vodRemarks;
  final String vodPubdate;
  final String vodArea;
  final String vodYear;
  final String vodContent;
  final String vodPlayFrom;
  final String vodPlayUrl;
  final String typeName;
  final String vodCode;
  final String vodActressPic;

  /// 归一化番号（与库内 works.codeKey 同一口径）。
  String get codeKey => normalizeAvCode(vodCode);

  /// `正片$地址` 里的直链地址；空表示这条还没取到流。
  String get playUrl {
    const marker = '正片\$';
    if (!vodPlayUrl.startsWith(marker)) return '';
    return vodPlayUrl.substring(marker.length);
  }

  /// 能播：有 http(s) 直链。
  bool get playable =>
      playUrl.startsWith('http://') || playUrl.startsWith('https://');

  /// 更新规则的键：（分类，番号）；没番号时退回 vod_id。
  String get mergeKey => '$typeName|${codeKey.isNotEmpty ? codeKey : vodId}';

  /// 按 15 字段顺序写回（indent=2 时与爬取成品同结构）。
  Map<String, dynamic> toRow() => <String, dynamic>{
    'vod_id': vodId,
    'vod_name': vodName,
    'vod_pic': vodPic,
    'vod_actor': vodActor,
    'vod_director': vodDirector,
    'vod_remarks': vodRemarks,
    'vod_pubdate': vodPubdate,
    'vod_area': vodArea,
    'vod_year': vodYear,
    'vod_content': vodContent,
    'vod_play_from': vodPlayFrom,
    'vod_play_url': vodPlayUrl,
    'type_name': typeName,
    'vod_code': vodCode,
    'vod_actress_pic': vodActressPic,
  };

  /// 兜底卡点播用的合成详情：单集“正片”，集 id 就是直链地址；
  /// resolve 时走潮流蜘蛛 playerContent 原始分支，原样回 parse=0
  /// 直链 + 播放头，不再解析一次。
  DramaDetail toDramaDetail() {
    final drama = Drama(
      id: 'json:$site:$vodId',
      source: ActressJsonFallback.playSource,
      title: vodName,
      description: vodContent,
      cover: vodPic,
      episodes: 1,
      category: typeName,
      onlineDate: vodPubdate,
    );
    return DramaDetail(drama, [
      Episode({'id': playUrl, 'title': '正片'}, 1),
    ]);
  }
}

/// 读 asset 用：默认走 rootBundle；测试可注入假文本。
typedef ActressJsonAssetReader = Future<String> Function(String assetPath);

Future<String> _defaultAssetReader(String assetPath) =>
    rootBundle.loadString(assetPath);

/// 女优库 JSON 兜底加载器：随包 asset + 本地现爬文件叠加，
/// 再叠 whos m3u 分片索引（用户 2026-11-19 发来的 9 个女优合集 m3u）。
/// JSON 行优先：同一播放地址 m3u 行不重复占位；m3u 行只补 JSON 没有的。
class ActressJsonFallback {
  ActressJsonFallback({
    ActressJsonAssetReader? assetReader,
    this._documentsDir,
    this._m3uIndex,
  }) : _assetReader = assetReader ?? _defaultAssetReader;

  /// whos m3u 索引：懒建，第一次查 m3u 时才解 manifest。
  WhosM3uIndex get m3uIndex => _m3uIndex ??= WhosM3uIndex();

  WhosM3uIndex? _m3uIndex;

  static const mjvAsset = 'assets/actress_json/mjv011.json';
  static const whosAsset = 'assets/actress_json/whos.json';

  /// 兜底线路的解析通道：潮流蜘蛛（mjv 全站蜘蛛）。whos 条目暂无
  /// 自己的蜘蛛，也走这条原始分支（地址原样回 parse=0）；手机上
  /// whos 直链若因头不对播不了，再立 whos 专用通道。
  static const playSource = 'chaoliu';

  /// 本地现爬文件目录名（documents 下）。
  static const localDirName = 'actress_json';

  final ActressJsonAssetReader _assetReader;
  final Directory? _documentsDir;

  var _loaded = false;
  var _entries = <ActressJsonEntry>[];
  final _byCode = <String, List<ActressJsonEntry>>{};
  final _byActor = <String, List<ActressJsonEntry>>{};
  final _counts = <String, int>{};
  final _lastUpdate = <String, String>{};

  bool get loaded => _loaded;

  List<ActressJsonEntry> get entries => List.unmodifiable(_entries);

  /// 每站条数（mjv/whos）。
  Map<String, int> get counts => Map.unmodifiable(_counts);

  /// 每站 last_update（随包版与本地版取较新的那份）。
  Map<String, String> get lastUpdate => Map.unmodifiable(_lastUpdate);

  /// 读随包两份 + 本地两份（有才读），按更新规则合并不去重。
  Future<void> load() async {
    final merged = <String, Map<String, ActressJsonEntry>>{};
    for (final site in const ['mjv', 'whos']) {
      final asset = site == 'mjv' ? mjvAsset : whosAsset;
      final bundled = await _readAsset(asset, site);
      final byKey = <String, ActressJsonEntry>{};
      for (final entry in bundled.entries) {
        byKey[entry.mergeKey] = entry;
      }
      final local = await _readLocal(site);
      for (final entry in local.entries) {
        final key = entry.mergeKey;
        final old = byKey[key];
        // 番号相同且播放链接相同才跳过；任一字段不同就替换。
        if (old != null && old.vodPlayUrl == entry.vodPlayUrl) continue;
        byKey[key] = entry;
      }
      merged[site] = byKey;
      _counts[site] = byKey.length;
      _lastUpdate[site] = local.lastUpdate.isNotEmpty
          ? local.lastUpdate
          : bundled.lastUpdate;
    }
    _entries = [
      for (final site in const ['mjv', 'whos']) ...merged[site]!.values,
    ];
    _byCode.clear();
    _byActor.clear();
    for (final entry in _entries) {
      if (entry.codeKey.isNotEmpty) {
        (_byCode[entry.codeKey] ??= []).add(entry);
      }
      final actorKey = normalizeActressJsonName(entry.vodActor);
      if (actorKey.isNotEmpty) {
        (_byActor[actorKey] ??= []).add(entry);
      }
    }
    _loaded = true;
  }

  Future<({List<ActressJsonEntry> entries, String lastUpdate})> _readAsset(
    String asset,
    String site,
  ) async {
    try {
      final text = await _assetReader(asset);
      final doc = jsonDecode(text);
      if (doc is! Map<String, dynamic>) {
        return (entries: <ActressJsonEntry>[], lastUpdate: '');
      }
      validateActressJsonDocument(doc, asset);
      final rows = doc['list'] as List;
      return (
        entries: [
          for (final row in rows)
            if (row is Map<String, dynamic>)
              ActressJsonEntry.fromRow(row, site),
        ],
        lastUpdate: doc['last_update']?.toString() ?? '',
      );
    } catch (_) {
      return (entries: <ActressJsonEntry>[], lastUpdate: '');
    }
  }

  Future<({List<ActressJsonEntry> entries, String lastUpdate})> _readLocal(
    String site,
  ) async {
    try {
      final dir = await _localDir();
      final file = File(path.join(dir.path, '$site.json'));
      if (!await file.exists()) {
        return (entries: <ActressJsonEntry>[], lastUpdate: '');
      }
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map<String, dynamic>) {
        return (entries: <ActressJsonEntry>[], lastUpdate: '');
      }
      validateActressJsonDocument(doc, file.path);
      final rows = doc['list'] as List;
      return (
        entries: [
          for (final row in rows)
            if (row is Map<String, dynamic>)
              ActressJsonEntry.fromRow(row, site),
        ],
        lastUpdate: doc['last_update']?.toString() ?? '',
      );
    } catch (_) {
      return (entries: <ActressJsonEntry>[], lastUpdate: '');
    }
  }

  Future<Directory> _localDir() async {
    if (_documentsDir != null) {
      return Directory(path.join(_documentsDir.path, localDirName));
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory(path.join(docs.path, localDirName));
  }

  /// 按番号取兜底条目（两站各留各的，不跨站合并）。
  List<ActressJsonEntry> entriesForCode(String codeKey, {String? site}) {
    final key = normalizeAvCode(codeKey);
    if (key.isEmpty) return const [];
    final rows = _byCode[key] ?? const [];
    if (site == null || site == 'all') return List.unmodifiable(rows);
    return [for (final e in rows) if (e.site == site) e];
  }

  /// 按女优名取兜底条目（名字归一化后相等才认）。
  List<ActressJsonEntry> entriesForActress(String name, {String? site}) {
    final key = normalizeActressJsonName(name);
    if (key.isEmpty) return const [];
    final rows = _byActor[key] ?? const [];
    if (site == null || site == 'all') return List.unmodifiable(rows);
    return [for (final e in rows) if (e.site == site) e];
  }

  /// 某人（名字 + 本地作品番号集合）在某站有没有 JSON 兜底条目。
  bool hasSiteEntriesForPerson({
    required List<String> names,
    required Set<String> codeKeys,
    required String site,
  }) {
    for (final name in names) {
      if (entriesForActress(name, site: site).isNotEmpty) return true;
    }
    for (final codeKey in codeKeys) {
      if (entriesForCode(codeKey, site: site).isNotEmpty) return true;
    }
    return false;
  }

  /// 异步版：JSON 行 + whos m3u 行合并（JSON 优先，m3u 补缺）。
  /// m3u 只有 whos 一路；选 mjv 时不查 m3u。m3u 索引读失败时
  /// 只回 JSON 行，不让 m3u 的问题拖垮兜底。
  Future<List<ActressJsonEntry>> entriesForActressAsync(
    String name, {
    String? site,
  }) async {
    final jsonRows = entriesForActress(name, site: site);
    if (site == 'mjv') return jsonRows;
    final m3uRows = await m3uEntriesForActress(name);
    return _mergeJsonFirst(jsonRows, m3uRows);
  }

  /// 异步版：按番号取 JSON + m3u 合并行（JSON 优先，m3u 补缺）。
  Future<List<ActressJsonEntry>> entriesForCodeAsync(
    String codeKey, {
    String? site,
  }) async {
    final jsonRows = entriesForCode(codeKey, site: site);
    if (site == 'mjv') return jsonRows;
    final m3uRows = await m3uEntriesForCode(codeKey);
    return _mergeJsonFirst(jsonRows, m3uRows);
  }

  /// 异步版：某人在某站有没有兜底条目（JSON 或 m3u）。
  Future<bool> hasSiteEntriesForPersonAsync({
    required List<String> names,
    required Set<String> codeKeys,
    required String site,
  }) async {
    if (hasSiteEntriesForPerson(
      names: names,
      codeKeys: codeKeys,
      site: site,
    )) {
      return true;
    }
    if (site != 'whos') return false;
    try {
      return await m3uIndex.hasEntriesForPerson(
        names: names,
        codeKeys: codeKeys,
      );
    } catch (_) {
      return false;
    }
  }

  /// 只取 m3u 行（不含 JSON 行）：详情页第二阶段补流用。
  /// m3u 只有 whos 一路；读失败回空，不拖垮兜底。
  Future<List<ActressJsonEntry>> m3uEntriesForActress(String name) async {
    try {
      return await m3uIndex.entriesForActress(name);
    } catch (_) {
      return const [];
    }
  }

  /// 只取 m3u 行（不含 JSON 行）：详情页第二阶段补流用。
  Future<List<ActressJsonEntry>> m3uEntriesForCode(String codeKey) async {
    try {
      return await m3uIndex.entriesForCode(codeKey);
    } catch (_) {
      return const [];
    }
  }

  /// JSON 行在前、m3u 行补缺：同一播放地址只留 JSON 那条；
  /// 没播放地址的按（站，分类|番号）去重。
  List<ActressJsonEntry> _mergeJsonFirst(
    List<ActressJsonEntry> jsonRows,
    List<ActressJsonEntry> m3uRows,
  ) {
    final seenUrls = <String>{};
    final seenKeys = <String>{};
    final out = <ActressJsonEntry>[];
    void add(ActressJsonEntry entry) {
      if (entry.playUrl.isNotEmpty) {
        if (!seenUrls.add(entry.playUrl)) return;
      } else {
        if (!seenKeys.add('${entry.site}|${entry.mergeKey}')) return;
      }
      out.add(entry);
    }

    for (final entry in jsonRows) {
      add(entry);
    }
    for (final entry in m3uRows) {
      add(entry);
    }
    return out;
  }
}
