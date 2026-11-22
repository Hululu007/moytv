import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/nonvideo_content.dart';

// 回归：正文翻到最后一页再往后点，必须走 onEndReached（下一章），
// 不能点了毫无反应；超长无换行文本也必须能分成多页（老实现在
// getLineBoundary 不前进时会死循环，界面直接卡住）。
void main() {
  testWidgets('文字章节翻到最后一页继续后翻会请求下一章', (tester) async {
    var ended = 0;
    final text = List.generate(400, (i) => '第$i段测试文字，用来把章节撑成很多页。').join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NovelReaderView(
            content: NonVideoContent.novel(text: text, title: '第一章'),
            title: '第一章',
            onEndReached: () => ended++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final right = Offset(size.width * 0.85, size.height * 0.5);
    for (var i = 0; i < 60; i++) {
      await tester.tapAt(right);
      await tester.pumpAndSettle();
    }
    expect(ended, greaterThan(0), reason: '翻到底后应请求下一章');
  });

  testWidgets('超长无换行文本能分页且不卡死', (tester) async {
    final text = '啰' * 20000;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NovelReaderView(
            content: NonVideoContent.novel(text: text, title: '长章'),
            title: '长章',
          ),
        ),
      ),
    );
    // 不 settle：只要这一帧能渲染出来就说明没有死循环。
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(NovelReaderView), findsOneWidget);
  });
}
