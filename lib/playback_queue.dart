import 'models.dart';

class PlaybackQueue {
  const PlaybackQueue({required this.items, required this.currentIndex});

  final List<Drama> items;
  final int currentIndex;

  factory PlaybackQueue.around(List<Drama> items, Drama current) {
    final index = items.indexWhere(
      (drama) => drama.id == current.id && drama.source == current.source,
    );
    return PlaybackQueue(
      items: List.unmodifiable(items),
      currentIndex: index < 0 ? 0 : index,
    );
  }

  bool get isEmpty => items.isEmpty;
  Drama? get current => currentIndex >= 0 && currentIndex < items.length
      ? items[currentIndex]
      : null;

  Drama? neighbor(int direction) {
    final next = currentIndex + direction;
    return next >= 0 && next < items.length ? items[next] : null;
  }

  PlaybackQueue moved(int direction) => PlaybackQueue(
    items: items,
    currentIndex: (currentIndex + direction).clamp(0, items.length - 1),
  );
}
