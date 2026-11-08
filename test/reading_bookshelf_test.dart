import 'dart:convert';

import 'package:moyi/content_models.dart';
import 'package:moyi/midnight_zone.dart';
import 'package:moyi/nonvideo_content.dart';
import 'package:moyi/novel_reader_page.dart';
import 'package:moyi/reading_bookshelf.dart';
import 'package:moyi/reading_bookshelf_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSource extends ContentSource {
  _FakeSource({
    required this.fakeId,
    required this.fakeName,
    this.chapters = const [
      ContentChapter(id: 'c1', title: '第1章'),
      ContentChapter(id: 'c2', title: '第2章'),
      ContentChapter(id: 'c3', title: '第3章'),
    ],
    this.texts = const {'c1': '第一章内容。', 'c2': '第二章内容。', 'c3': '第三章内容。'},
  });

  final String fakeId;
  final String fakeName;
  final List<ContentChapter> chapters;
  final Map<String, String> texts;

  @override
  String get id => fakeId;

  @override
  String get name => fakeName;

  @override
  ContentSection get section => ContentSection.novel;

  @override
  Future<List<ContentCategory>> categories() async => const [];

  @override
  Future<ContentPage> catalog(String categoryId, int page) async =>
      const ContentPage(items: []);

  @override
  Future<ContentPage> search(String keyword, int page) async =>
      const ContentPage(items: []);

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    return ContentBookDetail(
      book: ContentBook(id: bookId, title: 'Book $bookId'),
      chapters: chapters,
    );
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    return ContentAudioTrack(
      url:
          'novel://${jsonEncode({'title': chapter.title, 'content': texts[chapter.id] ?? ''})}',
    );
  }
}

ReadingShelfEntry _entry({
  String sourceId = 'fake',
  String sourceName = 'Fake',
  String bookId = 'b1',
  String title = 'Book One',
  int lastChapterIndex = 0,
  String lastChapterTitle = '',
  int chapterTotal = 3,
}) {
  return ReadingShelfEntry(
    sourceId: sourceId,
    sourceName: sourceName,
    bookId: bookId,
    title: title,
    lastChapterIndex: lastChapterIndex,
    lastChapterTitle: lastChapterTitle,
    chapterTotal: chapterTotal,
    updatedAtMs: 1,
  );
}

String _shelfJson(List<ReadingShelfEntry> entries) =>
    jsonEncode([for (final entry in entries) entry.toJson()]);

