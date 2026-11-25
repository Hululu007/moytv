// 直播页版式断言：三列区（分组/频道/线路胶囊）、瘦信息行（左槽
// 预览帧 + 节目卡 + 切源小方钮）、顶栏分辨率+帧率、右上角信息+
// 设置两钮、中央居中转圈、信息单、设置单。
// 只测版式与接线，不改直播源数据、不改取流逻辑。
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

class _RedesignLiveRepository extends LiveRepository {
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

class _RedesignFakePlayback extends LivePlaybackController {
  _RedesignFakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _route = 0;
  LiveDecoderMode _decoderMode = LiveDecoderMode.auto;
  bool _buffering = false;
  String? _errorText;
  Size? _videoSize;
  double? _videoFps;

  void setBuffering(bool value) {
    _buffering = value;
    notifyListeners();
  }

  void setError(String? value) {
    _errorText = value;
    notifyListeners();
  }

  void setVideoParams({Size? size, double? fps}) {
    _videoSize = size;
    _videoFps = fps;
    notifyListeners();
  }

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
  bool get buffering => _buffering;

  @override
  String? get error => _errorText;

  @override
  Size? get videoSize => _videoSize;

  @override
  double? get videoFps => _videoFps;

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
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

Future<_RedesignFakePlayback> _pumpLive(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LiveStore(prefs, 'default')..load();
  addTearDown(store.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _RedesignLiveRepository();
  final playback = _RedesignFakePlayback(repository: repository);
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
    i < 30 && find.byKey(const ValueKey('live-grid')).evaluate().isEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byKey(const ValueKey('live-grid')), findsOneWidget);
  return playback;
}

void main() {
  testWidgets('三列区：分组/频道同行对齐、选中黄字、未选跟主题', (tester) async {
    await _pumpLive(tester);
    // 左中两列都在同一网格里，行数取最长一列（分组 3 行：收藏 + 2 分组）。
    expect(find.byKey(const ValueKey('live-group-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-group-g2')), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-channel-k1')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-channel-k2')), findsOneWidget);
    // 没有右侧大预览面板与它的统计行（用户改令：预览收进胶囊）。
    expect(find.byKey(const ValueKey('live-preview-pane')), findsNothing);
    expect(find.byKey(const ValueKey('live-preview-stats')), findsNothing);
    // 线路恢复成第三列胶囊格，与频道胶囊同高。
    expect(find.byKey(const ValueKey('live-line-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-line-1')), findsOneWidget);
    final channelSize = tester.getSize(
      find.byKey(const ValueKey('live-channel-k2')),
    );
    final lineSize = tester.getSize(find.byKey(const ValueKey('live-line-0')));
    expect(lineSize.height, channelSize.height);
    expect(channelSize.height, 48);
    // 频道胶囊全部是普通文字胶囊，胶囊里不放预览（用户改令：
    // 预览落在信息行左槽，见信息行那条测试）。
    expect(find.byKey(const ValueKey('live-channel-preview')), findsNothing);
    // 当前分组/频道/线路以黄字表示；未选中跟应用主题正文色
    // （改版前口径，不再写死白字/灰绿）。
    final onSurface = Theme.of(
      tester.element(find.byKey(const ValueKey('live-grid'))),
    ).colorScheme.onSurface;
    Text groupText(String text) =>
        tester.widget<Text>(find.text(text).first);
    expect(groupText('测试分组').style?.color, const Color(0xFFFFDF00));
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('live-channel-k1')),
              matching: find.text('频道一'),
            ),
          )
          .style
          ?.color,
      const Color(0xFFFFDF00),
    );
    expect(groupText('线路1').style?.color, const Color(0xFFFFDF00));
    expect(groupText('第二分组').style?.color, onSurface);
    expect(groupText('频道二').style?.color, onSurface);
    expect(groupText('线路2').style?.color, onSurface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('信息卡：正在播放/即将播放是真标题、切源按钮在原位', (tester) async {
    await _pumpLive(tester);
    // 正在播放 = 当前标题（subtitle 不同则拼在后面），
    // 即将播放 = 列表里下一条标题，不再是“暂无节目信息”占位。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('live-epg-now')))
          .data,
      '正在播放：频道一 · 主播小明',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('live-epg-next')))
          .data,
      '即将播放：频道二',
    );
    // 切源直达按钮回到信息卡行右端（改版前位置）。
    expect(find.byKey(const ValueKey('live-source-button')), findsOneWidget);
    // 信息行按用户截图比例瘦身并钉死上限，防止以后再长胖：
    // 整行 80 高（约一颗半胶囊），左槽/节目卡/切源钮同高。
    // 大数字卡已不存在：左槽整个换成预览帧。
    expect(find.byKey(const ValueKey('live-number-card')), findsNothing);
    final previewSize = tester.getSize(
      find.byKey(const ValueKey('live-info-preview')),
    );
    expect(previewSize.height, 80);
    expect(previewSize.height, lessThanOrEqualTo(84));
    expect(
      tester.getSize(find.byKey(const ValueKey('live-epg-card'))).height,
      80,
    );
    // 频道号只作预览帧上的小角标（小字），不再是占满卡的大字。
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('live-info-preview')),
              matching: find.text('001'),
            ),
          )
          .style
          ?.fontSize,
      lessThanOrEqualTo(12),
    );
    // 切源钮是随行高的小方钮（56 宽 × 80 高），不是独立高柱。
    final sourceCardSize = tester.getSize(
      find.byKey(const ValueKey('live-source-card')),
    );
    expect(sourceCardSize.width, 56);
    expect(sourceCardSize.height, 80);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏：分辨率与帧率拼一行、没帧率只显示分辨率', (tester) async {
    final playback = await _pumpLive(tester);
    playback.setVideoParams(size: const Size(1920, 1080), fps: 25);
    await tester.pump(const Duration(milliseconds: 100));
    // 帧率拼在顶栏分辨率后面（原预览区统计行已随大预览面板删除）。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('live-video-resolution')))
          .data,
      '[ 1920 x 1080 · 25 帧/秒 ]',
    );
    expect(find.byKey(const ValueKey('live-preview-stats')), findsNothing);
    // 帧率拿不到就不显示那一段，不编数。
    playback.setVideoParams(size: const Size(1920, 1080));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('live-video-resolution')))
          .data,
      '[ 1920 x 1080 ]',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓冲态：中央只有居中转圈、没有大播放三角', (tester) async {
    final playback = await _pumpLive(tester);
    playback.setBuffering(true);
    await tester.pump(const Duration(milliseconds: 100));
    final overlay = find.byKey(const ValueKey('live-center-overlay'));
    expect(overlay, findsOneWidget);
    expect(
      find.descendant(
        of: overlay,
        matching: find.byKey(const ValueKey('live-center-spinner')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: overlay, matching: find.byIcon(Icons.play_arrow_rounded)),
      findsNothing,
    );
    expect(
      find.descendant(of: overlay, matching: find.byIcon(Icons.play_arrow)),
      findsNothing,
    );
    // 转圈与播放区中心同一竖轴（改版时偏在右上角是明确的错）；
    // 竖直方向只差速率文字那一小截。
    final spinnerCenter = tester.getCenter(
      find.byKey(const ValueKey('live-center-spinner')),
    );
    final stageCenter = tester.getCenter(
      find.byKey(const ValueKey('live-stage')),
    );
    expect((spinnerCenter.dx - stageCenter.dx).abs(), lessThan(1));
    expect((spinnerCenter.dy - stageCenter.dy).abs(), lessThan(8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('右上角整组：报错态信息与设置两钮也都在', (tester) async {
    final playback = await _pumpLive(tester);
    expect(find.byKey(const ValueKey('live-video-info')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-video-settings')), findsOneWidget);
    playback.setError('直播中断');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('live-video-info')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-video-settings')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('线路切换：点线路列胶囊切线路、再点回第一条', (tester) async {
    final playback = await _pumpLive(tester);
    expect(playback.route, 0);
    await tester.tap(find.byKey(const ValueKey('live-line-1')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(playback.route, 1);
    final onSurface = Theme.of(
      tester.element(find.byKey(const ValueKey('live-grid'))),
    ).colorScheme.onSurface;
    Text lineText(String text) =>
        tester.widget<Text>(find.text(text).first);
    expect(lineText('线路2').style?.color, const Color(0xFFFFDF00));
    expect(lineText('线路1').style?.color, onSurface);
    await tester.tap(find.byKey(const ValueKey('live-line-0')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(playback.route, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收藏分组：点左列收藏、空收藏显示空态', (tester) async {
    await _pumpLive(tester);
    await tester.tap(find.byKey(const ValueKey('live-group-__favourites')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('还没有收藏频道'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('频道信息单：真实字段在、入口全在', (tester) async {
    await _pumpLive(tester);
    await tester.tap(find.byKey(const ValueKey('live-video-info')));
    await tester.pump(const Duration(milliseconds: 600));
    // 只列真实字段：频道名、频道号·源·分组、线路 1/2、subtitle。
    expect(find.text('频道一'), findsWidgets);
    expect(find.textContaining('频道号 001'), findsOneWidget);
    expect(find.textContaining('频道号 001'), findsOneWidget);
    expect(find.text('线路 1/2'), findsOneWidget);
    expect(find.text('主播小明'), findsOneWidget);
    // 没有真实分辨率就不写；信息单里不编节目单（节目信息只在
    // 下面的节目卡里按真实 subtitle 显示）。
    expect(find.textContaining('分辨率'), findsNothing);
    // 入口：全屏/换源/刷新/收藏/睡眠定时。
    expect(find.byKey(const ValueKey('live-info-fullscreen')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('live-info-switch-source')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('live-info-refresh')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('live-info-favourite')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('live-info-sleep')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放设置单：解码模式可切换、恢复默认在', (tester) async {
    final playback = await _pumpLive(tester);
    await tester.tap(find.byKey(const ValueKey('live-video-settings')));
    // 点按只发事件不跑帧：先 pump 一次让点按生效、单子入栈，
    // 再 pump 一次让入场动画走完，单子落到屏内再点里面的格。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('解码模式'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-settings-decoder')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-settings-reset')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-settings-sleep')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('live-settings-decoder')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(playback.decoderMode, LiveDecoderMode.hardware);
    expect(find.textContaining('硬解'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
