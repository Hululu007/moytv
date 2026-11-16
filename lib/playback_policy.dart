import 'package:shared_preferences/shared_preferences.dart';

const String playbackBackgroundActiveKey = 'playback_background_active';
const String playbackBackgroundTitleKey = 'playback_background_title';

String playbackNotificationText(String title) {
  final trimmed = title.trim();
  return trimmed.isEmpty ? '正在播放' : '正在播放 · $trimmed';
}

bool shouldAcquirePlaybackService({
  required bool playing,
  required bool useTvbox,
}) {
  return playing && !useTvbox;
}

bool shouldStopIdleService({
  required bool playbackActive,
  required int idlePolls,
}) {
  return !playbackActive && idlePolls >= 5;
}

bool feedOverlayCanHide({
  required bool overlayVisible,
  required bool clearScreen,
  required bool sheetOpen,
  required bool playing,
}) {
  return overlayVisible && !clearScreen && !sheetOpen && playing;
}

Future<({bool active, String title})> readPlaybackFlag() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    return (
      active: preferences.getBool(playbackBackgroundActiveKey) ?? false,
      title: preferences.getString(playbackBackgroundTitleKey) ?? '',
    );
  } catch (_) {
    return (active: false, title: '');
  }
}
