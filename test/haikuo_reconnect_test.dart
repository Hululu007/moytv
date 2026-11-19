import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';

import 'player_fixtures.dart';

/// 海阔播放器视图断线重连测试：流错误时退避重试、断点续播，
/// 耗尽后才亮错卡；手动重试也从断点续播并刷新重试额度；
/// 换集/销毁时挂起的重试取消，不再重开。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Player buildPlayer(List<ScriptedPlayer> created) {
    final platform = ScriptedPlayer();
    created.add(platform);
    return Player(platformPlayer: platform);
  }

  Future<void> pumpView(
    WidgetTester tester,
    List<ScriptedPlayer> created, {
    String url = 'https://cdn.example.com/ep1.m3u8',
    HaikuoPlayerController? controller,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaikuoPlayerView(
            url: url,
            title: '第1集',
            seriesTitle: '剧A',
            episodes: const ['第1集', '第2集'],
            controller: controller,
            fullscreen: false,
            onFullscreenChanged: (_) {},
            playerFactory: () => buildPlayer(created),
            videoBuilder: (_) => const SizedBox(key: ValueKey('test-video')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'error retries once after 1s from breakpoint; progress resets the chain',
    (tester) async {
      final created = <ScriptedPlayer>[];
      await pumpView(tester, created);
      final player = created.single;
      expect(player.opened.map((m) => m.uri), [
        'https://cdn.example.com/ep1.m3u8',
      ]);

      // 播到 60 秒处：断点锚落在 60 秒。
      await player.seek(const Duration(seconds: 60));
      await tester.pump();

      // 一次故障连发两条错误：只排一次重试，退避 1 秒内不重开。
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('网络波动，正在重连…'), findsOneWidget);
      expect(find.textContaining('播放失败'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(player.opened, hasLength(1));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(player.opened, hasLength(2));
      expect(player.opened[1].start, const Duration(seconds: 60));
      expect(find.text('网络波动，正在重连…'), findsNothing);
      expect(find.textContaining('播放失败'), findsNothing);

      // 进度超过断点 3 秒：重试计数清零，下一次故障退避回到 1 秒。
      await player.seek(const Duration(seconds: 65));
      await tester.pump();
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(player.opened, hasLength(2));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(player.opened, hasLength(3));
      expect(player.opened[2].start, const Duration(seconds: 65));
      expect(find.textContaining('播放失败'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('consecutive failures back off 1s, 2s, 4s', (tester) async {
    final created = <ScriptedPlayer>[];
    await pumpView(tester, created);
    final player = created.single;
    await player.seek(const Duration(seconds: 30));
    await tester.pump();

    // 第 1 次失败：1 秒后重开。
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(player.opened, hasLength(2));

    // 第 2 次失败：1 秒内不重开，满 2 秒才重开。
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(player.opened, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(player.opened, hasLength(3));

    // 第 3 次失败：3 秒内不重开，满 4 秒才重开。
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
    expect(player.opened, hasLength(3));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(player.opened, hasLength(4));
    expect(
      player.opened.skip(1).map((m) => m.start),
      everyElement(const Duration(seconds: 30)),
    );
    expect(find.textContaining('播放失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error card only after 3 retries are exhausted', (tester) async {
    final created = <ScriptedPlayer>[];
    // broken 地址：假播放器每次打开都自动报两条错误。
    await pumpView(tester, created, url: 'https://cdn.example.com/broken.m3u8');
    final player = created.single;
    expect(player.opened, hasLength(1));
    expect(find.textContaining('播放失败'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(player.opened, hasLength(2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(player.opened, hasLength(3));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(player.opened, hasLength(4));

    // 第 4 次打开也失败：额度耗尽，亮错卡，且不再重开。
    await tester.pump();
    expect(find.textContaining('播放失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(player.opened, hasLength(4));
    expect(find.textContaining('播放失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual retry resumes from breakpoint and refreshes budget', (
    tester,
  ) async {
    final created = <ScriptedPlayer>[];
    await pumpView(tester, created);
    final player = created.single;
    await player.seek(const Duration(seconds: 60));
    await tester.pump();

    // 3 次自动重试全部失败，第 4 条错误亮错卡。
    for (final backoff in [1, 2, 4]) {
      player.fail();
      await tester.pump();
      await tester.pump(Duration(seconds: backoff));
      await tester.pump();
    }
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened, hasLength(4));
    expect(find.textContaining('播放失败'), findsOneWidget);

    // 点重试：从 60 秒断点重开，错卡消失。
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened, hasLength(5));
    expect(player.opened[4].start, const Duration(seconds: 60));
    expect(find.textContaining('播放失败'), findsNothing);

    // 手动重试后额度刷新：再失败仍先退避 1 秒重试。
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.opened, hasLength(5));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(player.opened, hasLength(6));
    expect(player.opened[5].start, const Duration(seconds: 60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending retry is cancelled when a new episode is delivered', (
    tester,
  ) async {
    final created = <ScriptedPlayer>[];
    final controller = HaikuoPlayerController();
    await pumpView(tester, created, controller: controller);
    final player = created.single;
    await player.seek(const Duration(seconds: 60));
    await tester.pump();

    player.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('网络波动，正在重连…'), findsOneWidget);

    // 换集递送：旧重试取消，只打开新地址。
    controller.deliver(
      url: 'https://cdn.example.com/ep2.m3u8',
      title: '第2集',
      index: 1,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(player.opened.map((m) => m.uri), [
      'https://cdn.example.com/ep1.m3u8',
      'https://cdn.example.com/ep2.m3u8',
    ]);
    expect(find.text('网络波动，正在重连…'), findsNothing);
    expect(find.textContaining('播放失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending retry is cancelled on dispose', (tester) async {
    final created = <ScriptedPlayer>[];
    await pumpView(tester, created);
    final player = created.single;
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('网络波动，正在重连…'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(player.opened, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
