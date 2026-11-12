import 'tmdb_config.dart';

const _chineseNumerals = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
  '十': 10,
  '百': 100,
};

int? parseChineseNumber(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final digits = int.tryParse(trimmed);
  if (digits != null) return digits;
  var total = 0;
  var current = 0;
  var seen = false;
  for (var i = 0; i < trimmed.length; i++) {
    final value = _chineseNumerals[trimmed[i]];
    if (value == null) return null;
    seen = true;
    if (value == 10 || value == 100) {
      total += (current == 0 ? 1 : current) * value;
      current = 0;
    } else {
      current = current * 10 + value;
    }
  }
  if (!seen) return null;
  return total + current;
}

int? seasonFromTitle(String title) {
  final seasonMatch = RegExp(
    r'第\s*([零〇一二两三四五六七八九十百\d]+)\s*季',
  ).firstMatch(title);
  if (seasonMatch != null) {
    return parseChineseNumber(seasonMatch.group(1)!);
  }
  final sMatch = RegExp(
    r'\bS(\d{1,3})\b',
    caseSensitive: false,
  ).firstMatch(title);
  if (sMatch != null) return int.tryParse(sMatch.group(1)!);
  return null;
}

({int season, int episode})? seasonEpisodeFromTitle(String title) {
  final match = RegExp(
    r'\bS(\d{1,3})\s*E(\d{1,4})\b',
    caseSensitive: false,
  ).firstMatch(title);
  if (match != null) {
    final season = int.tryParse(match.group(1)!);
    final episode = int.tryParse(match.group(2)!);
    if (season != null && episode != null) {
      return (season: season, episode: episode);
    }
  }
  final season = seasonFromTitle(title);
  final episodeMatch = RegExp(
    r'第\s*([零〇一二两三四五六七八九十百\d]+)\s*[集话]',
  ).firstMatch(title);
  if (season != null && episodeMatch != null) {
    final episode = parseChineseNumber(episodeMatch.group(1)!);
    if (episode != null) return (season: season, episode: episode);
  }
  return null;
}

