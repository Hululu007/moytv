import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_db_mirror.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/actress_models.dart';

void main() {
  group('mirrorWorks 批量合并', () {
    test('新建作品：建人、作品数跟着涨', () async {
      final db = MemoryActressDatabase();
      final result = await mirrorWorks(
        library: db,
        works: const [
          ActressDbMirrorWork(
            actress: '波多野结衣',
            title: '测试作品一',
            code: 'SSIS-001',
            playUrl: 'https://example.com/a.m3u8',
            site: 'mjv',
            coverSource: 'mjv',
          ),
          ActressDbMirrorWork(
            actress: '波多野结衣',
            title: '测试作品二',
            code: 'SSIS-002',
            playUrl: 'https://example.com/b.m3u8',
            site: 'mjv',
            coverSource: 'mjv',
          ),
          ActressDbMirrorWork(
            actress: '三上悠亚',
            title: '测试作品三',
            code: 'SSNI-001',
            playUrl: 'https://example.com/c.m3u8',
            site: 'whos',
            coverSource: 'whos',
          ),
        ],
      );
      expect(result.appended, 3);
      expect(result.updated, 0);
      expect(result.skipped, 0);
      expect(result.failed, 0);
      final overview = await db.overview();
      expect(overview.persons, 2);
      expect(overview.works, 3);
    });

    test('重读不重复加：番号+播放链接都相同就跳过', () async {
      final db = MemoryActressDatabase();
      const works = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '测试作品一',
          code: 'SSIS-001',
          playUrl: 'https://example.com/a.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
      ];
      final first = await mirrorWorks(library: db, works: works);
      expect(first.appended, 1);
      final second = await mirrorWorks(library: db, works: works);
      expect(second.appended, 0);
      expect(second.skipped, 1);
      final overview = await db.overview();
      expect(overview.works, 1);
    });

    test('任一不同就更新替换：同番号换了链接只换链接不加行', () async {
      final db = MemoryActressDatabase();
      const first = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '测试作品一',
          code: 'SSIS-001',
          playUrl: 'https://example.com/a.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
      ];
      await mirrorWorks(library: db, works: first);
      const second = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '测试作品一',
          code: 'SSIS-001',
          playUrl: 'https://example.com/a-new.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
      ];
      final result = await mirrorWorks(library: db, works: second);
      expect(result.updated, 1);
      expect(result.appended, 0);
      final overview = await db.overview();
      expect(overview.works, 1);
      final person = await db.personById(1);
      expect(person, isNotNull);
      final rows = await db.worksForPerson(
        person!.localId,
        offset: 0,
        limit: 10,
      );
      expect(rows.single.coverDramaId, 'https://example.com/a-new.m3u8');
    });

    test('作品叠加不去重：同番号换站各留一条', () async {
      final db = MemoryActressDatabase();
      const works = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '测试作品一',
          code: 'SSIS-001',
          playUrl: 'https://example.com/a.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '测试作品一',
          code: 'SSIS-001',
          playUrl: 'https://example.com/a.m3u8',
          site: 'whos',
          coverSource: 'whos',
        ),
      ];
      final result = await mirrorWorks(library: db, works: works);
      expect(result.appended, 2);
      final overview = await db.overview();
      expect(overview.works, 2);
    });

    test('同名女优归一化合并：去空白后同一人只建一次', () async {
      final db = MemoryActressDatabase();
      const works = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '测试作品一',
          code: 'SSIS-001',
          playUrl: 'https://example.com/a.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
        ActressDbMirrorWork(
          actress: '波多野 结衣',
          title: '测试作品二',
          code: 'SSIS-002',
          playUrl: 'https://example.com/b.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
      ];
      final result = await mirrorWorks(library: db, works: works);
      expect(result.appended, 2);
      final overview = await db.overview();
      expect(overview.persons, 1);
      expect(overview.works, 2);
    });

    test('无番号作品按标题去重：同标题换链接更新替换', () async {
      final db = MemoryActressDatabase();
      const first = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '无番号作品',
          playUrl: 'https://example.com/x.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
      ];
      await mirrorWorks(library: db, works: first);
      const second = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '无番号作品',
          playUrl: 'https://example.com/y.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
      ];
      final result = await mirrorWorks(library: db, works: second);
      expect(result.updated, 1);
      expect(result.appended, 0);
      final overview = await db.overview();
      expect(overview.works, 1);
    });

    test('没女优名、没番号没标题的行跳过不崩，同批其他条照常进', () async {
      final db = MemoryActressDatabase();
      const works = [
        ActressDbMirrorWork(actress: '', title: '没人名的作品', code: 'AB-1'),
        ActressDbMirrorWork(actress: '波多野结衣'),
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '正常作品',
          code: 'SSIS-003',
          playUrl: 'https://example.com/c.m3u8',
          site: 'mjv',
          coverSource: 'mjv',
        ),
      ];
      final result = await mirrorWorks(library: db, works: works);
      expect(result.appended, 1);
      expect(result.skipped, 2);
      expect(result.failed, 0);
    });

    test('没封面只有播放地址的条目：地址照样写进 cover_drama_id', () async {
      final db = MemoryActressDatabase();
      const works = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '只有地址的作品',
          code: 'SSIS-004',
          playUrl: 'https://example.com/d.m3u8',
          site: 'chaoliu',
          coverSource: 'chaoliu',
        ),
      ];
      await mirrorWorks(library: db, works: works);
      final person = await db.personById(1);
      final rows = await db.worksForPerson(
        person!.localId,
        offset: 0,
        limit: 10,
      );
      expect(rows.single.coverDramaId, 'https://example.com/d.m3u8');
      expect(rows.single.coverSource, 'chaoliu');
    });

    test('进度回调：done 从 1 涨到总数', () async {
      final db = MemoryActressDatabase();
      const works = [
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '一',
          code: 'A-1',
          playUrl: 'https://example.com/1',
          site: 'mjv',
        ),
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '二',
          code: 'A-2',
          playUrl: 'https://example.com/2',
          site: 'mjv',
        ),
        ActressDbMirrorWork(
          actress: '波多野结衣',
          title: '三',
          code: 'A-3',
          playUrl: 'https://example.com/3',
          site: 'mjv',
        ),
      ];
      final seen = <int>[];
      await mirrorWorks(
        library: db,
        works: works,
        onProgress: (done, total) {
          seen.add(done);
          expect(total, 3);
        },
      );
      expect(seen, [1, 2, 3]);
    });
  });

  group('updateWorkPlayLink', () {
    test('找到行换链接返回 true，找不到返回 false', () async {
      final db = MemoryActressDatabase();
      final person = await db.upsertCrawledPerson(name: '波多野结衣');
      expect(person, isNotNull);
      await db.upsertWorks(
        person!.localId,
        const [
          RosterFilm(code: 'SSIS-001', title: '测试作品一'),
        ],
        site: 'mjv',
      );
      final ok = await db.updateWorkPlayLink(
        personId: person.localId,
        site: 'mjv',
        codeKey: 'SSIS1',
        titleKey: '',
        coverSource: 'chaoliu',
        coverDramaId: 'https://example.com/new.m3u8',
        coverUrl: 'https://example.com/cover.jpg',
      );
      expect(ok, isTrue);
      final rows = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(rows.single.coverDramaId, 'https://example.com/new.m3u8');
      expect(rows.single.coverUrl, 'https://example.com/cover.jpg');
      final miss = await db.updateWorkPlayLink(
        personId: person.localId,
        site: 'mjv',
        codeKey: 'NOPE1',
        titleKey: '',
        coverSource: 'chaoliu',
        coverDramaId: 'https://example.com/no.m3u8',
        coverUrl: '',
      );
      expect(miss, isFalse);
    });
  });

  group('ActressDbMirrorWork.fromGenericWork', () {
    test('通用行转镜像行：站与封面来源站记 chaoliu', () {
      const generic = GenericDbWork(
        id: 1,
        title: '通用作品',
        actress: '波多野结衣',
        code: 'SSIS-001',
        playUrl: 'https://example.com/g.m3u8',
        coverUrl: 'https://example.com/g.jpg',
      );
      final work = ActressDbMirrorWork.fromGenericWork(generic);
      expect(work.site, 'chaoliu');
      expect(work.coverSource, 'chaoliu');
      expect(work.playUrl, 'https://example.com/g.m3u8');
      expect(work.actress, '波多野结衣');
    });
  });

  group('ActressDbMirror.mirrorFile 文件级', () {
    test('与当前库同一文件直接跳过，只读不写', () async {
      final db = MemoryActressDatabase();
      final result = await const ActressDbMirror().mirrorFile(
        sourcePath: '/tmp/some/女优库.db',
        library: db,
        libraryPath: '/tmp/some/女优库.db',
      );
      expect(result.appended, 0);
      expect(result.note, isNotNull);
    });

    test('源文件不存在返回 error，不抛错', () async {
      final db = MemoryActressDatabase();
      final result = await const ActressDbMirror().mirrorFile(
        sourcePath: '/tmp/actress-mirror-test/不存在的库.db',
        library: db,
        libraryPath: '/tmp/actress-mirror-test/女优库.db',
      );
      expect(result.error, isNotNull);
      expect(result.appended, 0);
    });
  });

  group('collectDbMirrorTargets 收集镜像源', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('actress_collect_');
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    File touch(String relative) {
      final file = File('${root.path}/$relative');
      file.createSync(recursive: true);
      return file;
    }

    test('主目录只扫一层：当前库排除、非 .db 排除、子目录不进', () {
      final main = Directory('${root.path}/MYTV/db')..createSync(recursive: true);
      touch('MYTV/db/a.db');
      touch('MYTV/db/B.DB');
      touch('MYTV/db/notes.txt');
      touch('MYTV/db/sub/nested.db');
      final library = File('${main.path}/女优库应用.db')..createSync();
      final targets = collectDbMirrorTargets(
        dbDir: main,
        libraryPath: library.path,
      );
      final names = targets.map((f) => f.path.split('/').last).toSet();
      expect(names, {'a.db', 'B.DB'});
    });

    test('补充目录递归扫：顶层与深层 .db 都收，不存在的目录不崩', () {
      final main = Directory('${root.path}/MYTV/db')..createSync(recursive: true);
      final extra = Directory('${root.path}/女优库')..createSync(recursive: true);
      touch('女优库/top.db');
      touch('女优库/子目录/deep.db');
      touch('女优库/readme.txt');
      final missing = Directory('${root.path}/纯福利/db');
      final targets = collectDbMirrorTargets(
        dbDir: main,
        libraryPath: '${main.path}/女优库应用.db',
        extraDirs: [extra, missing],
      );
      final names = targets.map((f) => f.path.split('/').last).toSet();
      expect(names, {'top.db', 'deep.db'});
    });

    test('同一文件在两个目录里出现只收一次', () {
      final main = Directory('${root.path}/MYTV/db')..createSync(recursive: true);
      final extra = Directory('${root.path}/lz/db')..createSync(recursive: true);
      touch('lz/db/x.db');
      final targets = collectDbMirrorTargets(
        dbDir: main,
        libraryPath: '${main.path}/女优库应用.db',
        extraDirs: [extra, extra],
      );
      expect(targets.length, 1);
      expect(targets.single.path.split('/').last, 'x.db');
    });
  });
}
