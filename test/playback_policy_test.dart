import 'package:moyi/playback_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('notification text uses title when present', () {
    expect(playbackNotificationText('天地不问'), '正在播放 · 天地不问');
    expect(playbackNotificationText('  天地不问  '), '正在播放 · 天地不问');
    expect(playbackNotificationText(''), '正在播放');
    expect(playbackNotificationText('   '), '正在播放');
  });

  test('acquire decision requires playing mpv route', () {
    expect(
      shouldAcquirePlaybackService(playing: true, useTvbox: false),
      isTrue,
    );
    expect(
      shouldAcquirePlaybackService(playing: false, useTvbox: false),
      isFalse,
    );
    expect(
      shouldAcquirePlaybackService(playing: true, useTvbox: true),
      isFalse,
    );
  });

  test('idle stop never fires while playback is active', () {
    expect(
      shouldStopIdleService(playbackActive: true, idlePolls: 100),
      isFalse,
    );
    expect(shouldStopIdleService(playbackActive: false, idlePolls: 4), isFalse);
    expect(shouldStopIdleService(playbackActive: false, idlePolls: 5), isTrue);
    expect(shouldStopIdleService(playbackActive: false, idlePolls: 6), isTrue);
  });

  test('feed overlay hides only when visible, unobstructed and playing', () {
    expect(
      feedOverlayCanHide(
        overlayVisible: true,
        clearScreen: false,
        sheetOpen: false,
        playing: true,
      ),
      isTrue,
    );
    expect(
      feedOverlayCanHide(
        overlayVisible: false,
        clearScreen: false,
        sheetOpen: false,
        playing: true,
      ),
      isFalse,
    );
    expect(
      feedOverlayCanHide(
        overlayVisible: true,
        clearScreen: true,
        sheetOpen: false,
        playing: true,
      ),
      isFalse,
    );
    expect(
      feedOverlayCanHide(
        overlayVisible: true,
        clearScreen: false,
        sheetOpen: true,
        playing: true,
      ),
      isFalse,
    );
    expect(
      feedOverlayCanHide(
        overlayVisible: true,
        clearScreen: false,
        sheetOpen: false,
        playing: false,
      ),
      isFalse,
    );
  });

  test('playback flag round-trips through preferences', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final empty = await readPlaybackFlag();
    expect(empty.active, isFalse);
    expect(empty.title, isEmpty);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(playbackBackgroundActiveKey, true);
    await preferences.setString(playbackBackgroundTitleKey, '天地不问');
    final held = await readPlaybackFlag();
    expect(held.active, isTrue);
    expect(held.title, '天地不问');
    await preferences.setBool(playbackBackgroundActiveKey, false);
    await preferences.remove(playbackBackgroundTitleKey);
    final released = await readPlaybackFlag();
    expect(released.active, isFalse);
    expect(released.title, isEmpty);
  });
}
