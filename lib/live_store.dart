import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_models.dart';

class LiveStore extends ChangeNotifier {
  LiveStore(this.preferences, this.profileId);

  final SharedPreferences preferences;
  final String profileId;
  final List<LiveChannel> _favourites = [];
  final List<LiveChannel> _recent = [];
  bool _ready = false;

  /// 上次观看的直播（源 + 分组 + 频道 + 点播位置）：只记最后一条，
  /// 存在 SharedPreferences 单键一个小 JSON，重启 App 还在。
  LiveLastWatched? _lastWatched;

  LiveLastWatched? get lastWatched => _lastWatched;

  bool get ready => _ready;
  List<LiveChannel> get favourites => List.unmodifiable(_favourites);
  List<LiveChannel> get recent => List.unmodifiable(_recent);
  bool isFavourite(String key) => _favourites.any((entry) => entry.key == key);

  String _scope(String key) =>
      profileId == 'default' ? key : 'profile.$profileId.$key';

  void load() {
    _favourites
      ..clear()
      ..addAll(_read(_scope('live.favourites')));
    _recent
      ..clear()
      ..addAll(_read(_scope('live.recent')));
    _lastWatched = _readLastWatched(_scope('live.lastWatched'));
    _ready = true;
    notifyListeners();
  }

  Future<void> toggleFavourite(LiveChannel channel) async {
    if (isFavourite(channel.key)) {
      _favourites.removeWhere((entry) => entry.key == channel.key);
    } else {
      _favourites.insert(0, channel);
    }
    notifyListeners();
    await _write(_scope('live.favourites'), _favourites);
  }

  Future<void> remember(LiveChannel channel) async {
    _recent.removeWhere((entry) => entry.key == channel.key);
    _recent.insert(0, channel);
    if (_recent.length > 60) _recent.removeRange(60, _recent.length);
    notifyListeners();
    await _write(_scope('live.recent'), _recent);
  }

  Future<void> clearRecent() async {
    _recent.clear();
    notifyListeners();
    await _write(_scope('live.recent'), _recent);
  }

  /// 记下上次看的频道：源 + 分组 + 频道 key/名 + 时间；点播可带位置。
  /// 频道变了才 notify（“上次观看”入口要刷新）；同一频道重复记
  /// 只更新时间戳，不重建界面。
  Future<void> rememberLastWatched({
    required String sourceId,
    required String groupId,
    required String groupName,
    required LiveChannel channel,
    int positionMs = 0,
  }) async {
    final record = LiveLastWatched(
      sourceId: sourceId,
      groupId: groupId,
      groupName: groupName,
      channelKey: channel.key,
      channelName: channel.name,
      positionMs: positionMs,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final changed =
        _lastWatched?.channelKey != record.channelKey ||
        _lastWatched?.sourceId != record.sourceId;
    _lastWatched = record;
    if (changed) notifyListeners();
    await _writeLastWatched();
  }

  /// 只更新点播位置：不 notify、不碰频道，写盘失败也静默。
  Future<void> rememberPosition(int positionMs) async {
    final current = _lastWatched;
    if (current == null) return;
    _lastWatched = current.withPosition(positionMs);
    await _writeLastWatched();
  }

  Future<void> clearLastWatched() async {
    if (_lastWatched == null) return;
    _lastWatched = null;
    notifyListeners();
    try {
      await preferences.remove(_scope('live.lastWatched'));
    } catch (_) {}
  }

  LiveLastWatched? _readLastWatched(String key) {
    final raw = preferences.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return LiveLastWatched.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLastWatched() async {
    final record = _lastWatched;
    if (record == null) return;
    try {
      await preferences.setString(
        _scope('live.lastWatched'),
        jsonEncode(record.toJson()),
      );
    } catch (_) {}
  }

  List<LiveChannel> _read(String key) {
    final raw = preferences.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (row) => LiveChannel.fromFavourite(Map<String, dynamic>.from(row)),
          )
          .where((entry) => entry.key.isNotEmpty && entry.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write(String key, List<LiveChannel> values) async {
    try {
      await preferences.setString(
        key,
        jsonEncode(values.map((entry) => entry.toFavourite()).toList()),
      );
    } catch (_) {}
  }
}
