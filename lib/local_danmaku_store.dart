import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocalDanmakuEntry {
  const LocalDanmakuEntry({required this.text, required this.timeMs});

  final String text;
  final int timeMs;

  Map<String, dynamic> toJson() => {'text': text, 'timeMs': timeMs};

  factory LocalDanmakuEntry.fromJson(Map<String, dynamic> json) =>
      LocalDanmakuEntry(
        text: json['text'] as String? ?? '',
        timeMs: json['timeMs'] as int? ?? 0,
      );
}

class LocalDanmakuStore {
  static String keyFor(String videoKey) => 'local_danmaku_$videoKey';

  static Future<List<LocalDanmakuEntry>> load(String videoKey) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(keyFor(videoKey));
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>)
            LocalDanmakuEntry.fromJson(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> add(String videoKey, LocalDanmakuEntry entry) async {
    try {
      final items = await load(videoKey);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        keyFor(videoKey),
        jsonEncode([...items, entry].map((item) => item.toJson()).toList()),
      );
    } catch (_) {}
  }

  static Future<void> clear(String videoKey) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(keyFor(videoKey));
    } catch (_) {}
  }
}
