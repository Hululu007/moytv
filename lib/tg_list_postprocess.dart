import 'dart:convert';

import 'models.dart';

/// TG 两个 jar 站源（ZakaTg / ZakaTgMovie）的壳侧列表后处理：广告帖
/// 过滤、去重、同名集数归拢。只对这两个站源的 jar 列表生效，以
/// spider 类名 gate，绝不波及其他站源。
///
/// 背景（反编译已证）：ZakaTgAllAmns 的 homeContent 不调 groupByTitle，
/// 壳侧 catalog 空分类走 homeVideoContent（空）回落 homeContent，所以
/// 默认“全部”视图从不归拢；ZakaTgMovieAmns 则完全没有标题归拢。
/// jar 二进制不动（指纹不动），归拢只能在壳侧补。
///
/// 标题归一 tgTitleKey 与集号 tgEpisodeNumber 是 jar 内同名函数的
/// 逐行移植：ZakaTg 的壳侧合成组 id 走 jar 自身的 t| 格式，详情必然
/// 落到 jar 的 titleGroupDetail 回落重抓路径，键不一致就找不到各集。
/// 对照表由 Java harness（函数原文摘录）逐条跑出，见同名测试文件，
/// Dart 实现必须与之一致。Dart 正则的 lookbehind 不依赖，两个
/// lookbehind 模式均以手动取尾数方式实现，与 Java 语义等价。

const tgAllAmnsClass = 'com.github.catvod.spider.ZakaTgAllAmns';
const tgMovieAmnsClass = 'com.github.catvod.spider.ZakaTgMovieAmns';

bool tgPostProcessAppliesToClass(String className) =>
    className == tgAllAmnsClass || className == tgMovieAmnsClass;

bool tgIsMovieClass(String className) => className == tgMovieAmnsClass;

/// 广告特征词表（小写比对）：标题/简介命中任一即过滤。词表只覆盖
/// 截图里那类广告帖的强特征；“关注”只认组合式（请关注/未关注等），
/// bare“关注”与 bare“游戏”不认，避免误删正片标题。
const _tgAdPhrases = <String>[
  'vpn',
  '代理',
  '广告',
  '推广',
  '搜索引擎',
  '极搜',
  '必备工具',
  '内群介绍',
  '群介绍',
  '进群',
  '入群',
  '失联',
  '备用频道',
  '下载app',
  'app下载',
  '点击下载',
  '立即下载',
  '按月收钱',
  '按月收费',
  '黄游',
  '性爱游戏',
  '加微信',
  '微信号',
  'qq群',
  '电报群',
  '扫码',
  '机场',
  '免费节点',
  '请关注',
  '未关注',
  '没有关注',
  '关注下',
  '关注我',
  '记得关注',
];

bool tgIsAdPost({required String title, required String description}) {
  final text = '$title\n$description'.toLowerCase();
  for (final phrase in _tgAdPhrases) {
    if (text.contains(phrase)) return true;
  }
  return false;
}

/// 去重：同标题（去首尾空白、折叠空白、小写）且同非空封面只留第一条。
/// 封面为空的条目不去重——不同频道可能发同标题无封面帖，列表行里
/// 没有可区分的链接字段，宁可多留不可误删。
List<Drama> tgDedupeItems(List<Drama> items) {
  final seen = <String>{};
  final kept = <Drama>[];
  for (final item in items) {
    final cover = item.cover.trim();
    if (cover.isEmpty) {
      kept.add(item);
      continue;
    }
    final key = '${_normalizeTitle(item.title)}\n$cover';
    if (seen.add(key)) kept.add(item);
  }
  return kept;
}

String _normalizeTitle(String title) =>
    title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

// ---- 标题归一：jar titleKeyOf / epNoOf 的逐行移植 ----

