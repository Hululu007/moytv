// 女优库合并新规（2026-11-20 用户令，取代 2026-11-18 番号键去重）：
// 同番号两站都留、同名合并、没有的新增；只有番号与播放链接完全
// 一样才算重复（爬取文件递增更新口径）；列表计数是叠加真数。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';

Map<String, dynamic> _row({
  required String vodId,
  required String code,
  required String actor,
  String playUrl = '',
  String typeName = '中文字幕',
}) => ActressJsonEntry(
  site: 'mjv',
  vodId: vodId,
  vodName: '测试作品 $code',
  vodPic: 'https://x/$vodId.jpg',
  vodActor: actor,
  vodDirector: '',
  vodRemarks: '高清',
  vodPubdate: '2026-01-01',
  vodArea: '日本',
  vodYear: '2026',
  vodContent: '<p>测试作品 $code</p>',
  vodPlayFrom: 'mjv011',
  vodPlayUrl: playUrl,
  typeName: typeName,
  vodCode: code,
  vodActressPic: '',
).toRow();

String _doc(List<Map<String, dynamic>> rows) => jsonEncode({
  'list': rows,
  'parse': 0,
  'jx': 0,
  'last_update': '2026-11-20T00:00:00',
});

void main() {
  group('合并新规：按（站，番号）去重', () {
    late MemoryActressDatabase db;

    setUp(() {
      db = MemoryActressDatabase();
    });

    Future<ActressPerson> seedPerson() async {
      final person = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'M1',
          name: '测试演员',
          sex: 'female',
        ),
      );
      return person!;
    }

    test('同番号两站都留，各算一条可播线路，计数是叠加真数', () async {
      final person = await seedPerson();
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-123', date: '2024-01-01'),
      ], site: 'chaoliu');
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
      ], site: 'whos');
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(2));
      expect(works.map((w) => w.codeKey).toSet(), {'SSIS123'});
      expect(works.map((w) => w.site).toSet(), {'chaoliu', 'whos'});
      expect((await db.personById(person.localId))!.worksCount, 2);
    });

    test('同站同番号只留一条（站内仍去重）', () async {
      final person = await seedPerson();
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-123'),
        RosterFilm(code: 'SSIS-00123'),
      ], site: 'chaoliu');
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect((await db.personById(person.localId))!.worksCount, 1);
    });

    test('无番号按（站，标题）去重：同站同标题一条、换站两条', () async {
      final person = await seedPerson();
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: '', title: '无番号标题'),
      ], site: 'chaoliu');
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: '', title: '无番号标题'),
      ], site: 'whos');
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(2));
      expect(works.map((w) => w.site).toSet(), {'chaoliu', 'whos'});
    });

    test('同名合并：两家名册同一人只一个', () async {
      final first = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'C1',
          name: '测试演员',
          sex: 'female',
        ),
      );
      final second = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'W1',
          name: '测试演员',
          sex: 'female',
        ),
      );
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second!.localId, first!.localId);
      final all = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 10,
      );
      expect(all, hasLength(1));
    });

    test('没有的新增：新番号进库', () async {
      final person = await seedPerson();
      await db.attachCover(
        personId: person.localId,
        codeKey: 'ABW999',
        titleKey: 'abw999',
        codeDisplay: 'ABW-999',
        title: 'ABW-999 新发现',
        coverSource: 'test-site',
        coverDramaId: 'd1',
        coverUrl: 'https://cover/1.jpg',
        site: 'test-site',
      );
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(works.single.site, 'test-site');
      expect(works.single.codeKey, 'ABW999');
    });

    test('attachCover：同站行补封面，跨站行只补封面并按新站新增一行', () async {
      final person = await seedPerson();
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-123'),
      ], site: 'chaoliu');
      // whos 命中同一番号：chaoliu 行补上封面，同时新增 whos 行。
      await db.attachCover(
        personId: person.localId,
        codeKey: 'SSIS123',
        titleKey: 'ssis123',
        coverSource: 'whos',
        coverDramaId: 'd-whos',
        coverUrl: 'https://cover/whos.jpg',
        site: 'whos',
      );
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(2));
      final chaoliu = works.firstWhere((w) => w.site == 'chaoliu');
      final whos = works.firstWhere((w) => w.site == 'whos');
      expect(chaoliu.coverUrl, 'https://cover/whos.jpg');
      expect(whos.coverUrl, 'https://cover/whos.jpg');
      expect(whos.fromCrossSite, isTrue);
      expect((await db.personById(person.localId))!.worksCount, 2);
    });

    test('attachCover：同站命中只补本行，不新增第二行', () async {
      final person = await seedPerson();
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-123'),
      ], site: 'chaoliu');
      await db.attachCover(
        personId: person.localId,
        codeKey: 'SSIS123',
        titleKey: 'ssis123',
        coverSource: 'chaoliu',
        coverDramaId: 'd1',
        coverUrl: 'https://cover/1.jpg',
        site: 'chaoliu',
      );
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(works.single.coverUrl, 'https://cover/1.jpg');
    });

    test('attachCover：不传 site 的旧调用行为不变', () async {
      final person = await seedPerson();
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-123'),
      ]);
      await db.attachCover(
        personId: person.localId,
        codeKey: 'SSIS123',
        titleKey: 'ssis123',
        coverSource: 'site-a',
        coverDramaId: 'd1',
        coverUrl: 'https://cover/1.jpg',
      );
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(works.single.coverUrl, 'https://cover/1.jpg');
    });
  });

  group('兜底合并：番号+链接完全一样才过滤', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    Future<ActressJsonFallback> loadWithLocal(
      String bundledMjv,
      String? localMjv,
    ) async {
      if (localMjv != null) {
        final dir = Directory('${temp.path}/actress_json')
          ..createSync(recursive: true);
        File('${dir.path}/mjv.json').writeAsStringSync(localMjv);
      }
      final fallback = ActressJsonFallback(
        assetReader: (asset) async =>
            asset.endsWith('mjv011.json') ? bundledMjv : _doc([]),
        documentsDir: temp,
      );
      await fallback.load();
      return fallback;
    }

    test('同 mergeKey 同链接：本地行被跳过，只留一条', () async {
      final bundled = _doc([
        _row(
          vodId: 'id-1',
          code: 'SSIS-123',
          actor: '测试演员',
          playUrl: '正片\$https://x/1.m3u8',
        ),
      ]);
      final local = _doc([
        _row(
          vodId: 'id-1',
          code: 'SSIS-123',
          actor: '测试演员',
          playUrl: '正片\$https://x/1.m3u8',
        ),
      ]);
      final fallback = await loadWithLocal(bundled, local);
      expect(fallback.counts['mjv'], 1);
      expect(fallback.entriesForCode('SSIS123'), hasLength(1));
    });

    test('同 mergeKey 不同链接：本地行替换随包行，仍一条', () async {
      final bundled = _doc([
        _row(
          vodId: 'id-1',
          code: 'SSIS-123',
          actor: '测试演员',
          playUrl: '正片\$https://x/old.m3u8',
        ),
      ]);
      final local = _doc([
        _row(
          vodId: 'id-1',
          code: 'SSIS-123',
          actor: '测试演员',
          playUrl: '正片\$https://x/new.m3u8',
        ),
      ]);
      final fallback = await loadWithLocal(bundled, local);
      expect(fallback.counts['mjv'], 1);
      expect(
        fallback.entriesForCode('SSIS123').single.vodPlayUrl,
        '正片\$https://x/new.m3u8',
      );
    });

    test('两站同一番号各留一条（合并不跨站）', () async {
      final bundled = _doc([
        _row(
          vodId: 'id-1',
          code: 'SSIS-123',
          actor: '测试演员',
          playUrl: '正片\$https://x/1.m3u8',
        ),
      ]);
      final fallback = ActressJsonFallback(
        assetReader: (asset) async => asset.endsWith('mjv011.json')
            ? bundled
            : _doc([
                _row(
                  vodId: 'id-2',
                  code: 'SSIS-123',
                  actor: '测试演员',
                  playUrl: '正片\$https://y/1.m3u8',
                ),
              ]),
        documentsDir: temp,
      );
      await fallback.load();
      final rows = fallback.entriesForCode('SSIS123');
      expect(rows, hasLength(2));
      expect(rows.map((e) => e.site).toSet(), {'mjv', 'whos'});
    });
  });
}
