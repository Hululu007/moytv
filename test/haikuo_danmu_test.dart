import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/danmaku_models.dart';
import 'package:moyi/miniapp/haikuo/haikuo_danmu.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';

import 'player_fixtures.dart';

/// D05 弹幕轻量层：解析/取数/控制器单元测试 + 播放器叠层 widget 测试。
/// 不碰主播放器 DanmakuController；取数一律假传输，不联网。
void main() {
  group('parseHaikuoDanmuBody', () {
    test('认 {text, time秒} 数组，转毫秒并按时间排序', () {
      final items = parseHaikuoDanmuBody(
        '[{"text":"后","time":10.5},{"text":"前","time":1.25}]',
      );
      expect(items, hasLength(2));
      expect(items[0].text, '前');
      expect(items[0].timeMs, 1250);
      expect(items[1].timeMs, 10500);
    });

    test('timeMs 备选形态也认', () {
      final items = parseHaikuoDanmuBody('[{"text":"x","timeMs":2500}]');
      expect(items.single.timeMs, 2500);
    });

    test('坏行跳过：缺 text、缺时间、时间为负、非对象', () {
      final items = parseHaikuoDanmuBody(
        '[{"text":"好","time":1},{"time":2},{"text":"","time":3},'
        '{"text":"负","time":-1},"str",{"text":"  ","time":4}]',
      );
      expect(items.map((e) => e.text), ['好']);
    });

    test('非数组/坏 JSON 回空列表，不抛错', () {
      expect(parseHaikuoDanmuBody('{"data":[]}'), isEmpty);
      expect(parseHaikuoDanmuBody('not json'), isEmpty);
      expect(parseHaikuoDanmuBody(''), isEmpty);
    });

    test('超量截断，留时间最早的', () {
      final body = List.generate(
        5,
        (i) => '{"text":"t$i","time":${5 - i}}',
      ).join(',');
      final items = parseHaikuoDanmuBody('[$body]', maxItems: 2);
      expect(items.map((e) => e.text), ['t4', 't3']);
    });
  });

  group('haikuoDanmuUrlIsFetchable', () {
    test('只有 http(s) 可取', () {
      expect(haikuoDanmuUrlIsFetchable('https://dm.example.com/x.json'), isTrue);
      expect(haikuoDanmuUrlIsFetchable('http://dm.example.com/x.json'), isTrue);
      expect(haikuoDanmuUrlIsFetchable(''), isFalse);
      expect(haikuoDanmuUrlIsFetchable('web://hiker://files/x.html'), isFalse);
      expect(haikuoDanmuUrlIsFetchable('ftp://x/y'), isFalse);
    });
  });

  group('fetchHaikuoDanmu', () {
    test('GET 带线路头，200 解析出条目', () async {
      var seenHeaders = <String, String>{};
      final client = MockClient((request) async {
        seenHeaders = Map<String, String>.from(request.headers);
        return http.Response('[{"text":"hi","time":2}]', 200);
      });
      final items = await fetchHaikuoDanmu(
        'https://dm.example.com/x.json',
        {'Referer': 'https://line/'},
        client: client,
      );
      expect(items.single.text, 'hi');
      expect(seenHeaders['Referer'], 'https://line/');
      expect(seenHeaders['User-Agent'], isNotEmpty);
    });

    test('非 200 抛错', () async {
      final client = MockClient((_) async => http.Response('nope', 403));
      await expectLater(
        fetchHaikuoDanmu('https://dm.example.com/x.json', {}, client: client),
        throwsA(isA<Exception>()),
      );
    });

    test('非 http(s) 地址抛错', () async {
      await expectLater(
        fetchHaikuoDanmu('web://x.html', {}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('HaikuoDanmuController', () {
    test('load 成功：装载、状态文案、重复同地址不重取', () async {
      var calls = 0;
      final controller = HaikuoDanmuController();
      addTearDown(controller.dispose);
      Future<List<DanmakuItem>> fetcher(String url, _) async {
        calls++;
        return [const DanmakuItem(id: 'dm:0', text: 'hi', timeMs: 1000)];
      }

      await controller.load('https://dm.example.com/x.json', {}, fetcher: fetcher);
      expect(controller.loaded, isTrue);
      expect(controller.items, hasLength(1));
      expect(controller.status, '已载入 1 条弹幕');
      expect(controller.visible, isTrue);

      await controller.load('https://dm.example.com/x.json', {}, fetcher: fetcher);
      expect(calls, 1);

      await controller.load(
        'https://dm.example.com/x.json',
        {'Referer': 'https://other/'},
        fetcher: fetcher,
      );
      expect(calls, 2, reason: '头变了应重取');
    });

    test('load 失败：failed 置真、状态文案为可重试', () async {
      final controller = HaikuoDanmuController();
      addTearDown(controller.dispose);
      await controller.load(
        'https://dm.example.com/x.json',
        {},
        fetcher: (_, _) async => throw Exception('boom'),
      );
      expect(controller.failed, isTrue);
      expect(controller.items, isEmpty);
      expect(controller.status, '弹幕加载失败，可重试');
    });

    test('不可取地址直接重置，不调取数', () async {
      final controller = HaikuoDanmuController();
      addTearDown(controller.dispose);
      var calls = 0;
      await controller.load(
        'web://hiker://files/x.html',
        {},
        fetcher: (_, _) async {
          calls++;
          return const [];
        },
      );
      expect(calls, 0);
      expect(controller.loaded, isFalse);
    });

    test('reset 清空并失效未完成的取数', () async {
      final controller = HaikuoDanmuController();
      addTearDown(controller.dispose);
      final gate = Completer<List<DanmakuItem>>();
      final pending = controller.load(
        'https://dm.example.com/x.json',
        {},
        fetcher: (_, _) => gate.future,
      );
      controller.reset();
      expect(controller.items, isEmpty);
      gate.complete([const DanmakuItem(id: 'dm:0', text: 'late', timeMs: 0)]);
      await pending;
      expect(controller.items, isEmpty, reason: '过期取数结果须丢弃');
    });

    test('update 节流通知：250ms 内不重复通知', () {
      final controller = HaikuoDanmuController();
      addTearDown(controller.dispose);
      var notified = 0;
      controller.addListener(() => notified++);
      controller.update(
        position: Duration.zero,
        duration: const Duration(minutes: 2),
        playing: true,
        rate: 1,
      );
      final afterFirst = notified;
      controller.update(
        position: const Duration(milliseconds: 100),
        duration: const Duration(minutes: 2),
        playing: true,
        rate: 1,
      );
      expect(notified, afterFirst);
      controller.update(
        position: const Duration(milliseconds: 500),
        duration: const Duration(minutes: 2),
        playing: true,
        rate: 1,
      );
      expect(notified, greaterThan(afterFirst));
    });
  });

  group('HaikuoPlayerView 弹幕叠层', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Player buildPlayer(List<ScriptedPlayer> created) {
      final platform = ScriptedPlayer();
      created.add(platform);
      return Player(platformPlayer: platform);
    }

    testWidgets('有弹幕地址时叠层渲染弹幕文本，开关可见', (tester) async {
      final created = <ScriptedPlayer>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaikuoPlayerView(
              url: 'https://cdn.example.com/a.m3u8',
              title: '片A',
              danmuUrl: 'https://dm.example.com/x.json',
              danmuFetcher: (_, _) async => [
                const DanmakuItem(id: 'dm:0', text: '弹幕一', timeMs: 0),
                const DanmakuItem(id: 'dm:1', text: '弹幕二', timeMs: 1000),
              ],
              fullscreen: false,
              onFullscreenChanged: (_) {},
              playerFactory: () => buildPlayer(created),
              videoBuilder: (_) =>
                  const SizedBox(key: ValueKey('test-video')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('弹幕一'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-danmaku-toggle')),
        findsOneWidget,
      );
    });

    testWidgets('无弹幕地址时无叠层、无开关', (tester) async {
      final created = <ScriptedPlayer>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaikuoPlayerView(
              url: 'https://cdn.example.com/a.m3u8',
              title: '片A',
              fullscreen: false,
              onFullscreenChanged: (_) {},
              playerFactory: () => buildPlayer(created),
              videoBuilder: (_) =>
                  const SizedBox(key: ValueKey('test-video')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('player-danmaku-toggle')),
        findsNothing,
      );
      expect(find.byType(HaikuoDanmuOverlay), findsNothing);
    });

    testWidgets('web:// 弹幕地址不取数、不渲染', (tester) async {
      final created = <ScriptedPlayer>[];
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaikuoPlayerView(
              url: 'https://cdn.example.com/a.m3u8',
              title: '片A',
              danmuUrl: 'web://hiker://files/_cache/rgdm_1.html',
              danmuFetcher: (_, _) async {
                calls++;
                return const [];
              },
              fullscreen: false,
              onFullscreenChanged: (_) {},
              playerFactory: () => buildPlayer(created),
              videoBuilder: (_) =>
                  const SizedBox(key: ValueKey('test-video')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 0);
      expect(find.byType(HaikuoDanmuOverlay), findsNothing);
    });
  });
}
