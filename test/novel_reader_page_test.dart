import 'dart:convert';

import 'package:moyi/content_models.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/nonvideo_content.dart';
import 'package:moyi/novel_reader_page.dart';
import 'package:moyi/novel_tts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSource extends ContentSource {
  _FakeSource({
    this.chapters = const [
      ContentChapter(id: 'c1', title: '第1章'),
      ContentChapter(id: 'c2', title: '第2章'),
      ContentChapter(id: 'c3', title: '第3章'),
    ],
    this.texts = const {'c1': '第一章内容。', 'c2': '第二章内容。', 'c3': '第三章内容。'},
    this.failDetail = false,
    this.failChapter = false,
  });

  final List<ContentChapter> chapters;
  final Map<String, String> texts;
  final bool failDetail;
  final bool failChapter;

  @override
  String get id => 'fake';

  @override
  String get name => 'Fake';

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
    if (failDetail) throw AppFailure('fail');
    return ContentBookDetail(
      book: const ContentBook(id: 'b', title: 'Test Book'),
      chapters: chapters,
    );
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    if (failChapter) throw AppFailure('fail');
    return ContentAudioTrack(
      url:
          'novel://${jsonEncode({'title': chapter.title, 'content': texts[chapter.id] ?? ''})}',
    );
  }
}

class _FakeTts implements NovelTtsEngine {
  final spoken = <String>[];
  final rates = <double>[];
  int stopCount = 0;
  void Function()? lastComplete;

  @override
  Future<void> setLanguage(String language) async {}

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Future<void> speak(String text, void Function() onComplete) async {
    spoken.add(text);
    lastComplete = onComplete;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  void complete() => lastComplete?.call();
}

Future<void> _pumpReader(
  WidgetTester tester,
  _FakeSource source,
  _FakeTts tts,
) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NovelReaderPage(
                    source: source,
                    book: const ContentBook(id: 'b', title: 'Test Book'),
                    ttsEngine: tts,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _openOverlay(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 300));
  await tester.pumpAndSettle();
}

void main() {
  test('splitTtsText chunks long chapters', () {
    final text = List.generate(40, (i) => '段落$i。').join('\n');
    final chunks = splitTtsText(text, 50);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((chunk) => chunk.length <= 50), isTrue);
    expect(chunks.join(), contains('段落0。'));
    expect(chunks.join(), contains('段落39。'));
  });

  testWidgets('reader enters fullscreen without app bar', (tester) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(), tts);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('第一章内容。'), findsOneWidget);
    expect(find.byKey(const ValueKey('novel-back')), findsNothing);
  });

  testWidgets('overlay back returns to previous screen', (tester) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(), tts);
    await _openOverlay(tester);
    expect(find.byKey(const ValueKey('novel-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('novel-back')));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(find.text('第一章内容。'), findsNothing);
  });

  testWidgets('system back closes overlay first then pops page', (
    tester,
  ) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(), tts);
    await _openOverlay(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('第一章内容。'), findsOneWidget);
    expect(find.byKey(const ValueKey('novel-back')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('tts play pause stop follow controls', (tester) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(), tts);
    await _openOverlay(tester);
    final playPause = find.byKey(const ValueKey('novel-tts-play-pause'));
    await tester.tap(playPause);
    await tester.pumpAndSettle();
    expect(tts.spoken, ['第一章内容。']);
    await tester.tap(playPause);
    await tester.pumpAndSettle();
    expect(tts.stopCount, 1);
    await tester.tap(playPause);
    await tester.pumpAndSettle();
    expect(tts.spoken, ['第一章内容。', '第一章内容。']);
    await tester.tap(find.byKey(const ValueKey('novel-tts-stop')));
    await tester.pumpAndSettle();
    expect(tts.stopCount, 2);
  });

  testWidgets('tts completion advances to next chapter', (tester) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(), tts);
    await _openOverlay(tester);
    await tester.tap(find.byKey(const ValueKey('novel-tts-play-pause')));
    await tester.pumpAndSettle();
    tts.complete();
    await tester.pumpAndSettle();
    expect(tts.spoken, ['第一章内容。', '第二章内容。']);
    expect(find.text('第二章内容。'), findsOneWidget);
  });

  testWidgets('exiting reader stops tts', (tester) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(), tts);
    await _openOverlay(tester);
    await tester.tap(find.byKey(const ValueKey('novel-tts-play-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('novel-back')));
    await tester.pumpAndSettle();
    expect(tts.stopCount, 1);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('no chapters shows error and no tts control', (tester) async {
    final tts = _FakeTts();
    await _pumpReader(
      tester,
      _FakeSource(chapters: const [], texts: const {}),
      tts,
    );
    expect(find.text('该书暂无章节'), findsOneWidget);
    expect(find.byKey(const ValueKey('novel-tts-play-pause')), findsNothing);
    expect(tts.spoken, isEmpty);
  });

  testWidgets('detail failure shows error without crash', (tester) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(failDetail: true), tts);
    expect(find.text('加载章节失败'), findsOneWidget);
    expect(tts.spoken, isEmpty);
  });

  testWidgets('chapter fetch failure shows error without crash', (
    tester,
  ) async {
    final tts = _FakeTts();
    await _pumpReader(tester, _FakeSource(failChapter: true), tts);
    expect(find.text('加载章节失败'), findsOneWidget);
    expect(tts.spoken, isEmpty);
  });

  testWidgets('page turn still works after fullscreen change', (tester) async {
    final longText = List.generate(
      300,
      (i) => '这是第$i段测试文本，用来把章节撑到多页。',
    ).join('\n');
    final tts = _FakeTts();
    await _pumpReader(
      tester,
      _FakeSource(
        chapters: const [ContentChapter(id: 'c1', title: '第1章')],
        texts: {'c1': longText},
      ),
      tts,
    );
    expect(find.textContaining('1 /'), findsOneWidget);
    await tester.drag(find.byType(NovelReaderView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 /'), findsOneWidget);
  });
}
