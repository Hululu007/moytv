import 'dart:async';

import 'core_bridge.dart';
import 'models.dart';
import 'playback_preloader.dart';

class HongguoPreloadWindow {
  HongguoPreloadWindow(
    this.repository, {
    this.episodeWindow = 5,
    this.upcomingDramas = 3,
    required this.detailOf,
  });

  final AppRepository repository;
  final int episodeWindow;
  final int upcomingDramas;
  final Future<DramaDetail?> Function(Drama drama) detailOf;

  final Map<String, PlaybackPreloader> _slots = {};
  final Map<String, (Drama, Episode)> _upcomingTargets = {};
  final Set<String> _detailLoading = {};
  bool _closed = false;

  String _key(String dramaId, int episodeNumber) => '$dramaId\u0000$episodeNumber';

  PlaybackPlan? take(Drama drama, Episode episode) {
    final slot = _slots.remove(_key(drama.id, episode.number));
    if (slot == null) return null;
    final plan = slot.take(drama, episode);
    slot.dispose();
    return plan;
  }

  void recenter({
    required Drama drama,
    required List<Episode> episodes,
    required int episodeIndex,
    required List<Drama> upcoming,
  }) {
    if (_closed) return;
    final wanted = <String>{};
    final wantedPlans = <String, (Drama, Episode)>{};
    for (var offset = 1; offset <= episodeWindow; offset++) {
      final index = episodeIndex + offset;
      if (index < 0 || index >= episodes.length) break;
      final episode = episodes[index];
      final key = _key(drama.id, episode.number);
      wanted.add(key);
      wantedPlans[key] = (drama, episode);
    }
    final upcomingIds = <String>{};
    for (final next in upcoming) {
      if (next.id == drama.id) continue;
      upcomingIds.add(next.id);
      if (upcomingIds.length > upcomingDramas) break;
      final target = _upcomingTargets[next.id];
      if (target != null) {
        final key = _key(next.id, target.$2.number);
        wanted.add(key);
        wantedPlans[key] = target;
      } else {
        unawaited(_prepareUpcoming(next));
      }
    }
    _upcomingTargets.removeWhere((id, _) => !upcomingIds.contains(id));
    for (final entry in wantedPlans.entries) {
      final slot = _slots.putIfAbsent(
        entry.key,
        () => PlaybackPreloader(repository),
      );
      slot.prepare(entry.value.$1, entry.value.$2);
    }
    final stale = _slots.keys.where((key) => !wanted.contains(key)).toList();
    for (final key in stale) {
      _slots.remove(key)?.dispose();
    }
  }

  Future<void> _prepareUpcoming(Drama drama) async {
    if (_closed || _detailLoading.contains(drama.id)) return;
    _detailLoading.add(drama.id);
    try {
      final detail = await detailOf(drama);
      if (_closed || detail == null || detail.episodes.isEmpty) return;
      final target = (drama, detail.episodes.first);
      _upcomingTargets[drama.id] = target;
      final slot = _slots.putIfAbsent(
        _key(drama.id, target.$2.number),
        () => PlaybackPreloader(repository),
      );
      slot.prepare(drama, target.$2);
    } catch (_) {
    } finally {
      _detailLoading.remove(drama.id);
    }
  }

  void clear() {
    for (final slot in _slots.values) {
      slot.dispose();
    }
    _slots.clear();
  }

  void dispose() {
    _closed = true;
    clear();
  }
}
