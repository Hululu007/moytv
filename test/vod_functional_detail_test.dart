import 'package:moyi/local_store.dart';
import 'package:moyi/playback_parse.dart';
import 'package:moyi/player_picker.dart';
import 'package:moyi/player_screen.dart';
import 'package:moyi/vod_detail_route.dart';
import 'package:moyi/xigua/xigua_player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  test('vod open action routes all card taps to direct playback', () {
    expect(
      vodOpenAction(isVodZone: true, resume: false),
      VodOpenAction.directPlayback,
    );
    expect(
      vodOpenAction(isVodZone: true, resume: true),
      VodOpenAction.directPlayback,
    );
    expect(
      vodOpenAction(isVodZone: false, resume: false),
      VodOpenAction.directPlayback,
    );
    expect(
      vodOpenAction(isVodZone: false, resume: true),
      VodOpenAction.directPlayback,
    );
  });

  test('parse interface apply replaces placeholder or appends', () {
    const api = ParseInterface(
      id: 'line1',
      name: '线路一',
      url: 'https://parse.test/?url={url}',
    );
    expect(
      api.apply('https://media.test/play.m3u8'),
      'https://parse.test/?url=https%3A%2F%2Fmedia.test%2Fplay.m3u8',
    );
    const appended = ParseInterface(
      id: 'line2',
      name: '线路二',
      url: 'https://parse.test/jx/',
    );
    expect(
      appended.apply('https://media.test/play.m3u8'),
      'https://parse.test/jx/https://media.test/play.m3u8',
    );
  });

  test(
    'parse interface store round trips enabled list and selection',
    () async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      final apis = [
        const ParseInterface(id: 'a', name: '线路甲', url: 'https://a.test/'),
        const ParseInterface(
          id: 'b',
          name: '线路乙',
          url: 'https://b.test/',
          enabled: false,
        ),
      ];
      await ParseInterfaceStore.save(apis);
      await ParseInterfaceStore.saveSelectedId('a');
      final enabled = await ParseInterfaceStore.loadEnabled();
      expect(enabled.map((api) => api.id), ['a']);
      expect(await ParseInterfaceStore.loadSelectedId(), 'a');
      await ParseInterfaceStore.saveSelectedId('');
      expect(await ParseInterfaceStore.loadSelectedId(), '');
    },
  );

  testWidgets('player route carries startFullscreen into player widgets', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final detail = await FixtureRepository().detail(FixtureRepository.free);
    const animation = AlwaysStoppedAnimation<double>(0);
    Widget buildRoute({bool fullscreen = false}) {
      final route = buildPlayerRoute<void>(
        captured,
        detail: detail,
        initialIndex: 0,
        repository: FixtureRepository(),
        store: store,
        startFullscreen: fullscreen,
      );
      return (route as PageRouteBuilder<void>).pageBuilder(
        captured,
        animation,
        animation,
      );
    }

    expect(
      (buildRoute(fullscreen: true) as PlayerScreen).startFullscreen,
      isTrue,
    );
    expect((buildRoute() as PlayerScreen).startFullscreen, isFalse);
    await setSelectedPlayer(store, AppPlayer.xigua);
    expect(
      (buildRoute(fullscreen: true) as XiguaPlayerScreen).startFullscreen,
      isTrue,
    );
  });
}
