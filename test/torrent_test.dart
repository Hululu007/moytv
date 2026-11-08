import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/torrent/torrent_engine.dart';
import 'package:moyi/torrent/torrent_home_screen.dart';
import 'package:moyi/torrent/torrent_magnet.dart';
import 'package:moyi/torrent/torrent_playback_adapter.dart';
import 'package:moyi/torrent/torrent_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const hexMagnet =
      'magnet:?xt=urn:btih:FC5353DC585D96AB95E99FD5CCAD7DC690A033EF&dn=%5Bjavdb.com%5DBBSS-106&tr=udp%3A%2F%2Ftracker.example.com%3A1337&tr=udp%3A%2F%2Ftracker2.example.com%3A80';
  const base32Magnet =
      'magnet:?xt=urn:btih:MFRGGZDFMZTWQ2LKNNWG23TPOJQXE4A7&dn=test';
  const noHashMagnet = 'magnet:?dn=test';

  Future<SharedPreferences> freshPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  group('parseMagnetUri', () {
    test('40 位十六进制哈希解析并转小写', () {
      final parsed = parseMagnetUri(hexMagnet);
      expect(parsed, isNotNull);
      expect(
        parsed!.infoHash,
        'fc5353dc585d96ab95e99fd5ccad7dc690a033ef',
      );
      expect(parsed.isBase32Hash, isFalse);
      expect(parsed.displayName, '[javdb.com]BBSS-106');
      expect(parsed.trackers, [
        'udp://tracker.example.com:1337',
        'udp://tracker2.example.com:80',
      ]);
      expect(parsed.shortHash, 'fc5353dc');
      expect(parsed.nameOrHash, '[javdb.com]BBSS-106');
    });

    test('32 位 Base32 哈希解析并转大写', () {
      final parsed = parseMagnetUri(base32Magnet);
      expect(parsed, isNotNull);
      expect(parsed!.infoHash, 'MFRGGZDFMZTWQ2LKNNWG23TPOJQXE4A7');
      expect(parsed.isBase32Hash, isTrue);
    });

    test('无 xt 或哈希不对都返回空', () {
      expect(parseMagnetUri(noHashMagnet), isNull);
      expect(parseMagnetUri('https://example.com/a.torrent'), isNull);
      expect(parseMagnetUri('magnet:?xt=urn:btih:abc'), isNull);
      expect(parseMagnetUri(''), isNull);
      expect(parseMagnetUri('  $hexMagnet  '), isNotNull);
    });

    test('isMagnetLink 只认 magnet: 开头', () {
      expect(isMagnetLink(hexMagnet), isTrue);
      expect(isMagnetLink('MAGNET:?xt=urn:btih:abc'), isTrue);
      expect(isMagnetLink('thunder://abc'), isFalse);
    });

    test('从站内 MagnetLink 模型解析', () {
      const link = MagnetLink(
        name: '站内名',
        url: hexMagnet,
        sizeLabel: '1.2 GB',
        quality: '1080p',
      );
      final parsed = TorrentMagnet.fromMagnetLink(link);
      expect(parsed.infoHash, 'fc5353dc585d96ab95e99fd5ccad7dc690a033ef');
      expect(parsed.displayName, '[javdb.com]BBSS-106');
    });
  });

  group('torrentLinkKind', () {
    test('磁力/迅雷/ed2k/种子文件分得清', () {
      expect(torrentLinkKind(hexMagnet), TorrentLinkKind.magnet);
      expect(torrentLinkKind('thunder://abc'), TorrentLinkKind.thunder);
      expect(torrentLinkKind('ed2k://|file|a|1|hash|/'), TorrentLinkKind.ed2k);
      expect(
        torrentLinkKind('https://example.com/a.torrent'),
        TorrentLinkKind.torrentFile,
      );
      expect(torrentLinkKind('https://example.com/a.mp4'), TorrentLinkKind.other);
      expect(isTorrentLink(hexMagnet), isTrue);
      expect(isTorrentLink('https://example.com/a.mp4'), isFalse);
    });
  });

  group('TorrentSession 状态机', () {
    TorrentSession savedSession() => TorrentSession(
      magnet: parseMagnetUri(hexMagnet)!,
    );

    test('无引擎时解析转态抛未接入错、状态不动', () {
      final session = savedSession();
      expect(
        () => session.transitionTo(
          TorrentSessionState.resolvingMetadata,
          engineAvailable: false,
        ),
        throwsA(isA<TorrentEngineUnavailable>()),
      );
      expect(session.state, TorrentSessionState.saved);
    });

    test('非法转态抛 StateError', () {
      final session = savedSession();
      expect(
        () => session.transitionTo(
          TorrentSessionState.ready,
          engineAvailable: true,
        ),
        throwsStateError,
      );
      expect(
        () => session.transitionTo(
          TorrentSessionState.streaming,
          engineAvailable: true,
        ),
        throwsStateError,
      );
    });

    test('有引擎时合法链路走得通，失败后可重试', () {
      final session = savedSession();
      session.transitionTo(
        TorrentSessionState.resolvingMetadata,
        engineAvailable: true,
      );
      session.transitionTo(
        TorrentSessionState.ready,
        engineAvailable: true,
      );
      session.transitionTo(
        TorrentSessionState.streaming,
        engineAvailable: true,
      );
      session.transitionTo(
        TorrentSessionState.stopped,
        engineAvailable: true,
      );
      session.transitionTo(
        TorrentSessionState.resolvingMetadata,
        engineAvailable: true,
      );
      session.markFailed('超时');
      expect(session.state, TorrentSessionState.failed);
      expect(session.error, '超时');
      session.transitionTo(
        TorrentSessionState.resolvingMetadata,
        engineAvailable: true,
      );
      expect(session.state, TorrentSessionState.resolvingMetadata);
      expect(session.error, isEmpty);
    });

    test('保存/读回往返，解析中与播放中态回落为已保存', () {
      final session = savedSession();
      final restored = TorrentSession.fromJson(session.toJson());
      expect(restored.id, session.id);
      expect(restored.state, TorrentSessionState.saved);
      final streaming = TorrentSession.fromJson({
        'magnet': session.magnet.toJson(),
        'state': 'streaming',
        'addedAt': 0,
        'updatedAt': 0,
      });
      expect(streaming.state, TorrentSessionState.saved);
    });
  });

  group('引擎未接入', () {
    test('工厂造出的就是未接入引擎', () {
      expect(TorrentEngineFactory.isEngineAvailable, isFalse);
      final engine = TorrentEngineFactory.create();
      expect(engine.kind, TorrentEngineKind.none);
      expect(engine.status, TorrentEngineStatus.unavailable);
      expect(TorrentEngineFactory.missingPieces.length, 3);
    });

    test('启动/加种/取流都抛未接入错，查状态给空数据不编假数', () async {
      const engine = UnavailableTorrentEngine();
      expect(engine.start, throwsA(isA<TorrentEngineUnavailable>()));
      expect(
        engine.addTorrent(parseMagnetUri(hexMagnet)!),
        throwsA(isA<TorrentEngineUnavailable>()),
      );
      expect(
        engine.streamUrl('abc', 0),
        throwsA(isA<TorrentEngineUnavailable>()),
      );
      expect((await engine.stats('abc')).hasLiveData, isFalse);
      expect(TorrentStats.empty.hasLiveData, isFalse);
    });

    test('播放适配器：磁力认、普通链接不认、无引擎取流抛错', () async {
      final adapter = TorrentPlaybackAdapter();
      expect(adapter.isAvailable, isFalse);
      expect(adapter.canHandle(hexMagnet), isTrue);
      expect(adapter.canHandle('https://example.com/a.mp4'), isFalse);
      final session = TorrentSession(magnet: parseMagnetUri(hexMagnet)!);
      expect(
        adapter.resolvePlayableUrl(session),
        throwsA(isA<TorrentEngineUnavailable>()),
      );
    });
  });

  group('TorrentSessionStore', () {
    test('保存/读回/去重/删除往返', () async {
      final prefs = await freshPrefs();
      final store = TorrentSessionStore(prefs);
      expect(await store.load(prefs), isEmpty);
      final magnet = parseMagnetUri(hexMagnet)!;
      var sessions = await store.add(magnet);
      expect(sessions.length, 1);
      sessions = await store.add(magnet);
      expect(sessions.length, 1);
      final reloaded = await TorrentSessionStore(prefs).load(prefs);
      expect(reloaded.length, 1);
      expect(reloaded.first.id, magnet.infoHash);
      sessions = await store.remove(magnet.infoHash);
      expect(sessions, isEmpty);
    });

    test('坏数据不崩、读回空', () async {
      final prefs = await freshPrefs();
      await prefs.setString(TorrentSessionStore.keySessions, 'not json');
      expect(await TorrentSessionStore(prefs).load(prefs), isEmpty);
    });
  });

  group('TorrentHomePage', () {
    testWidgets('未接入空态与磁力解析、保存', (tester) async {
      await freshPrefs();
      await tester.pumpWidget(
        const MaterialApp(home: TorrentHomePage()),
      );
      await tester.pumpAndSettle();
      expect(find.text('种子引擎未接入'), findsOneWidget);
      expect(find.text('还没有保存的种子：粘贴磁力链接解析后保存'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('torrent-magnet-input')),
        hexMagnet,
      );
      await tester.pump();
      expect(find.textContaining('[javdb.com]BBSS-106'), findsWidgets);
      expect(
        find.textContaining('fc5353dc585d96ab95e99fd5ccad7dc690a033ef'),
        findsOneWidget,
      );

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('[javdb.com]BBSS-106'), findsWidgets);
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('无效磁力链接报明确错误', (tester) async {
      await freshPrefs();
      await tester.pumpWidget(
        const MaterialApp(home: TorrentHomePage()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('torrent-magnet-input')),
        'https://example.com/a.mp4',
      );
      await tester.pump();
      expect(find.textContaining('不是有效的磁力链接'), findsOneWidget);
    });

    testWidgets('带初始磁力链接进页直接解析出名字', (tester) async {
      await freshPrefs();
      await tester.pumpWidget(
        const MaterialApp(home: TorrentHomePage(initialMagnet: hexMagnet)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('[javdb.com]BBSS-106'), findsWidgets);
    });
  });
}
