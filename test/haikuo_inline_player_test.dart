import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';

import 'player_fixtures.dart';

/// 海阔播放器视图/播放页 widget 测试：内嵌播放与推页播放共用同一套
/// 播放器视图——递送切集、全屏进出不重建 Player、返回键走 onClose、
/// 播放页选集条经控制器请视图切集。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Player buildPlayer(List<ScriptedPlayer> created) {
    final platform = ScriptedPlayer();
    created.add(platform);
    return Player(platformPlayer: platform);
  }

  // 控件层始终在树里，隐藏时靠 IgnorePointer 挡点按：按门的状态
  // 判断要不要先点一下画面把控件层唤出来（点画面是开关切换，
  // 不能无条件点，否则会把已显示的控件层按回去）。
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
      // 手势面同时认单击/双击：单击要等双击超时（300ms）才触发，
      // 必须把假时钟推出去，控件层才会真正显示出来。
      await tester.pump(const Duration(milliseconds: 350));
    }
    expect(gated(), isFalse);
  }

  testWidgets('view opens, delivers episodes, fullscreen keeps one player, back closes',
      (tester) async {
    final created = <ScriptedPlayer>[];
    final controller = HaikuoPlayerController();
    final fullscreenLog = <bool>[];
    final currentLog = <(int, String)>[];
    final requested = <int>[];
    var closed = false;
    var fullscreen = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => HaikuoPlayerView(
              url: 'https://cdn.example.com/ep1.m3u8',
              title: '第1集',
              seriesTitle: '剧A',
              episodes: const ['第1集', '第2集'],
              controller: controller,
              onSelectEpisode: (index) async {
                requested.add(index);
                return true;
              },
              fullscreen: fullscreen,
              onFullscreenChanged: (value) {
                fullscreenLog.add(value);
                setState(() => fullscreen = value);
              },
              onClose: () => closed = true,
              onCurrentChanged: (index, title) =>
                  currentLog.add((index, title)),
              playerFactory: () => buildPlayer(created),
              videoBuilder: (_) =>
                  const SizedBox(key: ValueKey('test-video')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('test-video')), findsOneWidget);
    expect(created, hasLength(1));
    expect(created.single.opened.map((m) => m.uri),
        ['https://cdn.example.com/ep1.m3u8']);

    // 递送切集：新地址进同一播放器，宿主收到当前集变化。
    controller.deliver(
      url: 'https://cdn.example.com/ep2.m3u8',
      title: '第2集',
      index: 1,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(created, hasLength(1));
    expect(created.single.opened.map((m) => m.uri), [
      'https://cdn.example.com/ep1.m3u8',
      'https://cdn.example.com/ep2.m3u8',
    ]);
    expect(currentLog, [(1, '第2集')]);

    // 经控制器请视图切集：onSelectEpisode 被调，解析中显示等待态。
    controller.requestEpisode(0);
    await tester.pump();
    expect(requested, [0]);
    expect(find.text('正在解析…'), findsOneWidget);
    controller.deliver(
      url: 'https://cdn.example.com/ep1.m3u8',
      title: '第1集',
      index: 0,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在解析…'), findsNothing);

    // 全屏进出：只改宿主状态，Player 不重建。
    await ensureControlsVisible(tester, '旋转与全屏');
    await tester.tap(find.byTooltip('旋转与全屏'));
    await tester.pump();
    expect(fullscreenLog, [true]);
    expect(created, hasLength(1));
    expect(find.byKey(const ValueKey('test-video')), findsOneWidget);
    await ensureControlsVisible(tester, '退出全屏');
    await tester.tap(find.byTooltip('退出全屏').first);
    await tester.pump();
    expect(fullscreenLog, [true, false]);
    expect(created, hasLength(1));

    // 返回键：非全屏时走 onClose（内嵌播放关闭播放器）。
    await ensureControlsVisible(tester, '返回');
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pushed page: chips switch via controller, fullscreen keeps one player',
      (tester) async {
    final created = <ScriptedPlayer>[];
    final controller = HaikuoPlayerController();
    final requested = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: HaikuoPlayPage(
          url: 'https://cdn.example.com/ep1.m3u8',
          title: '第1集',
          seriesTitle: '剧A',
          episodes: const ['第1集', '第2集'],
          controller: controller,
          onSelectEpisode: (index) async {
            requested.add(index);
            return true;
          },
          playerFactory: () => buildPlayer(created),
          videoBuilder: (_) =>
              const SizedBox(key: ValueKey('test-video')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('test-video')), findsOneWidget);
    expect(find.text('剧A · 第1集'), findsOneWidget);
    expect(find.text('第2集'), findsWidgets);

    // 点下方选集条的第2集：经控制器请视图切集。
    await tester.tap(find.byWidgetPredicate(
      (w) => w is ChoiceChip && (w.label as Text).data == '第2集',
    ));
    await tester.pump();
    expect(requested, [1]);
    controller.deliver(
      url: 'https://cdn.example.com/ep2.m3u8',
      title: '第2集',
      index: 1,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('剧A · 第2集'), findsOneWidget);
    final chip2 = tester.widget<ChoiceChip>(find.byWidgetPredicate(
      (w) => w is ChoiceChip && (w.label as Text).data == '第2集',
    ));
    expect(chip2.selected, isTrue);

    // 全屏：选集条藏起，Player 不重建；退出全屏后选集条回来。
    await ensureControlsVisible(tester, '旋转与全屏');
    await tester.tap(find.byTooltip('旋转与全屏'));
    await tester.pump();
    expect(created, hasLength(1));
    expect(find.byKey(const ValueKey('test-video')), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await ensureControlsVisible(tester, '退出全屏');
    await tester.tap(find.byTooltip('退出全屏').first);
    await tester.pump();
    expect(created, hasLength(1));
    expect(find.byType(ChoiceChip), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
