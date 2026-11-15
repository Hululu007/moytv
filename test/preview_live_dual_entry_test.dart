// 直播订阅双入口预览截图：只做测试内截图，不改业务代码。
// 假数据说明：订阅名、频道名、房间名、分组名均为测试内合成；
// 播放画面为空占位；图标/emoji 在测试环境可能渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/live_store.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/subscription_entries.dart';
import 'package:moyi/tvbox_config.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
      subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: 'PreviewCJK'),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) => base.filledButtonTheme.style?.textStyle
              ?.resolve(states)
              ?.copyWith(fontFamily: 'PreviewCJK'),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
  for (var i = 0; i < 10; i++) {
    try {
      if (tester.takeException() == null) break;
    } catch (_) {
      break;
    }
  }
}

void main() {
  testWidgets('live dual entry preview', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final appStore = LocalStore(prefs);
    addTearDown(appStore.dispose);
    final liveStore = LiveStore(prefs, 'default')..load();
    addTearDown(liveStore.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appThemeNotifier.value = AppThemeMode.purpleNeon;
    final repository = _PreviewLiveRepository();
    final playback = _PreviewFakePlayback(repository: repository);

    const record = TvBoxConfigRecord(
      configId: 'preview1',
      name: '示例订阅（假数据）',
      url: '',
      sites: [
        TvBoxSiteRecord(
          siteId: 'py:preview:a',
          key: 'a',
          name: '示例影视站甲',
          kind: 'py',
          coreId: 'py:preview:a',
        ),
        TvBoxSiteRecord(
          siteId: 'py:preview:b',
          key: 'b',
          name: '示例影视站乙',
          kind: 'py',
          coreId: 'py:preview:b',
        ),
      ],
      lives: [
        TvBoxLiveRecord(
          id: 'live:preview1:1',
          name: '示例直播源',
          url: 'https://example.com/live.m3u',
        ),
      ],
      parseIds: [],
      updatedAt: '',
    );

    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text(
                      '预览·假数据：订阅双入口 + 分组/换台列表',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const ListTile(
                          leading: Icon(
                            Icons.settings_input_component_outlined,
                          ),
                          title: Text('示例订阅（假数据）'),
                          subtitle: Text('站点 2 · 直播 1 · 解析 0'),
                        ),
                        SubscriptionEntryButtons(
                          entries: subscriptionEntriesForConfig(record),
                          onEnterVideo: (_) {},
                          onEnterLive: (_) {},
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LiveScreen(
                      repository: repository,
                      store: liveStore,
                      greenMode: false,
                      appStore: appStore,
                      playbackController: playback,
                      videoBuilder: (_, _) => Container(
                        color: Colors.black,
                        alignment: Alignment.center,
                        child: const Text(
                          '播放画面占位（假数据）',
                          style: TextStyle(
                            color: Colors.white70,
                            fontFamily: 'PreviewCJK',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    // 同步写图：异步 writeAsBytes 在此测试环境里悬住不返回，
    // 其它预览测试一律用 writeAsBytesSync（见 preview_batch10）。
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/live_dual_entry.png').writeAsBytesSync(bytes);
    print('preview landed: live_dual_entry');
  });
}

class _PreviewLiveRepository extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => [
    const LivePlatform(id: 'g1', name: '卫视频道', count: 6),
    const LivePlatform(id: 'g2', name: '体育赛事', count: 3),
    const LivePlatform(id: 'g3', name: '电影剧场', count: 4),
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
        for (var i = 0; i < 3; i++)
          LiveChannel(
            key: 'g2-$i',
            name: '体育频道 ${i + 1}',
            urls: const ['https://example.com/s.m3u8'],
            number: '00${i + 1}',
            group: '体育赛事',
            source: source.id,
          ),
      ];
    }
    if (platform.id == 'g3') {
      return [
        for (var i = 0; i < 4; i++)
          LiveChannel(
            key: 'g3-$i',
            name: '电影频道 ${i + 1}',
            urls: const ['https://example.com/m.m3u8'],
            number: '00${i + 1}',
            group: '电影剧场',
            source: source.id,
          ),
      ];
    }
    return [
      const LiveChannel(
        key: 'g1-0',
        name: '卫视一台',
        urls: ['https://example.com/a1.m3u8', 'https://example.com/a2.m3u8'],
        number: '001',
        group: '卫视频道',
        source: 'preview',
        subtitle: '晚间新闻（假数据）',
      ),
      const LiveChannel(
        key: 'g1-1',
        name: '卫视二台',
        urls: ['https://example.com/b.m3u8'],
        number: '002',
        group: '卫视频道',
        source: 'preview',
        subtitle: '电视剧场（假数据）',
      ),
      const LiveChannel(
        key: 'g1-2',
        name: '卫视三台',
        urls: ['https://example.com/c1.m3u8', 'https://example.com/c2.m3u8'],
        number: '003',
        group: '卫视频道',
        source: 'preview',
      ),
      for (var i = 3; i < 6; i++)
        LiveChannel(
          key: 'g1-$i',
          name: '卫视${i + 1}台',
          urls: const ['https://example.com/d.m3u8'],
          number: '00${i + 1}',
          group: '卫视频道',
          source: source.id,
        ),
    ];
  }

  @override
  Future<LivePlayback> playback(LiveSource source, LiveChannel channel) async =>
      LivePlayback(url: channel.url);
}

class _PreviewFakePlayback extends LivePlaybackController {
  _PreviewFakePlayback({required super.repository})
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
