import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'actress_m3u_index.dart';
import 'actress_models.dart';

/// 女优库 JSON 兜底：手机现爬服务写到 documents/actress_json/ 的
/// 本地文件（每站一份 `$site.json`），再叠 whos m3u 分片索引。
///
/// 随包快照已删（2026-11-21 用户令：内置 mjv011.json 删除，兜底
/// 全部走女优库 m3u + db）：加载器不再读任何随包 asset，只读本地
/// 现爬文件；本地没有的条目走 m3u 行补。
///
/// 格式照 UPDATE_RULES.md（~/workspace/mjv_whos_crawl_20261119/）：
/// 13 个 hsck 字段同顺序 + 末尾 vod_code、vod_actress_pic；
/// 顶层 list/parse/jx/last_update；indent=2；简介单段 <p>；
/// 备注一律“高清”；值照实数。两站各管各，不跨站合并。
///
/// 合并口径：同一文件里同（分类，番号）只留一条，后写的替换先写
/// 的；不同站同一番号各留一条，按（站，分类，番号）留。
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

/// whos 简介续补入口（纯函数，不读网不写盘）：把 whos 女优页上取到
/// 的简介段落追加进一行的 vod_content，原有简介不动、只追加。
/// 简介现在取不到（whos.tv 全站 Cloudflare 403 且出口断网，
/// 2026-11-20 实测），所以本批不写任何简介、不编假简介；等 whos
/// 通了，工作台工具 fetch_whos_bio.py 取回简介后调本函数续补。
/// 空简介原样返回，不改内容；简介里的 < > & 做转义，不破坏原有 HTML。
ActressJsonEntry mergeWhosBioIntoRow(
  ActressJsonEntry entry,
  String bio,
) {
  final text = bio.trim();
  if (text.isEmpty) return entry;
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return ActressJsonEntry(
    site: entry.site,
    vodId: entry.vodId,
    vodName: entry.vodName,
    vodPic: entry.vodPic,
    vodActor: entry.vodActor,
    vodDirector: entry.vodDirector,
    vodRemarks: entry.vodRemarks,
    vodPubdate: entry.vodPubdate,
    vodArea: entry.vodArea,
    vodYear: entry.vodYear,
    vodContent: '${entry.vodContent}<p>$escaped</p>',
    vodPlayFrom: entry.vodPlayFrom,
    vodPlayUrl: entry.vodPlayUrl,
    typeName: entry.typeName,
    vodCode: entry.vodCode,
    vodActressPic: entry.vodActressPic,
  );
}

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
      source: ActressJsonFallback.spiderIdForSite(site),
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

/// 女优库 JSON 兜底加载器：本地现爬文件 + whos m3u 分片索引。
/// 本地行优先：同一播放地址 m3u 行不重复占位；m3u 行只补本地没有的。
class ActressJsonFallback {
  ActressJsonFallback({
    Directory? documentsDir,
    WhosM3uIndex? m3uIndex,
  }) : _documentsDir = documentsDir,
       _m3uIndex = m3uIndex;

  /// whos m3u 索引：懒建，第一次查 m3u 时才解 manifest。
  WhosM3uIndex get m3uIndex => _m3uIndex ??= WhosM3uIndex();

  WhosM3uIndex? _m3uIndex;

  /// 兜底线路的解析通道：mjv/whos 走潮流蜘蛛（mjv 全站蜘蛛）；
  /// 片库站走本站蜘蛛自己的站 id。whos 条目暂无自己的蜘蛛，也走
  /// 这条原始分支（地址原样回 parse=0）；手机上 whos 直链若因头
  /// 不对播不了，再立 whos 专用通道。
  static const playSource = 'chaoliu';

  /// 兜底卡点播走哪个蜘蛛取流：mjv/whos 走潮流蜘蛛，其余站走本站。
  static String spiderIdForSite(String site) =>
      (site == 'mjv' || site == 'whos') ? playSource : site;

  /// 本地现爬文件目录名（documents 下）。
  static const localDirName = 'actress_json';

  final Directory? _documentsDir;

  var _loaded = false;
  var _entries = <ActressJsonEntry>[];
  final _byCode = <String, List<ActressJsonEntry>>{};
  final _byActor = <String, List<ActressJsonEntry>>{};
  final _counts = <String, int>{};
  final _lastUpdate = <String, String>{};

