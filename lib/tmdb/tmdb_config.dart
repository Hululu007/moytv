import 'package:shared_preferences/shared_preferences.dart';

class TmdbConfig {
  const TmdbConfig({
    this.apiKey = '',
    this.apiBase = TmdbConfig.defaultApiBase,
    this.imageBase = TmdbConfig.defaultImageBase,
    this.language = 'zh-CN',
  });

  static const String defaultApiBase = 'https://api.themoviedb.org';
  static const String defaultImageBase = 'https://image.tmdb.org/t/p';

  static const String keyApiKey = 'moyi_tmdb_api_key';
  static const String keyApiBase = 'moyi_tmdb_api_base';
  static const String keyImageBase = 'moyi_tmdb_image_base';
  static const String keyLanguage = 'moyi_tmdb_language';

  final String apiKey;
  final String apiBase;
  final String imageBase;
  final String language;

  bool get configured => apiKey.trim().isNotEmpty;

  static bool isValidHttpBase(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static bool isValidLanguage(String value) =>
      RegExp(r'^[a-z]{2}(-[A-Z]{2})?$').hasMatch(value.trim());

  static String normalizeBase(String value, String fallback) {
    final trimmed = value.trim();
    if (!isValidHttpBase(trimmed)) return fallback;
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Uri get apiBaseUri => Uri.parse(normalizeBase(apiBase, defaultApiBase));

  Uri get imageBaseUri => Uri.parse(normalizeBase(imageBase, defaultImageBase));

  Map<String, String> get _authParams => {
    'api_key': apiKey.trim(),
    'language': language.trim().isEmpty ? 'zh-CN' : language.trim(),
  };

  Uri searchMultiUri(String query) => apiBaseUri.replace(
    path: '/3/search/multi',
    queryParameters: {..._authParams, 'query': query, 'page': '1'},
  );

  Uri detailUri(String mediaType, int tmdbId) => apiBaseUri.replace(
    path: '/3/$mediaType/$tmdbId',
    queryParameters: {..._authParams, 'append_to_response': 'credits,images'},
  );

  Uri seasonUri(int tmdbId, int seasonNumber) => apiBaseUri.replace(
    path: '/3/tv/$tmdbId/season/$seasonNumber',
    queryParameters: {..._authParams},
  );

  Uri configurationUri() => apiBaseUri.replace(
    path: '/3/configuration',
    queryParameters: _authParams,
  );

  String imageUrl(String? path, {String size = 'w500'}) {
    if (path == null || path.isEmpty) return '';
    // 无 key 刮削源（TVMaze/Bangumi）给的是绝对地址，原样返回，
    // 不拼 TMDB 图床前缀；TMDB 自身的相对路径才走下面拼装。
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    if (!RegExp(r'^(w\d+|original)$').hasMatch(size)) return '';
    final base = imageBaseUri.toString();
    final clean = path.startsWith('/') ? path : '/$path';
    return '$base/$size$clean';
  }

  TmdbConfig copyWith({
    String? apiKey,
    String? apiBase,
    String? imageBase,
    String? language,
  }) => TmdbConfig(
    apiKey: apiKey ?? this.apiKey,
    apiBase: apiBase ?? this.apiBase,
    imageBase: imageBase ?? this.imageBase,
    language: language ?? this.language,
  );

  Map<String, dynamic> toJson() => {
    'apiKey': apiKey,
    'apiBase': apiBase,
    'imageBase': imageBase,
    'language': language,
  };

  factory TmdbConfig.fromJson(Map<String, dynamic> value) => TmdbConfig(
    apiKey: value['apiKey'] as String? ?? '',
    apiBase: normalizeBase(
      value['apiBase'] as String? ?? defaultApiBase,
      defaultApiBase,
    ),
    imageBase: normalizeBase(
      value['imageBase'] as String? ?? defaultImageBase,
      defaultImageBase,
    ),
    language: isValidLanguage(value['language'] as String? ?? '')
        ? (value['language'] as String)
        : 'zh-CN',
  );

  static Future<TmdbConfig> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    return TmdbConfig(
      apiKey: store.getString(keyApiKey) ?? '',
      apiBase: normalizeBase(
        store.getString(keyApiBase) ?? defaultApiBase,
        defaultApiBase,
      ),
      imageBase: normalizeBase(
        store.getString(keyImageBase) ?? defaultImageBase,
        defaultImageBase,
      ),
      language: isValidLanguage(store.getString(keyLanguage) ?? '')
          ? store.getString(keyLanguage)!
          : 'zh-CN',
    );
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setString(keyApiKey, apiKey.trim());
    await store.setString(keyApiBase, normalizeBase(apiBase, defaultApiBase));
    await store.setString(
      keyImageBase,
      normalizeBase(imageBase, defaultImageBase),
    );
    await store.setString(
      keyLanguage,
      isValidLanguage(language) ? language.trim() : 'zh-CN',
    );
  }
}
