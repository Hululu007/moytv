import 'package:moyi/app_drawer.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/zone_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<LocalStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return LocalStore(await SharedPreferences.getInstance());
}

void main() {
  testWidgets('settings screen has no drama style row', (tester) async {
    final store = await _store();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    expect(find.text('短剧区风格'), findsNothing);
    expect(find.text('首页全屏'), findsNothing);
  });

  testWidgets('library zone settings has no drama style row', (tester) async {
    final store = await _store();
    await tester.pumpWidget(
      MaterialApp(
        home: ZoneSettingsScreen(
          repository: FixtureRepository(),
          store: store,
          zone: HomeZone.library,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('短剧区风格'), findsNothing);
    expect(find.text('播放设置'), findsOneWidget);
  });
}
