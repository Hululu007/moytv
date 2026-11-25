// 直播「+」导入 + 节目单 + 回看 的测试：
// - 解析器：M3U 样本（分组/台标/节目单地址/附加行/多线路/
//   回看/授权键）与 TXT 样本（分组/多线路/请求头/分组清设置）；
// - analyzeM3u：节目单地址透传、报错按格式说清；
// - XMLTV：解析、对台（tvg-id 与显示名两路）、正在/下一条；
// - 节目单服务：gzip 内容能解、缓存目录走测试注入；
// - 回看地址生成：append 模板与 default 模板；
// - 组件：左下角「+」固定不动（滚列表不跟）、点开菜单两项齐；
//   带节目单的源信息行显示真节目名，节目单里过去的节目点回看
//   按模板地址起播。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:moyi/live_catchup.dart';
import 'package:moyi/live_epg.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_parser.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/live_store.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/m3u_subscriptions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

void main() {
  group('M3U 解析（easytv 支持面）', () {
    const sample = '#EXTM3U tvg-url="https://example.com/epg.xml" '
        'catchup="append" '
        'catchup-source="?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}" '
        'catchup-replace="/PLTV/,/TVOD/"\n'
        '#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV-1" tvg-chno="1" '
        'tvg-logo="https://example.com/cctv1.png" group-title="央视",CCTV-1\n'
        '#EXTVLCOPT:http-user-agent=Mozilla/5.0 TestUA\n'
        '#EXTVLCOPT:http-referrer=https://example.com/\n'
        '#EXTVLCOPT:http-origin=https://origin.example.com\n'
        '#EXTVLCOPT:http-cookie=session=abc\n'
        'http://example.com/PLTV/cctv1.m3u8\n'
        'http://example.com/PLTV/cctv1-backup.m3u8\n'
        '#EXTINF:-1 tvg-id="hnws" group-title="卫视",湖南卫视\n'
        '#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha\n'
        '#KODIPROP:inputstream.adaptive.license_key=https://example.com/license\n'
        '#KODIPROP:inputstream.adaptive.manifest_type=mpd\n'
        'http://example.com/hnws.mpd\n';

    test('分组/频道/线路数与节目单地址', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      expect(parsed.format, LiveFormat.m3u);
      expect(parsed.epg, 'https://example.com/epg.xml');
      expect(parsed.groups.map((group) => group.name), ['央视', '卫视']);
      expect(parsed.channelCount, 2);
      final cctv = parsed.groups.first.channels.single;
      expect(cctv.urls, [
        'http://example.com/PLTV/cctv1.m3u8',
        'http://example.com/PLTV/cctv1-backup.m3u8',
      ]);
    });

    test('台标/tvg-id/tvg-name/频道号落位', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      final cctv = parsed.groups.first.channels.single;
      expect(cctv.logo, 'https://example.com/cctv1.png');
      expect(cctv.tvgId, 'cctv1');
      expect(cctv.tvgName, 'CCTV-1');
      expect(cctv.number, '001');
    });

    test('#EXTVLCOPT 附加行落成播放请求头', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      final cctv = parsed.groups.first.channels.single;
      expect(cctv.headers['User-Agent'], 'Mozilla/5.0 TestUA');
      expect(cctv.headers['Referer'], 'https://example.com/');
      expect(cctv.headers['Origin'], 'https://origin.example.com');
      expect(cctv.headers['Cookie'], 'session=abc');
    });

    test('回看：全源默认被频道继承', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      final cctv = parsed.groups.first.channels.single;
      expect(cctv.catchup, isNotNull);
      expect(cctv.catchup!.type, 'append');
      expect(
        cctv.catchup!.source,
        '?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}',
      );
      expect(cctv.catchup!.replace, '/PLTV/,/TVOD/');
    });

    test('#KODIPROP 授权键与清单类型解析存储', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      final hnws = parsed.groups.last.channels.single;
      expect(hnws.licenseType, 'com.widevine.alpha');
      expect(hnws.licenseKey, 'https://example.com/license');
      expect(hnws.format, 'mpd');
    });

    test('#EXTINF 上的回看覆盖全源默认', () {
      const own = '#EXTM3U catchup="append" catchup-source="?global=1"\n'
          '#EXTINF:-1 catchup="default" '
          'catchup-source="https://example.com/vod/\${(b)timestamp}.m3u8",台一\n'
          'http://example.com/a.m3u8\n';
      final parsed = LiveParser.parse(own, source: 'test');
      final channel = parsed.groups.single.channels.single;
      expect(channel.catchup!.type, 'default');
      expect(
        channel.catchup!.source,
        'https://example.com/vod/\${(b)timestamp}.m3u8',
      );
    });
  });

  group('TXT 解析（easytv 支持面）', () {
    const sample = '央视,#genre#\n'
        'ua=Mozilla/5.0 TestUA\n'
        'CCTV-1,http://example.com/c1.m3u8#http://example.com/c1b.m3u8'
        '|Referer=http://example.com/\n'
        'CCTV-2,http://example.com/c2.m3u8\n'
        '卫视,#genre#\n'
        '湖南卫视,http://example.com/hn.m3u8\n';

    test('分组/频道/多线路（# 分隔）', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      expect(parsed.format, LiveFormat.text);
      expect(parsed.groups.map((group) => group.name), ['央视', '卫视']);
      expect(parsed.channelCount, 3);
      final cctv1 = parsed.groups.first.channels.first;
      expect(cctv1.urls, [
        'http://example.com/c1.m3u8',
        'http://example.com/c1b.m3u8',
      ]);
    });

    test('设置行作用于其后频道、| 后请求头落位', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      final cctv1 = parsed.groups.first.channels.first;
      expect(cctv1.headers['User-Agent'], 'Mozilla/5.0 TestUA');
      expect(cctv1.headers['Referer'], 'http://example.com/');
    });

    test('分组行清掉前一组的设置行', () {
      final parsed = LiveParser.parse(sample, source: 'test');
      final hnws = parsed.groups.last.channels.single;
      expect(hnws.headers, isEmpty);
    });
  });

  group('analyzeM3u', () {
    test('txt 文件也能过，节目单地址透传', () {
      final report = analyzeM3u(
        '分组,#genre#\n频道一,http://example.com/a.m3u8\n',
        source: 'test',
      );
      expect(report.channelCount, 1);
      final m3u = analyzeM3u(
        '#EXTM3U tvg-url="https://example.com/e.xml"\n'
        '#EXTINF:-1,频道一\nhttp://example.com/a.m3u8\n',
        source: 'test',
      );
      expect(m3u.epg, 'https://example.com/e.xml');
    });

    test('没有可用频道时报错按格式说清', () {
      expect(
        () => analyzeM3u('随便一段文字\n没有频道\n', source: 'test'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('txt 直播列表'),
          ),
        ),
      );
      expect(
        () => analyzeM3u(
          '#EXTM3U\n#EXTINF:-1,频道一\n不是地址\n',
          source: 'test',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('地址不可用'),
          ),
        ),
      );
    });

    test('远程源名：文件头 name 优先、否则主机名', () {
      expect(
        m3uRemoteName(
          '#EXTM3U name="我的订阅"\n#EXTINF:-1,台\nhttp://a.com/1.m3u8\n',
          'https://example.com/live.m3u',
        ),
        '我的订阅',
      );
      expect(
        m3uRemoteName(
          '#EXTM3U\n#EXTINF:-1,台\nhttp://a.com/1.m3u8\n',
          'https://example.com/live.m3u',
        ),
        'example.com',
      );
    });
  });

  group('XMLTV 节目单', () {
    const xml = '<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n'
        '<channel id="cctv1"><display-name>CCTV-1综合</display-name></channel>\n'
        '<channel id="hnws"><display-name>湖南卫视</display-name></channel>\n'
        '<programme start="20261125070000 +0800" stop="20261125080000 +0800" '
        'channel="cctv1"><title>朝闻天下</title></programme>\n'
        '<programme start="20261125080000 +0800" stop="20261125090000 +0800" '
        'channel="cctv1"><title>新闻直播间</title></programme>\n'
        '<programme start="20261125090000 +0800" stop="20261125100000 +0800" '
        'channel="cctv1"><title>今日说法</title></programme>\n'
        '</tv>';

    test('解析出节目并按 tvg-id 对台取正在/下一条', () {
      final guide = parseXmltvGuide(xml);
      const channel = LiveChannel(
        key: 'k',
        name: 'CCTV-1',
        urls: ['http://example.com/a.m3u8'],
        tvgId: 'cctv1',
      );
      final list = guide.programmesFor(channel);
      expect(list.map((item) => item.title), ['朝闻天下', '新闻直播间', '今日说法']);
      final at = list[1].start.add(const Duration(minutes: 10));
      final hit = guide.nowNext(channel, at);
      expect(hit.now?.title, '新闻直播间');
      expect(hit.next?.title, '今日说法');
    });

    test('tvg-id 对不上时按显示名对台', () {
      final guide = parseXmltvGuide(xml);
      const channel = LiveChannel(
        key: 'k',
        name: 'CCTV-1综合',
        urls: ['http://example.com/a.m3u8'],
      );
      expect(guide.programmesFor(channel), hasLength(3));
    });

    test('服务：gzip 内容能解、走注入的拉取与缓存目录', () async {
      final dir = Directory.systemTemp.createTempSync('epg_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      LiveEpgService.debugCacheDir = dir;
      LiveEpgService.debugFetcher = (_) async =>
          GZipCodec().encode(utf8.encode(xml));
      addTearDown(() {
        LiveEpgService.debugCacheDir = null;
        LiveEpgService.debugFetcher = null;
      });
      final guide = await LiveEpgService.instance.load(
        'https://example.com/epg.xml.gz',
        force: true,
      );
      expect(guide.byChannelId['cctv1'], hasLength(3));
      expect(
        dir.listSync().where((file) => file.path.contains('epg_')),
        hasLength(1),
      );
    });
  });

  group('回看地址生成', () {
    test('append：先 replace 改地址再拼模板', () {
      final url = formatLiveCatchupUrl(
        catchup: const LiveCatchup(
          type: 'append',
          source:
              '?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}',
          replace: '/PLTV/,/TVOD/',
        ),
        liveUrl: 'http://example.com/PLTV/cctv1.m3u8',
        start: DateTime(2026, 11, 25, 8),
        end: DateTime(2026, 11, 25, 9),
      );
      expect(
        url,
        'http://example.com/TVOD/cctv1.m3u8'
        '?playseek=20261125080000-20261125090000',
      );
    });

    test('append：地址已有查询串时模板的 ? 换 &', () {
      final url = formatLiveCatchupUrl(
        catchup: const LiveCatchup(
          type: 'append',
          source: '?playseek=\${(b)timestamp}',
        ),
        liveUrl: 'http://example.com/a.m3u8?token=1',
        start: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        end: DateTime.fromMillisecondsSinceEpoch(1700003600000),
      );
      expect(url, 'http://example.com/a.m3u8?token=1&playseek=1700000000');
    });

    test('default：模板本身就是回看地址', () {
      final start = DateTime(2026, 11, 25, 8);
      final url = formatLiveCatchupUrl(
        catchup: const LiveCatchup(
          type: 'default',
          source: 'https://example.com/vod/\${(b)timestamp}.m3u8',
        ),
        liveUrl: 'http://example.com/live.m3u8',
        start: start,
        end: DateTime(2026, 11, 25, 9),
      );
      expect(
        url,
        'https://example.com/vod/${start.millisecondsSinceEpoch ~/ 1000}.m3u8',
      );
    });

    test('模板为空回 null', () {
      expect(
        formatLiveCatchupUrl(
          catchup: const LiveCatchup(),
          liveUrl: 'http://example.com/a.m3u8',
          start: DateTime(2026),
          end: DateTime(2026),
        ),
        isNull,
      );
    });
  });

  group('直播页「+」与节目单', () {
    testWidgets('「+」固定左下角：滚列表不动，点开菜单两项齐', (tester) async {
      await _pumpLivePage(tester);
      final button = find.byKey(const ValueKey('live-import-add'));
      expect(button, findsOneWidget);
      final before = tester.getRect(button);
      expect(before.left, 12);
      expect(before.bottom, closeTo(844 - 12, 1));
      await tester.drag(
        find.byKey(const ValueKey('live-grid')),
        const Offset(0, -400),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(button), before);
      await tester.tap(button);
      // 等弹层动画落位：条目存在不等于已进屏幕，要等它的矩形
      // 完全落进视口再点，否则点在屏幕外。
      final remote = find.byKey(const ValueKey('live-import-remote'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (remote.evaluate().isNotEmpty &&
            tester.getRect(remote).bottom <= 844) {
          break;
        }
      }
      expect(find.byKey(const ValueKey('live-import-local')), findsOneWidget);
      expect(remote, findsOneWidget);
      expect(find.text('导入本地文件'), findsOneWidget);
      expect(find.text('添加远程链接'), findsOneWidget);
      // 点远程：出链接输入框。
      await tester.tap(find.byKey(const ValueKey('live-import-remote')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find
            .byKey(const ValueKey('live-import-url-field'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(
        find.byKey(const ValueKey('live-import-url-field')),
        findsOneWidget,
      );
    });

    testWidgets('节目单：信息行真节目名、过去节目点回看按模板起播', (
      tester,
    ) async {
      LiveEpgService.debugFetcher = (_) async =>
          utf8.encode(_xmltvNow(DateTime.now()));
      LiveEpgService.debugCacheDir =
          Directory.systemTemp.createTempSync('epg_ui_');
      addTearDown(() {
        LiveEpgService.debugFetcher = null;
        final dir = LiveEpgService.debugCacheDir;
        LiveEpgService.debugCacheDir = null;
        if (dir != null && dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });
      LiveSource.importedSources['test:epg'] = const LiveSource(
        id: 'test:epg',
        name: '节目单测试源',
        description: '测试',
        protocol: LiveProtocol.list,
        builtin: false,
        epg: 'https://example.com/epg-ui.xml',
      );
      addTearDown(() => LiveSource.importedSources.remove('test:epg'));
      final playback = await _pumpLivePage(
        tester,
        initialSourceId: 'test:epg',
      );
      // 节目单拉取走真实文件 IO（缓存读写），在组件测试的假
      // 异步区里不会自己完成：用 runAsync 真时间轮询等信息行
      // 换成真节目名（本树既有口径）。
      for (
        var i = 0;
        i < 40 && find.text('正在播放：正在播的节目').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('正在播放：正在播的节目'), findsOneWidget);
      expect(find.text('即将播放：即将播的节目'), findsOneWidget);
      // 信息单 → 节目单 → 点过去的节目回看。
      await tester.tap(find.byKey(const ValueKey('live-video-info')));
      for (
        var i = 0;
        i < 20 && find.byKey(const ValueKey('live-info-epg')).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('live-info-epg')), findsOneWidget);
      // 信息单是可滚的单子，节目单条目在折叠线以下：先滚到可见再点。
      await tester.ensureVisible(find.byKey(const ValueKey('live-info-epg')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('live-info-epg')));
      for (
        var i = 0;
        i < 20 && find.byKey(const ValueKey('live-epg-list')).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('已播节目'), findsOneWidget);
      // 等弹层动画落位再点（条目存在不等于已进屏幕）。
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final rect = tester.getRect(find.text('已播节目'));
        if (rect.top >= 0 && rect.bottom <= 844) break;
      }
      await tester.ensureVisible(find.text('已播节目'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('已播节目'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (playback.lastLoadedUrls.any(
          (url) => url.startsWith('https://example.com/vod/'),
        )) {
          break;
        }
      }
      expect(playback.lastLoadedUrls, hasLength(1));
      expect(
        playback.lastLoadedUrls.single,
        startsWith('https://example.com/vod/'),
      );
    });
  });
}

String _xmltvNow(DateTime now) {
  String fmt(DateTime time) {
    final utc = time.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)} +0000';
  }

  final pastStart = now.subtract(const Duration(minutes: 90));
  final pastEnd = now.subtract(const Duration(minutes: 30));
  final nextEnd = now.add(const Duration(hours: 1));
  return '<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n'
      '<channel id="cctv1"><display-name>CCTV-1</display-name></channel>\n'
      '<programme start="${fmt(pastStart)}" stop="${fmt(pastEnd)}" '
      'channel="cctv1"><title>已播节目</title></programme>\n'
      '<programme start="${fmt(pastEnd)}" stop="${fmt(nextEnd)}" '
      'channel="cctv1"><title>正在播的节目</title></programme>\n'
      '<programme start="${fmt(nextEnd)}" stop="${fmt(nextEnd.add(const Duration(hours: 1)))}" '
      'channel="cctv1"><title>即将播的节目</title></programme>\n'
      '</tv>';
}

class _ImportLiveRepository extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => [const LivePlatform(id: 'all', name: '全部频道', count: 30)];

  @override
  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async => [
    LiveChannel(
      key: 'k1',
      name: 'CCTV-1',
      urls: const ['http://example.com/live/cctv1.m3u8'],
      number: '001',
      group: '全部频道',
      source: source.id,
      tvgId: 'cctv1',
      catchup: const LiveCatchup(
        type: 'default',
        source: 'https://example.com/vod/\${(b)timestamp}.m3u8',
      ),
    ),
    for (var i = 2; i <= 30; i++)
      LiveChannel(
        key: 'k$i',
        name: '频道$i',
        urls: ['http://example.com/live/$i.m3u8'],
        number: '$i'.padLeft(3, '0'),
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

class _ImportFakePlayback extends LivePlaybackController {
  _ImportFakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _route = 0;
  LiveDecoderMode _decoderMode = LiveDecoderMode.auto;
  List<String> lastLoadedUrls = const [];

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
    lastLoadedUrls = channels.isEmpty
        ? const []
        : _channels[_index].urls;
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

Future<_ImportFakePlayback> _pumpLivePage(
  WidgetTester tester, {
  String initialSourceId = '',
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final appStore = LocalStore(prefs);
  addTearDown(appStore.dispose);
  final liveStore = LiveStore(prefs, 'default')..load();
  addTearDown(liveStore.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _ImportLiveRepository();
  final playback = _ImportFakePlayback(repository: repository);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LiveScreen(
          repository: repository,
          store: liveStore,
          greenMode: false,
          appStore: appStore,
          playbackController: playback,
          videoBuilder: (_, _) => const SizedBox(),
          initialSourceId: initialSourceId,
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
