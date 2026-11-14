import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/tmdb/tmdb_config.dart';
import 'package:moyi/tmdb/tmdb_metadata.dart';
import 'package:moyi/tmdb/tmdb_service.dart';
import 'package:moyi/tmdb/tmdb_settings_page.dart';
import 'package:moyi/viewing_experience_screen.dart';
import 'package:moyi/viewing_experience_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testConfig = TmdbConfig(apiKey: 'TEST_KEY');

  http.Response jsonResponse(Object value) => http.Response.bytes(
    utf8.encode(jsonEncode(value)),
    200,
    headers: {'content-type': 'application/json'},
  );

  Future<SharedPreferences> freshPrefs([
    Map<String, Object> values = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  group('TmdbConfig', () {
    test('defaults match the original structure', () {
      const config = TmdbConfig();
      expect(config.apiBase, 'https://api.themoviedb.org');
      expect(config.imageBase, 'https://image.tmdb.org/t/p');
      expect(config.language, 'zh-CN');
      expect(config.configured, isFalse);
    });

    test('empty key means unconfigured', () {
      expect(const TmdbConfig(apiKey: '  ').configured, isFalse);
      expect(testConfig.configured, isTrue);
    });

    test('search uri carries api key, language and query', () {
      final uri = testConfig.searchMultiUri('测试影片');
      expect(uri.host, 'api.themoviedb.org');
      expect(uri.path, '/3/search/multi');
      expect(uri.queryParameters['api_key'], 'TEST_KEY');
      expect(uri.queryParameters['language'], 'zh-CN');
      expect(uri.queryParameters['query'], '测试影片');
    });

    test('image url validates size and path', () {
      expect(
        testConfig.imageUrl('/p.jpg', size: 'w500'),
        'https://image.tmdb.org/t/p/w500/p.jpg',
      );
      expect(
        testConfig.imageUrl('/b.jpg', size: 'original'),
        'https://image.tmdb.org/t/p/original/b.jpg',
      );
      expect(testConfig.imageUrl('/p.jpg', size: 'huge'), isEmpty);
      expect(testConfig.imageUrl(''), isEmpty);
      expect(testConfig.imageUrl(null), isEmpty);
    });

    test('image url passes absolute urls through unchanged', () {
      // 无 key 源的海报是绝对地址，不拼 TMDB 图床前缀。
      expect(
        testConfig.imageUrl('https://static.tvmaze.com/o.jpg'),
        'https://static.tvmaze.com/o.jpg',
      );
      expect(
        testConfig.imageUrl('http://lain.bgm.tv/pic/cover/l/x.jpg'),
        'http://lain.bgm.tv/pic/cover/l/x.jpg',
      );
    });

    test('save and load round-trip', () async {
      final prefs = await freshPrefs();
      await const TmdbConfig(apiKey: 'TEST_KEY', language: 'en-US').save(prefs);
      final loaded = await TmdbConfig.load(prefs);
      expect(loaded.apiKey, 'TEST_KEY');
      expect(loaded.language, 'en-US');
      expect(loaded.configured, isTrue);
    });
  });

  group('TmdbMetadata helpers', () {
    test('season is stripped from the search title', () {
      expect(baseTitleForSearch('测试剧集 第2季'), '测试剧集');
      expect(baseTitleForSearch('测试剧集 S03E02'), '测试剧集');
      expect(seasonFromTitle('测试剧集 第2季'), 2);
      expect(seasonFromTitle('测试剧集 S03'), 3);
      expect(seasonFromTitle('测试剧集'), isNull);
    });

    test('chinese numerals parse', () {
      expect(parseChineseNumber('十'), 10);
      expect(parseChineseNumber('十二'), 12);
      expect(parseChineseNumber('二十一'), 21);
      expect(parseChineseNumber('3'), 3);
    });

    test('season and episode parse from title', () {
      expect(seasonEpisodeFromTitle('剧名 S01E02'), (season: 1, episode: 2));
      expect(seasonEpisodeFromTitle('剧名 第2季第3集'), (season: 2, episode: 3));
      expect(seasonEpisodeFromTitle('剧名'), isNull);
    });

    test('year comes from the first year in text', () {
      expect(yearFromText('2024-05-01 上线'), '2024');
      expect(yearFromText(''), isNull);
      expect(yearFromText(null), isNull);
    });

    test('media type hint follows category words', () {
      expect(tmdbMediaTypeHint('电影', '无名'), 'movie');
      expect(tmdbMediaTypeHint('国产剧', '无名'), 'tv');
      expect(tmdbMediaTypeHint('短剧', '无名'), isNull);
    });
  });

  group('TmdbService', () {
    test('no key attempts the keyless sources instead of skipping', () async {
      var requests = 0;
      final service = TmdbService(
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
        prefsProvider: () => freshPrefs(),
      );
      final meta = await service.fetchMetadata(
        title: '测试影片',
        config: const TmdbConfig(),
      );
      // 两家无 key 源都探了（TVMaze + Bangumi），都无果才返回 null。
      expect(meta, isNull);
      expect(requests, 2);
    });

    test('movie search, detail and cache hit', () async {
      var requests = 0;
      final prefs = await freshPrefs();
      final service = TmdbService(
        client: MockClient((request) async {
          requests++;
          if (request.url.path == '/3/search/multi') {
            return jsonResponse({
              'results': [
                {
                  'id': 123,
                  'media_type': 'movie',
                  'title': '测试影片',
                  'original_title': 'Test Movie',
                  'release_date': '2024-05-01',
                  'overview': '站源简介',
                  'poster_path': '/p.jpg',
                  'backdrop_path': '/b.jpg',
                  'vote_average': 7.5,
                },
                {
                  'id': 999,
                  'media_type': 'tv',
                  'name': '测试影片',
                  'first_air_date': '2020-01-01',
                  'overview': '',
                  'poster_path': '',
                  'backdrop_path': '',
                },
              ],
            });
          }
          if (request.url.path == '/3/movie/123') {
            return jsonResponse({
              'id': 123,
              'overview': 'TMDB 剧情',
              'poster_path': '/p2.jpg',
              'backdrop_path': '/b2.jpg',
              'runtime': 120,
              'credits': {
                'cast': [
                  {'name': '演员甲', 'character': '主角', 'profile_path': '/c.jpg'},
                ],
              },
              'images': {
                'backdrops': [
                  {'file_path': '/b2.jpg'},
                  {'file_path': '/b3.jpg'},
                ],
              },
              'seasons': [],
            });
          }
          return http.Response('{}', 404);
        }),
        prefsProvider: () async => prefs,
      );
      final meta = await service.fetchMetadata(
        title: '测试影片',
        year: '2024',
        typeHint: 'movie',
        config: testConfig,
        prefs: prefs,
      );
      expect(meta, isNotNull);
      expect(meta!.tmdbId, 123);
      expect(meta.mediaType, 'movie');
      expect(meta.year, '2024');
      expect(meta.overview, 'TMDB 剧情');
      expect(meta.posterUrl(testConfig), contains('/w500/p2.jpg'));
      expect(meta.backdropUrl(testConfig), contains('/w1280/b2.jpg'));
      expect(meta.cast.first.name, '演员甲');
      expect(meta.backdropPaths, ['/b2.jpg', '/b3.jpg']);
      expect(requests, 2);
      final cached = await service.fetchMetadata(
        title: '测试影片',
        year: '2024',
        typeHint: 'movie',
        config: testConfig,
        prefs: prefs,
      );
      expect(cached, isNotNull);
      expect(cached!.overview, 'TMDB 剧情');
      expect(requests, 2, reason: 'second call must hit the local cache');
    });

    test('tv detail loads season episodes for preview', () async {
      final prefs = await freshPrefs();
      final service = TmdbService(
        client: MockClient((request) async {
          if (request.url.path == '/3/search/multi') {
            return jsonResponse({
              'results': [
                {
                  'id': 456,
                  'media_type': 'tv',
                  'name': '测试剧集',
                  'original_name': 'Test Show',
                  'first_air_date': '2023-01-01',
                  'overview': '剧集简介',
                  'poster_path': '/tp.jpg',
                  'backdrop_path': '/tb.jpg',
                  'vote_average': 8.0,
                },
              ],
            });
          }
          if (request.url.path == '/3/tv/456') {
            return jsonResponse({
              'id': 456,
              'overview': '剧集简介',
              'poster_path': '/tp.jpg',
              'backdrop_path': '/tb.jpg',
              'seasons': [
                {'season_number': 1, 'episode_count': 2},
                {'season_number': 2, 'episode_count': 3},
              ],
              'credits': {'cast': []},
              'images': {'backdrops': []},
            });
          }
          if (request.url.path == '/3/tv/456/season/1') {
            return jsonResponse({
              'episodes': [
                {
                  'season_number': 1,
                  'episode_number': 1,
                  'name': '第一集',
                  'overview': '',
                  'still_path': '/s1.jpg',
                  'air_date': '2023-01-01',
                },
                {
                  'season_number': 1,
                  'episode_number': 2,
                  'name': '第二集',
                  'overview': '',
                  'still_path': '',
                  'air_date': '2023-01-08',
                },
              ],
            });
          }
          return http.Response('{}', 404);
        }),
        prefsProvider: () async => prefs,
      );
      final meta = await service.fetchMetadata(
        title: '测试剧集',
        year: '2023',
        typeHint: 'tv',
        config: testConfig,
        prefs: prefs,
      );
      expect(meta, isNotNull);
      expect(meta!.isTv, isTrue);
      expect(meta.episodes.length, 2);
      expect(meta.episodes.first.name, '第一集');
      expect(meta.episodes.last.airDate, '2023-01-08');
    });

    test('year mismatch is a no-match and is cached', () async {
      var requests = 0;
      final prefs = await freshPrefs();
      final service = TmdbService(
        client: MockClient((_) async {
          requests++;
          return jsonResponse({
            'results': [
              {
                'id': 123,
                'media_type': 'movie',
                'title': '测试影片',
                'release_date': '2020-05-01',
                'overview': '',
                'poster_path': '',
                'backdrop_path': '',
              },
            ],
          });
        }),
        prefsProvider: () async => prefs,
      );
      final first = await service.fetchMetadata(
        title: '测试影片',
        year: '2024',
        config: testConfig,
        prefs: prefs,
      );
      expect(first, isNull);
      // TMDB 无果后又探了两家无 key 源（同一 Mock 客户端都回 TMDB
      // 形态数据，两家都认不出），三次请求后写负缓存。
      expect(requests, 3);
      final second = await service.fetchMetadata(
        title: '测试影片',
        year: '2024',
        config: testConfig,
        prefs: prefs,
      );
      expect(second, isNull);
      expect(requests, 3, reason: 'negative result must be cached');
    });

    test('401 surfaces as an invalid key error', () async {
      final prefs = await freshPrefs();
      final service = TmdbService(
        client: MockClient((_) async => http.Response('{}', 401)),
        prefsProvider: () async => prefs,
      );
      await expectLater(
        service.fetchMetadata(title: '测试影片', config: testConfig, prefs: prefs),
        throwsA(
          isA<TmdbConnectionException>().having(
            (e) => e.message,
            'message',
            contains('API Key 无效'),
          ),
        ),
      );
    });

    test('testConnection reports success and failure', () async {
      final ok = TmdbService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await ok.testConnection(testConfig), isTrue);
      final bad = TmdbService(
        client: MockClient((_) async => http.Response('{}', 401)),
      );
      await expectLater(
        bad.testConnection(testConfig),
        throwsA(isA<TmdbConnectionException>()),
      );
      final empty = TmdbService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        empty.testConnection(const TmdbConfig()),
        throwsA(isA<TmdbConnectionException>()),
      );
    });
  });

  group('TmdbService keyless chain', () {
    List<Map<String, dynamic>> tvMazeFixture() => [
      {
        'score': 1.1,
        'show': {
          'id': 169,
          'name': 'Breaking Bad',
          'premiered': '2008-01-20',
          'runtime': 60,
          'rating': {'average': 9.2},
          'image': {
            'medium': 'https://static.tvmaze.com/m.jpg',
            'original': 'https://static.tvmaze.com/o.jpg',
          },
          'summary': '<p><b>Breaking Bad</b> follows Walter.</p>',
        },
      },
    ];

    Map<String, dynamic> bangumiFixture() => {
      'results': 1,
      'list': [
        {
          'id': 55770,
          'type': 2,
          'name': '進撃の巨人',
          'name_cn': '进击的巨人',
          'summary': '人类与巨人的故事',
          'air_date': '2013-04-07',
          'images': {
            'large': 'http://lain.bgm.tv/pic/cover/l/xx.jpg',
            'common': 'http://lain.bgm.tv/pic/cover/c/xx.jpg',
            'medium': 'http://lain.bgm.tv/pic/cover/m/xx.jpg',
          },
        },
      ],
    };

    test('empty key hits TVMaze and maps to TmdbMetadata', () async {
      final prefs = await freshPrefs();
      final hosts = <String>[];
      final service = TmdbService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host == 'api.tvmaze.com') {
            return jsonResponse(tvMazeFixture());
          }
          return jsonResponse({'list': []});
        }),
        prefsProvider: () async => prefs,
      );
      final meta = await service.fetchMetadata(
        title: 'Breaking Bad',
        config: const TmdbConfig(),
        prefs: prefs,
      );
      expect(meta, isNotNull);
      expect(meta!.tmdbId, 0);
      expect(meta.mediaType, 'tv');
      expect(meta.title, 'Breaking Bad');
      expect(meta.year, '2008');
      expect(meta.overview, 'Breaking Bad follows Walter.');
      expect(meta.voteAverage, 9.2);
      expect(
        meta.posterUrl(const TmdbConfig()),
        'https://static.tvmaze.com/o.jpg',
      );
      expect(hosts, ['api.tvmaze.com']);
    });

    test('TVMaze miss falls through to Bangumi', () async {
      final prefs = await freshPrefs();
      final service = TmdbService(
        client: MockClient((request) async {
          if (request.url.host == 'api.tvmaze.com') return jsonResponse([]);
          if (request.url.host == 'api.bgm.tv') {
            return jsonResponse(bangumiFixture());
          }
          return http.Response('{}', 404);
        }),
        prefsProvider: () async => prefs,
      );
      final meta = await service.fetchMetadata(
        title: '进击的巨人',
        config: const TmdbConfig(),
        prefs: prefs,
      );
      expect(meta, isNotNull);
      expect(meta!.title, '进击的巨人');
      expect(meta.originalTitle, '進撃の巨人');
      expect(meta.year, '2013');
      expect(meta.overview, '人类与巨人的故事');
      expect(
        meta.posterUrl(const TmdbConfig()),
        'http://lain.bgm.tv/pic/cover/l/xx.jpg',
      );
    });

    test('keyless failure returns null and is cached', () async {
      var requests = 0;
      final prefs = await freshPrefs();
      final service = TmdbService(
        client: MockClient((_) async {
          requests++;
          throw http.ClientException('boom');
        }),
        prefsProvider: () async => prefs,
      );
      final first = await service.fetchMetadata(
        title: '查不到的剧',
        config: const TmdbConfig(),
        prefs: prefs,
      );
      expect(first, isNull);
      expect(requests, 2);
      final second = await service.fetchMetadata(
        title: '查不到的剧',
        config: const TmdbConfig(),
        prefs: prefs,
      );
      expect(second, isNull);
      expect(requests, 2, reason: 'negative result must be cached');
    });

    test('TMDB miss falls back to the keyless source', () async {
      final prefs = await freshPrefs();
      final hosts = <String>[];
      final service = TmdbService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host == 'api.themoviedb.org') {
            return jsonResponse({'results': []});
          }
          if (request.url.host == 'api.tvmaze.com') {
            return jsonResponse(tvMazeFixture());
          }
          return jsonResponse({'list': []});
        }),
        prefsProvider: () async => prefs,
      );
      final meta = await service.fetchMetadata(
        title: 'Breaking Bad',
        config: testConfig,
        prefs: prefs,
      );
      expect(meta, isNotNull);
      expect(meta!.title, 'Breaking Bad');
      expect(meta.tmdbId, 0, reason: 'result came from the keyless source');
      expect(hosts, ['api.themoviedb.org', 'api.tvmaze.com']);
    });

    test('TMDB hit does not call the keyless sources', () async {
      final prefs = await freshPrefs();
      final hosts = <String>[];
      final service = TmdbService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.path == '/3/search/multi') {
            return jsonResponse({
              'results': [
                {
                  'id': 123,
                  'media_type': 'movie',
                  'title': '测试影片',
                  'release_date': '2024-05-01',
                  'overview': '',
                  'poster_path': '/p.jpg',
                  'backdrop_path': '',
                },
              ],
            });
          }
          if (request.url.path == '/3/movie/123') {
            return jsonResponse({'id': 123, 'overview': '', 'credits': {}});
          }
          return http.Response('{}', 404);
        }),
        prefsProvider: () async => prefs,
      );
      final meta = await service.fetchMetadata(
        title: '测试影片',
        config: testConfig,
        prefs: prefs,
      );
      expect(meta, isNotNull);
      expect(meta!.tmdbId, 123);
      expect(hosts, everyElement('api.themoviedb.org'));
    });

    test('movie hint skips TVMaze but still tries Bangumi', () async {
      final prefs = await freshPrefs();
      final hosts = <String>[];
      final service = TmdbService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          return jsonResponse({'list': []});
        }),
        prefsProvider: () async => prefs,
      );
      final meta = await service.fetchMetadata(
        title: '测试影片',
        typeHint: 'movie',
        config: const TmdbConfig(),
        prefs: prefs,
      );
      expect(meta, isNull);
      expect(hosts, ['api.bgm.tv']);
    });

    test('empty search title makes no request', () async {
      var requests = 0;
      final service = TmdbService(
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
        prefsProvider: () => freshPrefs(),
      );
      final meta = await service.fetchMetadata(
        title: '第2季',
        config: const TmdbConfig(),
      );
      expect(meta, isNull);
      expect(requests, 0);
    });
  });

  group('ViewingExperienceSettings', () {
    test('defaults match the video', () {
      const settings = ViewingExperienceSettings();
      expect(settings.immersive, isTrue);
      expect(settings.detailPosterBackground, isTrue);
      expect(settings.m3u8DownloadWhilePlaying, isFalse);
      expect(settings.deepSniffer, isTrue);
      expect(settings.posterBackgroundActive, isTrue);
    });

    test('poster background needs both immersive and the switch', () {
      expect(
        const ViewingExperienceSettings(
          immersive: false,
        ).posterBackgroundActive,
        isFalse,
      );
      expect(
        const ViewingExperienceSettings(
          detailPosterBackground: false,
        ).posterBackgroundActive,
        isFalse,
      );
    });

    test('save and load round-trip', () async {
      final prefs = await freshPrefs();
      await const ViewingExperienceSettings(
        immersive: false,
        detailPosterBackground: false,
        m3u8DownloadWhilePlaying: true,
        deepSniffer: false,
      ).save(prefs);
      final loaded = await ViewingExperienceSettings.load(prefs);
      expect(loaded.immersive, isFalse);
      expect(loaded.detailPosterBackground, isFalse);
      expect(loaded.m3u8DownloadWhilePlaying, isTrue);
      expect(loaded.deepSniffer, isFalse);
      expect(loaded.posterBackgroundActive, isFalse);
    });
  });

  group('ViewingExperienceScreen', () {
    testWidgets(
      'shows unconfigured tmdb state and persists the poster switch',
      (tester) async {
        final prefs = await freshPrefs();
        final store = LocalStore(prefs);
        addTearDown(store.dispose);
        await tester.pumpWidget(
          MaterialApp(home: ViewingExperienceScreen(store: store)),
        );
        await tester.pumpAndSettle();
        expect(find.text('未配置 apikey'), findsOneWidget);
        expect(find.text('详情页海报背景'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('viewing-detail-poster-switch')),
        );
        await tester.pumpAndSettle();
        expect(prefs.getBool('moyi_viewing_detail_poster_background'), isFalse);
      },
    );
  });

  group('TmdbSettingsPage', () {
    testWidgets('shows the unconfigured empty state', (tester) async {
      await freshPrefs();
      await tester.pumpWidget(const MaterialApp(home: TmdbSettingsPage()));
      await tester.pumpAndSettle();
      expect(find.text('未配置 apikey'), findsOneWidget);
      expect(find.text('TMDB 资料配置'), findsOneWidget);
    });

    testWidgets('test connection reports success with a fake response', (
      tester,
    ) async {
      await freshPrefs();
      final service = TmdbService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await tester.pumpWidget(
        MaterialApp(home: TmdbSettingsPage(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-api-key-field')),
        'TEST_KEY',
      );
      await tester.tap(find.byKey(const ValueKey('tmdb-test-button')));
      await tester.pumpAndSettle();
      expect(find.text('连接成功'), findsOneWidget);
    });

    testWidgets('test connection without a key reports the empty state', (
      tester,
    ) async {
      await freshPrefs();
      final service = TmdbService(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await tester.pumpWidget(
        MaterialApp(home: TmdbSettingsPage(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tmdb-test-button')));
      await tester.pumpAndSettle();
      expect(find.text('请先填写 API Key'), findsOneWidget);
    });
  });
}
