import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'torrent_engine.dart';
import 'torrent_magnet.dart';

class TorrentSessionStore {
  TorrentSessionStore([SharedPreferences? prefs]) : _prefs = prefs;

  static const String keySessions = 'moyi_torrent_sessions';

  final SharedPreferences? _prefs;

  Future<SharedPreferences> _store() async =>
      _prefs ?? await SharedPreferences.getInstance();

  Future<List<TorrentSession>> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await _store();
    final raw = store.getString(keySessions);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final sessions = <TorrentSession>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        try {
          final session = TorrentSession.fromJson(
            Map<String, dynamic>.from(row),
          );
          if (session.magnet.infoHash.isEmpty) continue;
          sessions.add(session);
        } catch (_) {
          continue;
        }
      }
      return sessions;
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<TorrentSession> sessions) async {
    final store = await _store();
    await store.setString(
      keySessions,
      jsonEncode([for (final s in sessions) s.toJson()]),
    );
  }

  Future<List<TorrentSession>> add(TorrentMagnet magnet) async {
    final sessions = await load();
    if (sessions.any((s) => s.id == magnet.infoHash)) return sessions;
    sessions.insert(0, TorrentSession(magnet: magnet));
    await save(sessions);
    return sessions;
  }

  /// 批量导入：去重后按文件内顺序插到列表最前面，返回去重后的新会话。
  Future<({List<TorrentSession> sessions, int added, int duplicates})>
  addAll(List<TorrentMagnet> magnets) async {
    final sessions = await load();
    final existing = {for (final s in sessions) s.id};
    final fresh = <TorrentSession>[];
    var duplicates = 0;
    for (final magnet in magnets) {
      if (magnet.infoHash.isEmpty || !existing.add(magnet.infoHash)) {
        duplicates++;
        continue;
      }
      fresh.add(TorrentSession(magnet: magnet));
    }
    sessions.insertAll(0, fresh);
    await save(sessions);
    return (sessions: sessions, added: fresh.length, duplicates: duplicates);
  }

  Future<List<TorrentSession>> remove(String infoHash) async {
    final sessions = await load();
    sessions.removeWhere((s) => s.id == infoHash);
    await save(sessions);
    return sessions;
  }
}
