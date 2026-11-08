class BackHistory<E> {
  BackHistory({this.limit = 50});

  final int limit;
  final List<E> _entries = [];

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

  void push(E entry) {
    if (_entries.isNotEmpty && _entries.last == entry) return;
    _entries.add(entry);
    while (_entries.length > limit) {
      _entries.removeAt(0);
    }
  }

  E? pop() => _entries.isEmpty ? null : _entries.removeLast();

  void clear() => _entries.clear();
}
