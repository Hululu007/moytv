import 'package:moyi/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('video grid vertical gap scales with tile width', () {
    expect(videoGridMainAxisSpacing(113), closeTo(11.3, 0.01));
    expect(videoGridMainAxisSpacing(50), 8.0);
    expect(videoGridMainAxisSpacing(300), 16.0);
    expect(
      videoGridMainAxisSpacing(113) < videoGridMainAxisSpacing(185),
      isTrue,
    );
  });

  testWidgets('video grid delegate tightens the old fixed gap', (
    tester,
  ) async {
    SliverGridDelegate? phoneDelegate;
    SliverGridDelegate? wideDelegate;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            phoneDelegate = dramaGridDelegate(context, 390);
            wideDelegate = dramaGridDelegate(context, 1200);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final phone =
        phoneDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    final wide = wideDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(phone.crossAxisCount, 3);
    expect(phone.mainAxisSpacing, lessThan(22));
    expect(wide.mainAxisSpacing, 16.0);
    expect(phone.mainAxisSpacing < wide.mainAxisSpacing, isTrue);
  });
}
