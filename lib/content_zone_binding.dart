import 'content_models.dart';
import 'content_registry.dart';

class ContentZoneBinding {
  ContentZoneBinding({
    List<ContentSource> Function(ContentSection section)? sourcesProvider,
    this._readPersisted,
    this._writePersisted,
  }) : _sourcesProvider = sourcesProvider ?? ContentRegistry.sourcesFor;

  final List<ContentSource> Function(ContentSection section) _sourcesProvider;
  final String? Function(String key)? _readPersisted;
  final void Function(String key, String value)? _writePersisted;
  final Map<ContentSection, String> _selectedIds = {};

  static String storageKey(ContentSection section) =>
      'content_zone_source_${section.name}';

  List<ContentSource> sourcesFor(ContentSection section) =>
      _sourcesProvider(section);

  String? selectedIdFor(ContentSection section) {
    final cached = _selectedIds[section];
    if (cached != null) return cached;
    final persisted = _readPersisted?.call(storageKey(section));
    if (persisted != null) _selectedIds[section] = persisted;
    return persisted;
  }

  ContentSource? sourceFor(ContentSection section) {
    final sources = sourcesFor(section);
    if (sources.isEmpty) return null;
    final selectedId = selectedIdFor(section);
    if (selectedId != null) {
      for (final source in sources) {
        if (source.id == selectedId) return source;
      }
    }
    return sources.first;
  }

  void select(ContentSection section, ContentSource source) {
    if (source.section != section) return;
    if (!sourcesFor(section).any((s) => s.id == source.id)) return;
    _selectedIds[section] = source.id;
    _writePersisted?.call(storageKey(section), source.id);
  }
}
