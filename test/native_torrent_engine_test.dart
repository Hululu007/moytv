import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moyi/torrent/native_torrent_engine.dart';
import 'package:moyi/torrent/torrent_bridge.dart';
import 'package:moyi/torrent/torrent_engine.dart';
import 'package:moyi/torrent/torrent_magnet.dart';
import 'package:moyi/torrent/torrent_playback_adapter.dart';
import 'package:moyi/torrent/torrserver_client.dart';

const _hexMagnet =
    'magnet:?xt=urn:btih:FC5353DC585D96AB95E99FD5CCAD7DC690A033EF&dn=Test';
const _hash = 'fc5353dc585d96ab95e99fd5ccad7dc690a033ef';
const _thunderLink = 'thunder://QUJDODgxNTIzNDQ2Mjk=';

class _FakeHttp extends http.BaseClient {
  _FakeHttp(this.handler);

  final Map<String, dynamic> Function(Map<String, dynamic> payload) handler;
  final List<Map<String, dynamic>> posts = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final payload = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(body)) as Map,
    );
    posts.add(payload);
    final response = handler(payload);
    final bytes = utf8.encode(jsonEncode(response));
    return http.StreamedResponse(Stream.value(bytes), 200);
  }
}

Map<String, dynamic> _serverTorrent({bool withFiles = true, int stat = 3}) {
  return {
    'hash': _hash,
    'name': 'Test',
    'stat': stat,
    'file_stats': withFiles
        ? [
            {'id': 0, 'path': 'Test/movie.mp4', 'length': 1000},
            {'id': 1, 'path': 'Test/sub.srt', 'length': 10},
          ]
        : [],
    'download_speed': 1000.0,
    'active_peers': 5,
    'connected_seeders': 2,
    'loaded_size': 500,
  };
}

class _ChannelStub {
  bool serverRunning = true;
  bool serverStartOk = true;
  bool thunderAvailable = true;
  final List<String> calls = [];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'torrserverStatus':
        return {'running': serverRunning, 'port': 8090};
      case 'torrserverStart':
        return {
          'running': serverStartOk,
          'port': 8090,
          if (!serverStartOk) 'error': '子进程起不来',
        };
      case 'torrserverStop':
        return {};
      case 'thunderStatus':
        return {
          'available': thunderAvailable,
          if (!thunderAvailable) 'reason': '迅雷库缺失',
        };
      case 'thunderResolve':
        return {
          'infoHash': _hash,
          'name': 'Thunder Test',
          'size': 2000,
          'files': [
            {'index': 0, 'name': 'a.mp4', 'size': 2000, 'isVideo': true},
          ],
          'taskKey': 'task-1',
          'singleFile': false,
        };
      case 'thunderStreamUrl':
        return {'url': 'http://127.0.0.1:9000/stream/a.mp4'};
      case 'thunderStats':
        return {
          'downloadSpeed': 500,
          'downloaded': 100,
          'total': 2000,
        };
      case 'thunderStop':
        return {};
    }
    return null;
  }
}

