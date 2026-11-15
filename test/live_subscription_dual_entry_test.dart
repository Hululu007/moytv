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
import 'package:moyi/local_store.dart';
import 'package:moyi/m3u_subscriptions.dart';
import 'package:moyi/subscription_entries.dart';
import 'package:moyi/tvbox_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

TvBoxConfigRecord _config({
  List<TvBoxSiteRecord> sites = const [],
  List<TvBoxLiveRecord> lives = const [],
}) => TvBoxConfigRecord(
  configId: 'cfg1',
  name: '测试订阅',
  url: '',
  sites: sites,
  lives: lives,
  parseIds: const [],
  updatedAt: '',
);

const _sitePy = TvBoxSiteRecord(
  siteId: 'py:tvbox:cfg1:a',
  key: 'a',
  name: '站点甲',
  kind: 'py',
  coreId: 'py:tvbox:cfg1:a',
);
const _siteJar = TvBoxSiteRecord(
  siteId: 'jar:cfg1:b',
  key: 'b',
  name: '站点乙',
  kind: 'jar',
  className: 'com.example.B',
);
const _liveA = TvBoxLiveRecord(
  id: 'live:cfg1:1',
  name: '直播甲',
  url: 'https://live.example.com/a.m3u',
);
const _liveB = TvBoxLiveRecord(
  id: 'live:cfg1:2',
  name: '直播乙',
  url: 'https://live.example.com/b.m3u',
);

