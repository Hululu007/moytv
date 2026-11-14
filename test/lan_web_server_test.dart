import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/lan_web/lan_web_server.dart';
import 'package:moyi/models.dart';

class FakeDataSource implements LanWebDataSource {
  final sites = [
    SourceSite('missav', 'MissAV', '', section: SourceSite.sectionVideo),
    SourceSite('cloud:pan115', '115网盘', '', section: SourceSite.sectionVideo),
  ];

  Drama get drama => const Drama(
        id: 'missav:abc',
        source: 'missav',
        title: '测试影片',
        cover: 'https://cdn.example.com/cover.jpg',
      );

  @override
  Future<List<SourceSite>> visibleSites() async => sites;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
  }) async {
    if (query.isNotEmpty) {
      return CatalogPage([drama], hasMore: false, page: page);
    }
    return CatalogPage([drama], hasMore: page < 2, page: page);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(
        drama,
        [Episode({'id': 'e1', 'title': '第1集'}, 1)],
        tags: [const DetailTag(id: 'k', name: '视频')],
      );

  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) async {
    if (episode.id == 'cenc') {
      return PlaybackPlan(
        url: 'https://cdn.example.com/enc.m3u8',
        decryptionKey: '00112233445566778899aabbccddeeff',
      );
    }
    if (episode.id == 'novel') {
      return PlaybackPlan(url: 'novel://{"title":"书"}');
    }
    return PlaybackPlan(
      url: 'https://cdn.example.com/play.m3u8',
      headers: {'Referer': 'https://site.example/'},
    );
  }

  @override
  Future<CatalogPage> searchAcross(String query) async =>
      CatalogPage([drama], hasMore: false);

  @override
  Future<List<HaikuoProgramSummary>> haikuoPrograms() async =>
      const [HaikuoProgramSummary(id: 'h1', name: '海阔规则一')];

  @override
  List<CloudDriveStatus> cloudDriveStatuses() => const [
        CloudDriveStatus(id: 'pan115', name: '115网盘', loggedIn: true),
        CloudDriveStatus(id: 'quark', name: '夸克网盘', loggedIn: false),
      ];
}

