import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/nonvideo_content.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

void main() {
  late Map<String, Uint8List> images;
  late List<String> urls;

  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    const colors = [
      Colors.red,
      Colors.green,
      Colors.blue,
      Colors.amber,
      Colors.purple,
    ];
    urls = List.generate(
      5,
      (i) => 'https://img.example.test/page${i + 1}.png',
    );
    images = {
      for (var i = 0; i < urls.length; i++)
        urls[i]: await fakeComicPagePng(colors[i]),
    };
  });

  // 注意：调过 toImage 的测试在收尾时会挂起（PNG 已落地）。单跑、
  // 超时杀掉只取 PNG。
  testWidgets('预览 漫画纵向连续滚动阅读页', (tester) async {
    HttpOverrides.global = FakeNetworkImageOverrides(images);
    addTearDown(() {
      HttpOverrides.global = null;
      PaintingBinding.instance.imageCache.clear();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    final base = ThemeData.dark();
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              backgroundColor: Colors.black,
              body: Column(
                children: [
                  Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.fromLTRB(12, 48, 12, 8),
                    child: const Row(
                      children: [
                        Icon(Icons.arrow_back, color: Colors.white),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '漫蛙·第1话（预览·假数据）',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        Text(
                          '纵向滚动',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PicsViewerView(
                      content: NonVideoContent.pics(title: '', urls: urls),
                      title: '第1话',
                      verticalScroll: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 假图走引擎解码，必须真等，否则截出来是空白页。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1 / 5'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/manwa_reader.png').writeAsBytesSync(bytes);
    print('preview landed: manwa_reader');
  });
}
