import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:moyi/app_orientation.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_player_screen.dart';
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
  }) async => [
    const LivePlatform(id: 'g1', name: '测试分组', count: 2),
  ];

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
      group: '测试分组',
      source: source.id,
    ),
    LiveChannel(
      key: 'k2',
      name: '频道二',
      urls: const ['https://example.com/b.m3u8'],
      group: '测试分组',
      source: source.id,
    ),
  ];

  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.url);
}

/// 播放控制器替身：真实 VideoController 在测试环境建不起来（原生
/// libmpv 不在），这里只保留接线用的状态，画面走 videoBuilder 替身。
class _FakePlayback extends LivePlaybackController {
  _FakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int loadCalls = 0;
  int playCalls = 0;

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
    loadCalls++;
    _source = source;
    _channels = List.of(channels);
    _index = channels.isEmpty ? 0 : index.clamp(0, channels.length - 1);
    notifyListeners();
  }

  @override
  Future<void> play(int index, {bool reconnect = false}) async {
    playCalls++;
    if (_channels.isEmpty) return;
    _index = index.clamp(0, _channels.length - 1);
    notifyListeners();
  }

  @override
  Future<void> playRoute(int route) => play(_index);

  @override
  Future<void> retry() => play(_index, reconnect: true);

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

const _inlineKey = ValueKey('test-video-inline');
const _fullscreenKey = ValueKey('test-video-fullscreen');

