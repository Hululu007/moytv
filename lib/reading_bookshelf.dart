import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const _shelfKey = 'readingBookshelf';
const _bookmarkKey = 'readingBookmarks';
const _historyKey = 'readingHistory';
const _readingHistoryLimit = 50;

String readingBookmarkKey(String sourceId, String bookId) =>
    '$sourceId::$bookId';

class ReadingShelfEntry {
  const ReadingShelfEntry({
    required this.sourceId,
    required this.sourceName,
    required this.bookId,
    required this.title,
    this.cover = '',
    this.author = '',
    this.lastChapterIndex = 0,
    this.lastChapterTitle = '',
    this.chapterTotal = 0,
    this.updatedAtMs = 0,
  });

  final String sourceId;
  final String sourceName;
  final String bookId;
  final String title;
  final String cover;
  final String author;
  final int lastChapterIndex;
  final String lastChapterTitle;
  final int chapterTotal;
  final int updatedAtMs;

  bool get started =>
      lastChapterIndex > 0 || lastChapterTitle.isNotEmpty;

  factory ReadingShelfEntry.fromJson(Map<String, dynamic> json) {
    return ReadingShelfEntry(
      sourceId: json['sourceId'] as String? ?? '',
      sourceName: json['sourceName'] as String? ?? '',
      bookId: json['bookId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      author: json['author'] as String? ?? '',
      lastChapterIndex: json['lastChapterIndex'] as int? ?? 0,
      lastChapterTitle: json['lastChapterTitle'] as String? ?? '',
      chapterTotal: json['chapterTotal'] as int? ?? 0,
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
    'lastChapterIndex': lastChapterIndex,
    'lastChapterTitle': lastChapterTitle,
    'chapterTotal': chapterTotal,
    'updatedAtMs': updatedAtMs,
  };
}

class ReadingBookmark {
  const ReadingBookmark({
    required this.chapterIndex,
    required this.pageIndex,
    this.chapterTitle = '',
    this.chapterTotal = 0,
    this.updatedAtMs = 0,
  });

  final int chapterIndex;
  final int pageIndex;
  final String chapterTitle;
  final int chapterTotal;
  final int updatedAtMs;

  factory ReadingBookmark.fromJson(Map<String, dynamic> json) {
    return ReadingBookmark(
      chapterIndex: json['chapterIndex'] as int? ?? 0,
      pageIndex: json['pageIndex'] as int? ?? 0,
      chapterTitle: json['chapterTitle'] as String? ?? '',
      chapterTotal: json['chapterTotal'] as int? ?? 0,
      updatedAtMs: json['updatedAtMs'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'chapterIndex': chapterIndex,
    'pageIndex': pageIndex,
    'chapterTitle': chapterTitle,
    'chapterTotal': chapterTotal,
    'updatedAtMs': updatedAtMs,
  };
}

Future<List<ReadingShelfEntry>> loadShelf() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_shelfKey);
  if (raw == null || raw.isEmpty) return [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return [];
  return [
    for (final item in decoded)
      if (item is Map<String, dynamic>)
        ReadingShelfEntry.fromJson(item),
  ];
}

Future<void> saveShelf(List<ReadingShelfEntry> entries) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _shelfKey,
    jsonEncode([for (final entry in entries) entry.toJson()]),
  );
}

Future<bool> isShelved(String sourceId, String bookId) async {
  final entries = await loadShelf();
  return entries.any(
    (entry) => entry.sourceId == sourceId && entry.bookId == bookId,
  );
}

Future<void> addShelfEntry(ReadingShelfEntry entry) async {
  final entries = await loadShelf();
  entries.removeWhere(
    (item) => item.sourceId == entry.sourceId && item.bookId == entry.bookId,
  );
  entries.insert(0, entry);
  await saveShelf(entries);
}

Future<void> removeShelfEntry(String sourceId, String bookId) async {
  final entries = await loadShelf();
  entries.removeWhere(
    (item) => item.sourceId == sourceId && item.bookId == bookId,
  );
  await saveShelf(entries);
}

Future<List<ReadingShelfEntry>> loadReadingHistory() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_historyKey);
  if (raw == null || raw.isEmpty) return [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return [];
  return [
    for (final item in decoded)
      if (item is Map<String, dynamic>)
        ReadingShelfEntry.fromJson(item),
  ];
}

Future<void> saveReadingHistory(List<ReadingShelfEntry> entries) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _historyKey,
    jsonEncode([for (final entry in entries) entry.toJson()]),
  );
}

Future<void> recordReadingHistory(ReadingShelfEntry entry) async {
  final entries = await loadReadingHistory();
  entries.removeWhere(
    (item) => item.sourceId == entry.sourceId && item.bookId == entry.bookId,
  );
  entries.insert(0, entry);
  if (entries.length > _readingHistoryLimit) {
    entries.removeRange(_readingHistoryLimit, entries.length);
  }
  await saveReadingHistory(entries);
}

Future<void> removeReadingHistory(String sourceId, String bookId) async {
  final entries = await loadReadingHistory();
  entries.removeWhere(
    (item) => item.sourceId == sourceId && item.bookId == bookId,
  );
  await saveReadingHistory(entries);
}

Future<Map<String, ReadingBookmark>> loadBookmarks() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_bookmarkKey);
  if (raw == null || raw.isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return {};
  return {
    for (final item in decoded.entries)
      if (item.value is Map<String, dynamic>)
        item.key: ReadingBookmark.fromJson(item.value),
  };
}

Future<ReadingBookmark?> loadBookmark(
  String sourceId,
  String bookId,
) async {
  final bookmarks = await loadBookmarks();
  return bookmarks[readingBookmarkKey(sourceId, bookId)];
}

Future<void> saveBookmark({
  required String sourceId,
  required String bookId,
  required int chapterIndex,
  required int pageIndex,
  String chapterTitle = '',
  int chapterTotal = 0,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final bookmarks = await loadBookmarks();
  bookmarks[readingBookmarkKey(sourceId, bookId)] = ReadingBookmark(
    chapterIndex: chapterIndex,
    pageIndex: pageIndex,
    chapterTitle: chapterTitle,
    chapterTotal: chapterTotal,
    updatedAtMs: now,
  );
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    _bookmarkKey,
    jsonEncode({
      for (final item in bookmarks.entries) item.key: item.value.toJson(),
    }),
  );
  final entries = await loadShelf();
  final index = entries.indexWhere(
    (item) => item.sourceId == sourceId && item.bookId == bookId,
  );
  if (index < 0) return;
  final entry = entries[index];
  entries[index] = ReadingShelfEntry(
    sourceId: entry.sourceId,
    sourceName: entry.sourceName,
    bookId: entry.bookId,
    title: entry.title,
    cover: entry.cover,
    author: entry.author,
    lastChapterIndex: chapterIndex,
    lastChapterTitle: chapterTitle,
    chapterTotal: chapterTotal > 0 ? chapterTotal : entry.chapterTotal,
    updatedAtMs: now,
  );
  await saveShelf(entries);
}

List<ReadingShelfEntry> visibleShelfEntries(
  List<ReadingShelfEntry> entries,
) => entries;
