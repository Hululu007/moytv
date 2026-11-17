import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/novel_reader_page.dart';
import 'package:moyi/novel_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSource extends ContentSource {
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
  Future<ContentBookDetail> detail(String bookId) async =>
      const ContentBookDetail(
        book: ContentBook(id: 'b', title: 'Test Book'),
        chapters: [
          ContentChapter(id: 'c1', title: '第1章'),
          ContentChapter(id: 'c2', title: '第2章'),
        ],
      );

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async => ContentAudioTrack(
    url: 'novel://${jsonEncode({'title': chapter.title, 'content': '正文。'})}',
  );
}

class _FakeTts implements NovelTtsEngine {
  @override
  Future<void> setLanguage(String language) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<bool> hasChineseVoice() async => true;

  @override
  Future<void> speak(
    String text,
    void Function() onComplete, {
    void Function()? onError,
  }) async {}

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpReader(WidgetTester tester) async {
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
                      source: _FakeSource(),
                      book: const ContentBook(id: 'b', title: 'Test Book'),
                      ttsEngine: _FakeTts(),
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
    // 点中央呼出覆盖层。
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
  }

  testWidgets('阅读器顶栏在状态栏下方、底栏在手势条上方', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    await pumpReader(tester);

    final back = tester.getRect(find.byKey(const ValueKey('novel-back')));
    expect(back.top, greaterThanOrEqualTo(44));

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final next = tester.getRect(
      find.byKey(const ValueKey('novel-next-chapter')),
    );
    expect(next.bottom, lessThanOrEqualTo(size.height - 34));
  });
}
