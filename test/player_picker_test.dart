import 'package:moyi/local_store.dart';
import 'package:moyi/player_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('tapping a player tile persists it without the confirm button', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'player': 'tvbox'});
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.player, 'guo');
    await tester.pumpWidget(
      MaterialApp(home: PlayerPickerScreen(store: store)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('guo 播放器'));
    await tester.pumpAndSettle();
    expect(store.player, 'guo');
  });
}
