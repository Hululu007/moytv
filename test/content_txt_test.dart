import 'dart:convert';
import 'dart:io';

import 'package:moyi/content_py.dart';
import 'package:moyi/content_txt.dart';
import 'package:moyi/nonvideo_content.dart';
import 'package:moyi/novel_source_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:enough_convert/gbk.dart';

const _sample = '''
这是一段前言文字。
第一章 初入江湖
春风拂面，少年提剑出门。
第二章 风云再起
江湖从此多事。
楔子
多年以前。
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('txt 编解码', () {
    test('UTF-8 正常解码', () {
      expect(
        decodeTxtBytes(utf8.encode('第一章 你好\n正文')),
        '第一章 你好\n正文',
      );
    });

    test('GBK 编码回退解码', () {
      final bytes = gbk.encode('第一章 你好\n正文内容');
      expect(decodeTxtBytes(bytes), '第一章 你好\n正文内容');
    });

    test('UTF-8 BOM 去除', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('第一章')];
      expect(decodeTxtBytes(bytes), '第一章');
    });
  });

  group('txt 章节切分', () {
    test('前言并入首章，章名保留', () {
      final chapters = splitTxtChapters(_sample);
      expect(chapters.map((c) => c.title), ['第一章 初入江湖', '第二章 风云再起', '楔子']);
      expect(chapters[0].body, contains('这是一段前言文字'));
      expect(chapters[0].body, contains('春风拂面'));
      expect(chapters[1].body, contains('江湖从此多事'));
      expect(chapters[2].body, contains('多年以前'));
    });

    test('无章名时整本作一章全文', () {
      final chapters = splitTxtChapters('没有章名的正文\n第二行');
      expect(chapters, hasLength(1));
      expect(chapters[0].title, '全文');
      expect(chapters[0].body, '没有章名的正文\n第二行');
    });

    test('空体卷名章丢弃', () {
      const text = '第一卷 卷首语\n第一章 开篇\n正文。\n第二章 续篇\n更多正文。';
      final chapters = splitTxtChapters(text);
      expect(chapters.map((c) => c.title), ['第一章 开篇', '第二章 续篇']);
    });

    test('超长行不算章名', () {
      const text = '第一章这是一个非常非常长的行足足超过四十个字所以不应该被当成章名来切分章节内容填充填充。\n正文。';
      final chapters = splitTxtChapters(text);
      expect(chapters, hasLength(1));
      expect(chapters[0].title, '全文');
    });
  });

  group('导入记录映射', () {
    test('txt 记录往返与源类型', () {
      const record = NovelImportRecord(
        id: 'novel_1',
        name: '测试小说',
        fileName: 'novel_1.txt',
        kind: NovelImportKind.txt,
      );
      final restored = NovelImportRecord.fromJson(record.toJson());
      expect(restored?.kind, NovelImportKind.txt);
      expect(restored?.toSource(), isA<TxtContentSource>());
    });

    test('旧记录按后缀推断类型', () {
      final txt = NovelImportRecord.fromJson({
        'id': 'novel_2',
        'name': '旧书',
        'fileName': 'novel_2.txt',
      });
      expect(txt?.kind, NovelImportKind.txt);
      expect(txt?.toSource(), isA<TxtContentSource>());
      final py = NovelImportRecord.fromJson({
        'id': 'novel_3',
        'name': '旧源',
        'fileName': 'novel_3.py',
      });
      expect(py?.kind, NovelImportKind.py);
      expect(py?.toSource(), isA<PyContentSource>());
    });
  });

  group('txt 源端到端', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('huoyi_txt_test');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => tempDir.path);
      final dir = Directory('${tempDir.path}/imported_spiders');
      await dir.create(recursive: true);
      await File('${dir.path}/book.txt').writeAsBytes(gbk.encode(_sample));
    });

    tearDownAll(() async {
      await tempDir.delete(recursive: true);
    });

    TxtContentSource source() => TxtContentSource(
      id: 'txt_1',
      name: '测试小说',
      importedFileName: 'book.txt',
    );

    test('分类与目录', () async {
      final s = source();
      expect((await s.categories()).map((c) => c.name), ['全部']);
      final page = await s.catalog('all', 1);
      expect(page.items, hasLength(1));
      expect(page.items[0].title, '测试小说');
      expect(page.items[0].remarks, '共3章');
      expect((await s.catalog('all', 2)).items, isEmpty);
    });

    test('详情与章节正文', () async {
      final s = source();
      final detail = await s.detail('txt_1');
      expect(detail.chapters.map((c) => c.title), [
        '第一章 初入江湖',
        '第二章 风云再起',
        '楔子',
      ]);
      final text = await s.chapterText('txt_1', detail.chapters[1]);
      expect(text, contains('江湖从此多事'));
    });

    test('阅读器走 novel 链接', () async {
      final s = source();
      final detail = await s.detail('txt_1');
      final track = await s.audioTrack('txt_1', detail.chapters[0]);
      final parsed = parseNonVideoUrl(track.url);
      expect(parsed, isNotNull);
      expect(parsed!.isNovel, isTrue);
      expect(parsed.title, '第一章 初入江湖');
      expect(parsed.text, contains('春风拂面'));
    });

    test('搜索按书名匹配', () async {
      final s = source();
      expect((await s.search('测试', 1)).items, hasLength(1));
      expect((await s.search('不存在', 1)).items, isEmpty);
    });
  });
}