final _pTags = RegExp(r'<[^>]+>');
final _pExtension = RegExp(
  r'\.(mp4|mkv|avi|ts|mov|wmv|flv|m4v|webm|rmvb)\b',
  caseSensitive: false,
);
final _pTme = RegExp(r'(https?://)?t\.me/\S+', caseSensitive: false);
final _pMention = RegExp(r'@[A-Za-z][A-Za-z0-9_]{2,31}');
final _pBracketUnwrap = RegExp(r'[《<]([^》>]{1,40})[》>]');
final _pBracket = RegExp(r'[（(【\[<《][^）)】\]>》]{0,30}[）)】\]>》]');
final _pEpSxxEyy = RegExp(r'S\d{1,2}\s*E\s*(\d{1,4})', caseSensitive: false);
final _pEpRange = RegExp(r'(\d{1,4})\s*[-~—]\s*(\d{1,4})\s*集');
final _pEpZh = RegExp(r'第\s*(\d{1,4})\s*[集话期节]');
final _pEpTotalKey = RegExp(
  r'(?:全|共|更新至|完结|连载)\s*\d{1,4}\s*集',
  caseSensitive: false,
);
final _pEpTotalNo = RegExp(
  r'(?:全|共|更新至)\s*(\d{1,4})\s*集',
  caseSensitive: false,
);
final _pQuality = RegExp(
  r'(4K|8K|1080P|720P|480P|FHD|UHD|HD|蓝光|超清|高清|原画|中文字幕|中字|简中|繁中|国配|国语|粤语|双语|无码|有码|破解版|破解|完整版|未删减|全集|合集|更新至|完结|磁力|种子|迅雷|pikpak|115|直链|在线观看)',
  caseSensitive: false,
);
final _pEpEn = RegExp(r'\bEP?\s*[.\-_ ]?(\d{1,4})\b', caseSensitive: false);
final _pBareRange = RegExp(r'\d{1,4}\s*[-~—]\s*\d{1,4}');
final _pSymbol = RegExp(r'[\p{P}\p{S}\p{Z}\s]+', unicode: true);
final _pTrailingDigits = RegExp(r'(\d+)$');
final _pSpaceOrPunct = RegExp(r'[\s\p{P}]', unicode: true);

/// 标题归一键：与 jar 的 titleKeyOf 逐字一致（含怪行为，如
/// 【标题】会被整段剥掉导致键为空——那是 jar 的原样行为，壳侧
/// 必须与它算出同一个键，否则 t| 详情回落重抓对不上）。
String tgTitleKey(String title) {
  var text = title.replaceAll(_pTags, ' ');
  text = text.replaceAll(_pExtension, ' ');
  text = text.replaceAll(_pTme, ' ');
  text = text.replaceAll(_pMention, ' ');
  text = text.replaceAllMapped(
    _pBracketUnwrap,
    (match) => ' ${match.group(1)} ',
  );
  text = text.replaceAll(_pBracket, ' ');
  text = text.replaceAll(_pEpSxxEyy, ' ');
  text = text.replaceAll(_pEpRange, ' ');
  text = text.replaceAll(_pEpZh, ' ');
  text = text.replaceAll(_pEpTotalKey, ' ');
  text = text.replaceAll(_pQuality, ' ');
  text = text.replaceAll(_pEpEn, ' ');
  text = text.replaceAll(_pBareRange, ' ');
  text = _stripTrailingNumber(text);
  text = text.replaceAll(_pSymbol, '');
  text = text.trim();
  if (text.length > 40) text = text.substring(0, 40);
  return text;
}

/// Java 模式 `(?<=[\s\p{P}])\d{1,4}$` 的无 lookbehind 等价实现：
/// 只认“整段尾数”——尾部数字串超过 4 位时 Java 同样不匹配（任何
/// 起点都会被前一位数字挡住 lookbehind），不足 4 位且前一字符是
/// 空白/标点时才剥掉。
String _stripTrailingNumber(String text) {
  final match = _pTrailingDigits.firstMatch(text);
  if (match == null) return text;
  final digits = match.group(1)!;
  if (digits.length > 4) return text;
  if (match.start == 0) return text;
  if (!_pSpaceOrPunct.hasMatch(text[match.start - 1])) return text;
  return '${text.substring(0, match.start)} ${text.substring(match.end)}';
}

