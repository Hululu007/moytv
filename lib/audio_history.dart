import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'midnight_zone.dart';

const _audioResumeKey = 'audioResume';
const _audioHistoryKey = 'audioHistory';
const _audioFavoritesKey = 'audioFavorites';
const _audioHistoryLimit = 50;

String audioRecordKey(String sourceId, String bookId) => '$sourceId::$bookId';

class AudioListenRecord {
  const AudioListenRecord({
    required this.sourceId,
    required this.sourceName,
    required this.bookId,
    required this.title,
    this.cover = '',
    this.author = '',
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.positionMs = 0,
    this.durationMs = 0,
    this.updatedAtMs = 0,
  });

  final String sourceId;
  final String sourceName;
  final String bookId;
  final String title;
  final String cover;
  final String author;
  final int chapterIndex;
  final String chapterTitle;
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  bool get started => chapterIndex > 0 || positionMs > 0;

  factory AudioListenRecord.fromJson(Map<String, dynamic> json) {
    return AudioListenRecord(
      sourceId: json['sourceId'] as String? ?? '',
      sourceName: json['sourceName'] as String? ?? '',
      bookId: json['bookId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      author: json['author'] as String? ?? '',
      chapterIndex: json['chapterIndex'] as int? ?? 0,
      chapterTitle: json['chapterTitle'] as String? ?? '',
      positionMs: json['positionMs'] as int? ?? 0,
      durationMs: json['durationMs'] as int? ?? 0,
      updatedAtMs: json['updatedAtMs'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'bookId': bookId,
    'title': title,
    'cover': cover,
    'author': author,
    'chapterIndex': chapterIndex,
    'chapterTitle': chapterTitle,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAtMs': updatedAtMs,
  };

  AudioListenRecord copyWith({
    int? chapterIndex,
    String? chapterTitle,
    int? positionMs,
    int? durationMs,
    int? updatedAtMs,
  }) {
    return AudioListenRecord(
      sourceId: sourceId,
      sourceName: sourceName,
      bookId: bookId,
      title: title,
      cover: cover,
      author: author,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }
}

class AudioFavoriteEntry {
  const AudioFavoriteEntry({
    required this.sourceId,
    required this.sourceName,
    required this.bookId,
    required this.title,
    this.cover = '',
    this.author = '',
    this.updatedAtMs = 0,
  });

  final String sourceId;
  final String sourceName;
  final String bookId;
  final String title;
  final String cover;
  final String author;
  final int updatedAtMs;

  factory AudioFavoriteEntry.fromJson(Map<String, dynamic> json) {
    return AudioFavoriteEntry(
      sourceId: json['sourceId'] as String? ?? '',
      sourceName: json['sourceName'] as String? ?? '',
      bookId: json['bookId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      author: json['author'] as String? ?? '',
      updatedAtMs: json['updatedAtMs'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'bookId': bookId,
    'title': title,
    'cover': cover,
    'author': author,
    'updatedAtMs': updatedAtMs,
  };
}

Future<Map<String, AudioListenRecord>> loadAudioResumes() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_audioResumeKey);
  if (raw == null || raw.isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return {};
  return {
    for (final item in decoded.entries)
      if (item.value is Map<String, dynamic>)
        item.key: AudioListenRecord.fromJson(item.value),
  };
}

Future<AudioListenRecord?> loadAudioResume(
  String sourceId,
  String bookId,
) async {
  final resumes = await loadAudioResumes();
  return resumes[audioRecordKey(sourceId, bookId)];
}

Future<void> saveAudioResume(AudioListenRecord record) async {
  final resumes = await loadAudioResumes();
  resumes[audioRecordKey(record.sourceId, record.bookId)] = record;
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _audioResumeKey,
    jsonEncode({
      for (final item in resumes.entries) item.key: item.value.toJson(),
    }),
  );
}

Future<List<AudioListenRecord>> loadAudioHistory() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_audioHistoryKey);
  if (raw == null || raw.isEmpty) return [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return [];
  return [
    for (final item in decoded)
      if (item is Map<String, dynamic>) AudioListenRecord.fromJson(item),
  ];
}

Future<void> saveAudioHistory(List<AudioListenRecord> entries) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _audioHistoryKey,
    jsonEncode([for (final entry in entries) entry.toJson()]),
  );
}

Future<void> recordAudioHistory(AudioListenRecord record) async {
  final entries = await loadAudioHistory();
  entries.removeWhere(
    (item) => item.sourceId == record.sourceId && item.bookId == record.bookId,
  );
  entries.insert(0, record);
  if (entries.length > _audioHistoryLimit) {
    entries.removeRange(_audioHistoryLimit, entries.length);
  }
  await saveAudioHistory(entries);
}

Future<void> removeAudioHistory(String sourceId, String bookId) async {
  final entries = await loadAudioHistory();
  entries.removeWhere(
    (item) => item.sourceId == sourceId && item.bookId == bookId,
  );
  await saveAudioHistory(entries);
}

Future<List<AudioFavoriteEntry>> loadAudioFavorites() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_audioFavoritesKey);
  if (raw == null || raw.isEmpty) return [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return [];
  return [
    for (final item in decoded)
      if (item is Map<String, dynamic>) AudioFavoriteEntry.fromJson(item),
  ];
}

Future<void> saveAudioFavorites(List<AudioFavoriteEntry> entries) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _audioFavoritesKey,
    jsonEncode([for (final entry in entries) entry.toJson()]),
  );
}

Future<bool> isAudioFavorite(String sourceId, String bookId) async {
  final entries = await loadAudioFavorites();
  return entries.any(
    (entry) => entry.sourceId == sourceId && entry.bookId == bookId,
  );
}

Future<void> addAudioFavorite(AudioFavoriteEntry entry) async {
  final entries = await loadAudioFavorites();
  entries.removeWhere(
    (item) => item.sourceId == entry.sourceId && item.bookId == entry.bookId,
  );
  entries.insert(0, entry);
  await saveAudioFavorites(entries);
}

Future<void> removeAudioFavorite(String sourceId, String bookId) async {
  final entries = await loadAudioFavorites();
  entries.removeWhere(
    (item) => item.sourceId == sourceId && item.bookId == bookId,
  );
  await saveAudioFavorites(entries);
}

List<AudioListenRecord> visibleAudioRecords(
  List<AudioListenRecord> entries,
  bool midnightActivated,
) {
  if (midnightActivated) return entries;
  return [
    for (final entry in entries)
      if (!isAdultSourceName(entry.sourceName)) entry,
  ];
}

List<AudioFavoriteEntry> visibleAudioFavorites(
  List<AudioFavoriteEntry> entries,
  bool midnightActivated,
) {
  if (midnightActivated) return entries;
  return [
    for (final entry in entries)
      if (!isAdultSourceName(entry.sourceName)) entry,
  ];
}
