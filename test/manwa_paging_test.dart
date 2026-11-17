import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/nonvideo_content.dart';

import 'fixtures.dart';

void main() {
  final urls = List.generate(
    5,
    (i) => 'https://img.example.test/page${i + 1}.png',
  );
  late Map<String, Uint8List> images;

  setUpAll(() async {
    const colors = [
      Colors.red,
      Colors.green,
      Colors.blue,
      Colors.amber,
      Colors.purple,
    ];
    images = {
      for (var i = 0; i < urls.length; i++)
        urls[i]: await fakeComicPagePng(colors[i]),
    };
  });

  setUp(() {
    HttpOverrides.global = FakeNetworkImageOverrides(images);
  });

  tearDown(() {
    HttpOverrides.global = null;
    PaintingBinding.instance.imageCache.clear();
  });

  Future<void> pumpViewer(
    WidgetTester tester, {
    bool verticalScroll = false,
    int initialIndex = 0,
    ValueChanged<int>? onIndexChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PicsViewerView(
            content: NonVideoContent.pics(title: '', urls: urls),
            title: '测试章节',
            initialIndex: initialIndex,
            onIndexChanged: onIndexChanged,
            verticalScroll: verticalScroll,
          ),
        ),
      ),
    );
    // 假图走引擎解码，pumpAndSettle 刷不出来，必须真等一会儿。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle(const Duration(seconds: 5));
  }

  testWidgets('纵向模式上下排图，拖动滚动且序号跟进', (tester) async {
    final seen = <int>[];
    await pumpViewer(
      tester,
      verticalScroll: true,
      onIndexChanged: seen.add,
    );
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('1 / 5'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('1 / 5'), findsNothing);
    expect(seen, contains(1));
  });

  testWidgets('纵向模式续读跳到初始序号附近', (tester) async {
    await pumpViewer(tester, verticalScroll: true, initialIndex: 4);
    final listView = tester.widget<ListView>(find.byType(ListView));
    final offset = listView.controller!.offset;
    expect(offset, greaterThan(1000));
  });

  testWidgets('默认横向逐张翻页不变', (tester) async {
    await pumpViewer(tester);
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.text('1 / 5'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('纵向模式上下屏按钮是上下箭头', (tester) async {
    await pumpViewer(tester, verticalScroll: true);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });
}