  bool get loaded => _loaded;

  List<ActressJsonEntry> get entries => List.unmodifiable(_entries);

  /// 每站条数（本地现爬文件里的站）。
  Map<String, int> get counts => Map.unmodifiable(_counts);

  /// 每站 last_update（本地现爬文件里的那份）。
  Map<String, String> get lastUpdate => Map.unmodifiable(_lastUpdate);

  /// 只读本地现爬文件（documents/actress_json/ 下每站一份
  /// `$site.json`，有才读），按更新规则合并不去重：同 mergeKey
  /// 且同 vodPlayUrl 跳过、任一字段不同替换；同一部在不同分类
  /// 各留一条。随包快照已删，不再读任何 asset。
  Future<void> load() async {
    final merged = <String, Map<String, ActressJsonEntry>>{};
    final sites = await _localSiteIds();
    for (final site in sites) {
      final byKey = <String, ActressJsonEntry>{};
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
      _lastUpdate[site] = local.lastUpdate;
    }
    _entries = [
      for (final site in sites) ...merged[site]!.values,
    ];
    _byCode.clear();
    _byActor.clear();
    for (final entry in _entries) {
      if (entry.codeKey.isNotEmpty) {
        (_byCode[entry.codeKey] ??= []).add(entry);
      }
      // vod_actor 可含逗号分隔的多名（m3u 合演归属，2026-11-20）：
      // 每名各建一条索引，否则合演行按单名查不到。
      for (final name in actressNameVariants(entry.vodActor)) {
        final actorKey = normalizeActressJsonName(name);
        if (actorKey.isNotEmpty) {
          (_byActor[actorKey] ??= []).add(entry);
        }
      }
    }
    _loaded = true;
  }

  /// 本地现爬目录里的站 id：每个 *.json 文件名（去后缀）即一站。
  Future<List<String>> _localSiteIds() async {
    try {
      final dir = await _localDir();
      if (!await dir.exists()) return const [];
      final out = <String>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = path.basename(entity.path);
        if (!name.endsWith('.json')) continue;
        final site = name.substring(0, name.length - 5);
        if (site.isNotEmpty) out.add(site);
      }
      return out;
    } catch (_) {
      return const [];
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

  /// 异步版：本地行 + whos m3u 行合并（本地优先，m3u 补缺）。
  /// m3u 只有 whos 一路；只有全部/whos 才并 m3u，选片库站时只回
  /// 本站本地行。m3u 索引读失败时只回本地行，不让 m3u 的问题
  /// 拖垮兜底。
  Future<List<ActressJsonEntry>> entriesForActressAsync(
    String name, {
    String? site,
  }) async {
    final jsonRows = entriesForActress(name, site: site);
    if (site != null && site != 'all' && site != 'whos') return jsonRows;
    final m3uRows = await m3uEntriesForActress(name);
    return _mergeJsonFirst(jsonRows, m3uRows);
  }

  /// 异步版：按番号取本地 + m3u 合并行（本地优先，m3u 补缺）。
  Future<List<ActressJsonEntry>> entriesForCodeAsync(
    String codeKey, {
    String? site,
  }) async {
    final jsonRows = entriesForCode(codeKey, site: site);
    if (site != null && site != 'all' && site != 'whos') return jsonRows;
    final m3uRows = await m3uEntriesForCode(codeKey);
    return _mergeJsonFirst(jsonRows, m3uRows);
  }

  /// 异步版：某人在某站有没有兜底条目（本地或 m3u）。
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

  /// 只取 m3u 行（不含本地行）：详情页第二阶段补流用。
  /// m3u 只有 whos 一路；读失败回空，不拖垮兜底。
  Future<List<ActressJsonEntry>> m3uEntriesForActress(String name) async {
    try {
      return await m3uIndex.entriesForActress(name);
    } catch (_) {
      return const [];
    }
  }

  /// 只取 m3u 行（不含本地行）：详情页第二阶段补流用。
  Future<List<ActressJsonEntry>> m3uEntriesForCode(String codeKey) async {
    try {
      return await m3uIndex.entriesForCode(codeKey);
    } catch (_) {
      return const [];
    }
  }

  /// 本地行在前、m3u 行补缺：同一播放地址只留本地那条；
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
