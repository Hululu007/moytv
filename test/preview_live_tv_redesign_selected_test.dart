// 直播页截图版式预览：默认态（CCTV-1 综合选中）。
// 假数据说明：分组名、频道名均为测试内合成（照截图同款 CCTV 频道名）；
// 播放画面为空占位；分辨率 1920x1080 是假播放器给出的假流参数，
// 不是产品代码硬写（产品里 videoSize 只取真实 videoParams，拿不到就不显示）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
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

const _previewDir =
    '/home/hatch/workspace/moyi_live_tv_redesign_20261125/preview';

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
    // 测试环境不自带中文字体与图标字体，显式加载（与其它预览测试同款）：
    // 中文不加载就是满屏方块，图标不加载就是方框。
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

  testWidgets('live tv redesign preview selected', (tester) async {
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
                      '预览·假数据：直播页截图版式（选中态：CCTV-2 财经）',
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
    // 选中态：点中列第二行 CCTV-2 财经，选中黄色落到该行，
    // 信息卡与顶栏跟着换成 CCTV-2。
    await tester.tap(find.byKey(const ValueKey('live-channel-cctv-2')));
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
    File('$_previewDir/live_tv_selected_cctv2.png').writeAsBytesSync(bytes);
    print('preview landed: live_tv_selected_cctv2');
  });
}

class _PreviewLiveRepository extends LiveRepository {
  static const _cctvNames = [
    'CCTV-1 综合',
    'CCTV-2 财经',
    'CCTV-3 综艺',
    'CCTV-4 中文国际',
    'CCTV-5 体育',
    'CCTV-5+ 体育赛事',
    'CCTV-6 电影',
    'CCTV-7 国防军事',
  ];

  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => [
    const LivePlatform(id: 'cctv', name: '央视网频', count: 8),
    const LivePlatform(id: 'ws', name: '央视卫视', count: 4),
    const LivePlatform(id: 'sd', name: '山东频道', count: 3),
    const LivePlatform(id: 'sh', name: '上海频道', count: 3),
    const LivePlatform(id: 'gd', name: '广东频道', count: 3),
    const LivePlatform(id: 'js', name: '江苏频道', count: 3),
    const LivePlatform(id: 'zj', name: '浙江频道', count: 3),
  ];

  @override
  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async {
    if (platform.id == 'cctv') {
      return [
        for (var i = 0; i < _cctvNames.length; i++)
          LiveChannel(
            key: 'cctv-${i + 1}',
            name: _cctvNames[i],
            urls: const ['https://example.com/c.m3u8'],
            number: '00${i + 1}',
            group: '央视网频',
            source: source.id,
          ),
      ];
    }
    const localNames = {
      'ws': ['北京卫视', '湖南卫视', '浙江卫视', '江苏卫视'],
      'sd': ['山东卫视', '山东齐鲁', '山东农科'],
      'sh': ['东方卫视', '上海新闻', '上海外语'],
      'gd': ['广东卫视', '广东珠江', '广东新闻'],
      'js': ['江苏卫视', '江苏城市', '江苏综艺'],
      'zj': ['浙江卫视', '浙江钱江', '浙江民生'],
    };
    final names = localNames[platform.id] ?? const <String>[];
    return [
      for (var i = 0; i < names.length; i++)
        LiveChannel(
          key: '${platform.id}-$i',
          name: names[i],
          urls: const ['https://example.com/l.m3u8'],
          number: '10${i + 1}',
          group: platform.name,
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

  /// 假流参数：只为预览图带上分辨率角标，产品代码不硬写。
  @override
  Size? get videoSize => const Size(1920, 1080);

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