Future<(_FakePlayback, List<LivePlaybackController>)> _pumpLive(
  WidgetTester tester, {
  bool withOrientationScope = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LiveStore(prefs, 'default')..load();
  addTearDown(store.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _ScriptedLiveRepository();
  final playback = _FakePlayback(repository: repository);
  final builtWith = <LivePlaybackController>[];
  final app = MaterialApp(
    home: Scaffold(
      body: LiveScreen(
        repository: repository,
        store: store,
        greenMode: false,
        playbackController: playback,
        videoBuilder: (controller, fullscreen) {
          builtWith.add(controller);
          return SizedBox(
            key: fullscreen ? _fullscreenKey : _inlineKey,
          );
        },
      ),
    ),
  );
  await tester.pumpWidget(
    withOrientationScope
        ? AppOrientationScope(television: false, child: app)
        : app,
  );
  // 替身画面第一帧就挂载，不能用它判断加载完成；等“全屏与旋转”按钮
  // 出现（_nowPlaying 要求 channel != null 且无错误），即加载已完成。
  for (
    var i = 0;
    i < 30 && find.byTooltip('全屏与旋转').evaluate().isEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (playback, builtWith);
}

/// 当前挂载的播放画面数：内嵌替身 + 全屏替身，同一时刻只能有 1 个。
int _mountedVideoCount(WidgetTester tester) {
  var count = 0;
  if (find.byKey(_inlineKey).evaluate().isNotEmpty) count++;
  if (find.byKey(_fullscreenKey).evaluate().isNotEmpty) count++;
  return count;
}

Future<void> _enterFullscreen(WidgetTester tester) async {
  expect(find.byKey(_inlineKey), findsOneWidget);
  await tester.tap(find.byTooltip('全屏与旋转'));
  for (
    var i = 0;
    i < 10 && find.byType(LivePlayerScreen).evaluate().isEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(LivePlayerScreen), findsOneWidget);
  // 路由出现不等于过渡完成：再泵 300ms（过渡 260ms）等滑入动画结束，
  // 否则随后的手势面点按可能落在过渡中的错位上。
  await tester.pump(const Duration(milliseconds: 300));
  expect(_mountedVideoCount(tester), 1);
  return;
}

Future<void> _settleToList(WidgetTester tester) async {
  for (
    var i = 0;
    i < 10 && find.byType(LivePlayerScreen).evaluate().isNotEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 控制条初始隐藏：点手势面唤出。手势面带双击识别，单击确认要等
/// 300ms 双击窗口，须泵够 400ms 否则唤出还没触发。
Future<void> _revealControls(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('退出过渡期间同一时刻只能挂一个播放画面', (tester) async {
    final (playback, builtWith) = await _pumpLive(tester);
    await _enterFullscreen(tester);

    await tester.binding.handlePopRoute();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(_mountedVideoCount(tester), 1);
    }
    await _settleToList(tester);
    expect(find.byType(LivePlayerScreen), findsNothing);
    expect(find.byKey(_inlineKey), findsOneWidget);
    expect(_mountedVideoCount(tester), 1);
    expect(builtWith, isNotEmpty);
    expect(builtWith.every((item) => identical(item, playback)), isTrue);
    expect(playback.loadCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统返回连按两次：只弹一层、回到直播列表、播放不死', (tester) async {
    final (playback, _) = await _pumpLive(tester);
    await _enterFullscreen(tester);

    await tester.binding.handlePopRoute();
    await tester.binding.handlePopRoute();
    await _settleToList(tester);
    expect(find.byType(LivePlayerScreen), findsNothing);
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(find.byKey(_inlineKey), findsOneWidget);
    expect(_mountedVideoCount(tester), 1);
    expect(playback.channel?.name, '频道一');
    expect(tester.takeException(), isNull);
  });

  testWidgets('屏上返回连按两次：只弹一层、回到直播列表', (tester) async {
    await _pumpLive(tester);
    await _enterFullscreen(tester);

    await _revealControls(tester);
    final back = find.byTooltip('退出全屏');
    expect(back, findsOneWidget);
    await tester.tap(back);
    await tester.tap(back);
    await _settleToList(tester);
    expect(find.byType(LivePlayerScreen), findsNothing);
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(find.byKey(_inlineKey), findsOneWidget);
    expect(_mountedVideoCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旋转键不退出、退出键单击退出：回到直播列表、播放不死', (tester) async {
    final (playback, _) = await _pumpLive(tester);
    await _enterFullscreen(tester);

    // “旋转与全屏”调的是 onRotate（切横竖屏），不是退出：点后仍在全屏页。
    await _revealControls(tester);
    await tester.tap(find.byTooltip('旋转与全屏'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(LivePlayerScreen), findsOneWidget);
    expect(find.byKey(_fullscreenKey), findsOneWidget);

    // 退出键单击即退出；若上一步点按顺带藏起了控制条，第一下只唤出、
    // 路由还在，才唤出再点。先 settle 排空过渡，避免与退场动画竞态。
    await tester.tap(find.byTooltip('退出全屏'), warnIfMissed: false);
    await _settleToList(tester);
    if (find.byType(LivePlayerScreen).evaluate().isNotEmpty) {
      await _revealControls(tester);
      await tester.tap(find.byTooltip('退出全屏'));
      await _settleToList(tester);
    }
    expect(find.byType(LivePlayerScreen), findsNothing);
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(find.byKey(_inlineKey), findsOneWidget);
    expect(_mountedVideoCount(tester), 1);
    expect(playback.channel?.name, '频道一');
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出后方向锁已释放：方向恢复四向、回到列表无异常', (tester) async {
    // 方向控制器调 moyi/device 与 flutter/platform：无桩时调用挂起、
    // 2 秒超时后才继续（同海阔测试的桩法）；桩上它让链路立即走通，
    // 并记录每次方向设置，断言退出后恢复四向。
    final orientationCalls = <List<String>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('moyi/device'),
      (call) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('moyi/device'),
        null,
      ),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter/platform', JSONMethodCodec()),
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationCalls.add(
            List<String>.from(call.arguments as List<dynamic>),
          );
        }
        return null;
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform', JSONMethodCodec()),
        null,
      ),
    );

    await _pumpLive(tester, withOrientationScope: true);
    await _enterFullscreen(tester);

    await tester.binding.handlePopRoute();
    await _settleToList(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(LivePlayerScreen), findsNothing);
    expect(find.byKey(_inlineKey), findsOneWidget);
    expect(_mountedVideoCount(tester), 1);
    expect(orientationCalls, isNotEmpty);
    expect(orientationCalls.last, hasLength(4));
    expect(tester.takeException(), isNull);
  });
}
