// 直播 DRM 频道改走 EXO 核的断言（v67 收口批）：
// - DRM 频道起播走 EXO 路：控制器产出带 drm 的 PlaybackPlan，
//   mpv 播放器根本不建；
// - 普通频道仍走 mpv 路（ScriptedPlayer 真被 open），EXO 计划为空；
// - 切线路 / 切台再切回：每次按当前频道重新归一化 drm，
//   session 换新让 pane 重开；
// - EXO 报失败只记明确报错、不回头建 mpv；归一化不出的 DRM
//   频道给「授权信息不完整」报错、不黑屏死等。
// 组件测试再钉直播页：DRM 频道主画面是 TvboxVideoPane、
// 信息行左槽不出 Video 预览帧；切到普通频道 pane 消失。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:moyi/live_drm.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/live_settings.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/live_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/tvbox_video_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

const _source = LiveSource(
  id: 'drm_test',
  name: 'DRM测试源',
  description: '',
  protocol: LiveProtocol.list,
);

const _drmWidevine = LiveChannel(
  key: 'wv',
  name: '宽vine台',
  urls: ['https://example.com/wv.mpd', 'https://example.com/wv2.mpd'],
  headers: {'User-Agent': 'ua-test'},
  group: '测试分组',
  source: 'drm_test',
  licenseKey: 'https://lic.example/wv|Authorization=Bearer abc',
  licenseType: 'com.widevine.alpha',
);

const _drmClearKey = LiveChannel(
  key: 'ck',
  name: '清key台',
  urls: ['https://example.com/ck.mpd'],
  group: '测试分组',
  source: 'drm_test',
  licenseKey: '000102030405060708090a0b0c0d0e0f:'
      '00112233445566778899aabbccddeeff',
  licenseType: 'org.w3.clearkey',
);

const _plain = LiveChannel(
  key: 'plain',
  name: '普通台',
  urls: ['https://example.com/plain.m3u8'],
  group: '测试分组',
  source: 'drm_test',
);

const _brokenDrm = LiveChannel(
  key: 'broken',
  name: '坏授权台',
  urls: ['https://example.com/broken.mpd'],
  group: '测试分组',
  source: 'drm_test',
  licenseKey: 'https://lic.example/wv',
  licenseType: '',
);