String baseTitleForSearch(String title) {
  var cleaned = title;
  cleaned = cleaned.replaceAll(RegExp(r'第\s*[零〇一二两三四五六七八九十百\d]+\s*季'), ' ');
  cleaned = cleaned.replaceAll(
    RegExp(r'\bS\d{1,3}\s*E\d{1,4}\b', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(
    RegExp(r'\bS\d{1,3}\b', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(RegExp(r'第\s*[零〇一二两三四五六七八九十百\d]+\s*[集话]'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  return cleaned;
}

String? yearFromText(String? text) {
  if (text == null || text.isEmpty) return null;
  final match = RegExp(r'(19|20)\d{2}').firstMatch(text);
  return match?.group(0);
}

String? tmdbMediaTypeHint(String category, String title) {
  final text = '$category $title';
  if (RegExp(r'电影|movie|film', caseSensitive: false).hasMatch(text)) {
    return 'movie';
  }
  if (RegExp(
    r'电视剧|剧集|连续剧|美剧|韩剧|日剧|国产剧|港剧|台剧|海外剧|\btv\b|series',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'tv';
  }
  return null;
}

int? parseTmdbNumber(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  return int.tryParse(value.toString());
}

double? parseTmdbDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

String _string(dynamic value) => value?.toString() ?? '';

class TmdbCastMember {
  const TmdbCastMember({
    this.name = '',
    this.character = '',
    this.profilePath = '',
  });

  final String name;
  final String character;
  final String profilePath;

  factory TmdbCastMember.fromJson(Map<String, dynamic> json) => TmdbCastMember(
    name: _string(json['name']),
    character: _string(json['character']),
    profilePath: _string(json['profile_path']),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'character': character,
    'profile_path': profilePath,
  };
}

class TmdbEpisode {
  const TmdbEpisode({
    this.seasonNumber = 0,
    this.episodeNumber = 0,
    this.name = '',
    this.overview = '',
    this.stillPath = '',
    this.airDate = '',
  });

  final int seasonNumber;
  final int episodeNumber;
  final String name;
  final String overview;
  final String stillPath;
  final String airDate;

  factory TmdbEpisode.fromJson(Map<String, dynamic> json) => TmdbEpisode(
    seasonNumber: parseTmdbNumber(json['season_number']) ?? 0,
    episodeNumber: parseTmdbNumber(json['episode_number']) ?? 0,
    name: _string(json['name']),
    overview: _string(json['overview']),
    stillPath: _string(json['still_path']),
    airDate: _string(json['air_date']),
  );

  Map<String, dynamic> toJson() => {
    'season_number': seasonNumber,
    'episode_number': episodeNumber,
    'name': name,
    'overview': overview,
    'still_path': stillPath,
    'air_date': airDate,
  };
}

class TmdbMetadata {
  const TmdbMetadata({
    this.tmdbId = 0,
    this.mediaType = '',
    this.title = '',
    this.originalTitle = '',
    this.year = '',
    this.overview = '',
    this.posterPath = '',
    this.backdropPath = '',
    this.voteAverage,
    this.runtime = 0,
    this.seasonCount = 0,
    this.episodes = const [],
    this.cast = const [],
    this.backdropPaths = const [],
  });

  final int tmdbId;
  final String mediaType;
  final String title;
  final String originalTitle;
  final String year;
  final String overview;
  final String posterPath;
  final String backdropPath;
  final double? voteAverage;
  final int runtime;
  final int seasonCount;
  final List<TmdbEpisode> episodes;
  final List<TmdbCastMember> cast;
  final List<String> backdropPaths;

  bool get isTv => mediaType == 'tv';
  bool get isMovie => mediaType == 'movie';

  String posterUrl(TmdbConfig config, {String size = 'w500'}) =>
      config.imageUrl(posterPath, size: size);

  String backdropUrl(TmdbConfig config, {String size = 'w1280'}) =>
      config.imageUrl(backdropPath, size: size);

  factory TmdbMetadata.fromSearchResult(Map<String, dynamic> json) {
    final mediaType = _string(json['media_type']);
    final title = mediaType == 'tv'
        ? _string(json['name'])
        : _string(json['title']);
    final originalTitle = mediaType == 'tv'
        ? _string(json['original_name'])
        : _string(json['original_title']);
    final date = mediaType == 'tv'
        ? _string(json['first_air_date'])
        : _string(json['release_date']);
    return TmdbMetadata(
      tmdbId: parseTmdbNumber(json['id']) ?? 0,
      mediaType: mediaType,
      title: title,
      originalTitle: originalTitle,
      year: yearFromText(date) ?? '',
      overview: _string(json['overview']),
      posterPath: _string(json['poster_path']),
      backdropPath: _string(json['backdrop_path']),
      voteAverage: parseTmdbDouble(json['vote_average']),
    );
  }

  TmdbMetadata withDetail(Map<String, dynamic> json) {
    final credits = json['credits'] as Map<String, dynamic>? ?? const {};
    final images = json['images'] as Map<String, dynamic>? ?? const {};
    final backdrops = images['backdrops'] as List? ?? const [];
    final seasons = json['seasons'] as List? ?? const [];
    return TmdbMetadata(
      tmdbId: tmdbId,
      mediaType: mediaType,
      title: title,
      originalTitle: originalTitle,
      year: year,
      overview: _string(json['overview']).isEmpty
          ? overview
          : _string(json['overview']),
      posterPath: _string(json['poster_path']).isEmpty
          ? posterPath
          : _string(json['poster_path']),
      backdropPath: _string(json['backdrop_path']).isEmpty
          ? backdropPath
          : _string(json['backdrop_path']),
      voteAverage: parseTmdbDouble(json['vote_average']) ?? voteAverage,
      runtime: parseTmdbNumber(json['runtime']) ?? 0,
      seasonCount: seasons.length,
      episodes: episodes,
      cast: [
        for (final row in credits['cast'] as List? ?? const [])
          if (row is Map<String, dynamic>) TmdbCastMember.fromJson(row),
      ],
      backdropPaths: [
        for (final row in backdrops)
          if (row is Map && _string(row['file_path']).isNotEmpty)
            _string(row['file_path']),
      ],
    );
  }

  TmdbMetadata withEpisodes(List<TmdbEpisode> value) => TmdbMetadata(
    tmdbId: tmdbId,
    mediaType: mediaType,
    title: title,
    originalTitle: originalTitle,
    year: year,
    overview: overview,
    posterPath: posterPath,
    backdropPath: backdropPath,
    voteAverage: voteAverage,
    runtime: runtime,
    seasonCount: seasonCount,
    episodes: value,
    cast: cast,
    backdropPaths: backdropPaths,
  );

  Map<String, dynamic> toJson() => {
    'tmdbId': tmdbId,
    'mediaType': mediaType,
    'title': title,
    'originalTitle': originalTitle,
    'year': year,
    'overview': overview,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'voteAverage': voteAverage,
    'runtime': runtime,
    'seasonCount': seasonCount,
    'episodes': [for (final e in episodes) e.toJson()],
    'cast': [for (final c in cast) c.toJson()],
    'backdropPaths': backdropPaths,
  };

  factory TmdbMetadata.fromJson(Map<String, dynamic> json) => TmdbMetadata(
    tmdbId: parseTmdbNumber(json['tmdbId']) ?? 0,
    mediaType: _string(json['mediaType']),
    title: _string(json['title']),
    originalTitle: _string(json['originalTitle']),
    year: _string(json['year']),
    overview: _string(json['overview']),
    posterPath: _string(json['posterPath']),
    backdropPath: _string(json['backdropPath']),
    voteAverage: parseTmdbDouble(json['voteAverage']),
    runtime: parseTmdbNumber(json['runtime']) ?? 0,
    seasonCount: parseTmdbNumber(json['seasonCount']) ?? 0,
    episodes: [
      for (final row in json['episodes'] as List? ?? const [])
        if (row is Map<String, dynamic>) TmdbEpisode.fromJson(row),
    ],
    cast: [
      for (final row in json['cast'] as List? ?? const [])
        if (row is Map<String, dynamic>) TmdbCastMember.fromJson(row),
    ],
    backdropPaths: [
      for (final row in json['backdropPaths'] as List? ?? const [])
        _string(row),
    ].where((path) => path.isNotEmpty).toList(),
  );
}

/// 从选集标题里提取集号，只认以下写法，其余返回 null：
///
/// - 中文“第 N 集”（含空格与前导零，如“第 03 集”）；
/// - 季集写法 SxxExx（如 S01E05 取 5）；
/// - EP/E + 数字（如 EP12、E03），前面不能紧贴字母数字；
/// - 纯数字标题（如“12”）；
/// - 开头数字 + 分隔符（如“12. 标题”“12、标题”“12 标题”）。
///
/// 年份日期不会被误认：分隔符不含 '-'，纯数字分支要求整条标题
/// 只有数字；即使误解析出超大数字，配对时也找不到对应的 TMDB 集。
int? episodeNumberFromTitle(String title) {
  final text = title.trim();
  if (text.isEmpty) return null;
  final chinese = RegExp(r'第\s*(\d+)\s*集').firstMatch(text);
  if (chinese != null) return int.tryParse(chinese.group(1)!);
  final seasonEpisode = RegExp(
    r'[sS]\s*\d+\s*[eE]\s*0*(\d+)',
  ).firstMatch(text);
  if (seasonEpisode != null) return int.tryParse(seasonEpisode.group(1)!);
  final ep = RegExp(r'[eE][pP]?\s*0*(\d+)').firstMatch(text);
  if (ep != null) {
    final before = ep.start == 0 ? '' : text[ep.start - 1];
    if (before.isEmpty || !_isAsciiAlphanumeric(before)) {
      return int.tryParse(ep.group(1)!);
    }
  }
  final pure = RegExp(r'^0*(\d+)$').firstMatch(text);
  if (pure != null) return int.tryParse(pure.group(1)!);
  final leading = RegExp(
    r'^0*(\d+)\s*(?:[.、:：]\s*|\s+)(?=\S)',
  ).firstMatch(text);
  if (leading != null) return int.tryParse(leading.group(1)!);
  return null;
}

bool _isAsciiAlphanumeric(String char) {
  final code = char.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A);
}

/// 把可播选集标题与 TMDB 集信息配对，返回与 [playableTitles] 等长、
///
/// 顺序一致的列表，配不上的位置为 null（调用方用兜底图显示）。
/// 先按标题里的集号对号；再把剩余的无集号标题按顺序配对；有集号
/// 但对不上的标题留空（不拿别集的剧照张冠李戴）。每条 TMDB 记录
/// 最多用一次；绝不丢集、不改顺序。季号不参与匹配：TMDB 集列表
/// 只取一季（见 TmdbService.fetchMetadata），同号重复时取先出现的。
List<TmdbEpisode?> matchTmdbEpisodes(
  List<String> playableTitles,
  List<TmdbEpisode> tmdbEpisodes,
) {
  final matched = List<TmdbEpisode?>.filled(playableTitles.length, null);
  if (playableTitles.isEmpty || tmdbEpisodes.isEmpty) return matched;
  final byNumber = <int, int>{};
  for (var i = 0; i < tmdbEpisodes.length; i++) {
    byNumber.putIfAbsent(tmdbEpisodes[i].episodeNumber, () => i);
  }
  final used = <int>{};
  for (var i = 0; i < playableTitles.length; i++) {
    final number = episodeNumberFromTitle(playableTitles[i]);
    if (number == null) continue;
    final index = byNumber[number];
    if (index == null || !used.add(index)) continue;
    matched[i] = tmdbEpisodes[index];
  }
  final leftovers = [
    for (var i = 0; i < tmdbEpisodes.length; i++)
      if (!used.contains(i)) i,
  ];
  var cursor = 0;
  for (var i = 0; i < matched.length; i++) {
    if (matched[i] != null ||
        episodeNumberFromTitle(playableTitles[i]) != null ||
        cursor >= leftovers.length) {
      continue;
    }
    matched[i] = tmdbEpisodes[leftovers[cursor++]];
  }
  return matched;
}
