import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

class EmbeddedRouteRepository extends RouteRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  Future<void> settleOperations(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> settleDispose(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await settleOperations(tester);
  }

  testWidgets('detail play stays inline, switches episodes, closes to detail',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = EmbeddedRouteRepository();
    final store = LocalStore(await SharedPreferences.getInstance());
    final created = <ScriptedPlayer>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DetailScreen(
          drama: FixtureRepository.free,
          repository: repository,
          store: store,
          playerFactory: () {
            final platform = ScriptedPlayer();
            created.add(platform);
            return Player(platformPlayer: platform);
          },
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.byKey(const ValueKey('start-play')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('start-play')));
    await settleOperations(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(repository.requestedEpisodes, [1]);
    expect(find.text('正在播放 · 第 1 集'), findsOneWidget);
    expect(find.text('选集 · 2 集'), findsOneWidget);
    expect(find.byKey(const ValueKey('start-play')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('toggle-embedded-fullscreen')));
    await settleOperations(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(created, hasLength(1));
    expect(find.text('正在播放 · 第 1 集'), findsNothing);
    await tester.tap(find.byTooltip('退出全屏').first);
    await settleOperations(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(created, hasLength(1));
    expect(find.text('正在播放 · 第 1 集'), findsOneWidget);

    await tester.tap(find.text('选集 · 2 集'));
    await settleOperations(tester);
    await tester.tap(find.byKey(const ValueKey('episode-2')));
    await settleOperations(tester);
    await settleDispose(tester);
    expect(repository.requestedEpisodes, [1, 2]);
    expect(created, hasLength(2));
    expect(repository.active, {'route-2'});
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.text('正在播放 · 第 2 集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-embedded-player')));
    await settleOperations(tester);
    await settleDispose(tester);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(repository.active, isEmpty);
    expect(find.byKey(const ValueKey('start-play')), findsOneWidget);
    expect(find.text('选集 · 2 集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