class _Repo extends LiveRepository {
  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.url, headers: channel.headers);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveSettingsStore.instance.resetForTest();
  });

  group('LivePlaybackController DRM 分流', () {
    late ScriptedPlayer scripted;
    late LivePlaybackController controller;

    LivePlaybackController build() {
      scripted = ScriptedPlayer();
      return LivePlaybackController(
        repository: _Repo(),
        createPlayer: () => Player(platformPlayer: scripted),
        // 真 VideoController 测试环境建不起来，只验播放路由。
        buildVideoController: false,
      );
    }

    test('DRM 频道走 EXO 路：计划带对 drm，mpv 不建', () async {
      controller = build();
      addTearDown(controller.dispose);
      await controller.load(_source, const [_drmWidevine, _plain]);
      expect(controller.usingExo, isTrue);
      final plan = controller.exoPlan!;
      expect(plan.url, 'https://example.com/wv.mpd');
      expect(plan.headers, {'User-Agent': 'ua-test'});
      expect(plan.drm, isNotNull);
      expect(plan.drm!.type, 'com.widevine.alpha');
      expect(plan.drm!.key, 'https://lic.example/wv');
      expect(plan.drm!.headers, {'Authorization': 'Bearer abc'});
      // mpv 完全没参与：播放器没建、ScriptedPlayer 没被 open。
      expect(controller.player, isNull);
      expect(scripted.opened, isEmpty);
      expect(controller.error, isNull);
    });

    test('普通频道仍走 mpv 路：EXO 计划为空，mpv 真被 open', () async {
      controller = build();
      addTearDown(controller.dispose);
      await controller.load(_source, const [_plain]);
      expect(controller.usingExo, isFalse);
      expect(controller.exoPlan, isNull);
      expect(controller.player, isNotNull);
      expect(scripted.opened.map((m) => m.uri), [
        'https://example.com/plain.m3u8',
      ]);
      expect(controller.error, isNull);
    });

    test('DRM 切线路：换地址、drm 不变、session 换新', () async {
      controller = build();
      addTearDown(controller.dispose);
      await controller.load(_source, const [_drmWidevine]);
      final first = controller.exoPlan!;
      await controller.playRoute(1);
      final second = controller.exoPlan!;
      expect(second.url, 'https://example.com/wv2.mpd');
      expect(second.drm!.key, 'https://lic.example/wv');
      expect(second.drm!.type, 'com.widevine.alpha');
      expect(second.session, isNot(first.session));
      expect(controller.player, isNull);
    });

    test('切台到另一 DRM 频道再切回：drm 各自归一化', () async {
      controller = build();
      addTearDown(controller.dispose);
      await controller.load(_source, const [_drmWidevine, _drmClearKey]);
      expect(controller.exoPlan!.drm!.type, 'com.widevine.alpha');
      await controller.play(1);
      expect(controller.usingExo, isTrue);
      expect(controller.exoPlan!.url, 'https://example.com/ck.mpd');
      expect(controller.exoPlan!.drm!.type, 'org.w3.clearkey');
      // ClearKey 本地键已转成 JWK，不是十六进制原样。
      expect(controller.exoPlan!.drm!.key, contains('"keys"'));
      await controller.play(0);
      expect(controller.exoPlan!.drm!.type, 'com.widevine.alpha');
      expect(controller.exoPlan!.drm!.key, 'https://lic.example/wv');
      expect(controller.player, isNull);
    });

    test('DRM 切到普通频道：回 mpv 路，EXO 计划清掉', () async {
      controller = build();
      addTearDown(controller.dispose);
      await controller.load(_source, const [_drmWidevine, _plain]);
      expect(controller.usingExo, isTrue);
      await controller.play(1);
      expect(controller.usingExo, isFalse);
      expect(controller.exoPlan, isNull);
      expect(scripted.opened.map((m) => m.uri), [
        'https://example.com/plain.m3u8',
      ]);
    });

    test('EXO 起播失败：明确报错、不回头建 mpv；重连仍走 EXO', () async {
      controller = build();
      addTearDown(controller.dispose);
      await controller.load(_source, const [_drmWidevine]);
      final session = controller.exoPlan!.session;
      controller.reportExoError('许可证服务器拒绝');
      expect(controller.error, contains('DRM 频道播放失败'));
      expect(controller.error, contains('许可证服务器拒绝'));
      expect(controller.usingExo, isTrue);
      expect(controller.player, isNull);
      expect(scripted.opened, isEmpty);
      await controller.retry();
      expect(controller.error, isNull);
      expect(controller.usingExo, isTrue);
      expect(controller.exoPlan!.session, isNot(session));
      expect(controller.player, isNull);
    });

    test('授权信息归一化不出：明确报错，不建 mpv 也不出 EXO 计划', () async {
      controller = build();
      addTearDown(controller.dispose);
      await controller.load(_source, const [_brokenDrm]);
      expect(controller.error, contains('授权信息不完整'));
      expect(controller.usingExo, isFalse);
      expect(controller.exoPlan, isNull);
      expect(controller.player, isNull);
      expect(scripted.opened, isEmpty);
    });
  });

  group('直播页 DRM 呈现', () {
    testWidgets('DRM 频道主画面是 EXO pane、左槽无预览帧；切普通台 pane 消失',
        (tester) async {
      final playback = await _pumpLive(tester);
      expect(playback.channel!.key, 'wv');
      final pane = find.byType(TvboxVideoPane);
      expect(pane, findsOneWidget);
      final widget = tester.widget<TvboxVideoPane>(pane);
      expect(widget.plan!.url, 'https://example.com/wv.mpd');
      expect(widget.plan!.drm!.type, 'com.widevine.alpha');
      expect(widget.plan!.drm!.key, 'https://lic.example/wv');
      // 主画面与左槽都没有 mpv 的 Video（左槽降级，只剩频道号角标）。
      expect(find.byType(Video), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('live-info-preview')),
          matching: find.text('001'),
        ),
        findsOneWidget,
      );
      // 切到普通频道：EXO pane 消失，回到 mpv 路的呈现。
      await tester.tap(find.byKey(const ValueKey('live-channel-plain')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TvboxVideoPane), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

class _ScreenRepo extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => [const LivePlatform(id: 'g1', name: '测试分组', count: 3)];

  @override
  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async => [
    LiveChannel(
      key: _drmWidevine.key,
      name: _drmWidevine.name,
      urls: _drmWidevine.urls,
      number: '001',
      group: '测试分组',
      source: source.id,
      licenseKey: _drmWidevine.licenseKey,
      licenseType: _drmWidevine.licenseType,
    ),
    LiveChannel(
      key: _plain.key,
      name: _plain.name,
      urls: _plain.urls,
      number: '002',
      group: '测试分组',
      source: source.id,
    ),
  ];

  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.url, headers: channel.headers);
}

/// 只替播放呈现的假控制器：load/play 时按当前频道算 EXO 计划，
/// 与真控制器的分流口径一致（hasDrm + liveDrmForChannel）。
class _ScreenFakePlayback extends LivePlaybackController {
  _ScreenFakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _route = 0;
  PlaybackPlan? _exoPlan;

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
  bool get usingExo => _exoPlan != null;

  @override
  PlaybackPlan? get exoPlan => _exoPlan;

  void _syncExo() {
    final current = channel;
    final drm = current != null && current.hasDrm
        ? liveDrmForChannel(current)
        : null;
    _exoPlan = drm == null
        ? null
        : PlaybackPlan(
            url: current!.urls[_route.clamp(0, current.urls.length - 1)],
            drm: drm,
            session: 'test-$_index-$_route',
          );
  }

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
    _route = 0;
    _syncExo();
    notifyListeners();
  }

  @override
  Future<void> play(int index, {bool reconnect = false}) async {
    if (_channels.isEmpty) return;
    if (index != _index) _route = 0;
    _index = index.clamp(0, _channels.length - 1);
    _syncExo();
    notifyListeners();
  }

  @override
  Future<void> playRoute(int route) async {
    _route = route < 0 ? 0 : route;
    _syncExo();
    notifyListeners();
  }

  @override
  Future<void> retry() => play(_index, reconnect: true);

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

Future<_ScreenFakePlayback> _pumpLive(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LiveStore(prefs, 'default')..load();
  addTearDown(store.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _ScreenRepo();
  final playback = _ScreenFakePlayback(repository: repository);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LiveScreen(
          repository: repository,
          store: store,
          greenMode: false,
          playbackController: playback,
        ),
      ),
    ),
  );
  for (
    var i = 0;
    i < 30 && find.byKey(const ValueKey('live-grid')).evaluate().isEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byKey(const ValueKey('live-grid')), findsOneWidget);
  return playback;
}
