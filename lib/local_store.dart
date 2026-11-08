import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_database.dart';
import 'content_registry.dart';
import 'custom_headers.dart';
import 'jar_import.dart';
import 'imported_site_record.dart';
import 'live_models.dart';
import 'live_sources.dart';
import 'local_profiles.dart';
import 'local_snapshot.dart';
import 'm3u_subscriptions.dart';
import 'models.dart';
import 'tvbox_config.dart';
import 'playback_preferences.dart';
import 'download_preferences.dart';
import 'catalog_sort.dart';
import 'follow_state.dart';
import 'hongguo_series.dart';
import 'lan_sync_models.dart';
import 'xigua/watch_stats.dart';

part 'local_store_sync.dart';

class LocalStore extends ChangeNotifier {
  LocalStore(this.preferences) {
    _initialize();
  }

  final SharedPreferences preferences;
  LocalSnapshot? _snapshot;
  LanDocument? _lanDocumentCache;
  int _lanRevision = 0;
  int _lanUrgentRevision = 0;
  int get lanRevision => _lanRevision;
  int get lanUrgentRevision => _lanUrgentRevision;
  final Map<String, WatchEntry> _history = {};
  final Map<String, Drama> _favorites = {};
  final Map<String, FollowState> _followStates = {};
  final Map<String, Drama> _seriesCandidates = {};
  Future<void> _writes = Future<void>.value();
  List<LocalProfile> _profiles = [];
  String _current = 'default';
  bool _locked = false;
  bool _disposed = false;
  String? _configurationError;
  int _epoch = 0;
  int _failures = 0;
  DateTime _retryAfter = DateTime(2000);
  List<CustomSourceSite> _customSources = [];
  List<ImportedSiteRecord> _importedSiteRecords = [];
  final Set<String> _registeredImportIds = {};
  List<M3uSubscription> _m3uSubscriptions = [];
  final Set<String> _registeredM3uIds = {};

  void _initialize() {
    try {
      _snapshot = LocalSnapshot(preferences);
    } catch (_) {
      _snapshot = LocalSnapshot.migrated(preferences);
    }
    try {
      _loadCustomSources();
      TvBoxConfigStore.restore(preferences);
      JarImport.restore(preferences);
      _loadImportedSites();
      _loadM3uSubscriptions();
    } catch (_) {}
    try {
      final raw = _snapshot!.getString('profiles');
      _profiles = raw == null
          ? [const LocalProfile(id: 'default', name: '管理员', admin: true)]
          : _readProfiles(jsonDecode(raw));
      _current = _snapshot!.getString('activeProfile') ?? 'default';
      if (!_profiles.any((profile) => profile.id == _current)) {
        _current = _profiles.firstWhere((profile) => profile.admin).id;
      }
    } catch (_) {
      _profiles = [const LocalProfile(id: 'default', name: '管理员', admin: true)];
      _current = 'default';
    }
    _configurationError = null;
    try {
      _loadLibrary();
    } catch (_) {
      _history.clear();
      _favorites.clear();
      _followStates.clear();
      _seriesCandidates.clear();
    }
  }

  static List<LocalProfile> _readProfiles(dynamic records) {
    final profiles = (records as List)
        .map(
          (row) => LocalProfile.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
    if (profiles.isEmpty ||
        profiles.length > 20 ||
        profiles.map((profile) => profile.id).toSet().length !=
            profiles.length ||
        profiles.where((profile) => profile.admin).length != 1 ||
        (profiles.length > 1 &&
            !profiles.firstWhere((profile) => profile.admin).protected)) {
      throw const FormatException('用户配置无效');
    }
    return profiles;
  }

  void _block(String message) {
    _configurationError = message;
    _locked = true;
    _profiles = [
      const LocalProfile(id: 'default', name: '配置待恢复', download: false),
    ];
    _current = 'default';
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    _seriesCandidates.clear();
    _epoch++;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String? _string(String key) => _snapshot?.getString(key);
  bool? _bool(String key) => _snapshot?.getBool(key);
  String _key(String key, [String? id]) =>
      (id ?? _current) == 'default' ? key : 'profile.${id ?? _current}.$key';
  String? get configurationError => _configurationError;
  List<LocalProfile> get profiles => List.unmodifiable(_profiles);
  LocalProfile get profile =>
      _profiles.firstWhere((profile) => profile.id == _current);
  bool get locked => _locked || _configurationError != null;
  int get profileEpoch => _epoch;

  bool get canDownload => !locked && (profile.admin || profile.download);
  WatchStats get watchStats {
    if (locked) return const WatchStats();
    try {
      return WatchStats.fromJson(
        jsonDecode(_string(_key('watchStats')) ?? '{}'),
      );
    } catch (_) {
      return const WatchStats();
    }
  }

  bool allowsSource(String source) {
    if (locked) return false;
    if (!SourceSite.isAvailable(source)) return false;
    // 自定义源为设备级功能，管理员与普通用户均可使用。
    if (SourceSite.isCustomId(source)) return true;
    if (SourceSite.importedSites.containsKey(source)) return true;
    return profile.allows(source);
  }

  List<SourceSite> get sources {
    final builtIn = SourceSite.values.where((site) => allowsSource(site.id));
    final custom = _customSources
        .where((site) => allowsSource(site.id))
        .where((site) => !SourceSite.importedSites.containsKey(site.id))
        .map((site) => site.asSourceSite);
    final imported = SourceSite.importedSites.values.where(
      (site) => allowsSource(site.id),
    );
    return [...builtIn, ...custom, ...imported];
  }

  /// 当前用户被隐藏、不首页显示的站源 id 集合（含内置与自定义站源）。
  /// 从未在「源显示列表」里配置过时，落到内置默认隐藏集
  /// （默认可见：红果、韩小圈、鬼片、A123、爱看机器人），
  /// 用户配置过则以存档值为准。
  Set<String> get hiddenSites {
    if (locked) return const {};
    return _effectiveHiddenSites(_current);
  }

  Set<String> _effectiveHiddenSites(String profileId) {
    final raw = _string(_key('hiddenSites', profileId));
    if (raw == null) {
      // 从未在「源显示列表」里配置过（新用户）：落到内置默认隐藏集。
      return Set<String>.of(SourceSite.defaultHiddenSiteIds);
    }
    try {
      final stored = jsonDecode(raw);
      if (stored is List) {
        // 用户配置过（含手动设为全部可见的空列表）：以存档值为准。
        return stored.whereType<String>().toSet();
      }
    } catch (_) {}
    // 存档损坏：同样落到默认隐藏集，避免退化为全可见。
    return Set<String>.of(SourceSite.defaultHiddenSiteIds);
  }

  bool siteVisible(String source) => !hiddenSites.contains(source);

  /// 首页与各站源分组消费的可见站源列表。
  List<SourceSite> get visibleSources {
    final hidden = hiddenSites;
    return sources.where((site) => !hidden.contains(site.id)).toList();
  }

  Future<void> setSiteVisible(String source, bool visible) {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      if (!SourceSite.isKnown(source) && !ContentRegistry.isKnownId(source)) {
        throw StateError('未知站源');
      }
      final next = Set<String>.of(hiddenSites);
      if (visible) {
        next.remove(source);
      } else {
        next.add(source);
      }
      await _commit({_key('hiddenSites'): jsonEncode(next.toList())});
      _notify();
    });
  }

