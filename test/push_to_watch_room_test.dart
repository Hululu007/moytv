import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/core_bridge.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/watchroom/push_to_watch_room.dart';

class _FakeRepository implements AppRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<LocalStore> openStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  Future<void> mount(
    WidgetTester tester,
    LocalStore store,
    List<Episode> episodes,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => pushDramaToWatchRoom(
                context,
                repository: _FakeRepository(),
                store: store,
                drama: const Drama(
                  id: 'd1',
                  source: 'hongguo',
                  title: 'Test Drama',
                ),
                episodes: episodes,
              ),
              child: const Text('push'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('empty episodes show a snackbar and push nothing', (
    tester,
  ) async {
    final store = await openStore();
    await mount(tester, store, const []);
    await tester.tap(find.text('push'));
    await tester.pump();
    expect(find.text('暂无可推送的剧集'), findsOneWidget);
  });
}
