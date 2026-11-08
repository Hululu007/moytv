import 'package:moyi/watchroom/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('room player view forwards completion to handle', (tester) async {
    final handle = RoomPlayerHandle();
    addTearDown(handle.dispose);
    var firstCalls = 0;
    var secondCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RoomPlayerView(
          handle: handle,
          viewType: '',
          onCompleted: () => firstCalls++,
          onError: (_) {},
          onRetry: () {},
        ),
      ),
    );
    expect(handle.onCompleted, isNotNull);
    handle.onCompleted!();
    expect(firstCalls, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: RoomPlayerView(
          handle: handle,
          viewType: '',
          onCompleted: () => secondCalls++,
          onError: (_) {},
          onRetry: () {},
        ),
      ),
    );
    handle.onCompleted!();
    expect(firstCalls, 1);
    expect(secondCalls, 1);
  });
}
