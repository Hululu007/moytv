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

class _LayoutLiveRepository extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => [
    const LivePlatform(id: 'g1', name: '测试分组', count: 2),
    const LivePlatform(id: 'g2', name: '第二分组', count: 1),
  ];

  @override
  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async {
    if (platform.id == 'g2') {
      return [
        LiveChannel(
          key: 'k3',
          name: '频道三',
          urls: const ['https://example.com/c.m3u8'],
          number: '003',
          group: '第二分组',
          source: source.id,
        ),
      ];
    }
    return [
      LiveChannel(
        key: 'k1',
        name: '频道一',
        urls: const [
          'https://example.com/a1.m3u8',
          'https://example.com/a2.m3u8',
        ],
        number: '001',
        group: '测试分组',
        source: source.id,
        subtitle: '主播小明',
      ),
      LiveChannel(
        key: 'k2',
        name: '频道二',
        urls: const ['https://example.com/b.m3u8'],
        number: '002',
        group: '测试分组',
        source: source.id,
      ),
    ];
  }

  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.url);
}

/// 播放控制器替身：与 live_fullscreen_exit_test 的 _FakePlayback 同款，
/// 另记线路与解码模式，供默认行为断言。画面走 videoBuilder 替身。
class _LayoutFakePlayback extends LivePlaybackController {
  _LayoutFakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _route = 0;
  LiveDecoderMode _decoderMode = LiveDecoderMode.auto;
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
  LiveChannel? get channel => _channels.isEmpty
      ? null
      : _channels[_index.clamp(0, _channels.length - 1)];

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
  int get route => _route;

  @override
  LiveDecoderMode get decoderMode => _decoderMode;

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
  Future<void> playRoute(int route) async {
    _route = route < 0 ? 0 : route;
    await play(_index);
  }

  @override
  Future<void> setDecoderMode(LiveDecoderMode mode) async {
    _decoderMode = mode;
    notifyListeners();
  }

  @override
  Future<bool> resetDefaults() async {
    final changed = _route != 0 || _decoderMode != LiveDecoderMode.auto;
    _route = 0;
    _decoderMode = LiveDecoderMode.auto;
    notifyListeners();
    return changed;
  }

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

Future<_LayoutFakePlayback> _pumpLive(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LiveStore(prefs, 'default')..load();
  addTearDown(store.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _LayoutLiveRepository();
  final playback = _LayoutFakePlayback(repository: repository);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LiveScreen(
          repository: repository,
          store: store,
          greenMode: false,
          playbackController: playback,
          videoBuilder: (_, _) => const SizedBox(),
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
  expect(find.byTooltip('全屏与旋转'), findsOneWidget);
  return playback;
}


Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var i = 0; i < 30 && find.text(text).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}



void main() {
  test('时钟格式：日期行与时间行', () {
    final time = DateTime(2026, 11, 14, 22, 13, 27);
    expect(liveClockDateLine(time), '11/14 周六');
    expect(liveClockTimeLine(time), '22:13:27');
    expect(liveClockDateLine(DateTime(2026, 11, 16, 9, 5, 3)), '11/16 周一');
    expect(liveClockTimeLine(DateTime(2026, 11, 16, 9, 5, 3)), '09:05:03');
  });

  test('解码模式：标签、mpv 取值、循环顺序', () {
    expect(LiveDecoderMode.auto.label, '自动');
    expect(LiveDecoderMode.hardware.label, '硬解');
    expect(LiveDecoderMode.software.label, '软解');
    expect(LiveDecoderMode.auto.mpvValue, 'auto-safe');
    expect(LiveDecoderMode.hardware.mpvValue, 'mediacodec-copy');
    expect(LiveDecoderMode.software.mpvValue, 'no');
    expect(LiveDecoderMode.auto.next, LiveDecoderMode.hardware);
    expect(LiveDecoderMode.hardware.next, LiveDecoderMode.software);
    expect(LiveDecoderMode.software.next, LiveDecoderMode.auto);
  });

  testWidgets('视频区角标：时钟在、网速无数据时不显示', (tester) async {
    await _pumpLive(tester);
    expect(find.byKey(const ValueKey('live-clock')), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'周[一二三四五六日]')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('live-speed-badge')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('当前频道卡：首字兜底、节目行显示真实 subtitle', (tester) async {
    await _pumpLive(tester);
    // 无台标时卡片显示频道名首字“频”。
    expect(find.text('频'), findsOneWidget);
    // subtitle 同时出现在频道卡、频道行与视频区底部信息条，三处一致。
    expect(find.text('主播小明'), findsNWidgets(3));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-channel-k1')),
        matching: find.text('主播小明'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('双栏：点分组切换频道列表、再点回原分组', (tester) async {
    await _pumpLive(tester);
    expect(find.text('频道一'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('live-group-g2')));
    await _waitForText(tester, '频道三');
    expect(find.text('频道三'), findsWidgets);
    expect(find.text('频道一'), findsNothing);
    expect(find.text('频道二'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('live-group-g1')));
    await _waitForText(tester, '频道一');
    expect(find.text('频道一'), findsWidgets);
    expect(find.text('频道三'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换台：点频道行切换当前频道、三角标记跟过去', (tester) async {
    final playback = await _pumpLive(tester);
    expect(playback.channel?.name, '频道一');
    await tester.tap(find.byKey(const ValueKey('live-channel-k2')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(playback.channel?.name, '频道二');
    expect(playback.playCalls, greaterThan(0));
    // 当前行以三角代替序号，非当前行仍显示序号。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-channel-k2')),
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-channel-k1')),
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-channel-k1')),
        matching: find.text('001'),
      ),
      findsOneWidget,
    );
    // 切到无 subtitle 的频道：频道卡与视频区信息条不再显示节目信息，
    // 只剩频道一自己那行还显示它自己的 subtitle，不编假节目单。
    expect(find.text('主播小明'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-channel-k1')),
        matching: find.text('主播小明'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-channel-k2')),
        matching: find.text('主播小明'),
      ),
      findsNothing,
    );
    // 每行末尾有右箭头。
    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('功能键排已删：四键与标签都不在、频道卡与列表仍在', (tester) async {
    final playback = await _pumpLive(tester);
    expect(find.byKey(const ValueKey('live-decoder-button')), findsNothing);
    expect(find.byKey(const ValueKey('live-route-button')), findsNothing);
    expect(find.byKey(const ValueKey('live-default-button')), findsNothing);
    expect(find.byKey(const ValueKey('live-speed-button')), findsNothing);
    expect(find.text('1.0倍速'), findsNothing);
    expect(find.text('线路 1/2'), findsNothing);
    // 底层仍走默认：首条线路、自动解码。
    expect(playback.route, 0);
    expect(playback.decoderMode, LiveDecoderMode.auto);
    // 频道卡、收藏行、分组/频道列表都在，布局上移不留空。
    expect(find.text('频'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('live-favourites-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('live-channel-k1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