NativeTorrentEngine _makeEngine(
  _ChannelStub stub,
  _FakeHttp fakeHttp, {
  Duration metadataTimeout = const Duration(seconds: 60),
}) {
  return NativeTorrentEngine(
    bridge: TorrentBridge(),
    clientBuilder: (baseUrl) =>
        TorrServerClient(baseUrl: baseUrl, httpClient: fakeHttp),
    metadataTimeout: metadataTimeout,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moyi/torrent');
  late _ChannelStub stub;

  setUp(() {
    stub = _ChannelStub();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, stub.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('magnet 走 TorrServer：加种、取流、状态都走 HTTP 客户端', () async {
    final fakeHttp = _FakeHttp((_) => _serverTorrent());
    final engine = _makeEngine(stub, fakeHttp);
    final torrent = await engine.addTorrent(parseMagnetUri(_hexMagnet)!);
    expect(torrent.backendLabel, 'TorrServer');
    expect(torrent.files.length, 2);
    expect(torrent.files.first.isVideo, isTrue);
    final url = await engine.streamUrl(_hash, 0);
    expect(url.path, '/stream');
    expect(url.queryParameters['link'], _hash);
    final stats = await engine.stats(_hash);
    expect(stats.peers, 5);
    expect(stats.hasLiveData, isTrue);
    expect(stub.calls, isNot(contains('thunderResolve')));
  });

  test('thunder 链接只走迅雷，不碰 TorrServer', () async {
    final fakeHttp = _FakeHttp((_) => _serverTorrent());
    final engine = _makeEngine(stub, fakeHttp);
    final magnet = TorrentMagnet(
      uri: _thunderLink,
      infoHash: 'xdeadbeef',
      isBase32Hash: false,
      displayName: '迅雷链接',
    );
    final torrent = await engine.addTorrent(magnet);
    expect(torrent.backendLabel, '迅雷');
    expect(fakeHttp.posts, isEmpty);
    expect(stub.calls, contains('thunderResolve'));
    final url = await engine.streamUrl(_hash, 0);
    expect(url.toString(), 'http://127.0.0.1:9000/stream/a.mp4');
    final files = await engine.files(_hash);
    expect(files.length, 1);
    final stats = await engine.stats(_hash);
    expect(stats.downloadBytesPerSec, 500);
  });

  test('TorrServer 起不来时 magnet 回落迅雷', () async {
    stub.serverRunning = false;
    stub.serverStartOk = false;
    final fakeHttp = _FakeHttp((_) => _serverTorrent());
    final engine = _makeEngine(stub, fakeHttp);
    final torrent = await engine.addTorrent(parseMagnetUri(_hexMagnet)!);
    expect(torrent.backendLabel, '迅雷');
    expect(engine.serverError, contains('子进程起不来'));
  });

  test('两个后端都不可用时启动抛错、带两个真实原因', () async {
    stub.serverRunning = false;
    stub.serverStartOk = false;
    stub.thunderAvailable = false;
    final fakeHttp = _FakeHttp((_) => _serverTorrent());
    final engine = _makeEngine(stub, fakeHttp);
    expect(
      engine.start(),
      throwsA(
        isA<TorrentEngineUnavailable>().having(
          (e) => e.message,
          'message',
          allOf(contains('子进程起不来'), contains('迅雷库缺失')),
        ),
      ),
    );
  });

  test('元数据轮询：第一次没文件、第二次有文件就返回', () async {
    var gets = 0;
    final fakeHttp = _FakeHttp((payload) {
      if (payload['action'] == 'add') return _serverTorrent(withFiles: false);
      gets++;
      return _serverTorrent(withFiles: gets >= 2);
    });
    final engine = _makeEngine(stub, fakeHttp);
    final torrent = await engine.addTorrent(parseMagnetUri(_hexMagnet)!);
    expect(torrent.files.length, 2);
  });

  test('种子被关闭（stat 4）时报明确原因', () async {
    stub.thunderAvailable = false;
    final fakeHttp = _FakeHttp((payload) {
      if (payload['action'] == 'add') return _serverTorrent(withFiles: false);
      return _serverTorrent(withFiles: false, stat: 4);
    });
    final engine = _makeEngine(stub, fakeHttp);
    expect(
      engine.addTorrent(parseMagnetUri(_hexMagnet)!),
      throwsA(
        isA<TorrentEngineUnavailable>().having(
          (e) => e.message,
          'message',
          contains('已关闭该种子'),
        ),
      ),
    );
  });

  test('元数据超时报 Peer/Tracker 原因', () async {
    stub.thunderAvailable = false;
    final fakeHttp = _FakeHttp((_) => _serverTorrent(withFiles: false));
    final engine = _makeEngine(
      stub,
      fakeHttp,
      metadataTimeout: const Duration(milliseconds: 1500),
    );
    expect(
      engine.addTorrent(parseMagnetUri(_hexMagnet)!),
      throwsA(
        isA<TorrentEngineUnavailable>().having(
          (e) => e.message,
          'message',
          contains('没有 Peer'),
        ),
      ),
    );
  });

  test('stop 停迅雷任务与服务', () async {
    final fakeHttp = _FakeHttp((_) => _serverTorrent());
    final engine = _makeEngine(stub, fakeHttp);
    await engine.addTorrent(parseMagnetUri(_hexMagnet)!);
    await engine.stop();
    expect(engine.status, TorrentEngineStatus.stopped);
    expect(stub.calls, contains('torrserverStop'));
  });

  group('适配器 + 假引擎', () {
    test('假引擎下取流走通、未就绪抛状态错', () async {
      final fake = _FakeEngine();
      final adapter = TorrentPlaybackAdapter(engine: fake);
      expect(adapter.isAvailable, isTrue);
      final magnet = parseMagnetUri(_hexMagnet)!;
      final session = TorrentSession(magnet: magnet);
      expect(
        adapter.resolvePlayableUrl(session),
        throwsA(isA<StateError>()),
      );
      session.transitionTo(
        TorrentSessionState.resolvingMetadata,
        engineAvailable: true,
      );
      session.transitionTo(
        TorrentSessionState.ready,
        engineAvailable: true,
      );
      final url = await adapter.resolvePlayableUrl(session);
      expect(url.toString(), 'http://127.0.0.1:8090/stream?link=$_hash');
    });
  });
}

class _FakeEngine implements TorrentEngine {
  @override
  TorrentEngineKind get kind => TorrentEngineKind.torrServer;

  @override
  String get name => '假引擎';

  @override
  TorrentEngineStatus get status => TorrentEngineStatus.running;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<EngineTorrent> addTorrent(TorrentMagnet magnet) async {
    return EngineTorrent(
      infoHash: magnet.infoHash,
      name: magnet.displayName,
      files: const [
        EngineFile(index: 0, name: 'a.mp4', size: 1, isVideo: true),
      ],
    );
  }

  @override
  Future<List<EngineFile>> files(String infoHash) async => const [];

  @override
  Future<Uri> streamUrl(String infoHash, int fileIndex) async {
    return Uri.parse('http://127.0.0.1:8090/stream?link=$infoHash');
  }

  @override
  Future<TorrentStats> stats(String infoHash) async => TorrentStats.empty;
}
