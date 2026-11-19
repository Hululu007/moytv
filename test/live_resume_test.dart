// 直播记忆播放测试草稿（先放工作目录，等能耗协调员完工、
// 树里 LiveLastWatched / LiveStore.rememberLastWatched /
// LivePlaybackController.seekTo 落地后再拷进 test/ 跑）。
// 脚手架抄 test/live_fullscreen_exit_test.dart 的 _ScriptedLiveRepository
// + _FakePlayback 写法；本文件自包含，不 import 别的测试文件。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/live_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

class _ScriptedLiveRepository extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => source.protocol == LiveProtocol.list
      ? [const LivePlatform(id: 'all', name: '全部频道')]
      : [const LivePlatform(id: 'g1', name: '测试分组', count: 2)];

  @override
  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async => [
    LiveChannel(
      key: 'k1',
      name: '频道一',
      urls: const ['https://example.com/a.m3u8'],
      group: platform.name,
      source: source.id,
    ),
    LiveChannel(
      key: 'k2',
      name: '频道二',
      urls: const ['https://example.com/b.m3u8'],
      group: platform.name,
      source: source.id,
    ),
  ];

  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.url);
}

/// 播放控制器替身：load 时真 open（ScriptedPlayer 会把 duration 置
/// 2 分钟、走 position 流），便于测点播续播 seek；seekTo 记调用。
class _FakePlayback extends LivePlaybackController {
  _FakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  final seekCalls = <Duration>[];

  @override
  Player get player => _player;

  @override
  VideoController? get controller => null;

  @override
  LiveSource? get source => _source;

  @override
  List<LiveChannel> get channels => _channels;

  @override
  LiveChannel? get channel =>
      _channels.isEmpty ? null : _channels[_index.clamp(0, _channels.length - 1)];

  @override
  int get index => _index;

  @override
  int get count => _channels.length;

  @override
  bool get loading => false;

  @override
  bool get buffering => false;

  @override
  String? get error => null;

  @override
  bool get ready => true;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Future<void> load(
    LiveSource source,
    List<LiveChannel> channels, {
    int index = 0,
    bool autoplay = true,
  }) async {
    _source = source;
    _channels = List.of(channels);
    _index = channels.isEmpty ? 0 : index.clamp(0, channels.length - 1);
    if (autoplay && _channels.isNotEmpty) {
      await _player.open(Media(_channels[_index].url));
    }
    notifyListeners();
  }

  @override
  Future<void> play(int index, {bool reconnect = false}) async {
    if (_channels.isEmpty) return;
    _index = index.clamp(0, _channels.length - 1);
    await _player.open(Media(_channels[_index].url));
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration position) async {
    seekCalls.add(position);
    await _player.seek(position);
  }

