import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/audio_background.dart';
import 'package:moyi/audio_playback.dart';
import 'package:moyi/content_detail_screen.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/core_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假播放引擎：调用记账 + 事件手动发，播控走真实控制器逻辑。
class FakeAudioEngine implements AudioPlayerEngine {
  final _positionController = StreamController<Duration>();
  final _durationController = StreamController<Duration>();
  final _playingController = StreamController<bool>();
  final _completedController = StreamController<bool>();
  final _errorController = StreamController<String>();

  final opens = <String>[];
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  final seeks = <Duration>[];
  final rates = <double>[];
  int disposeCount = 0;

  bool playingValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = Duration.zero;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<bool> get completedStream => _completedController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  bool get playing => playingValue;

  @override
  Duration get position => positionValue;

  @override
  Duration get duration => durationValue;

  void emitPosition(Duration value) {
    positionValue = value;
    _positionController.add(value);
  }

  void emitDuration(Duration value) {
    durationValue = value;
    _durationController.add(value);
  }

  void emitPlaying(bool value) {
    playingValue = value;
    _playingController.add(value);
  }

  void emitCompleted() => _completedController.add(true);

  void emitError(String message) => _errorController.add(message);

  @override
  Future<void> open(String url) async {
    opens.add(url);
    positionValue = Duration.zero;
    durationValue = Duration.zero;
  }

  @override
  Future<void> play() async {
    plays++;
    emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    emitPlaying(false);
  }

  @override
  Future<void> stop() async {
    stops++;
    playingValue = false;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    emitPosition(position);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _completedController.close();
    await _errorController.close();
  }
}

class FakeContentSource extends ContentSource {
  FakeContentSource({this.trackResolver});

  final Future<ContentAudioTrack> Function(int index)? trackResolver;

  static const book = ContentBook(id: 'book1', title: '测试书');
  static const chapters = [
    ContentChapter(id: 'c0', title: '第一集'),
    ContentChapter(id: 'c1', title: '第二集'),
    ContentChapter(id: 'c2', title: '第三集'),
  ];

  @override
  String get id => 'fake_audio';

  @override
  String get name => '假听书源';

  @override
  ContentSection get section => ContentSection.audio;

  @override
  Future<List<ContentCategory>> categories() async => const [];

  @override
  Future<ContentPage> catalog(String categoryId, int page) async =>
      const ContentPage(items: []);

  @override
  Future<ContentPage> search(String keyword, int page) async =>
      const ContentPage(items: []);

  @override
  Future<ContentBookDetail> detail(String bookId) async =>
      const ContentBookDetail(book: book, chapters: chapters);

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    final index = chapters.indexWhere((c) => c.id == chapter.id);
    final resolver = trackResolver;
    if (resolver != null) return resolver(index);
    return ContentAudioTrack(url: 'https://example.com/track_$index.mp3');
  }
}