void main() {
  group('subscriptionEntriesForConfig', () {
    test('双边订阅出影视和直播两个入口', () {
      final record = _config(sites: [_sitePy, _siteJar], lives: [_liveA]);
      expect(record.isDualSided, isTrue);
      final entries = subscriptionEntriesForConfig(record);
      expect(entries.length, 2);
      expect(entries[0].isVideo, isTrue);
      expect(entries[0].items.length, 2);
      expect(entries[0].actionLabel, '影视 · 2 个站');
      expect(entries[1].isLive, isTrue);
      expect(entries[1].items.single.id, 'live:cfg1:1');
      expect(entries[1].actionLabel, '直播');
    });

    test('只有影视的订阅只出单入口', () {
      final record = _config(sites: [_sitePy]);
      expect(record.hasVideo, isTrue);
      expect(record.hasLive, isFalse);
      final entries = subscriptionEntriesForConfig(record);
      expect(entries.length, 1);
      expect(entries.single.isVideo, isTrue);
    });

    test('只有直播的订阅只出单入口', () {
      final record = _config(lives: [_liveA, _liveB]);
      final entries = subscriptionEntriesForConfig(record);
      expect(entries.length, 1);
      expect(entries.single.isLive, isTrue);
      expect(entries.single.items.length, 2);
      expect(entries.single.actionLabel, '直播 · 2 个');
    });

    test('两边都没有的订阅不出入口', () {
      expect(subscriptionEntriesForConfig(_config()), isEmpty);
    });
  });

  group('videoSiteIdForRecord', () {
    test('py 站用 coreId，jar 站用 siteId', () {
      expect(videoSiteIdForRecord(_sitePy), 'py:tvbox:cfg1:a');
      expect(videoSiteIdForRecord(_siteJar), 'jar:cfg1:b');
    });

    test('coreId 为空时回落 siteId', () {
      const site = TvBoxSiteRecord(
        siteId: 'custom-1',
        key: 'c',
        name: '站点丙',
        kind: 'api',
      );
      expect(videoSiteIdForRecord(site), 'custom-1');
    });
  });

  test('m3u 订阅只有单个直播入口', () {
    const sub = M3uSubscription(
      id: 'abc',
      name: '我的 m3u',
      kind: M3uSubscription.kindUrl,
      url: 'https://example.com/list.m3u',
      channels: [],
    );
    final entries = subscriptionEntriesForM3u(sub);
    expect(entries.length, 1);
    expect(entries.single.isLive, isTrue);
    expect(entries.single.items.single.id, 'm3u:abc');
    expect(entries.single.actionLabel, '直播');
  });

  group('LiveGroupMemory', () {
    test('记住每源上次分组与每组滚动位置，互不干扰', () {
      final memory = LiveGroupMemory();
      expect(memory.lastGroupFor('s1'), '');
      expect(memory.offsetFor('s1', 'g1'), 0);
      memory.rememberGroup('s1', 'g1');
      memory.rememberOffset('s1', 'g1', 120);
      memory.rememberOffset('s1', 'g2', 40);
      memory.rememberGroup('s2', 'g2');
      expect(memory.lastGroupFor('s1'), 'g1');
      expect(memory.lastGroupFor('s2'), 'g2');
      expect(memory.offsetFor('s1', 'g1'), 120);
      expect(memory.offsetFor('s1', 'g2'), 40);
      expect(memory.offsetFor('s2', 'g2'), 0);
    });

    test('负偏移记为 0，空键不记', () {
      final memory = LiveGroupMemory();
      memory.rememberOffset('s1', 'g1', -5);
      memory.rememberOffset('', 'g1', 10);
      memory.rememberGroup('', 'g1');
      expect(memory.offsetFor('s1', 'g1'), 0);
      expect(memory.lastGroupFor(''), '');
    });
  });

  group('liveChannelRowCaption', () {
    LiveChannel channel({
      String subtitle = '',
      String group = '',
      List<String> urls = const ['https://example.com/a.m3u8'],
    }) => LiveChannel(
      key: 'k',
      name: '频道',
      urls: urls,
      group: group,
      subtitle: subtitle,
    );

    test('优先真实 subtitle', () {
      expect(
        liveChannelRowCaption(
          channel(subtitle: '主播小明', group: '卫视', urls: const ['u1', 'u2']),
        ),
        '主播小明',
      );
    });

    test('收藏混排时落到分组', () {
      expect(
        liveChannelRowCaption(channel(group: '卫视'), inFavourites: true),
        '卫视',
      );
      expect(liveChannelRowCaption(channel(group: '卫视')), '');
    });

    test('多线路频道显示线路数', () {
      expect(
        liveChannelRowCaption(channel(urls: const ['u1', 'u2', 'u3'])),
        '3 条线路',
      );
    });

    test('什么都没有时为空，不编节目单', () {
      expect(liveChannelRowCaption(channel()), '');
    });
  });

  group('SubscriptionEntryButtons', () {
    testWidgets('双边订阅出两个按钮，单边只出一个', (tester) async {
      final dual = subscriptionEntriesForConfig(
        _config(sites: [_sitePy], lives: [_liveA]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionEntryButtons(
              entries: dual,
              onEnterVideo: (_) {},
              onEnterLive: (_) {},
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('subscription-entry-video')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subscription-entry-live')),
        findsOneWidget,
      );

      final single = subscriptionEntriesForConfig(_config(lives: [_liveA]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionEntryButtons(
              entries: single,
              onEnterVideo: (_) {},
              onEnterLive: (_) {},
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('subscription-entry-video')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('subscription-entry-live')),
        findsOneWidget,
      );
    });

    testWidgets('单选项直接进入，多选项弹选单再进入', (tester) async {
      var enteredVideo = '';
      var enteredLive = '';
      final entries = subscriptionEntriesForConfig(
        _config(sites: [_sitePy], lives: [_liveA, _liveB]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionEntryButtons(
              entries: entries,
              onEnterVideo: (id) => enteredVideo = id,
              onEnterLive: (id) => enteredLive = id,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('subscription-entry-video')));
      await tester.pump();
      expect(enteredVideo, 'py:tvbox:cfg1:a');

      await tester.tap(find.byKey(const ValueKey('subscription-entry-live')));
      await tester.pumpAndSettle();
      expect(find.text('选择直播源进入'), findsOneWidget);
      await tester.tap(find.text('直播乙'));
      await tester.pumpAndSettle();
      expect(enteredLive, 'live:cfg1:2');
    });

    testWidgets('无入口时不渲染按钮', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionEntryButtons(
              entries: const [],
              onEnterVideo: (_) {},
              onEnterLive: (_) {},
            ),
          ),
        ),
      );
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('enterSubscription helpers', () {
    testWidgets('直播进入记待办并退回首页', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: Builder(
                        builder: (inner) => FilledButton(
                          key: const ValueKey('enter-live'),
                          onPressed: () => enterSubscriptionLive(
                            inner,
                            store,
                            'live:cfg1:1',
                          ),
                          child: const Text('进直播'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('打开订阅页'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开订阅页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('enter-live')));
      await tester.pumpAndSettle();
      expect(store.pendingLiveSourceId, 'live:cfg1:1');
      expect(store.pendingVideoSiteId, '');
      expect(find.text('打开订阅页'), findsOneWidget);
      expect(find.byKey(const ValueKey('enter-live')), findsNothing);
      store.clearSubscriptionEntryRequest();
      expect(store.pendingLiveSourceId, '');
    });
  });

  group('LiveScreen subscription entry', () {
    testWidgets('递进来的直播源被首选，nonce 变化时切源', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LiveStore(prefs, 'default')..load();
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _DualEntryLiveRepository();
      final playback = _DualEntryFakePlayback(repository: repository);

      Widget frame({String sourceId = '', int nonce = 0}) => MaterialApp(
        home: Scaffold(
          body: LiveScreen(
            repository: repository,
            store: store,
            greenMode: false,
            playbackController: playback,
            videoBuilder: (_, _) => const SizedBox(),
            initialSourceId: sourceId,
            initialSourceNonce: nonce,
          ),
        ),
      );

      await tester.pumpWidget(frame(sourceId: 'xiuguo', nonce: 1));
      await _waitForLiveReady(tester);
      // 当前频道带 subtitle 时简介行显示 subtitle 而不是源名，
      // 故直接断言播放器选中的源。
      expect(playback.source?.id, 'xiuguo');

      await tester.pumpWidget(frame(sourceId: 'bilibili', nonce: 2));
      for (var i = 0; i < 30 && playback.source?.id != 'bilibili'; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.source?.id, 'bilibili');
    });

    testWidgets('切分组后记住分组，换台列表显示真实第二行', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LiveStore(prefs, 'default')..load();
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _DualEntryLiveRepository();
      final playback = _DualEntryFakePlayback(repository: repository);
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
      await _waitForLiveReady(tester);
      // 频道一带真实 subtitle，频道二多线路：两行真实信息都出现。
      expect(find.text('主播小明'), findsWidgets);
      expect(find.text('2 条线路'), findsOneWidget);
      // 分组栏显示真实频道数。
      expect(find.text('2 个'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('live-group-g2')));
      await _waitForText(tester, '频道三');
      // 频道名同时出现在正在播放条、当前频道卡与换台列表里。
      expect(find.text('频道三'), findsWidgets);
      expect(repository.groupMemory.lastGroupFor(playback.source!.id), 'g2');
    });
  });
}

Future<void> _waitForLiveReady(WidgetTester tester) async {
  for (var i = 0; i < 30 && find.byTooltip('全屏与旋转').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byTooltip('全屏与旋转'), findsOneWidget);
}

/// 已在直播页内再次切源/切分组时，全屏按钮早已存在，不能再拿它当
/// 就绪信号，改为等目标文案出现。
Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var i = 0; i < 30 && find.textContaining(text).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.textContaining(text), findsWidgets);
}

class _DualEntryLiveRepository extends LiveRepository {
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
        urls: const [
          'https://example.com/b1.m3u8',
          'https://example.com/b2.m3u8',
        ],
        number: '002',
        group: '测试分组',
        source: source.id,
      ),
    ];
  }

  @override
  Future<LivePlayback> playback(LiveSource source, LiveChannel channel) async =>
      LivePlayback(url: channel.url);
}

class _DualEntryFakePlayback extends LivePlaybackController {
  _DualEntryFakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _route = 0;
  LiveDecoderMode _decoderMode = LiveDecoderMode.auto;

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
