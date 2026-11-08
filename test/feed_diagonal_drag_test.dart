import 'dart:math' as math;

import 'package:moyi/feed_diagonal_drag.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget buildHarness({
  required List<String> mine,
  required List<String> vertical,
  required List<String> horizontal,
  required bool Function() isBlocked,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          key: const Key('dragArea'),
          width: 300,
          height: 300,
          child: RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory>{
              HorizontalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    HorizontalDragGestureRecognizer
                  >(() => HorizontalDragGestureRecognizer(), (recognizer) {
                    recognizer.onStart = (_) => horizontal.add('start');
                    recognizer.onUpdate = (_) => horizontal.add('update');
                    recognizer.onEnd = (_) => horizontal.add('end');
                  }),
              VerticalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    VerticalDragGestureRecognizer
                  >(() => VerticalDragGestureRecognizer(), (recognizer) {
                    recognizer.onStart = (_) => vertical.add('start');
                    recognizer.onUpdate = (_) => vertical.add('update');
                    recognizer.onEnd = (_) => vertical.add('end');
                  }),
              FeedDiagonalDragRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    FeedDiagonalDragRecognizer
                  >(
                    () => FeedDiagonalDragRecognizer(
                      isBlocked: isBlocked,
                      onStart: (_) => mine.add('start'),
                      onUpdate: (_) => mine.add('update'),
                      onEnd: (_) => mine.add('end'),
                      onCancel: () => mine.add('cancel'),
                    ),
                    (recognizer) {
                      recognizer.isBlocked = isBlocked;
                      recognizer.onStart = (_) => mine.add('start');
                      recognizer.onUpdate = (_) => mine.add('update');
                      recognizer.onEnd = (_) => mine.add('end');
                      recognizer.onCancel = () => mine.add('cancel');
                    },
                  ),
            },
            child: Container(color: Colors.black),
          ),
        ),
      ),
    ),
  );
}

Future<void> dragAngle(
  WidgetTester tester,
  double degrees, {
  int steps = 12,
}) async {
  final center = tester.getCenter(find.byKey(const Key('dragArea')));
  final radians = degrees * math.pi / 180;
  final total = Offset(100 * math.sin(radians), -100 * math.cos(radians));
  final gesture = await tester.startGesture(center);
  await tester.pump();
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(total / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  test('diagonal angle is measured from vertical', () {
    expect(diagonalDragAngleFromVertical(const Offset(0, -100)), 0);
    expect(diagonalDragAngleFromVertical(const Offset(100, -100)), 45);
    expect(diagonalDragAngleFromVertical(const Offset(100, 0)), 90);
    expect(diagonalDragAngleFromVertical(Offset.zero), 90);
  });

  test('claim band covers 45 and 60 degrees, not 30 or 80', () {
    expect(shouldClaimDiagonalDrag(const Offset(50, -86.6)), isFalse);
    expect(shouldClaimDiagonalDrag(const Offset(70.7, -70.7)), isTrue);
    expect(shouldClaimDiagonalDrag(const Offset(86.6, -50)), isTrue);
    expect(shouldClaimDiagonalDrag(const Offset(98.5, -17.4)), isFalse);
    expect(shouldClaimDiagonalDrag(const Offset(7, -7)), isFalse);
    expect(shouldClaimDiagonalDrag(Offset.zero), isFalse);
  });

  testWidgets('30 degree drag is won by the vertical recognizer', (
    tester,
  ) async {
    final mine = <String>[];
    final vertical = <String>[];
    final horizontal = <String>[];
    await tester.pumpWidget(
      buildHarness(
        mine: mine,
        vertical: vertical,
        horizontal: horizontal,
        isBlocked: () => false,
      ),
    );
    await dragAngle(tester, 30.0);
    expect(mine, isEmpty);
    expect(horizontal, isEmpty);
    expect(vertical, containsAll(['start', 'update', 'end']));
  });

  testWidgets('45 degree drag is won by the diagonal recognizer', (
    tester,
  ) async {
    final mine = <String>[];
    final vertical = <String>[];
    final horizontal = <String>[];
    await tester.pumpWidget(
      buildHarness(
        mine: mine,
        vertical: vertical,
        horizontal: horizontal,
        isBlocked: () => false,
      ),
    );
    await dragAngle(tester, 45.0);
    expect(mine, containsAll(['start', 'update', 'end']));
    expect(vertical, isEmpty);
    expect(horizontal, isEmpty);
  });

  testWidgets('60 degree drag is won by the diagonal recognizer', (
    tester,
  ) async {
    final mine = <String>[];
    final vertical = <String>[];
    final horizontal = <String>[];
    await tester.pumpWidget(
      buildHarness(
        mine: mine,
        vertical: vertical,
        horizontal: horizontal,
        isBlocked: () => false,
      ),
    );
    await dragAngle(tester, 60.0);
    expect(mine, containsAll(['start', 'update', 'end']));
    expect(vertical, isEmpty);
    expect(horizontal, isEmpty);
  });

  testWidgets('80 degree drag is won by the horizontal recognizer', (
    tester,
  ) async {
    final mine = <String>[];
    final vertical = <String>[];
    final horizontal = <String>[];
    await tester.pumpWidget(
      buildHarness(
        mine: mine,
        vertical: vertical,
        horizontal: horizontal,
        isBlocked: () => false,
      ),
    );
    await dragAngle(tester, 80.0);
    expect(mine, isEmpty);
    expect(vertical, isEmpty);
    expect(horizontal, containsAll(['start', 'update', 'end']));
  });

  testWidgets('blocked diagonal drag never claims', (tester) async {
    final mine = <String>[];
    final vertical = <String>[];
    final horizontal = <String>[];
    await tester.pumpWidget(
      buildHarness(
        mine: mine,
        vertical: vertical,
        horizontal: horizontal,
        isBlocked: () => true,
      ),
    );
    await dragAngle(tester, 50.0);
    expect(mine, isEmpty);
  });

  testWidgets('tiny drag claims nothing', (tester) async {
    final mine = <String>[];
    final vertical = <String>[];
    final horizontal = <String>[];
    await tester.pumpWidget(
      buildHarness(
        mine: mine,
        vertical: vertical,
        horizontal: horizontal,
        isBlocked: () => false,
      ),
    );
    final center = tester.getCenter(find.byKey(const Key('dragArea')));
    final gesture = await tester.startGesture(center);
    await tester.pump();
    await gesture.moveBy(const Offset(7, -7));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();
    expect(mine, isEmpty);
    expect(vertical, isEmpty);
    expect(horizontal, isEmpty);
  });
}