/// 集号提取：与 jar 的 epNoOf 同顺序——SxxEyy → 范围 → 第N集 →
/// 全/共/更新至N集 → 尾数 → EP N。找不到返回 0。
int tgEpisodeNumber(String title) {
  final sxx = _pEpSxxEyy.firstMatch(title);
  if (sxx != null) return int.parse(sxx.group(1)!);
  final range = _pEpRange.firstMatch(title);
  if (range != null) return int.parse(range.group(1)!);
  final zh = _pEpZh.firstMatch(title);
  if (zh != null) return int.parse(zh.group(1)!);
  final total = _pEpTotalNo.firstMatch(title);
  if (total != null) return int.parse(total.group(1)!);
  final trailing = _trailingNumber(title.trim());
  if (trailing != null) return trailing;
  final en = _pEpEn.firstMatch(title);
  if (en != null) return int.parse(en.group(1)!);
  return 0;
}

/// Java 模式 `(?<![A-Za-z0-9])(\d{1,4})\s*$`（作用于 trim 后文本）
/// 的无 lookbehind 等价实现：尾部数字串超过 4 位时不认；前一字符
/// 是 ASCII 字母数字时不认；串首起算的数字认。
int? _trailingNumber(String trimmed) {
  final match = _pTrailingDigits.firstMatch(trimmed);
  if (match == null) return null;
  final digits = match.group(1)!;
  if (digits.length > 4) return null;
  if (match.start > 0) {
    final prev = trimmed.codeUnitAt(match.start - 1);
    final isAlnum =
        (prev >= 0x30 && prev <= 0x39) ||
        (prev >= 0x41 && prev <= 0x5A) ||
        (prev >= 0x61 && prev <= 0x7A);
    if (isAlnum) return null;
  }
  return int.parse(digits);
}

// ---- 组 id 编解码 ----

