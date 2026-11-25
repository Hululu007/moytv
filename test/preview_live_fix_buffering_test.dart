// 直播修复预览图（缓冲态）：中央转圈居中对齐、无大播放三角；
// 缩窄 + 右侧预览区（线路小按钮 + 分辨率/帧率）、配色跟主题。
// 假数据说明：分组/频道名均为测试内合成的演示数据（内置片库风格
// 的影片频道）；播放画面为占位块（测试环境没有真播放器），产品里
// 预览区与播放区共用同一播放器、是真实时画面；分辨率 1920x1080、
// 帧率 25 是假播放器给出的假流参数，产品代码只取真实参数、拿不
// 到就不显示。一测一张：调过 toImage 的测试收尾会挂起（PNG 已落
// 地），跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_live_fix_20261125/preview';

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
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
  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    try {
      final bytes = File(
        '/home/hatch/workspace/tools/flutter-3.50.0/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  testWidgets('live fix preview buffering', (tester) async {
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
                      '预览·演示数据：直播修复版（缓冲态）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
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
                          '实时画面（演示占位）',
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
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/live_fix_buffering.png').writeAsBytesSync(bytes);
    print('preview landed: live_fix_buffering');
  });
}

class _PreviewLiveRepository extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => [
    const LivePlatform(id: 'all', name: '全部频道', count: 3),
    const LivePlatform(id: 'new', name: '最新', count: 3),
    const LivePlatform(id: 'brand:mida', name: 'MIDA', count: 1),
  ];

  @override
  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async => [
    LiveChannel(
      key: 'w1',
      name: 'MIDA-619 示例影片·海岛假期',
      urls: const [
        'https://example.com/a1.m3u8',
        'https://example.com/a2.m3u8',
      ],
      number: '619',
      group: '全部频道',
      source: source.id,
    ),
    LiveChannel(
      key: 'w2',
      name: 'SONE-482 示例影片·都市夜话',
      urls: const ['https://example.com/b.m3u8'],
      number: '482',
      group: '全部频道',
      source: source.id,
    ),
    LiveChannel(
      key: 'w3',
      name: 'IPZZ-503 示例影片·山间来信',
      urls: const ['https://example.com/c.m3u8'],
      number: '503',
      group: '全部频道',
      source: source.id,
    ),
  ];

  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.url);
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
  bool get buffering => true;

  @override
  String? get error => null;

  @override
  bool get ready => true;

  @override
  double get aspectRatio => 16 / 9;

  /// 假流参数：只为预览图带上分辨率与帧率，产品代码不硬写。
  @override
  Size? get videoSize => const Size(1920, 1080);

  @override
  double? get videoFps => 25;

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
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
