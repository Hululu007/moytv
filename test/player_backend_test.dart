import 'package:moyi/player_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initial backend is current and untried remains', () {
    final manager = PlaybackBackendManager(initial: PlaybackBackend.tvbox);
    expect(manager.current, PlaybackBackend.tvbox);
    expect(manager.hasUntried, isTrue);
  });

  test('next backend moves once and never ping-pongs', () {
    final manager = PlaybackBackendManager(initial: PlaybackBackend.tvbox);
    expect(manager.nextBackend(), PlaybackBackend.main);
    expect(manager.current, PlaybackBackend.main);
    expect(manager.hasUntried, isFalse);
    expect(manager.nextBackend(), isNull);
    expect(manager.current, PlaybackBackend.main);
  });

  test('main-first chain switches to tvbox once', () {
    final manager = PlaybackBackendManager(initial: PlaybackBackend.main);
    expect(manager.nextBackend(), PlaybackBackend.tvbox);
    expect(manager.nextBackend(), isNull);
  });

  test('reset starts a fresh chain', () {
    final manager = PlaybackBackendManager(initial: PlaybackBackend.tvbox);
    manager.nextBackend();
    expect(manager.hasUntried, isFalse);
    manager.reset(PlaybackBackend.main);
    expect(manager.current, PlaybackBackend.main);
    expect(manager.hasUntried, isTrue);
    expect(manager.nextBackend(), PlaybackBackend.tvbox);
  });
}
