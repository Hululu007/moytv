import 'dart:async';

import 'danmaku_models.dart';
import 'models.dart';

class DanmakuWindowState {
  const DanmakuWindowState({
    required this.visible,
    required this.buffering,
    required this.positionMs,
    required this.moving,
    required this.durationMs,
    required this.plan,
  });

  final bool visible;
  final bool buffering;
  final int positionMs;
  final bool moving;
  final int durationMs;
  final PlaybackPlan? plan;
}

typedef DanmakuLoadPage =
    Future<DanmakuPage> Function(
      PlaybackPlan plan,
      int startMs,
      int durationMs,
    );

class DanmakuLoader {
  DanmakuLoader({
    required this.state,
    required this.loadPage,
    required this.cancelLoad,
    required this.onItems,
    required this.onChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DanmakuWindowState Function() state;
  final DanmakuLoadPage loadPage;
  final Future<void> Function() cancelLoad;
  final void Function(List<DanmakuItem> items) onItems;
  final void Function() onChanged;
  final DateTime Function() _now;

  final _pages = <int, DanmakuPage>{};
  final _failures = <int, DateTime>{};
  int _generation = 0;
  int? _pendingStart;

  bool get hasPages => _pages.isNotEmpty;
  bool get hasFailures => _failures.isNotEmpty;
  bool get loading => _pendingStart != null;

  void cancel() {
    _generation++;
    if (_pendingStart != null) {
      _pendingStart = null;
      unawaited(cancelLoad().catchError((Object _) {}));
    }
  }

  void clearPages() {
    _pages.clear();
    _failures.clear();
    _rebuildItems();
  }

  void clearFailures() {
    _failures.clear();
  }

  void ensureWindow() {
    final current = state();
    if (!current.visible || current.buffering || _pendingStart != null) return;
    final page = _covering(current.positionMs);
    var start = current.positionMs ~/ danmakuWindowMs * danmakuWindowMs;
    if (page == null && _pages.containsKey(start)) start = current.positionMs;
    if (page != null) {
      if (!current.moving ||
          current.positionMs < page.nextMs - danmakuLifetimeMs ||
          page.nextMs >= current.durationMs ||
          _covering(page.nextMs) != null) {
        return;
      }
      start = page.nextMs;
    }
    final retryAt = _failures[start];
    if (retryAt != null && _now().isBefore(retryAt)) return;
    unawaited(_load(start));
  }

  DanmakuPage? _covering(int position) {
    DanmakuPage? found;
    for (final page in _pages.values) {
      if (page.startMs <= position &&
          position < page.nextMs &&
          (found == null || page.startMs > found.startMs)) {
        found = page;
      }
    }
    return found;
  }

  Future<void> _load(int start) async {
    final ticket = _generation;
    final plan = state().plan!;
    final duration = state().durationMs;
    _pendingStart = start;
    onChanged();
    try {
      final page = await loadPage(plan, start, duration);
      if (ticket != _generation) return;
      if (page.episodeId != plan.danmakuId ||
          page.startMs != start ||
          page.nextMs <= start ||
          page.nextMs > duration ||
          page.items.length > 90 ||
          page.items.any(
            (item) => item.timeMs < start || item.timeMs >= page.nextMs,
          )) {
        throw const FormatException('弹幕时间范围无效');
      }
      _pages[start] = page;
      _failures.remove(start);
      final position = state().positionMs;
      final nearest = _pages.keys.toList()
        ..sort((a, b) => (a - position).abs().compareTo((b - position).abs()));
      for (final key in nearest.skip(6)) {
        _pages.remove(key);
      }
      _rebuildItems();
    } catch (_) {
      if (ticket != _generation) return;
      _failures[start] = _now().add(const Duration(seconds: 15));
      while (_failures.length > 8) {
        _failures.remove(_failures.keys.first);
      }
    } finally {
      if (ticket == _generation) {
        _pendingStart = null;
        onChanged();
        ensureWindow();
      }
    }
  }

  void _rebuildItems() {
    final unique = <String, DanmakuItem>{};
    final pages = _pages.values.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    for (final page in pages) {
      for (final item in page.items) {
        unique.putIfAbsent(item.id, () => item);
      }
    }
    final sorted = unique.values.toList()
      ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    onItems(List.unmodifiable(sorted));
  }
}
