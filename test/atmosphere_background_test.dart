import 'dart:typed_data';

import 'package:moyi/atmosphere_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test('uniform pixels yield a single-color palette', () {
    final palette = atmospherePaletteFromPixels(
      Uint8List.fromList([
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
      ]),
      2,
      2,
    );
    expect(palette, isNotNull);
    expect(palette!.primary, const Color.fromRGBO(255, 0, 0, 1));
    expect(palette.secondary, const Color.fromRGBO(255, 0, 0, 1));
  });

  test('average is the primary and the farthest sample is secondary', () {
    final palette = atmospherePaletteFromPixels(
      Uint8List.fromList([
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        255,
      ]),
      2,
      2,
    );
    expect(palette, isNotNull);
    expect(palette!.primary, const Color.fromRGBO(127, 0, 127, 1));
    expect(palette.secondary, const Color.fromRGBO(255, 0, 0, 1));
  });

  test('empty or truncated pixels yield no palette', () {
    expect(atmospherePaletteFromPixels(Uint8List(0), 0, 0), isNull);
    expect(
      atmospherePaletteFromPixels(Uint8List.fromList([255, 0, 0]), 2, 2),
      isNull,
    );
  });

  BoxDecoration decorationOf(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byType(AtmosphereBackground),
      matching: find.byType(Container),
    );
    return tester.widget<Container>(finder).decoration! as BoxDecoration;
  }

  testWidgets('empty url falls back to the theme gradient', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AtmosphereBackground(
            url: '',
            repository: FixtureRepository(),
            drama: FixtureRepository.free,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gradient = decorationOf(tester).gradient! as LinearGradient;
    final scheme = Theme.of(
      tester.element(find.byType(AtmosphereBackground)),
    ).colorScheme;
    expect(gradient.colors, [
      scheme.surfaceContainerHighest,
      scheme.surfaceContainer,
    ]);
  });

  testWidgets('a cached palette is reused without calling the loader again', (
    tester,
  ) async {
    const palette = AtmospherePalette(
      Color.fromRGBO(10, 20, 30, 1),
      Color.fromRGBO(200, 100, 50, 1),
    );
    var calls = 0;
    Future<AtmospherePalette?> countingLoader(_, _) async {
      calls++;
      return palette;
    }

    Future<void> pump() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AtmosphereBackground(
              url: 'https://example.test/poster.jpg',
              repository: FixtureRepository(),
              drama: FixtureRepository.free,
              loader: countingLoader,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump();
    var gradient = decorationOf(tester).gradient! as LinearGradient;
    expect(gradient.colors, [
      palette.primary.withValues(alpha: .55),
      palette.secondary.withValues(alpha: .75),
    ]);
    expect(calls, 1);
    await pump();
    gradient = decorationOf(tester).gradient! as LinearGradient;
    expect(gradient.colors, [
      palette.primary.withValues(alpha: .55),
      palette.secondary.withValues(alpha: .75),
    ]);
    expect(calls, 1);
  });
}