String _b64urlNoPad(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

/// jar 自身的组 id 格式：`t|<b64url无填充(键)>|<频道逗号表>`。
/// ZakaTg 的壳侧合成组用此格式，详情直接走 jar 的 titleGroupDetail。
String tgJarGroupId(String key, List<String> users) =>
    't|${_b64urlNoPad(key)}|${users.join(',')}';

/// 壳侧组 id 格式（只用于 ZakaTgMovie）：`shelltg|<b64>|<频道表>`，
/// 与 jar 的 `user|id`、`g|`、`t|` 均不撞，详情由壳侧合成。
String tgShellGroupId(String key, List<String> users) =>
    'shelltg|${_b64urlNoPad(key)}|${users.join(',')}';

bool tgIsShellGroupId(String id) => id.startsWith('shelltg|');

bool tgIsJarGroupId(String id) => id.startsWith('t|') || id.startsWith('g|');

bool tgIsGroupId(String id) => tgIsJarGroupId(id) || tgIsShellGroupId(id);

class TgGroupRef {
  const TgGroupRef({required this.key, required this.users});

  final String key;
  final List<String> users;
}

TgGroupRef? tgParseGroupId(String id) {
  final parts = id.split('|');
  if (parts.length < 3) return null;
  if (parts[0] != 't' && parts[0] != 'shelltg') return null;
  final encoded = parts[1];
  if (encoded.isEmpty) return null;
  try {
    final padded = encoded + '=' * ((4 - encoded.length % 4) % 4);
    final key = utf8.decode(base64Url.decode(padded));
    if (key.isEmpty) return null;
    final users = parts[2]
        .split(',')
        .map((user) => user.trim())
        .where((user) => user.isNotEmpty)
        .toList();
    return TgGroupRef(key: key, users: users);
  } catch (_) {
    return null;
  }
}

/// 列表行 id `user|id`（照片行可能带 `p|` 前缀）里的频道用户名。
String tgChannelUserOf(String memberId) {
  var id = memberId;
  if (id.startsWith('p|')) id = id.substring(2);
  final bar = id.indexOf('|');
  if (bar <= 0) return '';
  return id.substring(0, bar);
}

// ---- 会话内组成员缓存（只记 Movie 壳侧组；ZakaTg 组详情走 jar） ----

class TgGroupMembers {
  TgGroupMembers._();

  static const maxEntries = 200;
  static final Map<String, List<Drama>> _entries = {};

  static void remember(String groupId, List<Drama> members) {
    _entries.remove(groupId);
    _entries[groupId] = List<Drama>.unmodifiable(members);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static List<Drama>? lookup(String groupId) => _entries[groupId];

  static void clear() => _entries.clear();
}

// ---- 归拢 ----

/// 同名集数归拢：同键（tgTitleKey）且至少 2 个不同集号（>0）的条目
/// 合成一张组卡，位置取首现成员处。比 jar 更严一档：jar 只要求同键
/// 满 minGroup（2）即合拢，壳侧还要求集号真实不同，避免把同标题
/// 非剧集帖、重复帖误合成“剧集”。已成组的卡（t|/g|/shelltg|）、
/// 文件夹卡、键不足 2 字的一律不参与。
List<Drama> tgGroupItems(List<Drama> items, {required bool isMovie}) {
  final keys = <String?>[];
  final buckets = <String, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    String? key;
    if (!item.isFolder && !tgIsGroupId(item.id)) {
      final candidate = tgTitleKey(item.title);
      if (candidate.length >= 2) key = candidate;
    }
    keys.add(key);
    if (key != null) {
      buckets.putIfAbsent(key, () => []).add(i);
    }
  }
  final valid = <String>{};
  for (final entry in buckets.entries) {
    if (entry.value.length < 2) continue;
    final epNos = <int>{};
    for (final i in entry.value) {
      final ep = tgEpisodeNumber(items[i].title);
      if (ep > 0) epNos.add(ep);
    }
    if (epNos.length >= 2) valid.add(entry.key);
  }
  if (valid.isEmpty) return items;
  final emitted = <String>{};
  final out = <Drama>[];
  for (var i = 0; i < items.length; i++) {
    final key = keys[i];
    if (key == null || !valid.contains(key)) {
      out.add(items[i]);
      continue;
    }
    if (!emitted.add(key)) continue;
    final members = buckets[key]!.map((j) => items[j]).toList();
    out.add(_buildGroupCard(key, members, isMovie: isMovie));
  }
  return out;
}

Drama _buildGroupCard(
  String key,
  List<Drama> members, {
  required bool isMovie,
}) {
  final indexed = [for (var i = 0; i < members.length; i++) (i, members[i])];
  indexed.sort((a, b) {
    final ea = tgEpisodeNumber(a.$2.title);
    final eb = tgEpisodeNumber(b.$2.title);
    if (ea != eb) return ea - eb;
    return a.$1 - b.$1;
  });
  final sorted = [for (final entry in indexed) entry.$2];
  final users = <String>[];
  for (final member in sorted) {
    final user = tgChannelUserOf(member.id);
    if (user.isNotEmpty && !users.contains(user)) users.add(user);
  }
  final id = isMovie ? tgShellGroupId(key, users) : tgJarGroupId(key, users);
  var cover = '';
  for (final member in sorted) {
    if (member.cover.trim().isNotEmpty) {
      cover = member.cover;
      break;
    }
  }
  // 封面取排序后首张非空（与 jar 组卡一致）；分类/年份取末位成员。
  final last = sorted.last;
  final card = Drama(
    id: id,
    source: sorted.first.source,
    title: key,
    cover: cover,
    episodes: sorted.length,
    category: last.category,
    heat: '${sorted.length}集',
    onlineDate: last.onlineDate,
  );
  if (isMovie) TgGroupMembers.remember(id, sorted);
  return card;
}

/// 全流程：广告过滤 → 去重 → 归拢（图片分类只做前两步，jar 的
/// groupByTitle 同样跳过照片帖，壳侧以分类 id 识别）。
/// 非 TG 两站原样返回同一页对象。
CatalogPage tgPostProcessPage(
  CatalogPage page, {
  required String className,
  required String category,
}) {
  if (!tgPostProcessAppliesToClass(className)) return page;
  final filtered = <Drama>[];
  for (final item in page.items) {
    if (!tgIsAdPost(title: item.title, description: item.description)) {
      filtered.add(item);
    }
  }
  var items = tgDedupeItems(filtered);
  if (category != 'pic') {
    items = tgGroupItems(items, isMovie: tgIsMovieClass(className));
  }
  return CatalogPage(
    items,
    hasMore: page.hasMore,
    warning: page.warning,
    page: page.page,
    fresh: page.fresh,
    tags: page.tags,
    filters: page.filters,
  );
}

// ---- ZakaTgMovie 壳侧组详情合成 ----

class TgGroupDetailFailure implements Exception {
  TgGroupDetailFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Movie 壳侧组的详情合成：先查会话缓存，缓存未命中时以组键搜一遍
/// 该站、把同键成员捞回（搜索结果里的组卡按缓存展开，成员仍逐条
/// 验键）。集名按 jar titleGroupDetail 的口径：有集号用“第N集”，
/// 否则按序补“第i集”；currentEpisode 取序位，与 jar 详情解析一致。
/// 搜不到成员时抛错（与 jar 详情无结果时抛错的口径一致），不造假集。
Future<DramaDetail> tgSynthesizeMovieGroupDetail({
  required Drama drama,
  required Future<CatalogPage> Function(String query) search,
}) async {
  final ref = tgParseGroupId(drama.id);
  if (ref == null || !tgIsShellGroupId(drama.id)) {
    throw TgGroupDetailFailure('该合集链接无法识别，请返回列表重新打开');
  }
  var members = TgGroupMembers.lookup(drama.id);
  members ??= await _searchGroupMembers(ref.key, search);
  if (members.isEmpty) {
    throw TgGroupDetailFailure('未找到「${ref.key}」的各集，频道内容可能已翻页，请返回列表重试');
  }
  TgGroupMembers.remember(drama.id, members);
  final episodes = <Episode>[];
  for (var i = 0; i < members.length; i++) {
    final epNo = tgEpisodeNumber(members[i].title);
    final name = epNo > 0 ? '第$epNo集' : '第${i + 1}集';
    episodes.add(
      Episode({
        'id': members[i].id,
        'title': name,
        'flag': 'TG直连',
        'playId': members[i].id,
        'currentEpisode': i + 1,
      }, i + 1),
    );
  }
  final detailDrama = Drama(
    id: drama.id,
    source: drama.source,
    title: ref.key,
    description: drama.description,
    cover: drama.cover,
    episodes: members.length,
    category: drama.category,
    heat: '${members.length}集',
    onlineDate: drama.onlineDate,
    tags: drama.tags,
  );
  return DramaDetail(detailDrama, episodes);
}

Future<List<Drama>> _searchGroupMembers(
  String key,
  Future<CatalogPage> Function(String query) search,
) async {
  final page = await search(key);
  final wanted = key.toLowerCase();
  final found = <Drama>[];
  final seen = <String>{};
  void addIfMatch(Drama member) {
    if (tgTitleKey(member.title).toLowerCase() != wanted) return;
    if (seen.add(member.id)) found.add(member);
  }

  for (final item in page.items) {
    if (tgIsShellGroupId(item.id)) {
      final cached = TgGroupMembers.lookup(item.id);
      if (cached != null) {
        for (final member in cached) {
          addIfMatch(member);
        }
      }
      continue;
    }
    if (tgIsJarGroupId(item.id)) continue;
    addIfMatch(item);
  }
  final indexed = [for (var i = 0; i < found.length; i++) (i, found[i])];
  indexed.sort((a, b) {
    final ea = tgEpisodeNumber(a.$2.title);
    final eb = tgEpisodeNumber(b.$2.title);
    if (ea != eb) return ea - eb;
    return a.$1 - b.$1;
  });
  return [for (final entry in indexed) entry.$2];
}
