import 'package:moyi/audio_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AudioListenRecord record({
  String sourceId = 'tingshuwang',
  String sourceName = '听书网',
  String bookId = 'book1',
  String title = '测试书',
  int chapterIndex = 2,
  int positionMs = 61000,
  int durationMs = 1800000,
}) {
  return AudioListenRecord(
    sourceId: sourceId,
    sourceName: sourceName,
    bookId: bookId,
    title: title,
    chapterIndex: chapterIndex,
    chapterTitle: '第 3 集',
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAtMs: 1000,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('resume saves and loads by book', () async {
    await saveAudioResume(record());
    final loaded = await loadAudioResume('tingshuwang', 'book1');
    expect(loaded?.title, '测试书');
    expect(loaded?.chapterIndex, 2);
    expect(loaded?.positionMs, 61000);
    expect(loaded?.durationMs, 1800000);
    expect(await loadAudioResume('tingshuwang', 'missing'), isNull);
  });

  test('resume keeps the latest chapter and position', () async {
    await saveAudioResume(record());
    await saveAudioResume(
      record(chapterIndex: 5, positionMs: 120000, durationMs: 1500000),
    );
    final loaded = await loadAudioResume('tingshuwang', 'book1');
    expect(loaded?.chapterIndex, 5);
    expect(loaded?.positionMs, 120000);
  });

  test('history dedups by book and keeps most recent first', () async {
    await recordAudioHistory(record(bookId: 'a'));
    await recordAudioHistory(record(bookId: 'b'));
    await recordAudioHistory(record(bookId: 'a', chapterIndex: 4));
    final history = await loadAudioHistory();
    expect(history.length, 2);
    expect(history.first.bookId, 'a');
    expect(history.first.chapterIndex, 4);
    expect(history.last.bookId, 'b');
  });

  test('history caps at fifty entries', () async {
    for (var i = 0; i < 55; i++) {
      await recordAudioHistory(record(bookId: 'book$i'));
    }
    final history = await loadAudioHistory();
    expect(history.length, 50);
    expect(history.first.bookId, 'book54');
    expect(history.last.bookId, 'book5');
  });

  test('history entry can be removed', () async {
    await recordAudioHistory(record(bookId: 'a'));
    await recordAudioHistory(record(bookId: 'b'));
    await removeAudioHistory('tingshuwang', 'a');
    final history = await loadAudioHistory();
    expect(history.length, 1);
    expect(history.first.bookId, 'b');
  });

  test('favorites add, check and remove', () async {
    expect(await isAudioFavorite('tingshuwang', 'book1'), isFalse);
    await addAudioFavorite(
      const AudioFavoriteEntry(
        sourceId: 'tingshuwang',
        sourceName: '听书网',
        bookId: 'book1',
        title: '测试书',
      ),
    );
    expect(await isAudioFavorite('tingshuwang', 'book1'), isTrue);
    await addAudioFavorite(
      const AudioFavoriteEntry(
        sourceId: 'tingshuwang',
        sourceName: '听书网',
        bookId: 'book1',
        title: '测试书',
      ),
    );
    expect((await loadAudioFavorites()).length, 1);
    await removeAudioFavorite('tingshuwang', 'book1');
    expect(await isAudioFavorite('tingshuwang', 'book1'), isFalse);
  });

  test('adult sources are no longer hidden by a midnight gate', () async {
    final entries = [record(), record(sourceName: '🔞午夜听书', bookId: 'adult1')];
    // 与火蚁TV现行做法一致：听书历史/收藏不再按午夜激活过滤，全部在列。
    expect(visibleAudioRecords(entries).length, 2);
    final favorites = [
      const AudioFavoriteEntry(
        sourceId: 'x',
        sourceName: '🔞午夜听书',
        bookId: 'adult1',
        title: '成人书',
      ),
    ];
    expect(visibleAudioFavorites(favorites).length, 1);
  });
}