ContentBookDetail fakeDetail() =>
    const ContentBookDetail(book: FakeContentSource.book, chapters: FakeContentSource.chapters);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mediaChannel = MethodChannel('moyi/audio_media');
  const capsuleChannel = MethodChannel('moyi/audio_capsule');
  const floatingChannel = MethodChannel('moyi/floating_window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final mediaCalls = <MethodCall>[];
  final capsuleCalls = <MethodCall>[];
  final floatingCalls = <MethodCall>[];
  var permissionGranted = true;

  AudioPlaybackController? controller;
  FakeAudioEngine? engine;

  Future<void> flush() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mediaCalls.clear();
    capsuleCalls.clear();
    floatingCalls.clear();
    permissionGranted = true;
    messenger.setMockMethodCallHandler(mediaChannel, (call) async {
      mediaCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(capsuleChannel, (call) async {
      capsuleCalls.add(call);
      if (call.method == 'isPermissionGranted') return permissionGranted;
      return true;
    });
    messenger.setMockMethodCallHandler(floatingChannel, (call) async {
      floatingCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    controller?.dispose();
    controller = null;
    engine = null;
    AudioPlaybackController.resetInstance();
    messenger.setMockMethodCallHandler(mediaChannel, null);
    messenger.setMockMethodCallHandler(capsuleChannel, null);
    messenger.setMockMethodCallHandler(floatingChannel, null);
  });

  AudioPlaybackController makeController() {
    engine = FakeAudioEngine();
    controller = AudioPlaybackController(engine: engine);
    return controller!;
  }

  Future<void> playFirstChapter(AudioPlaybackController c) async {
    final source = FakeContentSource();
    await c.playChapter(source, fakeDetail(), 0);
    await flush();
  }

  Map lastPublishArgs() {
    final publishes = mediaCalls.where((c) => c.method == 'publish');
    return publishes.last.arguments as Map;
  }

  group('自有链路：播控', () {
    test('播新的一章停掉旧的：只开新地址，引擎不销毁', () async {
      final c = makeController();
      final source = FakeContentSource();
      await c.playChapter(source, fakeDetail(), 0);
      await flush();
      await c.playChapter(source, fakeDetail(), 1);
      await flush();
      expect(engine!.opens, [
        'https://example.com/track_0.mp3',
        'https://example.com/track_1.mp3',
      ]);
      expect(engine!.disposeCount, 0);
      expect(c.playingIndex, 1);
      expect(c.playing, isTrue);
    });

    test('慢取流的旧请求盖不掉后点的章节（代次号）', () async {
      final c = makeController();
      final gate = Completer<ContentAudioTrack>();
      var calls = 0;
      final source = FakeContentSource(
        trackResolver: (index) {
          calls++;
          if (calls == 1) return gate.future;
          return Future.value(
            ContentAudioTrack(url: 'https://example.com/track_$index.mp3'),
          );
        },
      );
      final first = c.playChapter(source, fakeDetail(), 0);
      await c.playChapter(source, fakeDetail(), 1);
      gate.complete(
        const ContentAudioTrack(url: 'https://example.com/track_0.mp3'),
      );
      await first;
      await flush();
      expect(engine!.opens, ['https://example.com/track_1.mp3']);
      expect(c.playingIndex, 1);
    });

    test('播完自动连播下一集', () async {
      final c = makeController();
      await playFirstChapter(c);
      engine!.emitCompleted();
      await flush();
      expect(engine!.opens, [
        'https://example.com/track_0.mp3',
        'https://example.com/track_1.mp3',
      ]);
      expect(c.playingIndex, 1);
    });

    test('播放出错重试一次，再错报“音频播放出错”', () async {
      final c = makeController();
      await playFirstChapter(c);
      engine!.emitError('boom');
      await flush();
      expect(engine!.opens, hasLength(2));
      expect(c.trackError, isEmpty);
      engine!.emitError('boom');
      await flush();
      expect(c.trackError, '音频播放出错');
      expect(engine!.opens, hasLength(2));
    });

    test('取流失败报源方错误，不崩', () async {
      final c = makeController();
      final source = FakeContentSource(
        trackResolver: (_) => throw AppFailure('该源不支持音频播放'),
      );
      await c.playChapter(source, fakeDetail(), 0);
      await flush();
      expect(c.trackError, '该源不支持音频播放');
      expect(engine!.opens, isEmpty);
    });

    test('stop 复位状态并撤掉三路输出', () async {
      final c = makeController();
      await playFirstChapter(c);
      await c.stop();
      await flush();
      expect(engine!.stops, 1);
      expect(c.playingIndex, -1);
      expect(c.playing, isFalse);
      expect(mediaCalls.map((call) => call.method), contains('release'));
      expect(capsuleCalls.map((call) => call.method), contains('stop'));
    });

    test('isCurrentBook 只认同一源同一书且有在播曲目', () async {
      final c = makeController();
      expect(c.isCurrentBook('fake_audio', 'book1'), isFalse);
      await playFirstChapter(c);
      expect(c.isCurrentBook('fake_audio', 'book1'), isTrue);
      expect(c.isCurrentBook('other', 'book1'), isFalse);
      expect(c.isCurrentBook('fake_audio', 'other'), isFalse);
      await c.stop();
      expect(c.isCurrentBook('fake_audio', 'book1'), isFalse);
    });
  });

  group('自有链路：后台与锁屏', () {
    test('切后台不暂停，并出锁屏载荷（九键齐全）', () async {
      final c = makeController();
      await playFirstChapter(c);
      engine!.emitDuration(const Duration(milliseconds: 1800000));
      engine!.emitPosition(const Duration(milliseconds: 61000));
      await flush();
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      expect(engine!.pauses, 0);
      expect(engine!.playingValue, isTrue);
      final args = lastPublishArgs();
      expect(args['bookTitle'], '测试书');
      expect(args['chapterTitle'], '第一集');
      expect(args['coverUrl'], '');
      expect(args['playing'], isTrue);
      expect(args['positionMs'], 61000);
      expect(args['durationMs'], 1800000);
      expect(args['hasPrevious'], isFalse);
      expect(args['hasNext'], isTrue);
      expect(args['rate'], 1.0);
    });

    test('锁屏按键经原生通道分发到控制器', () async {
      final c = makeController();
      await playFirstChapter(c);
      await messenger.handlePlatformMessage(
        'moyi/audio_media',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('mediaAction', {'action': 'pause'}),
        ),
        (_) {},
      );
      await flush();
      expect(engine!.pauses, 1);
      expect(c.manuallyPaused, isTrue);
    });

    test('锁屏按键：播/停/上下章', () async {
      final c = makeController();
      await playFirstChapter(c);
      c.handleMediaAction('pause');
      await flush();
      expect(engine!.pauses, 1);
      expect(c.manuallyPaused, isTrue);
      c.handleMediaAction('play');
      await flush();
      expect(engine!.plays, 2);
      expect(c.manuallyPaused, isFalse);
      c.handleMediaAction('next');
      await flush();
      expect(c.playingIndex, 1);
      c.handleMediaAction('previous');
      await flush();
      expect(c.playingIndex, 0);
    });

    test('手动暂停是粘性的：回前台不自动续播', () async {
      final c = makeController();
      await playFirstChapter(c);
      await c.toggle();
      await flush();
      expect(c.playing, isFalse);
      expect(c.manuallyPaused, isTrue);
      final playsBefore = engine!.plays;
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      c.handleLifecycleState(AppLifecycleState.resumed);
      await flush();
      expect(engine!.plays, playsBefore);
      expect(c.playing, isFalse);
    });

    test('回前台同步引擎真实状态，不替用户按播放', () async {
      final c = makeController();
      await playFirstChapter(c);
      engine!.emitPosition(const Duration(milliseconds: 90000));
      await flush();
      c.handleLifecycleState(AppLifecycleState.resumed);
      await flush();
      expect(c.position.inMilliseconds, 90000);
      expect(engine!.plays, 1);
    });
  });

  group('胶囊条件与权限一次流', () {
    test('后台+在播+有权限：出胶囊；回前台：藏胶囊', () async {
      final c = makeController();
      await playFirstChapter(c);
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      final shows = capsuleCalls.where((call) => call.method == 'show');
      expect(shows, hasLength(1));
      final args = shows.single.arguments as Map;
      expect(args['title'], '测试书');
      expect(args['chapter'], '第一集');
      expect(args['playing'], isTrue);
      c.handleLifecycleState(AppLifecycleState.resumed);
      await flush();
      expect(capsuleCalls.map((call) => call.method), contains('hide'));
    });

    test('前台在播不出胶囊，暂停时切后台也不出', () async {
      final c = makeController();
      await playFirstChapter(c);
      await flush();
      expect(
        capsuleCalls.where((call) => call.method == 'show'),
        isEmpty,
      );
      await c.toggle();
      await flush();
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      expect(
        capsuleCalls.where((call) => call.method == 'show'),
        isEmpty,
      );
    });

    test('权限未给：跳授权页一次且只一次，持久标记跨实例生效', () async {
      permissionGranted = false;
      final c = makeController();
      await playFirstChapter(c);
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      expect(
        floatingCalls.map((call) => call.method),
        ['requestPermission'],
      );
      c.handleLifecycleState(AppLifecycleState.resumed);
      await flush();
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      expect(floatingCalls, hasLength(1));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('audio_capsule_overlay_prompted'), isTrue);

      // 新实例（同持久存储）再切后台：不再跳。
      c.dispose();
      controller = null;
      final c2 = makeController();
      await playFirstChapter(c2);
      c2.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      expect(floatingCalls, hasLength(1));
    });

    test('拒绝后降级：无胶囊、有锁屏、不抛错', () async {
      permissionGranted = false;
      final c = makeController();
      await playFirstChapter(c);
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      expect(
        capsuleCalls.where((call) => call.method == 'show'),
        isEmpty,
      );
      expect(mediaCalls.map((call) => call.method), contains('publish'));
      expect(c.playing, isTrue);
    });
  });

  group('外部音频会话（播放页音频模式）', () {
    ExternalAudioSession fakeSession({
      required List<String> actions,
      required List<int> takeovers,
      bool playing = true,
    }) {
      return ExternalAudioSession(
        ownerId: 'player_screen@test',
        infoProvider: () => AudioLockscreenInfo(
          bookTitle: '剧名',
          chapterTitle: '第 2 集',
          coverUrl: 'https://example.com/cover.jpg',
          playing: playing,
          positionMs: 30000,
          durationMs: 600000,
          hasPrevious: true,
          hasNext: true,
          rate: 1.0,
        ),
        onAction: actions.add,
        onTakeover: () => takeovers.add(1),
      );
    }

    test('认领后锁屏发布外部信息，胶囊条件同样生效', () async {
      final c = makeController();
      final actions = <String>[];
      final takeovers = <int>[];
      c.claimExternalAudio(
        fakeSession(actions: actions, takeovers: takeovers),
      );
      await flush();
      final args = lastPublishArgs();
      expect(args['bookTitle'], '剧名');
      expect(args['chapterTitle'], '第 2 集');
      expect(args['playing'], isTrue);
      c.handleLifecycleState(AppLifecycleState.paused);
      await flush();
      final shows = capsuleCalls.where((call) => call.method == 'show');
      expect(shows, hasLength(1));
      final showArgs = shows.single.arguments as Map;
      expect(showArgs['title'], '剧名');
      expect(showArgs['chapter'], '第 2 集');
    });

    test('锁屏按键交给外部归属方，不动自有引擎', () async {
      final c = makeController();
      final actions = <String>[];
      final takeovers = <int>[];
      c.claimExternalAudio(
        fakeSession(actions: actions, takeovers: takeovers),
      );
      await flush();
      c.handleMediaAction('pause');
      c.handleMediaAction('next');
      await flush();
      expect(actions, ['pause', 'next']);
      expect(engine!.pauses, 0);
      expect(engine!.opens, isEmpty);
    });

    test('外部认领时停掉自有播放（播新章停旧声）', () async {
      final c = makeController();
      await playFirstChapter(c);
      final actions = <String>[];
      final takeovers = <int>[];
      c.claimExternalAudio(
        fakeSession(actions: actions, takeovers: takeovers),
      );
      await flush();
      expect(engine!.stops, 1);
      expect(c.playingIndex, -1);
      expect(lastPublishArgs()['bookTitle'], '剧名');
    });

    test('自有起播时通知外部归属方接管', () async {
      final c = makeController();
      final actions = <String>[];
      final takeovers = <int>[];
      c.claimExternalAudio(
        fakeSession(actions: actions, takeovers: takeovers),
      );
      await flush();
      await playFirstChapter(c);
      expect(takeovers, hasLength(1));
      expect(engine!.opens, hasLength(1));
      expect(lastPublishArgs()['bookTitle'], '测试书');
    });

    test('放弃认领：错的 owner 不生效，对的撤掉输出', () async {
      final c = makeController();
      final actions = <String>[];
      final takeovers = <int>[];
      c.claimExternalAudio(
        fakeSession(actions: actions, takeovers: takeovers),
      );
      await flush();
      c.releaseExternalAudio('someone-else');
      await flush();
      expect(mediaCalls.map((call) => call.method), isNot(contains('release')));
      c.releaseExternalAudio('player_screen@test');
      await flush();
      expect(mediaCalls.map((call) => call.method), contains('release'));
      expect(capsuleCalls.map((call) => call.method), contains('stop'));
    });

    test('外部状态上报刷新锁屏载荷', () async {
      final c = makeController();
      var playing = true;
      final actions = <String>[];
      final takeovers = <int>[];
      c.claimExternalAudio(
        ExternalAudioSession(
          ownerId: 'player_screen@test',
          infoProvider: () => AudioLockscreenInfo(
            bookTitle: '剧名',
            chapterTitle: '第 2 集',
            coverUrl: '',
            playing: playing,
            positionMs: 30000,
            durationMs: 600000,
            hasPrevious: true,
            hasNext: true,
            rate: 1.0,
          ),
          onAction: actions.add,
          onTakeover: () => takeovers.add(1),
        ),
      );
      await flush();
      playing = false;
      c.reportExternalAudio();
      await flush();
      expect(lastPublishArgs()['playing'], isFalse);
    });
  });

  group('详情页挂接', () {
    testWidgets('返回离页继续播、重进显示真实状态', (tester) async {
      final fakeEngine = FakeAudioEngine();
      final testController = AudioPlaybackController(engine: fakeEngine);
      AudioPlaybackController.installTestInstance(testController);
      addTearDown(AudioPlaybackController.resetInstance);
      final source = FakeContentSource();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ContentDetailScreen(
                        source: source,
                        book: FakeContentSource.book,
                      ),
                    ),
                  );
                },
                child: const Text('打开详情'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.text('第一集'), findsOneWidget);

      await tester.tap(find.text('第一集'));
      await tester.pumpAndSettle();
      expect(fakeEngine.opens, ['https://example.com/track_0.mp3']);
      expect(find.byTooltip('暂停'), findsOneWidget);

      // 返回离页：播放继续，引擎不销毁。
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fakeEngine.stops, 0);
      expect(fakeEngine.disposeCount, 0);
      expect(testController.playing, isTrue);
      expect(testController.playingIndex, 0);

      // 重进：显示当前真实状态。
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('暂停'), findsOneWidget);
      expect(find.text('第 1 集 / 共 3 集'), findsOneWidget);
    });
  });
}
