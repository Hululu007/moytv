import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:moyi/reading_bookshelf.dart';
import 'package:moyi/reading_bookshelf_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadPreviewFont() async {
  try {
    const path = String.fromEnvironment(
      'PREVIEW_FONT',
      defaultValue: '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final loader = FontLoader('PreviewCJK')
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
    await loader.load().timeout(
      const Duration(seconds: 30),
      onTimeout: () {},
    );
  } catch (_) {}
}

Future<void> _capture(
  WidgetTester tester,
  Widget page,
  String name,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'PreviewCJK'),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('preview-boundary'),
          child: page,
        ),
      ),
    ),
  );
  await tester.runAsync(_loadPreviewFont);
  await tester.pumpAndSettle();
  await tester.pump();
  final boundary =
      tester
              .element(find.byKey(const ValueKey('preview-boundary')))
              .renderObject
          as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  await tester.runAsync(() async {
    final file = File('reading_bookshelf_previews/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    expect(await file.length(), greaterThan(0));
  });
}

Widget _detailHeaderPreview() {
  return Builder(
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 96,
                  height: 128,
                  color: Colors.grey.shade300,
                  alignment: Alignment.center,
                  child: const Text('海报占位'),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '示例小说',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '示例作者',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Fake · 3 章',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        key: const ValueKey('detail-bookshelf-toggle'),
                        onPressed: () {},
                        icon: const Icon(Icons.bookmark_border),
                        label: const Text('加入书架'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text('章节', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          for (var i = 0; i < 3; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text('第${i + 1}章'),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
        ],
        ),
      );
    },
  );
}

void main() {
  testWidgets('preview bookshelf list', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    SharedPreferences.setMockInitialValues({
      'readingBookshelf': jsonEncode([
        const ReadingShelfEntry(
          sourceId: 'fake',
          sourceName: 'Fake',
          bookId: 'b1',
          title: '示例小说',
          lastChapterIndex: 1,
          lastChapterTitle: '第2章',
          chapterTotal: 3,
          updatedAtMs: 1,
        ).toJson(),
        const ReadingShelfEntry(
          sourceId: 'fake',
          sourceName: 'Fake',
          bookId: 'b2',
          title: '还没开始的小说',
          chapterTotal: 12,
          updatedAtMs: 2,
        ).toJson(),
        const ReadingShelfEntry(
          sourceId: 'adult',
          sourceName: '🔞成人源',
          bookId: 'b3',
          title: '午夜门禁隐藏的书',
          chapterTotal: 5,
          updatedAtMs: 3,
        ).toJson(),
      ]),
    });
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _capture(
      tester,
      const ReadingBookshelfScreen(sources: []),
      'bookshelf_list',
    );
  });

  testWidgets('preview detail bookshelf button', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _capture(
      tester,
      _detailHeaderPreview(),
      'detail_bookshelf_button',
    );
  });
}
