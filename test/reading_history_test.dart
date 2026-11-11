import 'package:moyi/reading_bookshelf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReadingShelfEntry entry({
  String sourceId = 'cheniyo',
  String sourceName = '桃色书屋',
  String bookId = 'book1',
  String title = '测试小说',
  int lastChapterIndex = 3,
}) {
  return ReadingShelfEntry(
    sourceId: sourceId,
    sourceName: sourceName,
    bookId: bookId,
    title: title,
    lastChapterIndex: lastChapterIndex,
    lastChapterTitle: '第 4 章',
    chapterTotal: 20,
    updatedAtMs: 1000,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('reading history records and loads in recency order', () async {
    await recordReadingHistory(entry(bookId: 'a'));
    await recordReadingHistory(entry(bookId: 'b'));
    final history = await loadReadingHistory();
    expect(history.length, 2);
    expect(history.first.bookId, 'b');
    expect(history.last.bookId, 'a');
  });

  test('reading history dedups by book and updates progress', () async {
    await recordReadingHistory(entry(bookId: 'a', lastChapterIndex: 3));
    await recordReadingHistory(entry(bookId: 'b'));
    await recordReadingHistory(entry(bookId: 'a', lastChapterIndex: 9));
    final history = await loadReadingHistory();
    expect(history.length, 2);
    expect(history.first.bookId, 'a');
    expect(history.first.lastChapterIndex, 9);
  });

  test('reading history caps at fifty entries', () async {
    for (var i = 0; i < 55; i++) {
      await recordReadingHistory(entry(bookId: 'book$i'));
    }
    final history = await loadReadingHistory();
    expect(history.length, 50);
    expect(history.first.bookId, 'book54');
  });

  test('reading history entry can be removed', () async {
    await recordReadingHistory(entry(bookId: 'a'));
    await recordReadingHistory(entry(bookId: 'b'));
    await removeReadingHistory('cheniyo', 'a');
    final history = await loadReadingHistory();
    expect(history.length, 1);
    expect(history.first.bookId, 'b');
  });

  test('shelf and history stay independent', () async {
    await addShelfEntry(entry(bookId: 'shelf-one'));
    await recordReadingHistory(entry(bookId: 'history-one'));
    expect((await loadShelf()).length, 1);
    expect((await loadReadingHistory()).length, 1);
    expect((await loadShelf()).first.bookId, 'shelf-one');
    expect((await loadReadingHistory()).first.bookId, 'history-one');
  });
}
