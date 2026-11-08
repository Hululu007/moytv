import 'package:moyi/content_models.dart';
import 'package:moyi/content_py.dart';
import 'package:moyi/content_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('内容注册表清单', () {
    test('听书：听书网、喜马拉雅、红果听书、懒人听书', () {
      expect(
        ContentRegistry.sourcesFor(ContentSection.audio).map((s) => s.id),
        ['tingshuwang', 'ximalaya', 'hongguo_audio', 'lrts', 'tingyou', 'jar_tingshu'],
      );
      expect(
        ContentRegistry.sourcesFor(ContentSection.audio).map((s) => s.name),
        ['听书网', '喜马拉雅', '红果听书', '懒人听书', '听友听书', '飞卢听书'],
      );
    });

    test('午夜未激活时成人源隐藏，激活后出现', () {
      addTearDown(() => ContentRegistry.midnightActivated = false);
      expect(
        ContentRegistry.sourcesFor(ContentSection.audio).map((s) => s.id),
        ['tingshuwang', 'ximalaya', 'hongguo_audio', 'lrts', 'tingyou', 'jar_tingshu'],
      );
      ContentRegistry.midnightActivated = true;
      expect(
        ContentRegistry.sourcesFor(ContentSection.audio).map((s) => s.id),
        ['tingshuwang', 'ximalaya', 'hongguo_audio', 'lrts', 'hsvoice31', 'tingyou', 'hysxs', 'jar_tingshu'],
      );
      expect(
        ContentRegistry.sourcesFor(ContentSection.audio).last.name,
        '飞卢听书',
      );
    });

    test('小说：内置源默认在列，导入后只进小说区', () {
      addTearDown(() {
        ContentRegistry.setNovelImports([]);
        ContentRegistry.midnightActivated = false;
      });
      ContentRegistry.midnightActivated = true;
      expect(
        ContentRegistry.sourcesFor(ContentSection.novel).map((s) => s.id),
        containsAll([
          'aabook',
          'ylxs',
          'cheniyo',
          'hwg4',
          'lbwen',
          'cjg',
          'buliang',
          'yinse',
          'ssxxs',
          'mhbl',
          'ho5ho',
        ]),
      );
      ContentRegistry.setNovelImports([
        PyContentSource(
          id: 'novel_demo',
          name: '演示小说',
          importedFileName: 'demo.py',
          section: ContentSection.novel,
        ),
      ]);
      final novelIds = ContentRegistry.sourcesFor(
        ContentSection.novel,
      ).map((s) => s.id);
      expect(novelIds, contains('novel_demo'));
      expect(novelIds.last, 'novel_demo');
      ContentRegistry.midnightActivated = false;
      expect(
        ContentRegistry.sourcesFor(ContentSection.audio).map((s) => s.id),
        ['tingshuwang', 'ximalaya', 'hongguo_audio', 'lrts', 'tingyou', 'jar_tingshu'],
      );
    });

    test('小说内置源默认隐藏，午夜激活后出现且排在导入源前面', () {
      addTearDown(() {
        ContentRegistry.setNovelImports([]);
        ContentRegistry.midnightActivated = false;
      });
      final offIds = ContentRegistry.sourcesFor(
        ContentSection.novel,
      ).map((s) => s.id);
      expect(offIds, isEmpty);
      expect(offIds, isNot(contains('aabook')));
      ContentRegistry.midnightActivated = true;
      final onIds = ContentRegistry.sourcesFor(
        ContentSection.novel,
      ).map((s) => s.id).toList();
      expect(onIds.sublist(0, 10), [
        'aabook',
        'ylxs',
        'cheniyo',
        'hwg4',
        'lbwen',
        'cjg',
        'buliang',
        'yinse',
        'ssxxs',
        'mhbl',
      ]);
      expect(
        ContentRegistry.sourcesFor(ContentSection.novel).first.name,
        '🔞疯情书库',
      );
      ContentRegistry.setNovelImports([
        PyContentSource(
          id: 'novel_demo',
          name: '演示小说',
          importedFileName: 'demo.py',
          section: ContentSection.novel,
        ),
      ]);
      final withImport = ContentRegistry.sourcesFor(
        ContentSection.novel,
      ).map((s) => s.id).toList();
      expect(withImport.last, 'novel_demo');
      expect(withImport.sublist(0, 10), [
        'aabook',
        'ylxs',
        'cheniyo',
        'hwg4',
        'lbwen',
        'cjg',
        'buliang',
        'yinse',
        'ssxxs',
        'mhbl',
      ]);
    });

    test('午夜未激活时小说区有成人源被隐藏，激活后不再隐藏', () {
      addTearDown(() => ContentRegistry.midnightActivated = false);
      expect(
        ContentRegistry.hasHiddenAdultSources(ContentSection.novel),
        isTrue,
      );
      ContentRegistry.midnightActivated = true;
      expect(
        ContentRegistry.hasHiddenAdultSources(ContentSection.novel),
        isFalse,
      );
    });

    test('id 全局唯一且分区归属自洽', () {
      final all = [
        for (final section in ContentSection.values)
          ...ContentRegistry.sourcesFor(section),
      ];
      expect(all.map((s) => s.id).toSet(), hasLength(all.length));
      for (final section in ContentSection.values) {
        for (final source in ContentRegistry.sourcesFor(section)) {
          expect(source.section, section);
        }
      }
    });
  });
}