  Set<String> get expandedSourceGroups {
    if (locked) return const {};
    final raw = _string(_key('expandedSourceGroups'));
    if (raw == null) return const {};
    try {
      final stored = jsonDecode(raw);
      if (stored is! List) return const {};
      return stored.whereType<String>().toSet();
    } catch (_) {
      return const {};
    }
  }

  Future<void> setExpandedSourceGroups(Set<String> ids) {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      await _commit({_key('expandedSourceGroups'): jsonEncode(ids.toList())});
      _notify();
    });
  }

  Future<void> resetSiteVisibility() {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      await _commit({
        _key('hiddenSites'): jsonEncode(
          SourceSite.defaultHiddenSiteIds.toList(),
        ),
      });
      _notify();
    });
  }

  List<CustomSourceSite> get customSources => List.unmodifiable(_customSources);

  void _loadCustomSources() {
    try {
      _customSources = [
        for (final row in readJsonList(_string('customSources')))
          CustomSourceSite.fromJson(row),
      ];
    } catch (_) {
      _customSources = [];
    }
    _syncCustomIds();
  }

  void _syncCustomIds() {
    SourceSite.customIds
      ..clear()
      ..addAll(_customSources.map((site) => site.id));
  }

  /// 将设备端已保存的自定义源替换为最新结果并持久化。
  Future<void> syncCustomSources(List<CustomSourceSite> sources) async {
    final epoch = _epoch;
    await _queue(() async {
      if (locked || epoch != _epoch) return;
      final sorted = List<CustomSourceSite>.of(sources)
        ..sort((a, b) {
          final la = a.name.toLowerCase(), lb = b.name.toLowerCase();
          return la.compareTo(lb);
        });
      final serialized = jsonEncode(
        sorted.map((site) => site.toJson()).toList(),
      );
      if (serialized == _string('customSources')) {
        _customSources = sorted;
        _syncCustomIds();
        return;
      }
      await _commit({'customSources': serialized});
      _customSources = sorted;
      _syncCustomIds();
      _notify();
    });
  }

  Future<void> persistCustomSources(List<CustomSourceSite> sources) =>
      syncCustomSources(sources);

  List<ImportedSiteRecord> get importedSiteRecords =>
      List.unmodifiable(_importedSiteRecords);

  void _loadImportedSites() {
    try {
      _importedSiteRecords =
          [
                for (final row in readJsonList(_string('importedSites')))
                  ImportedSiteRecord.fromJson(row),
              ]
              .where((record) => record.id.isNotEmpty && record.type.isNotEmpty)
              .toList();
    } catch (_) {
      _importedSiteRecords = [];
    }
    _syncImportedRegistry();
  }

  void _syncImportedRegistry() {
    for (final id in _registeredImportIds) {
      SourceSite.importedSites.remove(id);
      SourceSite.importedPyFiles.remove(id);
      SourceSite.importedJsFiles.remove(id);
    }
    _registeredImportIds.clear();
    for (final record in _importedSiteRecords) {
      if (!record.enabled) continue;
      SourceSite.importedSites[record.id] = record.asSite;
      _registeredImportIds.add(record.id);
      if (record.type == ImportedSiteRecord.typePy) {
        SourceSite.importedPyFiles[record.id] = record.fileName;
      }
      if (record.type == ImportedSiteRecord.typeJs) {
        SourceSite.importedJsFiles[record.id] = record.fileName;
      }
    }
  }

  Future<void> syncImportedSites(List<ImportedSiteRecord> records) async {
    final epoch = _epoch;
    await _queue(() async {
      if (locked || epoch != _epoch) return;
      final serialized = jsonEncode(
        records.map((record) => record.toJson()).toList(),
      );
      if (serialized != _string('importedSites')) {
        await _commit({'importedSites': serialized});
      }
      _importedSiteRecords = List.of(records);
      _syncImportedRegistry();
      _notify();
    });
  }

  List<M3uSubscription> get m3uSubscriptions =>
      List.unmodifiable(_m3uSubscriptions);

  void _loadM3uSubscriptions() {
    try {
      _m3uSubscriptions = [
        for (final row in readJsonList(_string('m3uSubscriptions')))
          M3uSubscription.fromJson(row),
      ].where((sub) => sub.id.isNotEmpty).toList();
    } catch (_) {
      _m3uSubscriptions = [];
    }
    _syncM3uRegistry();
  }

  void _syncM3uRegistry() {
    for (final sourceId in _registeredM3uIds) {
      LiveSource.importedSources.remove(sourceId);
      importedLiveChannels.remove(sourceId);
    }
    _registeredM3uIds.clear();
    for (final sub in _m3uSubscriptions) {
      LiveSource.importedSources[sub.sourceId] = LiveSource(
        id: sub.sourceId,
        name: sub.name,
        description: 'm3u 导入 · ${sub.channelCount} 个频道',
        protocol: LiveProtocol.list,
        builtin: false,
      );
      importedLiveChannels[sub.sourceId] = sub.channels;
      _registeredM3uIds.add(sub.sourceId);
    }
  }

  Future<void> syncM3uSubscriptions(List<M3uSubscription> subscriptions) async {
    final epoch = _epoch;
    await _queue(() async {
      if (locked || epoch != _epoch) return;
      final serialized = jsonEncode(
        subscriptions.map((sub) => sub.toJson()).toList(),
      );
      if (serialized != _string('m3uSubscriptions')) {
        await _commit({'m3uSubscriptions': serialized});
      }
      _m3uSubscriptions = List.of(subscriptions);
      _syncM3uRegistry();
      _notify();
    });
  }

  void _loadLibrary() {
    _lanDocumentCache = null;
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    _seriesCandidates.clear();
    if (_configurationError != null) return;
    for (final row in readJsonList(_string(_key('history')))) {
      try {
        final entry = WatchEntry.fromJson(row);
        _history[entry.drama.id] = entry;
      } catch (_) {}
    }
    for (final row in readJsonList(_string(_key('favorites')))) {
      try {
        final drama = Drama.fromJson(row);
        _favorites[drama.id] = drama;
      } catch (_) {}
    }
    Map<String, dynamic> states = {};
    try {
      states = Map<String, dynamic>.from(
        jsonDecode(_string(_key('followStates')) ?? '{}') as Map,
      );
    } catch (_) {}
    for (final drama in _favorites.values) {
      try {
        _followStates[drama.id] = FollowState.fromJson(
          Map<String, dynamic>.from(states[drama.id] as Map),
        );
      } catch (_) {
        _followStates[drama.id] = FollowState.initial(
          drama,
          _history[drama.id],
        );
      }
    }
    for (final row in readJsonList(_string(_key('seriesCandidates')))) {
      try {
        final drama = Drama.fromJson(row);
        if (drama.source == SourceSite.hongguo.id) {
          _seriesCandidates[drama.id] = drama;
        }
      } catch (_) {}
    }
  }

  (String, String)? _libraryKeyProfile(String key) {
    if (key == 'history') return ('default', 'history');
    if (key == 'favorites') return ('default', 'favorites');
    final parts = key.split('.');
    if (parts.length == 3 &&
        parts[0] == 'profile' &&
        (parts[2] == 'history' || parts[2] == 'favorites')) {
      return (parts[1], parts[2]);
    }
    return null;
  }

  Future<void> _syncLibraryKeysToDb(
    Map<String, Object> changes,
    Iterable<String> remove,
  ) async {
    final db = AppDatabase.instance;
    final historyByProfile = <String, List<WatchEntry>>{};
    final favoritesByProfile = <String, List<Drama>>{};
    for (final key in changes.keys) {
      final parsed = _libraryKeyProfile(key);
      if (parsed == null) continue;
      final raw = changes[key];
      if (raw is! String) continue;
      if (parsed.$2 == 'history') {
        final entries = <WatchEntry>[];
        for (final row in readJsonList(raw)) {
          try {
            entries.add(WatchEntry.fromJson(row));
          } catch (_) {}
        }
        historyByProfile[parsed.$1] = entries;
      } else {
        final dramas = <Drama>[];
        for (final row in readJsonList(raw)) {
          try {
            dramas.add(Drama.fromJson(row));
          } catch (_) {}
        }
        favoritesByProfile[parsed.$1] = dramas;
      }
    }
    for (final key in remove) {
      if (changes.containsKey(key)) continue;
      final parsed = _libraryKeyProfile(key);
      if (parsed == null) continue;
      if (parsed.$2 == 'history') {
        historyByProfile[parsed.$1] = const [];
      } else {
        favoritesByProfile[parsed.$1] = const [];
      }
    }
    for (final entry in historyByProfile.entries) {
      await db.replaceHistory(entry.key, entry.value);
    }
    for (final entry in favoritesByProfile.entries) {
      await db.replaceFavorites(entry.key, entry.value);
    }
  }

  Future<void> _syncLibraryFromDbLocked() async {
    if (_configurationError != null) return;
    try {
      final db = AppDatabase.instance;
      if (await db.isSynced(_current)) {
        final history = await db.loadHistory(_current);
        final favorites = await db.loadFavorites(_current);
        _history.clear();
        for (final entry in history) {
          _history[entry.drama.id] = entry;
        }
        _favorites.clear();
        for (final drama in favorites) {
          _favorites[drama.id] = drama;
        }
        Map<String, dynamic> states = {};
        try {
          states = Map<String, dynamic>.from(
            jsonDecode(_string(_key('followStates')) ?? '{}') as Map,
          );
        } catch (_) {}
        _followStates.clear();
        for (final drama in _favorites.values) {
          try {
            _followStates[drama.id] = FollowState.fromJson(
              Map<String, dynamic>.from(states[drama.id] as Map),
            );
          } catch (_) {
            _followStates[drama.id] = FollowState.initial(
              drama,
              _history[drama.id],
            );
          }
        }
        _notify();
      } else {
        await db.replaceHistory(_current, _history.values);
        await db.replaceFavorites(_current, _favorites.values);
      }
    } catch (_) {}
  }

  Future<void> syncLibraryFromDb() => _queue(_syncLibraryFromDbLocked);

  List<WatchEntry> get history =>
      _history.values
          .where((entry) => allowsSource(entry.drama.source))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  List<Drama> get favorites => _favorites.values
      .where((drama) => allowsSource(drama.source))
      .toList()
      .reversed
      .toList();
  WatchEntry? watched(String id) {
    WatchEntry? entry = _history[id];
    if (entry == null && isFavorite(id)) {
      try {
        entry = lanDocument.records[id]?.watch;
      } catch (_) {}
    }
    return entry != null && allowsSource(entry.drama.source) ? entry : null;
  }

  bool isFavorite(String id) =>
      _favorites[id] != null && allowsSource(_favorites[id]!.source);
  FollowState? following(String id) =>
      isFavorite(id) ? _followStates[id] : null;
  List<Drama> seriesDramasFor(Drama anchor) {
    if (!allowsSource(SourceSite.hongguo.id) ||
        anchor.source != SourceSite.hongguo.id) {
      return const [];
    }
    final items = <String, Drama>{};
    for (final drama in _seriesCandidates.values) {
      if (allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final drama in _favorites.values) {
      if (allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final entry in _history.values) {
      if (allowsSource(entry.drama.source)) items[entry.drama.id] = entry.drama;
    }
    final notices = <SeriesSeasonNotice>[
      ...?_followStates[anchor.id]?.seriesSeasons.values,
      for (final state in _followStates.values)
        if (state.seriesSeasons.containsKey(anchor.id))
          state.seriesSeasons[anchor.id]!,
    ];
    for (final notice in notices) {
      items.putIfAbsent(
        notice.id,
        () => Drama(
          id: notice.id,
          source: SourceSite.hongguo.id,
          sourceId: notice.id.substring(SourceSite.hongguo.id.length + 1),
          title: notice.title,
        ),
      );
    }
    final current = items.remove(anchor.id) ?? anchor;
    final rest = items.values.toList()
      ..sort((a, b) => naturalTitleCompare(a.title, b.title));
    return [current, ...rest];
  }

  bool get hideVip =>
      _configurationError == null ? _bool(_key('hideVip')) ?? true : true;
  String get displayMode {
    final value = _configurationError == null ? _string('displayMode') : null;
    return {'auto', 'television', 'standard'}.contains(value) ? value! : 'auto';
  }

  String get themeMode {
    final value = _configurationError == null ? _string('themeMode') : null;
    return {'light', 'dark', 'system'}.contains(value) ? value! : 'system';
  }

  String get source {
    if (locked) return '';
    final visible = visibleSources;
    final value = _string(_key('source')) ?? '';
    // 首页默认站源只在可见站源中选择；站源被隐藏后自动落到下一个可见源。
    return visible.any((site) => site.id == value)
        ? value
        : visible.firstOrNull?.id ?? sources.firstOrNull?.id ?? '';
  }

  DownloadPreferences get downloadPreferences {
    if (locked) return const DownloadPreferences();
    try {
      return DownloadPreferences.fromJson(
        jsonDecode(_string(_key('downloadPreferences')) ?? '{}')
            as Map<String, dynamic>,
      );
    } catch (_) {
      return const DownloadPreferences();
    }
  }

  PlaybackPreferences get playbackPreferences {
    if (locked) return const PlaybackPreferences();
    try {
      return PlaybackPreferences.fromJson(
        jsonDecode(_string(_key('playback')) ?? '{}') as Map<String, dynamic>,
      );
    } catch (_) {
      return const PlaybackPreferences();
    }
  }

  CatalogView get catalogView {
    if (locked) return const CatalogView();
    try {
      return CatalogView.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(_string(_key('catalogView')) ?? '{}') as Map,
        ),
      );
    } catch (_) {
      return const CatalogView();
    }
  }

  List<String> get recentSearches {
    if (locked) return const [];
    try {
      return (jsonDecode(_string(_key('recentSearches')) ?? '[]') as List)
          .whereType<String>()
          .take(20)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setCatalogView(CatalogView value) =>
      _setting(_key('catalogView'), jsonEncode(value.toJson()));

  Future<void> setCatalogSource(String source, {required bool allSources}) {
    final epoch = _epoch;
    return _queue(() async {
      if (!allowsSource(source) || epoch != _epoch) {
        throw StateError('当前用户没有此站源权限');
      }
      await _commit({
        _key('source'): source,
        _key('catalogView'): jsonEncode(
          catalogView.copyWith(allSources: allSources).toJson(),
        ),
      });
      _notify();
    });
  }

  /// 视频区按区记忆的上次站点：'__all__' 表示全部站源模式，其余为站源 id。
  static const zoneSourceAll = '__all__';

  Map<String, String> _zoneSources() {
    try {
      final raw = _string(_key('zoneSources'));
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  /// 读某视频区（drama/vod/midnight）上次选中的站，'' 表示没记过。
  /// 只读不回落；回落由调用方按当前区可见源做（站不存在或被门禁藏起时落默认站）。
  String zoneSource(String zone) {
    if (locked) return '';
    return _zoneSources()[zone] ?? '';
  }

  /// 切换视频区站点时立即记盘。尽力而为：写盘失败不抛错、不影响切站本身。
  Future<void> setZoneSource(String zone, String source) {
    final epoch = _epoch;
    return _queue(() async {
      try {
        if (locked || epoch != _epoch) return;
        final values = _zoneSources();
        values[zone] = source;
        await _commit({_key('zoneSources'): jsonEncode(values)});
        _notify();
      } catch (_) {}
    });
  }

  Future<void> rememberSearch(String text) {
    final query = text.trim();
    if (query.isEmpty || query.runes.length > 80) return Future.value();
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      final entries = [
        query,
        ...recentSearches.where(
          (entry) => normalizedSearchText(entry) != normalizedSearchText(query),
        ),
      ].take(20).toList();
      await _commit({_key('recentSearches'): jsonEncode(entries)});
      _notify();
    });
  }

  Future<void> clearRecentSearches() => _setting(_key('recentSearches'), '[]');

  Future<void> _commit(
    Map<String, Object> changes, {
    Iterable<String> remove = const [],
    bool replace = false,
    bool trackSync = true,
    bool syncUrgent = true,
    Set<String> clearSyncProgress = const {},
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null) throw StateError('请先恢复本地配置');
    final values = replace ? <String, Object>{} : snapshot.values;
    for (final key in remove) {
      values.remove(key);
    }
    values.addAll(changes);
    if (trackSync && !replace) {
      _trackLanChanges(
        values,
        keys: {...changes.keys, ...remove},
        clearProgress: clearSyncProgress,
      );
    }
    values.putIfAbsent(
      'profiles',
      () => jsonEncode(_profiles.map((profile) => profile.toJson()).toList()),
    );
    values.putIfAbsent('activeProfile', () => _current);
    try {
      await snapshot.commit(values);
      if (trackSync &&
          !replace &&
          {...changes.keys, ...remove}.any(
            (key) =>
                key == _key('favorites') ||
                key == _key('history') ||
                key == _key('followStates'),
          )) {
        _lanRevision++;
        if (syncUrgent) _lanUrgentRevision++;
      }
      try {
        await _syncLibraryKeysToDb(changes, remove);
      } catch (_) {}
    } on SnapshotRecoveryRequired catch (error) {
      _block(error.toString());
      _notify();
      rethrow;
    }
  }

  Future<void> _setting(String key, Object value, {bool admin = false}) {
    final epoch = _epoch;
    return _queue(() async {
      if (admin) _requireAdmin();
      if (locked || epoch != _epoch) throw StateError('当前用户已变更，请重试');
      await _commit({key: value});
      _notify();
    });
  }

  Future<void> setHideVip(bool value) => _setting(_key('hideVip'), value);

  bool get pythonCfDisguise => _configurationError == null
      ? _bool(_key('pythonCfDisguise')) ?? true
      : true;

  Future<void> setPythonCfDisguise(bool value) =>
      _setting(_key('pythonCfDisguise'), value);

  bool get jarFingerprintEnabled => _configurationError == null
      ? _bool(_key('jarFingerprintEnabled')) ?? true
      : true;

  Future<void> setJarFingerprintEnabled(bool value) =>
      _setting(_key('jarFingerprintEnabled'), value);

  DateTime? get siteCheckLastRun {
    final raw = _string('site_check_last_run');
    final millis = raw == null ? null : int.tryParse(raw);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setSiteCheckLastRun(DateTime value) =>
      _setting('site_check_last_run', value.millisecondsSinceEpoch.toString());

  bool get customHeadersEnabled => _configurationError == null
      ? _bool(_key('customHeadersEnabled')) ?? false
      : false;

  Future<void> setCustomHeadersEnabled(bool value) =>
      _setting(_key('customHeadersEnabled'), value);

  List<CustomHeaderRule> get customHeaderRules {
    if (_configurationError != null) return const [];
    return parseCustomHeaderRules(_string(_key('customHeaderRules')) ?? '[]');
  }

  Future<void> setCustomHeaderRules(List<CustomHeaderRule> rules) => _setting(
    _key('customHeaderRules'),
    jsonEncode(rules.map((rule) => rule.toJson()).toList()),
  );
  Future<void> setSource(String value) {
    if (!allowsSource(value)) return Future.error(StateError('当前用户没有此站源权限'));
    return _setting(_key('source'), value);
  }

  Future<void> setDisplayMode(String value) =>
      {'auto', 'television', 'standard'}.contains(value)
      ? _setting('displayMode', value)
      : Future.value();
  String get player {
    final value = _string('player') ?? 'guo';
    return {'guo', 'xigua'}.contains(value) ? value : 'guo';
  }

  Future<void> setPlayer(String value) =>
      {'guo', 'xigua'}.contains(value)
      ? _setting('player', value)
      : Future.value();
  Future<void> setThemeMode(String value) =>
      {'light', 'dark', 'system'}.contains(value)
      ? _setting('themeMode', value)
      : Future.value();

  String get themeModeStyle {
    final value = _configurationError == null
        ? _string('themeModeStyle')
        : null;
    return {'pureLight', 'pureDark'}.contains(value) ? value! : '';
  }

  Future<void> setThemeModeStyle(String value) =>
      {'pureLight', 'pureDark', ''}.contains(value)
      ? _setting('themeModeStyle', value)
      : Future.value();

  String get themeStyle {
    final value = _configurationError == null ? _string('themeStyle') : null;
    return {'neon', 'deep', 'candy', 'paper', 'glass', 'aurora'}.contains(value)
        ? value!
        : '';
  }

  Future<void> setThemeStyle(String value) =>
      {'neon', 'deep', 'candy', 'paper', 'glass', 'aurora', ''}.contains(value)
      ? _setting('themeStyle', value)
      : Future.value();

  String get themeAccent {
    final value = _configurationError == null ? _string('themeAccent') : null;
    if (value != null && _isCustomThemeAccentId(value)) return value;
    return {
          'default',
          'green',
          'blue',
          'purple',
          'red',
          'orange',
          'jiucai',
          'matcha',
          'luhui',
          'qingci',
          'boheqing',
          'chunrilv',
          'qingkonglan',
          'shenhailan',
          'shilan',
          'qunqing',
          'yuanwei',
          'xunyicao',
          'meizizi',
          'putaozi',
          'xiangyuzi',
          'shanhuhong',
          'meiguifen',
          'zhuanhong',
        }.contains(value)
        ? value!
        : '';
  }

  static bool _isCustomThemeAccentId(String id) {
    if (!id.startsWith('custom:')) return false;
    final hex = id.substring('custom:'.length);
    return hex.length == 6 && int.tryParse(hex, radix: 16) != null;
  }

  Future<void> setThemeAccent(String value) =>
      {
        'default',
        'green',
        'blue',
        'purple',
        'red',
        'orange',
        'jiucai',
        'matcha',
        'luhui',
        'qingci',
        'boheqing',
        'chunrilv',
        'qingkonglan',
        'shenhailan',
        'shilan',
        'qunqing',
        'yuanwei',
        'xunyicao',
        'meizizi',
        'putaozi',
        'xiangyuzi',
        'shanhuhong',
        'meiguifen',
        'zhuanhong',
        '',
      }.contains(value) || _isCustomThemeAccentId(value)
      ? _setting('themeAccent', value)
      : Future.value();

  String get themeBackground {
    final value = _configurationError == null
        ? _string('themeBackground')
        : null;
    return {'theme', 'solid', 'gradient', 'custom'}.contains(value)
        ? value!
        : 'theme';
  }

  Future<void> setThemeBackground(String value) =>
      {'theme', 'solid', 'gradient', 'custom'}.contains(value)
      ? _setting('themeBackground', value)
      : Future.value();

  String get themeBackgroundImage {
    final value = _configurationError == null
        ? _string('themeBackgroundImage')
        : null;
    return value ?? '';
  }

  Future<void> setThemeBackgroundImage(String value) =>
      _setting('themeBackgroundImage', value);

  Future<void> resetThemeSettings() async {
    await setThemeModeStyle('');
    await setThemeStyle('');
    await setThemeAccent('');
    await setThemeBackground('theme');
    await setThemeBackgroundImage('');
  }

  Future<void> setPlaybackPreferences(PlaybackPreferences value) {
    PlaybackPreferences.fromJson(value.toJson());
    return _setting(_key('playback'), jsonEncode(value.toJson()));
  }

  Future<void> setDownloadPreferences(DownloadPreferences value) {
    DownloadPreferences.fromJson(value.toJson());
    return _setting(_key('downloadPreferences'), jsonEncode(value.toJson()));
  }

  Future<void> toggleFavorite(Drama drama) {
    final epoch = _epoch;
    return _queue(() async {
      if (!allowsSource(drama.source) || epoch != _epoch) return;
      final entries = Map.of(_favorites);
      final states = Map.of(_followStates);
      if (entries.containsKey(drama.id)) {
        entries.remove(drama.id);
        states.remove(drama.id);
      } else {
        if (entries.length >= 20000) throw StateError('追剧数量已达上限，请先整理追剧');
        entries[drama.id] = drama;
        states[drama.id] = FollowState.initial(drama, _history[drama.id]);
      }
      await _commit({
        _key('favorites'): jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        _key('followStates'): _encodeFollowStates(states),
      });
      _loadLibrary();
      _notify();
    });
  }

  String _encodeFollowStates(Map<String, FollowState> states) => jsonEncode({
    for (final entry in states.entries) entry.key: entry.value.toJson(),
  });

  Future<void> setFollowStatus(Drama drama, FollowStatus status) {
    final epoch = _epoch;
    return _queue(() async {
      if (!allowsSource(drama.source) || epoch != _epoch) return;
      if (!_favorites.containsKey(drama.id) && _favorites.length >= 20000) {
        throw StateError('追剧数量已达上限，请先整理追剧');
      }
      final current = _favorites[drama.id]?.merge(drama) ?? drama;
      final entries = Map.of(_favorites)..[drama.id] = current;
      final state =
          (_followStates[drama.id] ??
                  FollowState.initial(current, _history[drama.id]))
              .observe(current)
              .withStatus(status);
      final states = Map.of(_followStates)..[drama.id] = state;
      await _commit({
        _key('favorites'): jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        _key('followStates'): _encodeFollowStates(states),
      });
      _loadLibrary();
      _notify();
    });
  }

  Future<void> markUpdatesRead(String id) {
    final epoch = _epoch;
    return _queue(() async {
      if (!isFavorite(id) || epoch != _epoch) return;
      final states = Map.of(_followStates)
        ..[id] = _followStates[id]!.markRead();
      await _commit({_key('followStates'): _encodeFollowStates(states)});
      _loadLibrary();
      _notify();
    });
  }

  Future<void> markSeriesSeasonRead(String id, String seasonId) {
    final epoch = _epoch;
    return _queue(() async {
      if (!isFavorite(id) || epoch != _epoch) return;
      final current = _followStates[id]!;
      final updated = current.markSeriesSeasonRead(seasonId);
      if (identical(current, updated)) return;
      final states = Map.of(_followStates)..[id] = updated;
      await _commit({_key('followStates'): _encodeFollowStates(states)});
      _loadLibrary();
      _notify();
    });
  }

  Future<void> saveWatch(
    WatchEntry entry, {
    double watchSeconds = 0,
    int completedEpisodes = 0,
  }) {
    final epoch = _epoch;
    return _queue(() async {
      if (!allowsSource(entry.drama.source) || epoch != _epoch) return;
      final stats = watchStats.addSample(
        source: entry.drama.source,
        seconds: watchSeconds,
        episodes: completedEpisodes,
      );
      final previous = _history[entry.drama.id]?.drama;
      final current = previous == null
          ? entry
          : WatchEntry(
              drama: previous.merge(entry.drama),
              episode: entry.episode,
              position: entry.position,
              duration: entry.duration,
              updatedAt: entry.updatedAt,
            );
      final entries = Map.of(_history)..[entry.drama.id] = current;
      final sorted = entries.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final following = _followStates[entry.drama.id];
      final states = Map.of(_followStates);
      final favorites = Map.of(_favorites);
      if (following != null) {
        states[entry.drama.id] = following.afterPlayback(current);
        favorites[entry.drama.id] = favorites[entry.drama.id]!.merge(
          current.drama,
        );
      }
      await _commit({
        _key('history'): jsonEncode(
          sorted.take(300).map((entry) => entry.toJson()).toList(),
        ),
        _key('watchStats'): jsonEncode(stats.toJson()),
        if (following != null) ...{
          _key('followStates'): _encodeFollowStates(states),
          _key('favorites'): jsonEncode(
            favorites.values.map((entry) => entry.toJson()).toList(),
          ),
        },
      }, syncUrgent: false);
      _loadLibrary();
      _notify();
    });
  }

  WatchEntry? mediaWatched(String id) {
    if (!canDownload) return null;
    try {
      final data = jsonDecode(_string(_key('mediaHistory')) ?? '{}') as Map;
      final entry = data[id] == null
          ? null
          : WatchEntry.fromJson(Map<String, dynamic>.from(data[id] as Map));
      return entry != null && allowsSource(entry.drama.source) ? entry : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMediaWatch(
    String id,
    WatchEntry entry, {
    double watchSeconds = 0,
    int completedEpisodes = 0,
  }) {
    final epoch = _epoch;
    return _queue(() async {
      if (!canDownload ||
          !allowsSource(entry.drama.source) ||
          epoch != _epoch) {
        return;
      }
      final data = jsonDecode(_string(_key('mediaHistory')) ?? '{}') as Map;
      data.remove(id);
      data[id] = entry.toJson();
      while (data.length > 300) {
        data.remove(data.keys.first);
      }
      final stats = watchStats.addSample(
        source: entry.drama.source,
        seconds: watchSeconds,
        episodes: completedEpisodes,
      );
      await _commit({
        _key('mediaHistory'): jsonEncode(data),
        _key('watchStats'): jsonEncode(stats.toJson()),
      });
    });
  }

  Future<void> clearHistory() {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      await _commit(
        {},
        remove: [_key('history')],
        clearSyncProgress: {..._history.keys, ...lanDocument.records.keys},
      );
      _loadLibrary();
      _notify();
    });
  }

  Future<void> removeHistory(String id) {
    final epoch = _epoch;
    return _queue(() async {
      if (watched(id) == null || epoch != _epoch) return;
      final entries = Map.of(_history)..remove(id);
      await _commit(
        {
          _key('history'): jsonEncode(
            entries.values.map((entry) => entry.toJson()).toList(),
          ),
        },
        clearSyncProgress: {id},
      );
      _loadLibrary();
      _notify();
    });
  }

  Future<void> refreshDrama(Drama drama) =>
      _refreshDramas([drama], cacheSeriesCandidates: false);

  Future<void> refreshDramas(Iterable<Drama> dramas) =>
      _refreshDramas(dramas, cacheSeriesCandidates: true);

  Future<void> _refreshDramas(
    Iterable<Drama> dramas, {
    required bool cacheSeriesCandidates,
  }) {
    final epoch = _epoch;
    final updates = dramas.toList();
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      final changes = <String, Object>{};
      final favorites = Map.of(_favorites);
      final history = Map.of(_history);
      final states = Map.of(_followStates);
      final seriesCandidates = Map.of(_seriesCandidates);
      for (final drama in updates) {
        if (!allowsSource(drama.source)) continue;
        if (cacheSeriesCandidates && drama.source == SourceSite.hongguo.id) {
          seriesCandidates[drama.id] = (seriesCandidates[drama.id] ?? drama)
              .merge(drama);
        }
        final favorite = favorites[drama.id];
        if (favorite != null) {
          favorites[drama.id] = favorite.merge(drama);
          states[drama.id] = states[drama.id]!.observe(favorites[drama.id]!);
        }
        final watched = history[drama.id];
        if (watched != null) {
          history[drama.id] = WatchEntry(
            drama: watched.drama.merge(drama),
            episode: watched.episode,
            position: watched.position,
            duration: watched.duration,
            updatedAt: watched.updatedAt,
          );
        }
      }
      final candidates = <String, Drama>{
        for (final entry in history.values) entry.drama.id: entry.drama,
        ...favorites,
        for (final drama in updates)
          if (allowsSource(drama.source)) drama.id: drama,
      };
      for (final state in states.values) {
        for (final notice in state.seriesSeasons.values) {
          candidates.putIfAbsent(
            notice.id,
            () => Drama(
              id: notice.id,
              source: SourceSite.hongguo.id,
              sourceId: notice.id.substring(SourceSite.hongguo.id.length + 1),
              title: notice.title,
            ),
          );
        }
      }
      final favoriteIds = favorites.keys.toSet();
      for (final favorite in favorites.values) {
        if (favorite.source != SourceSite.hongguo.id ||
            states[favorite.id] == null) {
          continue;
        }
        states[favorite.id] = observeHongguoSeriesSeasons(
          anchor: favorite,
          state: states[favorite.id]!,
          candidates: candidates.values,
          favoriteIds: favoriteIds,
        );
      }
      final favoriteJson = jsonEncode(
        favorites.values.map((entry) => entry.toJson()).toList(),
      );
      final historyJson = jsonEncode(
        history.values.map((entry) => entry.toJson()).toList(),
      );
      final statesJson = _encodeFollowStates(states);
      final seriesCandidateJson = cacheSeriesCandidates
          ? jsonEncode(
              (seriesCandidates.values.toList()
                    ..sort((a, b) => a.id.compareTo(b.id)))
                  .take(2000)
                  .map((entry) => entry.toJson())
                  .toList(),
            )
          : null;
      if (favoriteJson !=
          jsonEncode(
            _favorites.values.map((entry) => entry.toJson()).toList(),
          )) {
        changes[_key('favorites')] = favoriteJson;
      }
      if (historyJson !=
          jsonEncode(_history.values.map((entry) => entry.toJson()).toList())) {
        changes[_key('history')] = historyJson;
      }
      if (statesJson != _encodeFollowStates(_followStates)) {
        changes[_key('followStates')] = statesJson;
      }
      if (seriesCandidateJson != null &&
          seriesCandidateJson !=
              jsonEncode(
                (_seriesCandidates.values.toList()
                      ..sort((a, b) => a.id.compareTo(b.id)))
                    .take(2000)
                    .map((entry) => entry.toJson())
                    .toList(),
              )) {
        changes[_key('seriesCandidates')] = seriesCandidateJson;
      }
      if (changes.isEmpty) return;
      await _commit(changes);
      _loadLibrary();
      _notify();
    });
  }

  void _requireAdmin() {
    if (locked || !profile.admin) throw StateError('仅管理员可以修改此设置');
  }

  Future<void> _checkPin(LocalProfile target, String pin) async {
    if (DateTime.now().isBefore(_retryAfter)) {
      throw StateError('密码输入过于频繁，请稍后再试');
    }
    if (!await checkProfilePin(target, pin)) {
      _failures++;
      if (_failures >= 3) {
        _retryAfter = DateTime.now().add(
          Duration(seconds: (_failures * 2).clamp(0, 30)),
        );
      }
      throw StateError('密码不正确');
    }
    _failures = 0;
  }

  Future<void> switchProfile(String id, {String pin = ''}) => _queue(() async {
    if (_configurationError != null) throw StateError('本地用户配置损坏，请先恢复');
    final target = _profiles.firstWhere((profile) => profile.id == id);
    await _checkPin(target, pin);
    await _commit({'activeProfile': id});
    _current = id;
    _locked = false;
    _loadLibrary();
    await _syncLibraryFromDbLocked();
    _epoch++;
    _notify();
  });

  Future<void> saveProfile({
    String? id,
    required String name,
    required List<String> sources,
    required bool download,
    String? pin,
  }) => _queue(() async {
    _requireAdmin();
    final old = _profiles.where((profile) => profile.id == id).firstOrNull;
    final targetId = old?.id ?? randomProfileToken();
    final cleanName = name.trim();
    if (cleanName.isEmpty || cleanName.length > 40) {
      throw StateError('用户名需要 1 至 40 个字符');
    }
    if (sources.any((source) => !SourceSite.isKnown(source))) {
      throw StateError('站源无效');
    }
    if (targetId != 'default' &&
        !_profiles.firstWhere((profile) => profile.admin).protected) {
      throw StateError('请先为管理员设置密码，再创建或修改其他用户');
    }
    if (old == null && _profiles.length >= 20) {
      throw StateError('最多支持 20 个本地用户');
    }
    var salt = old?.salt ?? '', hash = old?.pinHash ?? '';
    if (pin != null) {
      if (pin.isEmpty) {
        if (targetId == 'default' && _profiles.length > 1) {
          throw StateError('存在其他用户时不能取消管理员密码');
        }
        salt = '';
        hash = '';
      } else {
        if (pin.length < 6 || pin.length > 128) {
          throw StateError('密码需要 6 至 128 个字符');
        }
        salt = randomProfileToken();
        hash = await hashProfilePin(pin, salt);
      }
    }
    _requireAdmin();
    final updated = LocalProfile(
      id: targetId,
      name: cleanName,
      admin: targetId == 'default',
      sources: sources.toSet().toList(),
      download: download,
      salt: salt,
      pinHash: hash,
    );
    final profiles =
        [
          for (final profile in _profiles)
            if (profile.id != targetId) profile,
          updated,
        ]..sort(
          (a, b) => a.admin
              ? -1
              : b.admin
              ? 1
              : a.name.compareTo(b.name),
        );
    await _commit({
      'profiles': jsonEncode(
        profiles.map((profile) => profile.toJson()).toList(),
      ),
    });
    _profiles = profiles;
    _notify();
  });
  Future<void> deleteProfile(String id) => _queue(() async {
    _requireAdmin();
    if (id == 'default') throw StateError('不能删除管理员');
    final profiles = _profiles.where((profile) => profile.id != id).toList();
    await _commit({
      'profiles': jsonEncode(
        profiles.map((profile) => profile.toJson()).toList(),
      ),
    }, remove: LocalSnapshot.libraryKeys.map((key) => _key(key, id)));
    _profiles = profiles;
    _notify();
  });

  Future<void> reload() => _queue(() async {
    final previousProfiles = _configurationError == null
        ? _string('profiles')
        : null;
    final previousId = _current;
    final previousLocked = locked;
    await preferences.reload();
    _initialize();
    if (_configurationError == null &&
        previousProfiles == _string('profiles') &&
        previousId == _current) {
      _locked = previousLocked;
    } else {
      _epoch++;
    }
    _notify();
  });

  Future<void> _queue(Future<void> Function() action) {
    _writes = _writes.catchError((Object _) {}).then((_) => action());
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