  @override
  void switchBy(int delta) {
    if (_channels.isEmpty) return;
    _index = (_index + delta).clamp(0, _channels.length - 1);
    notifyListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

String _memoryJson({
  String sourceId = 'xiuguo',
  String groupId = 'g1',
  String groupName = '测试分组',
  String channelKey = 'k2',
  String channelName = '频道二',
  int positionMs = 0,
}) => jsonEncode({
  'sourceId': sourceId,
  'groupId': groupId,
  'groupName': groupName,
  'channelKey': channelKey,
  'channelName': channelName,
  'positionMs': positionMs,
  'updatedAtMs': 1795088000000,
});

Future<(_FakePlayback, LiveStore)> _pumpLive(
  WidgetTester tester, {
  Map<String, Object> initialPrefs = const {},
  String initialSourceId = '',
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  final store = LiveStore(prefs, 'default')..load();
  addTearDown(store.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _ScriptedLiveRepository();
  final playback = _FakePlayback(repository: repository);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LiveScreen(
          repository: repository,
          store: store,
          greenMode: false,
          playbackController: playback,
          initialSourceId: initialSourceId,
          videoBuilder: (controller, fullscreen) =>
              const SizedBox(key: ValueKey('test-video')),
        ),
      ),
    ),
  );
  for (
    var i = 0;
    i < 30 && find.byTooltip('全屏与旋转').evaluate().isEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (playback, store);
}

void main() {
  test('记忆存取往返：字段全对、清掉为 null、坏串不抛', () async {
    SharedPreferences.setMockInitialValues({
      'live.lastWatched': _memoryJson(),
    });
    final prefs = await SharedPreferences.getInstance();
    final store = LiveStore(prefs, 'default')..load();
    addTearDown(store.dispose);
    final first = store.lastWatched;
    expect(first?.sourceId, 'xiuguo');
    expect(first?.groupId, 'g1');
    expect(first?.channelKey, 'k2');
    expect(first?.channelName, '频道二');
    expect(first?.positionMs, 0);

    await store.rememberLastWatched(
      sourceId: 'bilibili',
      groupId: 'g9',
      groupName: '分区九',
      channel: const LiveChannel(
        key: 'k9',
        name: '频道九',
        urls: ['https://example.com/c.m3u8'],
      ),
      positionMs: 12345,
    );
    final second = LiveStore(prefs, 'default')..load();
    addTearDown(second.dispose);
    expect(second.lastWatched?.sourceId, 'bilibili');
    expect(second.lastWatched?.channelKey, 'k9');
    expect(second.lastWatched?.positionMs, 12345);

    await second.clearLastWatched();
    expect(second.lastWatched, isNull);
    final third = LiveStore(prefs, 'default')..load();
    addTearDown(third.dispose);
    expect(third.lastWatched, isNull);

    await prefs.setString('live.lastWatched', '{bad json');
    final fourth = LiveStore(prefs, 'default')..load();
    addTearDown(fourth.dispose);
    expect(fourth.lastWatched, isNull);
  });

  testWidgets('进直播自动续播上次频道（不是第一条）', (tester) async {
    final (playback, store) = await _pumpLive(
      tester,
      initialPrefs: {'live.lastWatched': _memoryJson()},
    );
    expect(playback.channel?.key, 'k2');
    expect(playback.channel?.name, '频道二');
    expect(store.lastWatched?.channelKey, 'k2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('记忆频道不在列表：播首频道，失效记忆被新记录顶掉', (tester) async {
    final (playback, store) = await _pumpLive(
      tester,
      initialPrefs: {
        'live.lastWatched': _memoryJson(channelKey: 'kX', channelName: '已下线'),
      },
    );
    expect(playback.channel?.key, 'k1');
    // 失效的 kX 已清；回退播 k1 后记忆重记为 k1，下次进直播续 k1。
    expect(store.lastWatched?.channelKey, 'k1');
    expect(find.byKey(const ValueKey('live-resume-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记忆源已不存在：走首个可见源，失效记忆被新记录顶掉', (tester) async {
    final (playback, store) = await _pumpLive(
      tester,
      initialPrefs: {
        'live.lastWatched': _memoryJson(sourceId: 'deleted_source'),
      },
    );
    expect(playback.source?.id, 'xiuguo');
    expect(playback.channel?.key, 'k1');
    expect(store.lastWatched?.sourceId, 'xiuguo');
    expect(store.lastWatched?.channelKey, 'k1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('记忆分组 id 变了但分组名还在：按名匹配照样续播', (tester) async {
    final (playback, _) = await _pumpLive(
      tester,
      initialPrefs: {'live.lastWatched': _memoryJson(groupId: 'gX')},
    );
    expect(playback.channel?.key, 'k2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('记忆分组彻底没了：播首分组首频道，失效记忆被新记录顶掉', (tester) async {
    final (playback, store) = await _pumpLive(
      tester,
      initialPrefs: {
        'live.lastWatched': _memoryJson(
          groupId: 'gX',
          groupName: '不存在的分组',
        ),
      },
    );
    expect(playback.channel?.key, 'k1');
    expect(store.lastWatched?.channelKey, 'k1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点第二频道后记忆跟上；“上次观看”按钮出现、点后回播', (tester) async {
    // 进直播时已有上次记忆 k2：自动续播 k2，按钮先藏起（正在播它）。
    final (playback, store) = await _pumpLive(
      tester,
      initialPrefs: {'live.lastWatched': _memoryJson()},
    );
    expect(playback.channel?.key, 'k2');
    expect(store.lastWatched?.channelKey, 'k2');
    expect(find.byKey(const ValueKey('live-resume-button')), findsNothing);

    // 切到频道一：记忆跟到 k1；按钮出现，目标仍是进直播那一刻的记忆 k2。
    await tester.tap(find.text('频道一'));
    for (
      var i = 0;
      i < 30 &&
          find.byKey(const ValueKey('live-resume-button')).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(playback.channel?.key, 'k1');
    expect(store.lastWatched?.channelKey, 'k1');
    final button = find.byKey(const ValueKey('live-resume-button'));
    expect(button, findsOneWidget);
    expect(find.text('上次观看：频道二'), findsOneWidget);

    await tester.tap(button);
    for (
      var i = 0;
      i < 30 &&
          find.byKey(const ValueKey('live-resume-button')).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(playback.channel?.key, 'k2');
    expect(find.byKey(const ValueKey('live-resume-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('显式入口源优先于记忆源', (tester) async {
    final (playback, store) = await _pumpLive(
      tester,
      initialPrefs: {'live.lastWatched': _memoryJson()},
      initialSourceId: 'bilibili',
    );
    expect(playback.source?.id, 'bilibili');
    expect(playback.channel?.key, 'k1');
    // 入口是一次性导航，记忆被当次实际播放覆盖（bilibili 首频道）。
    expect(store.lastWatched?.sourceId, 'bilibili');
    // “上次观看”按钮仍指向上次记忆（秀果/频道二），点后跨源续播。
    final button = find.byKey(const ValueKey('live-resume-button'));
    expect(button, findsOneWidget);
    expect(find.text('上次观看：频道二'), findsOneWidget);
    await tester.tap(button);
    for (
      var i = 0;
      i < 30 &&
          find.byKey(const ValueKey('live-resume-button')).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(playback.source?.id, 'xiuguo');
    expect(playback.channel?.key, 'k2');
    expect(find.byKey(const ValueKey('live-resume-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点播续播带位置：seek 到 45 秒；直播源不 seek', (tester) async {
    final (playback, _) = await _pumpLive(
      tester,
      initialPrefs: {
        'live.lastWatched': _memoryJson(
          sourceId: 'user_m3u',
          groupId: 'all',
          groupName: '全部频道',
          positionMs: 45000,
        ),
      },
    );
    expect(playback.channel?.key, 'k2');
    expect(playback.seekCalls, [const Duration(seconds: 45)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('直播源记忆即使带位置也不 seek', (tester) async {
    final (playback, _) = await _pumpLive(
      tester,
      initialPrefs: {'live.lastWatched': _memoryJson(positionMs: 45000)},
    );
    expect(playback.channel?.key, 'k2');
    expect(playback.seekCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点播播放中位置节流写记忆（每推进 10 秒媒体进度写一次）', (tester) async {
    final (playback, store) = await _pumpLive(
      tester,
      initialPrefs: {
        'live.lastWatched': _memoryJson(
          sourceId: 'user_m3u',
          groupId: 'all',
          groupName: '全部频道',
          channelKey: 'k1',
          channelName: '频道一',
        ),
      },
    );
    expect(playback.channel?.key, 'k1');
    await playback.player.seek(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.lastWatched?.positionMs, 30000);
    await playback.player.seek(const Duration(seconds: 31));
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.lastWatched?.positionMs, 30000);
    await playback.player.seek(const Duration(seconds: 45));
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.lastWatched?.positionMs, 45000);
    await playback.player.seek(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.lastWatched?.positionMs, 10000);
    expect(tester.takeException(), isNull);
  });
}
