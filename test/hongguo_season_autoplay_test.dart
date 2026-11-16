import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/hongguo_season_countdown.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/xigua/playback_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountdownHarness extends StatefulWidget {
  const _CountdownHarness({required this.onFire, required this.onCancelTap});

  final VoidCallback onFire;
  final VoidCallback onCancelTap;

  @override
  State<_CountdownHarness> createState() => _CountdownHarnessState();
}

class _CountdownHarnessState extends State<_CountdownHarness> {
  late final SeasonAutoplayCountdown _countdown;

  @override
  void initState() {
    super.initState();
    _countdown = SeasonAutoplayCountdown(onFire: widget.onFire)..start();
  }

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _countdown,
    builder: (_, _) => Column(
      children: [
        Text('剩余 ${_countdown.remaining}'),
        TextButton(
          key: const ValueKey('harness-cancel'),
          onPressed: () {
            _countdown.cancel();
            widget.onCancelTap();
          },
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

void main() {
  group('SeasonAutoplayCountdown', () {
    testWidgets('5 秒倒数走完只触发一次', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _CountdownHarness(
            onFire: () => fired++,
            onCancelTap: () {},
          ),
        ),
      );
      expect(find.text('剩余 5'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('剩余 4'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(fired, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(fired, 1);
    });

    testWidgets('取消后不再触发', (tester) async {
      var fired = 0;
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: _CountdownHarness(
            onFire: () => fired++,
            onCancelTap: () => cancelled = true,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byKey(const ValueKey('harness-cancel')));
      await tester.pump();
      expect(cancelled, isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(fired, 0);
    });

    testWidgets('重新开始重置剩余秒数', (tester) async {
      var fired = 0;
      final countdown = SeasonAutoplayCountdown(onFire: () => fired++);
      addTearDown(countdown.dispose);
      countdown.start();
      expect(countdown.remaining, 5);
      countdown.start();
      expect(countdown.remaining, 5);
      expect(countdown.active, isTrue);
      countdown.cancel();
      expect(countdown.active, isFalse);
      expect(fired, 0);
    });

    test('倒计时秒数是 5', () {
      expect(hongguoSeasonCountdownSeconds, 5);
    });
  });

  group('SeasonAutoplayCountdownOverlay', () {
    testWidgets('显示下一季名、季标签与剩余秒数，取消钮回调', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeasonAutoplayCountdownOverlay(
              nextTitle: '测试剧第二季',
              seasonLabel: '第 2 季',
              remaining: 3,
              onCancel: () => cancelled = true,
            ),
          ),
        ),
      );
      expect(find.text('即将播放下一季'), findsOneWidget);
      expect(find.text('第 2 季 · 测试剧第二季'), findsOneWidget);
      expect(find.text('3 秒后自动播放'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('season-countdown-overlay')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('season-countdown-cancel')));
      expect(cancelled, isTrue);
    });
  });

  group('跨季自动连播开关', () {
    Future<LocalStore> freshStore() async {
      SharedPreferences.setMockInitialValues({});
      return LocalStore(await SharedPreferences.getInstance());
    }

    testWidgets('默认开，点按切换写读生效', (tester) async {
      final store = await freshStore();
      expect(store.hongguoSeasonAutoplay, isTrue);
      await tester.pumpWidget(
        MaterialApp(home: PlaybackSettingsScreen(store: store)),
      );
      await tester.pump();
      final tile = find.byKey(const ValueKey('season-autoplay-switch'));
      // 设置列表按需建子项：开关在折叠线下时须先滚进画面才建出来。
      await tester.scrollUntilVisible(tile, 200);
      await tester.pump();
      expect(tile, findsOneWidget);
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      await tester.tap(tile);
      await tester.pump();
      expect(store.hongguoSeasonAutoplay, isFalse);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      await tester.tap(tile);
      await tester.pump();
      expect(store.hongguoSeasonAutoplay, isTrue);
    });

    testWidgets('自动连播关掉时副标题说明开关暂不生效', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await freshStore();
      await tester.pumpWidget(
        MaterialApp(home: PlaybackSettingsScreen(store: store)),
      );
      await tester.pump();
      final autoAdvance = find.ancestor(
        of: find.text('自动连播'),
        matching: find.byType(SwitchListTile),
      );
      await tester.scrollUntilVisible(autoAdvance, 200);
      await tester.tap(autoAdvance);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('season-autoplay-switch')),
        200,
      );
      await tester.pump();
      expect(find.text('自动连播未开，本开关暂不生效。'), findsOneWidget);
    });
  });
}