void main() {
  late LanWebServer server;
  late HttpClient client;
  late String base;

  setUp(() async {
    server = LanWebServer(dataSource: FakeDataSource());
    final port = await server.start(port: 0);
    base = 'http://127.0.0.1:$port';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    server.dispose();
  });

  Future<(int, String)> get(String path) async {
    final request = await client.getUrl(Uri.parse('$base$path'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, body);
  }

  String encodeDrama(Drama drama) =>
      base64Url.encode(utf8.encode(jsonEncode(drama.toJson())));

  String encodeEpisode(Episode episode) => base64Url.encode(
        utf8.encode(jsonEncode({'raw': episode.raw, 'fallback': 1})),
      );

  group('局域网服务', () {
    test('启动后 running，端口为实际绑定端口', () {
      expect(server.running, isTrue);
      expect(server.boundPort, greaterThan(0));
    });

    test('首页列出站源与海阔规则名', () async {
      final (status, body) = await get('/');
      expect(status, HttpStatus.ok);
      expect(body, contains('MissAV'));
      expect(body, contains('115网盘'));
      expect(body, contains('海阔规则一'));
      expect(body, contains('魔蚁'));
    });

    test('/api/sites 返回站源 JSON', () async {
      final (status, body) = await get('/api/sites');
      expect(status, HttpStatus.ok);
      final decoded = jsonDecode(body) as Map;
      final sites = decoded['sites'] as List;
      expect(sites.length, 2);
      expect(sites.map((s) => s['id']), containsAll(['missav', 'cloud:pan115']));
    });

    test('/api/catalog 返回目录 JSON', () async {
      final (status, body) = await get('/api/catalog?source=missav&page=1');
      expect(status, HttpStatus.ok);
      final decoded = jsonDecode(body) as Map;
      expect((decoded['items'] as List).length, 1);
      expect(decoded['hasMore'], isTrue);
      expect(decoded['page'], 1);
    });

    test('/api/catalog 支持搜索参数', () async {
      final (status, body) = await get('/api/catalog?source=missav&q=%E6%B5%8B%E8%AF%95');
      expect(status, HttpStatus.ok);
      expect(jsonDecode(body)['items'], hasLength(1));
    });

    test('/api/detail 返回详情 JSON', () async {
      const drama = Drama(id: 'missav:abc', source: 'missav', title: '测试影片');
      final (status, body) = await get('/api/detail?drama=${Uri.encodeComponent(encodeDrama(drama))}');
      expect(status, HttpStatus.ok);
      final decoded = jsonDecode(body) as Map;
      expect((decoded['episodes'] as List).length, 1);
      expect((decoded['tags'] as List).first['name'], '视频');
    });

    test('/api/detail 参数无效时返回 error', () async {
      final (status, body) = await get('/api/detail?drama=!!!');
      expect(status, HttpStatus.ok);
      expect(jsonDecode(body)['error'], isNotNull);
    });

    test('/api/resolve 返回网关地址', () async {
      const drama = Drama(id: 'missav:abc', source: 'missav', title: '测试影片');
      final episode = Episode({'id': 'e1', 'title': '第1集'}, 1);
      final (status, body) = await get(
        '/api/resolve?drama=${Uri.encodeComponent(encodeDrama(drama))}&episode=${Uri.encodeComponent(encodeEpisode(episode))}',
      );
      expect(status, HttpStatus.ok);
      final decoded = jsonDecode(body) as Map;
      expect(decoded['playable'], isTrue);
      expect(decoded['url'], contains('/stream?url='));
      expect(decoded['url'], contains('play.m3u8'));
    });

    test('/api/resolve 加密计划不可播并说明原因', () async {
      const drama = Drama(id: 'missav:abc', source: 'missav', title: '测试影片');
      final episode = Episode({'id': 'cenc', 'title': '加密'}, 1);
      final (status, body) = await get(
        '/api/resolve?drama=${Uri.encodeComponent(encodeDrama(drama))}&episode=${Uri.encodeComponent(encodeEpisode(episode))}',
      );
      expect(status, HttpStatus.ok);
      final decoded = jsonDecode(body) as Map;
      expect(decoded['playable'], isFalse);
      expect(decoded['reason'], isNotEmpty);
    });

    test('/api/resolve 非视频协议不可播', () async {
      const drama = Drama(id: 'missav:abc', source: 'missav', title: '测试影片');
      final episode = Episode({'id': 'novel', 'title': '小说'}, 1);
      final (_, body) = await get(
        '/api/resolve?drama=${Uri.encodeComponent(encodeDrama(drama))}&episode=${Uri.encodeComponent(encodeEpisode(episode))}',
      );
      expect(jsonDecode(body)['playable'], isFalse);
    });

    test('/api/search 返回搜索结果', () async {
      final (status, body) = await get('/api/search?q=%E6%B5%8B%E8%AF%95');
      expect(status, HttpStatus.ok);
      expect((jsonDecode(body)['items'] as List).length, 1);
    });

    test('/drives 列出网盘登录状态', () async {
      final (status, body) = await get('/drives');
      expect(status, HttpStatus.ok);
      expect(body, contains('115网盘'));
      expect(body, contains('夸克网盘'));
    });

    test('/list 列表页含卡片', () async {
      final (status, body) = await get('/list?source=missav');
      expect(status, HttpStatus.ok);
      expect(body, contains('测试影片'));
    });

    test('/detail 详情页含选集', () async {
      const drama = Drama(id: 'missav:abc', source: 'missav', title: '测试影片');
      final (status, body) = await get('/detail?drama=${Uri.encodeComponent(encodeDrama(drama))}');
      expect(status, HttpStatus.ok);
      expect(body, contains('第1集'));
    });

    test('/watch 播放页含 video 标签', () async {
      const drama = Drama(id: 'missav:abc', source: 'missav', title: '测试影片');
      final episode = Episode({'id': 'e1', 'title': '第1集'}, 1);
      final (status, body) = await get(
        '/watch?drama=${Uri.encodeComponent(encodeDrama(drama))}&episode=${Uri.encodeComponent(encodeEpisode(episode))}',
      );
      expect(status, HttpStatus.ok);
      expect(body, contains('<video'));
    });

    test('未知路径 404', () async {
      final (status, _) = await get('/nope');
      expect(status, HttpStatus.notFound);
    });

    test('/stream 拦截回环目标', () async {
      final (status, _) = await get('/stream?url=${Uri.encodeComponent('http://127.0.0.1:1/x.mp4')}');
      expect(status, HttpStatus.badRequest);
    });

    test('/cover 拦截回环目标', () async {
      final (status, _) = await get('/cover?url=${Uri.encodeComponent('http://127.0.0.1:1/x.jpg')}');
      expect(status, HttpStatus.badRequest);
    });

    test('/cover 非 http(s) 地址 400', () async {
      final (status, _) = await get('/cover?url=${Uri.encodeComponent('ftp://x/y.jpg')}');
      expect(status, HttpStatus.badRequest);
    });
  });

  group('LanWebController', () {
    test('start/stop 切换网关状态', () async {
      final controller = LanWebController(FakeDataSource());
      final port = await controller.start(0);
      expect(port, greaterThan(0));
      expect(controller.running, isTrue);
      await controller.stop();
      expect(controller.running, isFalse);
    });
  });
}
