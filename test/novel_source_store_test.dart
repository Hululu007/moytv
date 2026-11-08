import 'package:moyi/content_legado.dart';
import 'package:moyi/novel_source_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('小说导入识别', () {
    test('含 novel:// 的是小说源', () {
      expect(
        NovelSourceStore.isNovelComicPyText(
          'return {"parse": 0, "url": "novel://" + payload}',
        ),
        isTrue,
      );
    });

    test('含 pics:// 的是漫画源', () {
      expect(
        NovelSourceStore.isNovelComicPyText(
          'return {"parse": 0, "url": "pics://" + urls}',
        ),
        isTrue,
      );
    });

    test('只回视频地址的不是小说漫画源', () {
      expect(
        NovelSourceStore.isNovelComicPyText(
          'return {"parse": 0, "url": "https://cdn.example.com/v.m3u8"}',
        ),
        isFalse,
      );
    });

    test('只回音频地址的不是小说漫画源', () {
      expect(
        NovelSourceStore.isNovelComicPyText(
          'return {"parse": 0, "url": "https://cdn.example.com/a.mp3"}',
        ),
        isFalse,
      );
    });

    test('大写协议头不算', () {
      expect(
        NovelSourceStore.isNovelComicPyText(
          'return {"parse": 0, "url": "NOVEL://" + payload}',
        ),
        isFalse,
      );
    });

    test('空文本不是小说漫画源', () {
      expect(NovelSourceStore.isNovelComicPyText(''), isFalse);
    });
  });

  group('导入记录类型', () {
    test('漫画类型往返不丢', () {
      final record = NovelImportRecord(
        id: 'novel_1',
        name: 'C',
        fileName: 'novel_1.json',
        kind: NovelImportKind.json,
        sourceType: 2,
      );
      final back = NovelImportRecord.fromJson(record.toJson());
      expect(back?.sourceType, 2);
      final source = back?.toSource();
      expect(source, isA<JsonContentSource>());
      expect((source as JsonContentSource).isComic, isTrue);
    });

    test('老记录缺类型默认小说', () {
      final back = NovelImportRecord.fromJson({
        'id': 'novel_2',
        'name': 'T',
        'fileName': 'novel_2.json',
        'kind': 'json',
      });
      expect(back?.sourceType, 0);
      expect(
        (back?.toSource() as JsonContentSource).isComic,
        isFalse,
      );
    });
  });
}
