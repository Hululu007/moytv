import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/playback_preferences.dart';
import 'package:moyi/player_menu.dart';

void main() {
  final episodes = [
    Episode(const {'id': 'e1', 'currentEpisode': 1}, 1),
    Episode(const {'id': 'e2', 'currentEpisode': 2}, 2),
  ];

  Future<List<PlaybackPreferences>> pumpMenu(
    WidgetTester tester,
    PlaybackPreferences preferences,
  ) async {
    final saved = <PlaybackPreferences>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerMenu(
            section: PlayerMenuSection.settings,
            episodes: episodes,
            currentIndex: 0,
            preferences: preferences,
            qualities: const [],
            actualQuality: 0,
            local: false,
            favorite: false,
            mobile: true,
            onEpisode: (_) {},
            onPreferences: (next) async => saved.add(next),
            onFavorite: () async {},
            preloadStatus: '下一集播放地址已准备',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('播放设置里有无缝播放开关，打开时连带打开预加载', (tester) async {
    final saved = await pumpMenu(
      tester,
      const PlaybackPreferences(preload: false),
    );
    final tile = find.byKey(const ValueKey('player-seamless-enabled'));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.seamless, isTrue);
    expect(saved.single.preload, isTrue, reason: '开无缝自动开预加载');
  });

  testWidgets('关闭预加载连带关闭无缝', (tester) async {
    final saved = await pumpMenu(
      tester,
      const PlaybackPreferences(seamless: true),
    );
    final tile = find.byKey(const ValueKey('player-preload-enabled'));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.preload, isFalse);
    expect(saved.single.seamless, isFalse, reason: '关预加载连带关无缝');
  });

  testWidgets('无缝默认关时开关呈关态', (tester) async {
    await pumpMenu(tester, const PlaybackPreferences());
    final widget = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('player-seamless-enabled')),
    );
    expect(widget.value, isFalse);
  });
}
