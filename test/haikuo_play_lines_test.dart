import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

import 'player_fixtures.dart';

/// D02 多线路：play 消息 lines 解析、运行时 JS 落点钉串、
/// 播放器画质按钮切线路 widget 测试。
void main() {
  group('parseHaikuoPlayLines', () {
    const fallbackHeaders = {'Referer': 'https://fallback/'};

    test('缺省回落单条：名为空、地址与头取主字段', () {
      final lines = parseHaikuoPlayLines(
        null,
        fallbackUrl: 'https://cdn.example.com/a.m3u8',
        fallbackHeaders: fallbackHeaders,
      );
      expect(lines, [
        const HaikuoPlayLine(
          name: '',
          url: 'https://cdn.example.com/a.m3u8',
          headers: fallbackHeaders,
        ),
      ]);
    });

    test('空数组与非列表同样回落', () {
      for (final raw in [<dynamic>[], 'nope', 42]) {
        final lines = parseHaikuoPlayLines(
          raw,
          fallbackUrl: 'https://cdn.example.com/a.m3u8',
          fallbackHeaders: const {},
        );
        expect(lines, hasLength(1));
        expect(lines.single.url, 'https://cdn.example.com/a.m3u8');
      }
    });

    test('逐条解析：名/地址/头下标对齐', () {
      final lines = parseHaikuoPlayLines(
        [
          {
            'name': '完整版',
            'url': 'https://cdn.example.com/full.m3u8',
            'headers': {'Referer': 'https://a/'},
          },
          {
            'name': '预览',
            'url': 'https://cdn.example.com/prev.m3u8',
            'headers': {'Referer': 'https://b/'},
          },
        ],
        fallbackUrl: 'https://cdn.example.com/full.m3u8',
        fallbackHeaders: const {},
      );
      expect(lines, hasLength(2));
      expect(lines[0].name, '完整版');
      expect(lines[1].headers, {'Referer': 'https://b/'});
    });

    test('缺名补默认名、空地址条目跳过', () {
      final lines = parseHaikuoPlayLines(
        [
          {'url': 'https://cdn.example.com/a.m3u8'},
          {'name': '空地址', 'url': ''},
          {'name': '', 'url': 'https://cdn.example.com/c.m3u8'},
        ],
        fallbackUrl: 'https://cdn.example.com/a.m3u8',
        fallbackHeaders: const {},
      );
      expect(lines, hasLength(2));
      expect(lines[0].name, '线路1');
      expect(lines[1].name, '线路3');
    });

    test('全是空地址时回落单条', () {
      final lines = parseHaikuoPlayLines(
        [
          {'name': 'x', 'url': ''},
        ],
        fallbackUrl: 'https://cdn.example.com/a.m3u8',
        fallbackHeaders: const {},
      );
      expect(lines, hasLength(1));
      expect(lines.single.url, 'https://cdn.example.com/a.m3u8');
    });
  });

  group('runtime JS 落点钉串', () {
    final html = haikuoRuntimeHtml;

    void has(String needle) {
      expect(html, contains(needle), reason: '缺失：$needle');
    }

    test('parsePlayJson 返回完整 urls/names/headersList/danmu', () {
      has('function normalizePlayHeadersList(h)');
      has('headersList: normalizePlayHeadersList(obj.headers)');
      has("var danmu = (typeof obj.danmu === 'string') ? obj.danmu : undefined;");
      has('var urls = obj.urls.map(function (u) { return String(u || \'\'); });');
    });

    test('sendPlay 组装 lines：逐条摘后缀、JSON 头优先、单条不发', () {
      has('if (playExtras && Array.isArray(playExtras.urls) && playExtras.urls.length > 1) {');
      has('var lineClean = extractPlayHeaderSuffix(stripFlags(rawLine));');
      has('payload.lines = lines;');
      has("if (typeof playExtras.danmu === 'string' && playExtras.danmu) payload.danmaku = playExtras.danmu;");
    });

    test('handleLazyResult 对象分支整体传 urls/headersList/danmu', () {
      has('headersList: normalizePlayHeadersList(result.headers),');
      has('urls: result.urls,');
      has('danmu: result.danmu');
    });

    test('云剪贴板桥函数存在且已导出', () {
      has('function pasteRequest(body)');
      has('function getPastes()');
      has('function sharePaste(content, paste)');
      has('function parsePaste(url)');
      has("xhr.open('POST', window.location.origin + '/__paste', false);");
      has('getPastes: getPastes, sharePaste: sharePaste, parsePaste: parsePaste,');
    });
  });

  group('HaikuoPlayerView 线路切换', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Player buildPlayer(List<ScriptedPlayer> created) {
      final platform = ScriptedPlayer();
      created.add(platform);
      return Player(platformPlayer: platform);
    }

    Future<void> ensureControlsVisible(
      WidgetTester tester,
      String tooltip,
    ) async {
      bool gated() {
        final gates = find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IgnorePointer),
        );
        return tester.widgetList<IgnorePointer>(gates).any((w) => w.ignoring);
      }

      if (gated()) {
        await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
        await tester.pump(const Duration(milliseconds: 350));
      }
      expect(gated(), isFalse);
    }

    const lines = [
      HaikuoPlayLine(
        name: '线路1',
        url: 'https://cdn.example.com/l1.m3u8',
        headers: {'Referer': 'https://l1/'},
      ),
      HaikuoPlayLine(
        name: '线路2',
        url: 'https://cdn.example.com/l2.m3u8',
        headers: {'Referer': 'https://l2/'},
      ),
    ];

    testWidgets('多线路：画质按钮显示线路名，点选换地址+头重开并回原位',
        (tester) async {
      final created = <ScriptedPlayer>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaikuoPlayerView(
              url: 'https://cdn.example.com/l1.m3u8',
              title: '片A',
              headers: const {'Referer': 'https://l1/'},
              lines: lines,
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
      expect(created.single.opened.map((m) => m.uri),
          ['https://cdn.example.com/l1.m3u8']);
      expect(find.text('线路1'), findsOneWidget);

      // 先播到 30 秒处：切线路后应 best-effort 回原位。
      await created.single.seek(const Duration(seconds: 30));
      await tester.pump();

      await ensureControlsVisible(tester, '清晰度');
      await tester.tap(find.byKey(const ValueKey('player-quality')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择线路'), findsOneWidget);
      await tester.tap(find.text('线路2').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(created.single.opened.map((m) => m.uri), [
        'https://cdn.example.com/l1.m3u8',
        'https://cdn.example.com/l2.m3u8',
      ]);
      expect(created.single.opened[1].httpHeaders, {'Referer': 'https://l2/'});
      // 画质按钮内的线路名（sheet 退场动画中树里暂有两个“线路2”，
      // 故只在按钮内找，避免误判）。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-quality')),
          matching: find.text('线路2'),
        ),
        findsOneWidget,
      );
      expect(created.single.state.position, const Duration(seconds: 30));
    });

    testWidgets('单线路：画质按钮仍是默认，递送新线路表后刷新', (tester) async {
      final created = <ScriptedPlayer>[];
      final controller = HaikuoPlayerController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HaikuoPlayerView(
              url: 'https://cdn.example.com/only.m3u8',
              title: '片B',
              controller: controller,
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
      expect(find.text('默认'), findsOneWidget);

      controller.deliver(
        url: 'https://cdn.example.com/l1.m3u8',
        title: '片B',
        index: 0,
        headers: const {'Referer': 'https://l1/'},
        lines: lines,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('线路1'), findsOneWidget);
      expect(created.single.opened.map((m) => m.uri), [
        'https://cdn.example.com/only.m3u8',
        'https://cdn.example.com/l1.m3u8',
      ]);
    });
  });
}
