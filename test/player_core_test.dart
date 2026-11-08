import 'package:moyi/ijk_video_pane.dart';
import 'package:moyi/player_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parse falls back to mpv for unknown values', () {
    expect(PlayerCore.parse('mpv'), PlayerCore.mpv);
    expect(PlayerCore.parse('exo'), PlayerCore.exo);
    expect(PlayerCore.parse('ijk'), PlayerCore.ijk);
    expect(PlayerCore.parse(null), PlayerCore.mpv);
    expect(PlayerCore.parse('bogus'), PlayerCore.mpv);
  });

  test('parse migrates retired mdk to mpv', () {
    expect(PlayerCore.parse('mdk'), PlayerCore.mpv);
  });

  test('guo follows the stored core', () {
    expect(
      effectivePlayerCore(stored: PlayerCore.exo),
      PlayerCore.exo,
    );
    expect(
      effectivePlayerCore(stored: PlayerCore.ijk),
      PlayerCore.ijk,
    );
    expect(
      effectivePlayerCore(stored: PlayerCore.mpv),
      PlayerCore.mpv,
    );
  });

  test('other players keep their stored core', () {
    expect(
      effectivePlayerCore(stored: PlayerCore.exo),
      PlayerCore.exo,
    );
    expect(
      effectivePlayerCore(stored: PlayerCore.ijk),
      PlayerCore.ijk,
    );
  });

  test('dialog titles carry engine names', () {
    expect(PlayerCore.mpv.dialogTitle, 'MPV (media_kit)');
    expect(PlayerCore.ijk.dialogTitle, 'IJK (ijkplayer)');
    expect(PlayerCore.exo.dialogTitle, 'EXO (Media3)');
  });

  test('every core has a description', () {
    for (final core in PlayerCore.values) {
      expect(core.description.isNotEmpty, isTrue);
      expect(core.label.isNotEmpty, isTrue);
    }
  });

  test('options enable all cores when exo and ijk are available', () {
    final options = playerCoreOptions(
      exoAvailable: true,
      ijkAvailable: true,
    );
    expect(options.length, 3);
    expect(options.every((option) => option.enabled), isTrue);
  });

  test('options disable exo when it is unavailable', () {
    final options = playerCoreOptions(
      exoAvailable: false,
      ijkAvailable: true,
    );
    final exo = options.firstWhere((option) => option.core == PlayerCore.exo);
    expect(exo.enabled, isFalse);
    expect(exo.disabledNote, '仅 Android 可用');
    expect(
      options
          .where((option) => option.core != PlayerCore.exo)
          .every((option) => option.enabled),
      isTrue,
    );
  });

  test('options disable ijk when it is unavailable', () {
    final options = playerCoreOptions(
      exoAvailable: true,
      ijkAvailable: false,
    );
    final ijk = options.firstWhere((option) => option.core == PlayerCore.ijk);
    expect(ijk.enabled, isFalse);
    expect(ijk.disabledNote, '仅 Android 可用');
    expect(
      options
          .where((option) => option.core != PlayerCore.ijk)
          .every((option) => option.enabled),
      isTrue,
    );
  });

  test('ijk handle defaults and speed tracking', () async {
    final handle = IjkPlaybackHandle();
    expect(handle.speed, 1.0);
    expect(handle.position, Duration.zero);
    expect(handle.duration, Duration.zero);
    expect(handle.playing, isFalse);
    expect(handle.completed, isFalse);
    expect(handle.positionSeconds, 0);
    expect(handle.durationSeconds, 0);
    await handle.setSpeed(1.5);
    expect(handle.speed, 1.5);
    await handle.play();
    await handle.pause();
    await handle.seek(const Duration(seconds: 10));
  });
}