void main() {
  test('shelf add list remove round trip', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await loadShelf(), isEmpty);
    expect(await isShelved('fake', 'b1'), isFalse);
    await addShelfEntry(_entry());
    await addShelfEntry(_entry(bookId: 'b2', title: 'Book Two'));
    final entries = await loadShelf();
    expect(entries.map((e) => e.bookId), ['b2', 'b1']);
    expect(await isShelved('fake', 'b1'), isTrue);
    await addShelfEntry(_entry(title: 'Book One Again'));
    expect((await loadShelf()).first.title, 'Book One Again');
    await removeShelfEntry('fake', 'b1');
    expect((await loadShelf()).map((e) => e.bookId), ['b2']);
  });

  test('same book id on different sources stays separate', () async {
    SharedPreferences.setMockInitialValues({});
    await addShelfEntry(_entry(sourceId: 's1'));
    await addShelfEntry(_entry(sourceId: 's2', sourceName: 'Other'));
    await saveBookmark(
      sourceId: 's1',
      bookId: 'b1',
      chapterIndex: 2,
      pageIndex: 1,
      chapterTitle: '第3章',
      chapterTotal: 3,
    );
    final first = await loadBookmark('s1', 'b1');
    expect(first?.chapterIndex, 2);
    expect(first?.pageIndex, 1);
    expect(await loadBookmark('s2', 'b1'), isNull);
    final entries = await loadShelf();
    expect(
      entries.firstWhere((e) => e.sourceId == 's1').lastChapterIndex,
      2,
    );
    expect(
      entries.firstWhere((e) => e.sourceId == 's2').lastChapterIndex,
      0,
    );
  });

  test('bookmark save updates shelved progress', () async {
    SharedPreferences.setMockInitialValues({});
    await addShelfEntry(_entry());
    await saveBookmark(
      sourceId: 'fake',
      bookId: 'b1',
      chapterIndex: 1,
      pageIndex: 0,
      chapterTitle: '第2章',
      chapterTotal: 3,
    );
    final entry = (await loadShelf()).single;
    expect(entry.lastChapterIndex, 1);
    expect(entry.lastChapterTitle, '第2章');
    expect(entry.started, isTrue);
  });

  test('midnight gate hides adult entries only when inactive', () {
    final entries = [
      _entry(sourceName: '🔞成人源'),
      _entry(sourceId: 'plain', sourceName: '普通源', bookId: 'b9'),
    ];
    expect(visibleShelfEntries(entries, true).length, 2);
    final hidden = visibleShelfEntries(entries, false);
    expect(hidden.length, 1);
    expect(hidden.single.sourceId, 'plain');
  });

  testWidgets('bookshelf lists progress and source', (tester) async {
    SharedPreferences.setMockInitialValues({
      'readingBookshelf': _shelfJson([
        _entry(lastChapterIndex: 1, lastChapterTitle: '第2章'),
        _entry(bookId: 'b2', title: 'Book Two'),
      ]),
    });
    await tester.pumpWidget(
      const MaterialApp(home: ReadingBookshelfScreen(sources: [])),
    );
    await tester.pumpAndSettle();
    expect(find.text('Book One'), findsOneWidget);
    expect(find.text('读到第 2 章 / 共 3 章'), findsOneWidget);
    expect(find.text('尚未开始 / 共 3 章'), findsOneWidget);
    expect(find.text('Fake'), findsNWidgets(2));
  });

  testWidgets('bookshelf hides adult entries when midnight inactive', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      midnightActivatedKey: false,
      'readingBookshelf': _shelfJson([
        _entry(sourceName: '🔞成人源', title: 'Adult Book'),
        _entry(bookId: 'b2', title: 'Book Two'),
      ]),
    });
    await tester.pumpWidget(
      const MaterialApp(home: ReadingBookshelfScreen(sources: [])),
    );
    await tester.pumpAndSettle();
    expect(find.text('Adult Book'), findsNothing);
    expect(find.text('Book Two'), findsOneWidget);
    expect(find.text('有 1 本书因午夜门禁隐藏'), findsOneWidget);
  });

  testWidgets('bookshelf delete removes entry', (tester) async {
    SharedPreferences.setMockInitialValues({
      'readingBookshelf': _shelfJson([_entry()]),
    });
    await tester.pumpWidget(
      const MaterialApp(home: ReadingBookshelfScreen(sources: [])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shelf-remove-fake-b1')));
    await tester.pumpAndSettle();
    expect(find.text('Book One'), findsNothing);
    expect(await loadShelf(), isEmpty);
  });

  testWidgets('bookshelf tap resumes through its own source', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    SharedPreferences.setMockInitialValues({
      'readingBookshelf': _shelfJson([
        _entry(lastChapterIndex: 1, lastChapterTitle: '第2章'),
      ]),
      'readingBookmarks': jsonEncode({
        readingBookmarkKey('fake', 'b1'): const ReadingBookmark(
          chapterIndex: 1,
          pageIndex: 0,
          chapterTitle: '第2章',
          chapterTotal: 3,
        ).toJson(),
      }),
    });
    final source = _FakeSource(fakeId: 'fake', fakeName: 'Fake');
    await tester.pumpWidget(
      MaterialApp(home: ReadingBookshelfScreen(sources: [source])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book One'));
    await tester.pumpAndSettle();
    expect(find.text('第二章内容。'), findsOneWidget);
  });

  testWidgets('reader restores bookmarked chapter on open', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    SharedPreferences.setMockInitialValues({
      'readingBookmarks': jsonEncode({
        readingBookmarkKey('fake', 'b1'): const ReadingBookmark(
          chapterIndex: 2,
          pageIndex: 0,
          chapterTitle: '第3章',
          chapterTotal: 3,
        ).toJson(),
      }),
    });
    final source = _FakeSource(fakeId: 'fake', fakeName: 'Fake');
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderPage(
          source: source,
          book: const ContentBook(id: 'b1', title: 'Book One'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第三章内容。'), findsOneWidget);
  });

  testWidgets('reader page turn saves page position', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final longText = List.generate(
      300,
      (i) => '这是第$i段测试文本，用来把章节撑到多页。',
    ).join('\n');
    final source = _FakeSource(
      fakeId: 'fake',
      fakeName: 'Fake',
      chapters: const [ContentChapter(id: 'c1', title: '第1章')],
      texts: {'c1': longText},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderPage(
          source: source,
          book: const ContentBook(id: 'b1', title: 'Book One'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(NovelReaderView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    final bookmark = await loadBookmark('fake', 'b1');
    expect(bookmark?.chapterIndex, 0);
    expect(bookmark?.pageIndex, 1);
  });
}
