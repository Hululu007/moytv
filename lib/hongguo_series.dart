import 'catalog_sort.dart';
import 'follow_state.dart';
import 'models.dart';

const _hongguoSeriesLimit = 200;

final _seasonSuffix = RegExp(
  r'第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]*$',
);

// S2 / Season 2：S 前必须有分隔符（空格/-/_/·），避免把标题正文
// 里的 S 误认；季号只认 1~200（与 _seasonNumber 的上限一致）。
final _seasonSuffixS = RegExp(
  r'[\s\-_·]\s*[Ss](?:eason)?\s*([0-9]{1,3})[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]*$',
);

// 上部/下部：无数字，以上下定季号 1/2，单位记“部”，与“第X部”
// 同组；只有“上部/下部”两个字、前面没有剧名的不算（base 为空）。
final _seasonSuffixPart = RegExp(
  r'([上下])部[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]*$',
);

class HongguoSeriesInfo {
  const HongguoSeriesInfo({
    required this.baseTitle,
    required this.key,
    required this.season,
    required this.unit,
    required this.explicit,
  });

  final String baseTitle;
  final String key;
  final int season;
  final String unit;
  final bool explicit;
}

class HongguoSeriesEntry {
  const HongguoSeriesEntry({
    required this.drama,
    required this.season,
    required this.unit,
  });

  final Drama drama;
  final int season;
  final String unit;

  String get label => '第 $season $unit';
}

int? _seasonNumber(String label) {
  final numeric = int.tryParse(label);
  if (numeric != null) {
    return numeric >= 1 && numeric <= _hongguoSeriesLimit ? numeric : null;
  }
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var number = 0;
  if (!label.contains(RegExp('[十百]'))) {
    for (final rune in label.runes) {
      final digit = digits[String.fromCharCode(rune)];
      if (digit == null) return null;
      number = number * 10 + digit;
      if (number > _hongguoSeriesLimit) return null;
    }
    return number >= 1 ? number : null;
  }
  var digit = 0;
  var previous = 1000;
  for (final rune in label.runes) {
    final character = String.fromCharCode(rune);
    final value = digits[character];
    if (value != null) {
      digit = digit * 10 + value;
      continue;
    }
    final multiplier = character == '百' ? 100 : 10;
    if (multiplier >= previous || digit > 9) return null;
    number += (digit == 0 ? 1 : digit) * multiplier;
    digit = 0;
    previous = multiplier;
  }
  number += digit;
  return number >= 1 && number <= _hongguoSeriesLimit ? number : null;
}

HongguoSeriesInfo? hongguoSeriesInfo(Drama drama, {String? unit}) {
  if (drama.source != SourceSite.hongguo.id) return null;
  final title = drama.title.trim();
  final match = _seasonSuffix.firstMatch(title);
  if (match != null) {
    final base = title.substring(0, match.start).trim();
    final season = _seasonNumber(match[1]!);
    if (base.isEmpty || season == null) return null;
    return HongguoSeriesInfo(
      baseTitle: base,
      key: normalizedSearchText(base),
      season: season,
      unit: match[2]!,
      explicit: true,
    );
  }
  final sMatch = _seasonSuffixS.firstMatch(title);
  if (sMatch != null) {
    final base = title.substring(0, sMatch.start).trim();
    final season = _seasonNumber(sMatch[1]!);
    if (base.isEmpty || season == null) return null;
    return HongguoSeriesInfo(
      baseTitle: base,
      key: normalizedSearchText(base),
      season: season,
      unit: '季',
      explicit: true,
    );
  }
  final partMatch = _seasonSuffixPart.firstMatch(title);
  if (partMatch != null) {
    final base = title.substring(0, partMatch.start).trim();
    if (base.isEmpty) return null;
    return HongguoSeriesInfo(
      baseTitle: base,
      key: normalizedSearchText(base),
      season: partMatch[1] == '上' ? 1 : 2,
      unit: '部',
      explicit: true,
    );
  }
  if (unit == null || title.isEmpty) return null;
  return HongguoSeriesInfo(
    baseTitle: title,
    key: normalizedSearchText(title),
    season: 1,
    unit: unit,
    explicit: false,
  );
}

/// 站方相关接口返回的季条目：Drama 已转好，seasonIndex 为站方季号。
/// seasonIndex <= 0 或超上限的不可信，合并时按标题规律复核。
typedef HongguoApiSeason = ({Drama drama, int seasonIndex});

