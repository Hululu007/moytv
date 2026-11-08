enum PlaybackBackend { main, tvbox }

class PlaybackBackendManager {
  PlaybackBackendManager({required PlaybackBackend initial})
    : _current = initial,
      _tried = {initial};

  PlaybackBackend _current;
  final Set<PlaybackBackend> _tried;

  PlaybackBackend get current => _current;

  bool get hasUntried => _tried.length < PlaybackBackend.values.length;

  PlaybackBackend? nextBackend() {
    for (final backend in PlaybackBackend.values) {
      if (!_tried.contains(backend)) {
        _tried.add(backend);
        _current = backend;
        return backend;
      }
    }
    return null;
  }

  void reset(PlaybackBackend initial) {
    _current = initial;
    _tried
      ..clear()
      ..add(initial);
  }
}
