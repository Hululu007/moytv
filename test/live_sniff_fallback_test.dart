// 直播链嗅探兜底（梯子最后一级）的断言：
// - 取流（线路解析）失败且频道地址是网页：经宿主钩子嗅探取链，
//   嗅到的地址递给 mpv 起播；嗅不到如实保留原取流错误；
// - 取流失败但频道是直链：不嗅探，原错误保留；
// - 正常直链频道：不嗅探、照常直走；
// - 没注入钩子：嗅探级整体停用，原错误保留；
// - 核播失败、重连梯子耗尽：落嗅探续播，闩锁只落一次；嗅不到
//   时原播放错误保留，不假装有信号。
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_settings.dart';
import 'package:moyi/live_sources.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

const _source = LiveSource(
  id: 'sniff_test',
  name: '嗅探测试源',
  description: '',
  protocol: LiveProtocol.list,
);

const _webChannel = LiveChannel(
  key: 'web',
  name: '网页台',
  urls: ['https://example.com/live/room.html'],
  headers: {'User-Agent': 'ua-test'},
  group: '测试分组',
  source: 'sniff_test',
);

const _directChannel = LiveChannel(
  key: 'direct',
  name: '直链台',
  urls: ['https://example.com/plain.m3u8'],
  group: '测试分组',
  source: 'sniff_test',
);

/// uri 带 broken 的台：ScriptedPlayer 打开即报播放错误，走核播
/// 失败→重连梯子。地址本身是网页形态，供耗尽后落嗅探。
const _brokenWebChannel = LiveChannel(
  key: 'brokenweb',
  name: '坏网页台',
  urls: ['https://example.com/broken-room.html'],
  group: '测试分组',
  source: 'sniff_test',
);

class _Repo extends LiveRepository {
  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.urls.first, headers: channel.headers);
}

class _ThrowingRepo extends LiveRepository {
  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => throw AppFailure('线路解析失败');
}

Future<void> _until(bool Function() condition, {int seconds = 20}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveSettingsStore.instance.resetForTest();
  });

  group('直播嗅探兜底', () {
    late ScriptedPlayer scripted;
    late LivePlaybackController controller;
    var resolverCalls = 0;
    String? resolverPage;
    Map<String, String>? resolverHeaders;

    LivePlaybackController build(
      LiveRepository repository, {
      String? Function()? sniffResult,
    }) {
      scripted = ScriptedPlayer();
      resolverCalls = 0;
      resolverPage = null;
      resolverHeaders = null;
      final built = LivePlaybackController(
        repository: repository,
        createPlayer: () => Player(platformPlayer: scripted),
        buildVideoController: false,
      );
      if (sniffResult != null) {
        built.sniffResolver = (pageUrl, headers) async {
          resolverCalls++;
          resolverPage = pageUrl;
          resolverHeaders = headers;
          return sniffResult();
        };
      }
      controller = built;
      addTearDown(built.dispose);
      return built;
    }

    test('取流失败＋网页频道：嗅探取链递给 mpv 起播', () async {
      build(
        _ThrowingRepo(),
        sniffResult: () => 'https://cdn.example.com/fixed.m3u8',
      );
      await controller.load(_source, const [_webChannel]);
      expect(resolverCalls, 1);
      expect(resolverPage, 'https://example.com/live/room.html');
      expect(resolverHeaders, {'User-Agent': 'ua-test'});
      expect(
        scripted.opened.map((media) => media.uri),
        ['https://cdn.example.com/fixed.m3u8'],
      );
      expect(controller.error, isNull);
    });

    test('取流失败＋网页频道＋嗅不到：原取流错误保留', () async {
      build(_ThrowingRepo(), sniffResult: () => null);
      await controller.load(_source, const [_webChannel]);
      expect(resolverCalls, 1);
      expect(scripted.opened, isEmpty);
      expect(controller.error, '线路解析失败');
    });

    test('取流失败＋直链频道：不嗅探，原错误保留', () async {
      build(
        _ThrowingRepo(),
        sniffResult: () => 'https://cdn.example.com/fixed.m3u8',
      );
      await controller.load(_source, const [_directChannel]);
      expect(resolverCalls, 0);
      expect(scripted.opened, isEmpty);
      expect(controller.error, '线路解析失败');
    });

    test('正常直链频道：不嗅探，照常直走', () async {
      build(
        _Repo(),
        sniffResult: () => 'https://cdn.example.com/fixed.m3u8',
      );
      await controller.load(_source, const [_directChannel]);
      expect(resolverCalls, 0);
      expect(
        scripted.opened.map((media) => media.uri),
        ['https://example.com/plain.m3u8'],
      );
      expect(controller.error, isNull);
    });

    test('没注入钩子＋取流失败＋网页频道：原错误保留', () async {
      build(_ThrowingRepo());
      await controller.load(_source, const [_webChannel]);
      expect(scripted.opened, isEmpty);
      expect(controller.error, '线路解析失败');
    });

    test('核播失败重连耗尽：落嗅探续播，只落一次', () async {
      build(
        _Repo(),
        sniffResult: () => 'https://cdn.example.com/fixed.m3u8',
      );
      await controller.load(_source, const [_brokenWebChannel]);
      await _until(
        () => scripted.opened.any(
          (media) => media.uri == 'https://cdn.example.com/fixed.m3u8',
        ),
      );
      expect(resolverCalls, 1);
      expect(resolverPage, 'https://example.com/broken-room.html');
      expect(controller.error, isNull);
      // 嗅到的地址打开后不再触发第二次嗅探（闩锁）。
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(resolverCalls, 1);
    });

    test('核播失败重连耗尽＋嗅不到：原播放错误保留', () async {
      build(_Repo(), sniffResult: () => null);
      await controller.load(_source, const [_brokenWebChannel]);
      await _until(() => resolverCalls >= 1);
      expect(resolverCalls, 1);
      // 原播放错误原样保留：最后一次播放器报错文案。
      expect(controller.error, 'synthetic decoder failure');
      // 耗尽后不再重播原坏线路：打开次数停在初播＋重连。
      final openedCount = scripted.opened.length;
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(scripted.opened.length, openedCount);
      expect(resolverCalls, 1);
    });
  });
}
