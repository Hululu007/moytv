import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_build.dart';
import 'background_downloads.dart';
import 'playback_policy.dart';

export 'playback_policy.dart';

class PlaybackForeground {
  static Future<void> acquire(String title) async {
    if (!Platform.isAndroid) return;
    try {
      await BackgroundDownloads.prepare();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(playbackBackgroundActiveKey, true);
      await preferences.setString(playbackBackgroundTitleKey, title);
      final text = playbackNotificationText(title);
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: appName,
          notificationText: text,
        );
        return;
      }
      await FlutterForegroundTask.requestNotificationPermission();
      final result = await FlutterForegroundTask.startService(
        serviceId: 2406,
        serviceTypes: const [ForegroundServiceTypes.mediaPlayback],
        notificationTitle: appName,
        notificationText: text,
        callback: downloadServiceEntry,
      );
      if (result is ServiceRequestFailure &&
          !await FlutterForegroundTask.isRunningService) {
        await preferences.setBool(playbackBackgroundActiveKey, false);
        await preferences.remove(playbackBackgroundTitleKey);
      }
    } catch (_) {}
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(playbackBackgroundActiveKey, false);
      await preferences.remove(playbackBackgroundTitleKey);
    } catch (_) {}
  }

  static Future<void> clearStaleFlag() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(playbackBackgroundActiveKey, false);
      await preferences.remove(playbackBackgroundTitleKey);
    } catch (_) {}
  }
}
