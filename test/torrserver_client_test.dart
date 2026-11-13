import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moyi/torrent/torrent_engine.dart';
import 'package:moyi/torrent/torrserver_client.dart';

class _FakeHttp extends http.BaseClient {
  _FakeHttp(this.handler);

  final http.Response Function(http.BaseRequest request) handler;
  final List<Map<String, dynamic>> posts = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is Map) posts.add(Map<String, dynamic>.from(decoded));
    final response = handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

Map<String, dynamic> _torrentJson({
  String hash = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
  int stat = 3,
  List<Map<String, dynamic>>? files,
}) {
  return {
    'hash': hash,
    'name': 'Test Movie',
    'stat': stat,
    'file_stats':
        files ??
        [
          {'id': 1, 'path': 'Test Movie/movie.mp4', 'length': 1000},
          {'id': 0, 'path': 'Test Movie/cover.jpg', 'length': 10},
        ],
    'download_speed': 123456.0,
    'active_peers': 7,
    'pending_peers': 2,
    'connected_seeders': 3,
    'loaded_size': 500,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('add 解析状态：文件按 id 排，哈希转小写，转引擎对象带 TorrServer 标签', () async {
    final httpClient = _FakeHttp(
      (_) => http.Response(jsonEncode(_torrentJson()), 200),
    );
    final client = TorrServerClient(
      baseUrl: 'http://127.0.0.1:8090',
      httpClient: httpClient,
    );
    final torrent = await client.add(link: 'magnet:?xt=urn:btih:ABCDEF01');
    expect(torrent.hash, 'abcdef0123456789abcdef0123456789abcdef01');
    expect(torrent.stat, 3);
    expect(torrent.files.map((f) => f.id), [0, 1]);
    expect(torrent.files[1].displayName, 'movie.mp4');
    expect(torrent.hasMetadata, isTrue);
    final engine = torrent.toEngineTorrent();
    expect(engine.backendLabel, 'TorrServer');
    expect(engine.files[1].isVideo, isTrue);
    expect(engine.files[0].isVideo, isFalse);
    expect(engine.size, 1010);
    expect(httpClient.posts.single['action'], 'add');
  });

  test('get/list/remove 发对 action，list 空响应给空列表', () async {
    final httpClient = _FakeHttp((request) {
      return http.Response(jsonEncode([_torrentJson()]), 200);
    });
    final client = TorrServerClient(
      baseUrl: 'http://127.0.0.1:8090',
      httpClient: httpClient,
    );
    final listed = await client.list();
    expect(listed.length, 1);
    await client.remove('abcdef01');
    expect(
      httpClient.posts.map((p) => p['action']),
      ['list', 'rem'],
    );
    expect(httpClient.posts[1]['hash'], 'abcdef01');
    final emptyClient = TorrServerClient(
      baseUrl: 'http://127.0.0.1:8090',
      httpClient: _FakeHttp((_) => http.Response('{}', 200)),
    );
    expect(await emptyClient.list(), isEmpty);
  });

  test('streamUri 拼对参数', () {
    final client = TorrServerClient(baseUrl: 'http://127.0.0.1:8090');
    final uri = client.streamUri('abcdef01', 2);
    expect(uri.path, '/stream');
    expect(uri.queryParameters, {
      'link': 'abcdef01',
      'index': '2',
      'play': '1',
    });
  });

  test('toStats 进度按 loaded/total，Peer 与种子数透传', () {
    final torrent = TorrServerTorrent.fromJson(_torrentJson());
    final stats = torrent.toStats();
    expect(stats.progress, closeTo(500 / 1010, 0.001));
    expect(stats.peers, 7);
    expect(stats.seeds, 3);
    expect(stats.downloadBytesPerSec, 123456);
    expect(stats.hasLiveData, isTrue);
  });

  test('HTTP 错误报状态码', () async {
    final client = TorrServerClient(
      baseUrl: 'http://127.0.0.1:8090',
      httpClient: _FakeHttp((_) => http.Response('nope', 500)),
    );
    expect(
      client.add(link: 'magnet:?xt=urn:btih:ABCDEF01'),
      throwsA(
        isA<TorrentEngineUnavailable>().having(
          (e) => e.message,
          'message',
          contains('HTTP 500'),
        ),
      ),
    );
  });

  test('空响应与非 JSON 响应报明确原因', () async {
    final empty = TorrServerClient(
      baseUrl: 'http://127.0.0.1:8090',
      httpClient: _FakeHttp((_) => http.Response('', 200)),
    );
    expect(
      empty.get('x'),
      throwsA(
        isA<TorrentEngineUnavailable>().having(
          (e) => e.message,
          'message',
          contains('空响应'),
        ),
      ),
    );
    final garbage = TorrServerClient(
      baseUrl: 'http://127.0.0.1:8090',
      httpClient: _FakeHttp((_) => http.Response('not json{{', 200)),
    );
    expect(
      garbage.get('x'),
      throwsA(
        isA<TorrentEngineUnavailable>().having(
          (e) => e.message,
          'message',
          contains('不是 JSON'),
        ),
      ),
    );
  });

  test('连不上服务报地址与原因', () async {
    final client = TorrServerClient(
      baseUrl: 'http://127.0.0.1:8090',
      httpClient: _FakeHttp(
        (_) => throw http.ClientException('connection refused'),
      ),
    );
    expect(
      client.get('x'),
      throwsA(
        isA<TorrentEngineUnavailable>().having(
          (e) => e.message,
          'message',
          allOf(contains('连不上本地 TorrServer'), contains('127.0.0.1:8090')),
        ),
      ),
    );
  });

  test('字段缺失时容忍：空对象不崩、没元数据', () {
    final torrent = TorrServerTorrent.fromJson({});
    expect(torrent.hash, isEmpty);
    expect(torrent.hasMetadata, isFalse);
    expect(torrent.toStats().hasLiveData, isFalse);
    expect(torrent.toEngineTorrent().files, isEmpty);
  });
}