/// 站方接口 + 标题规律合并后的同系列条目：按季号升序，含当前这部。
///
/// 口径（保守）：站方季号 > 0 的直接采信（站方自己的数据）；季号
/// 不可信的条目须标题规律复核通过（同基础标题 + 同单位）才收；标题
/// 规律的分组沿用 hongguoSeriesEntries。同季号只留一个：当前这部
/// 优先（去重重复上架），其余先入列者留。不足 2 部时返回空（无兄弟
/// 不成区）。只认红果站内数据，不跨站。
List<HongguoSeriesEntry> hongguoMergedSeasonEntries({
  required Drama anchor,
  required List<HongguoApiSeason> apiSeasons,
  required Iterable<Drama> candidates,
}) {
  if (anchor.source != SourceSite.hongguo.id) return const [];
  final byId = <String, HongguoSeriesEntry>{};
  for (final entry in hongguoSeriesEntries(anchor, candidates)) {
    byId[entry.drama.id] = entry;
  }
  final anchorPattern = byId[anchor.id];
  final anchorInfo = hongguoSeriesInfo(anchor);
  final unit = anchorPattern?.unit ?? anchorInfo?.unit ?? '季';
  final anchorSeason = anchorPattern?.season ?? anchorInfo?.season ?? 1;
  final anchorKey =
      anchorInfo?.key ?? normalizedSearchText(anchor.title.trim());
  for (final api in apiSeasons) {
    if (api.drama.id == anchor.id ||
        api.drama.source != SourceSite.hongguo.id) {
      continue;
    }
    var season = api.seasonIndex;
    if (season <= 0 || season > _hongguoSeriesLimit) {
      final info = hongguoSeriesInfo(api.drama, unit: unit);
      if (info == null || info.key != anchorKey || info.unit != unit) {
        continue;
      }
      season = info.season;
    }
    byId[api.drama.id] = HongguoSeriesEntry(
      drama: api.drama,
      season: season,
      unit: unit,
    );
  }
  if (byId.keys.where((id) => id != anchor.id).isEmpty) return const [];
  byId[anchor.id] = HongguoSeriesEntry(
    drama: anchor,
    season: anchorSeason,
    unit: unit,
  );
  final bySeason = <int, HongguoSeriesEntry>{};
  for (final entry in byId.values) {
    final previous = bySeason[entry.season];
    if (previous == null || entry.drama.id == anchor.id) {
      bySeason[entry.season] = entry;
    }
  }
  final entries = bySeason.values.toList()
    ..sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0
          ? season
          : naturalTitleCompare(a.drama.title, b.drama.title);
    });
  return entries.length > 1 ? entries : const [];
}

/// 在已按季号升序的条目里找比当前季大的最小一季；没有返回 null。
/// entries 须已排序（hongguoSeriesEntries 与 hongguoMergedSeasonEntries
/// 的返回都满足）；未排序时结果只保证季号大于当前季。
HongguoSeriesEntry? hongguoNextSeasonEntry(
  List<HongguoSeriesEntry> entries,
  String anchorId,
) {
  final anchorEntry = entries
      .where((entry) => entry.drama.id == anchorId)
      .firstOrNull;
  if (anchorEntry == null) return null;
  HongguoSeriesEntry? next;
  for (final entry in entries) {
    if (entry.season <= anchorEntry.season) continue;
    if (next == null || entry.season < next.season) next = entry;
  }
  return next;
}

List<HongguoSeriesEntry> hongguoSeriesEntries(
  Drama anchor,
  Iterable<Drama> candidates,
) {
  if (anchor.source != SourceSite.hongguo.id) return const [];
  var anchorInfo = hongguoSeriesInfo(anchor);
  String key, unit;
  int anchorSeason;
  if (anchorInfo == null) {
    final baseKey = normalizedSearchText(anchor.title);
    final groups = <String, List<HongguoSeriesInfo>>{};
    for (final drama in candidates) {
      final info = hongguoSeriesInfo(drama);
      if (info != null && info.key == baseKey) {
        (groups[info.unit] ??= []).add(info);
      }
    }
    if (groups.isEmpty) return const [];
    final best = groups.entries.toList()
      ..sort((a, b) {
        final count = b.value.length.compareTo(a.value.length);
        if (count != 0) return count;
        final maxA = a.value.fold<int>(
          0,
          (value, info) => value > info.season ? value : info.season,
        );
        final maxB = b.value.fold<int>(
          0,
          (value, info) => value > info.season ? value : info.season,
        );
        return maxB.compareTo(maxA);
      });
    key = baseKey;
    unit = best.first.key;
    anchorSeason = 1;
    anchorInfo = hongguoSeriesInfo(anchor, unit: unit);
  } else {
    key = anchorInfo.key;
    unit = anchorInfo.unit;
    anchorSeason = anchorInfo.season;
  }
  if (anchorInfo == null) return const [];
  final byId = <String, HongguoSeriesEntry>{};
  for (final drama in [anchor, ...candidates]) {
    if (drama.source != SourceSite.hongguo.id) continue;
    final info = hongguoSeriesInfo(drama, unit: unit);
    if (info == null || info.key != key || info.unit != unit) continue;
    byId[drama.id] = HongguoSeriesEntry(
      drama: drama,
      season: drama.id == anchor.id ? anchorSeason : info.season,
      unit: unit,
    );
  }
  final entries = byId.values.toList()
    ..sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0
          ? season
          : naturalTitleCompare(a.drama.title, b.drama.title);
    });
  return entries.length > 1 ? entries : const [];
}

FollowState observeHongguoSeriesSeasons({
  required Drama anchor,
  required FollowState state,
  required Iterable<Drama> candidates,
  required Set<String> favoriteIds,
}) {
  final entries = hongguoSeriesEntries(anchor, candidates);
  if (entries.isEmpty) return state;
  final anchorSeason = entries
      .where((entry) => entry.drama.id == anchor.id)
      .firstOrNull
      ?.season;
  if (anchorSeason == null) return state;
  var seasons = state.seriesSeasons;
  for (final id in seasons.keys.toList()) {
    if (id == anchor.id || favoriteIds.contains(id)) {
      seasons = Map.of(seasons)..remove(id);
    }
  }
  for (final entry in entries) {
    if (entry.drama.id == anchor.id ||
        favoriteIds.contains(entry.drama.id) ||
        entry.season <= anchorSeason) {
      continue;
    }
    final previous = seasons[entry.drama.id];
    final notice = SeriesSeasonNotice(
      id: entry.drama.id,
      title: entry.drama.title,
      season: entry.season,
      unit: entry.unit,
      read: previous?.read ?? false,
    );
    if (previous?.title == notice.title &&
        previous?.season == notice.season &&
        previous?.unit == notice.unit &&
        previous?.read == notice.read) {
      continue;
    }
    seasons = Map.of(seasons)..[notice.id] = notice;
  }
  return identical(seasons, state.seriesSeasons)
      ? state
      : state.copyWith(seriesSeasons: seasons);
}
