import 'package:moyi/player_back.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('panel closes first', () {
    expect(
      resolvePlayerBackAction(
        panelOpen: true,
        pageFullscreen: true,
        fullscreen: true,
        television: false,
        isFirstRoute: false,
      ),
      PlayerBackAction.closePanel,
    );
  });

  test('television pops once', () {
    expect(
      resolvePlayerBackAction(
        panelOpen: false,
        pageFullscreen: false,
        fullscreen: true,
        television: true,
        isFirstRoute: false,
      ),
      PlayerBackAction.backOnce,
    );
  });

  test('page fullscreen exits before fullscreen', () {
    expect(
      resolvePlayerBackAction(
        panelOpen: false,
        pageFullscreen: true,
        fullscreen: true,
        television: false,
        isFirstRoute: false,
      ),
      PlayerBackAction.exitPageFullscreen,
    );
  });

  test('fullscreen exits before list', () {
    expect(
      resolvePlayerBackAction(
        panelOpen: false,
        pageFullscreen: false,
        fullscreen: true,
        television: false,
        isFirstRoute: false,
      ),
      PlayerBackAction.exitFullscreen,
    );
  });

  test('first route falls back to home', () {
    expect(
      resolvePlayerBackAction(
        panelOpen: false,
        pageFullscreen: false,
        fullscreen: false,
        television: false,
        isFirstRoute: true,
      ),
      PlayerBackAction.toHome,
    );
  });

  test('plain back goes to list', () {
    expect(
      resolvePlayerBackAction(
        panelOpen: false,
        pageFullscreen: false,
        fullscreen: false,
        television: false,
        isFirstRoute: false,
      ),
      PlayerBackAction.backToList,
    );
  });

  test('popUntil stops at unnamed routes only', () {
    Route<dynamic> routeWithName(String? name) => MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => const SizedBox.shrink(),
    );
    expect(isBackToListStop(routeWithName('player')), isFalse);
    expect(isBackToListStop(routeWithName('detail')), isFalse);
    expect(isBackToListStop(routeWithName(null)), isTrue);
    expect(isBackToListStop(routeWithName('search')), isTrue);
  });
}
