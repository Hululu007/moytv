// 影视库（2026-11-20）：番号 slug、站 id、域名、严格结构判定、
// 状态存储、修复站点匹配、探活（本地 HttpServer）、条目转播放详情。
// 纯函数 + 本地 IO 测试，不碰真 sqlite 库：flutter test 里 sqflite
// 没有桌面实现，打不开真库；写库 SQL（追加/去重/补空/域名替换）
// 另在成品库副本上用 python sqlite3 按 SQL 原文重放验证，
// 见 ~/workspace/actress_db_20261120/REPORT.md。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _store = LocalStore(await SharedPreferences.getInstance());
  });
  group('filmSlugCode（与离线 merge.py 的 norm_code 同口径）', () {
    test('JUL-893-uncensored-leak → jul-893', () {
      expect(filmSlugCode('JUL-893-uncensored-leak'), 'jul-893');
    });
    test('MEYD-701全肯 → meyd-701（中文处截断）', () {
      expect(filmSlugCode('MEYD-701全肯'), 'meyd-701');
    });
    test('IPX-707「不可 → ipx-707', () {
      expect(filmSlugCode('IPX-707「不可'), 'ipx-707');
    });
    test('caribbeancom-121722-001 不动', () {
      expect(
        filmSlugCode('caribbeancom-121722-001'),
        'caribbeancom-121722-001',
      );
    });
    test('-uncensored 与 -leak 后缀都去', () {
      expect(filmSlugCode('ssis-123-uncensored'), 'ssis-123');
      expect(filmSlugCode('ssis-123-leak'), 'ssis-123');
    });
    test('空串与纯符号返回空', () {
      expect(filmSlugCode(''), '');
      expect(filmSlugCode('全肯'), '');
    });
  });

  group('filmSiteId / filmPlayHost', () {
    test('whos.tv / mjv011 归一到 whos / mjv', () {
      expect(filmSiteId('whos.tv'), 'whos');
      expect(filmSiteId('whos'), 'whos');
      expect(filmSiteId('mjv011'), 'mjv');
      expect(filmSiteId('mjv011.com'), 'mjv');
      expect(filmSiteId('chaoliu'), 'chaoliu');
    });
    test('播放地址取 host，非 http(s) 返回空', () {
      expect(
        filmPlayHost('https://v.hersav.me/abc/1.m3u8'),
        'v.hersav.me',
      );
      expect(filmPlayHost('正片\$https://x/1.m3u8'), '');
      expect(filmPlayHost(''), '');
      expect(filmPlayHost('not a url'), '');
    });
  });

  group('filmIsStrictVideosSchema', () {
    test('videos + video_actress + video_category 为严格结构', () {
      final schema = classifyGenericTables({
        'videos': [
          'vod_id',
          'title',
          'pic_url',
          'm3u8_url',
          'vod_play_url',
          'vod_play_from',
        ],
        'actresses': ['cate_id', 'name', 'avatar'],
        'video_actress': ['vod_id', 'cate_id'],
        'video_category': ['vod_id', 'main_category'],
      });
      expect(filmIsStrictVideosSchema(schema), isTrue);
    });
    test('缺 video_actress 或 video_category 不走严格路径', () {
      final schema = classifyGenericTables({
        'videos': ['vod_id', 'title', 'm3u8_url'],
      });
      expect(filmIsStrictVideosSchema(schema), isFalse);
    });
    test('作品表不是 videos 不走严格路径', () {
      final schema = classifyGenericTables({
        'films': ['id', 'title', 'url'],
      });
      expect(filmIsStrictVideosSchema(schema), isFalse);
    });
  });

  group('FilmLibraryEntry', () {
    test('转播放详情：单集“正片”，集 id 即直链', () {
      const entry = FilmLibraryEntry(
        vodId: 'jul-893',
        title: '测试标题',
        coverUrl: 'https://x/cover.jpg',
        playUrl: 'https://v.hersav.me/abc/1.m3u8',
        actress: '波多野結衣',
        code: 'jul-893',
        category: '有码',
        site: 'whos.tv',
      );
      final detail = entry.toDramaDetail();
      expect(detail.episodes.length, 1);
      expect(detail.episodes.first.title, '正片');
      expect(detail.episodes.first.id, 'https://v.hersav.me/abc/1.m3u8');
      expect(detail.drama.title, '测试标题');
      // whos 走潮流蜘蛛原始分支（parse=0 直通）。
      expect(detail.drama.source, 'chaoliu');
    });
    test('无地址不可播', () {
      const entry = FilmLibraryEntry(vodId: 'x', title: 't');
      expect(entry.playable, isFalse);
      expect(entry.displayTitle, 't');
    });
    test('displaySubtitle 拼女优/番号/分类/日期', () {
      const entry = FilmLibraryEntry(
        vodId: 'jul-893',
        title: 't',
        actress: '波多野結衣',
        code: 'jul-893',
        category: '有码',
        date: '2026-05-06',
      );
      expect(entry.displaySubtitle, '波多野結衣 · jul-893 · 有码 · 2026-05-06');
    });
  });

  group('FilmLibraryStateStore（sidecar 影视库状态.json）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('film_state_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('域名/失效标记/修复汇总来回存取', () {
      final store = FilmLibraryStateStore(
        file: File('${tempDir.path}/影视库状态.json'),
      );
      const fingerprint = 'videos|actresses';
      store.saveCurrentDomain(fingerprint, 'v.hersav.me');
      expect(store.currentDomain(fingerprint), 'v.hersav.me');
      store.noteObservedDomain(fingerprint, 'v-proxy.imgcaches.cc');
      expect(store.observedDomain(fingerprint), 'v-proxy.imgcaches.cc');
      store.markDead(
        fingerprint,
        site: 'whos',
        code: 'jul-893',
        reason: 'HTTP 404',
      );
      final marks = store.deadMarks(fingerprint);
      expect(marks.length, 1);
      expect(marks.first.code, 'jul-893');
      expect(marks.first.reason, 'HTTP 404');
      store.clearDeadMark(fingerprint, 'whos', 'jul-893');
      expect(store.deadMarks(fingerprint), isEmpty);
      store.saveLastRepair(fingerprint, {
        'checked': 10,
        'fixed': 2,
      });
      expect(store.lastRepair(fingerprint)?['fixed'], 2);
    });

    test('坏文件不崩：读到空状态', () {
      final file = File('${tempDir.path}/影视库状态.json')
        ..writeAsStringSync('not json {{{');
      final store = FilmLibraryStateStore(file: file);
      expect(store.currentDomain('x'), '');
      expect(store.deadMarks('x'), isEmpty);
    });
  });

  group('FilmLinkRepairService.filmMatchSiteId', () {
    const sources = [
      SourceSite('whos', 'whos', ''),
      SourceSite('mjv', 'mjv', ''),
      SourceSite('chaoliu', '潮流AV', ''),
    ];

    test('按站 id 匹配', () {
      const entry = FilmLibraryEntry(
        vodId: 'jul-893',
        title: 't',
        site: 'whos.tv',
        playUrl: 'https://v.hersav.me/a/1.m3u8',
        code: 'jul-893',
      );
      expect(FilmLinkRepairService.filmMatchSiteId(entry, sources), 'whos');
    });

    test('按失效链接域名匹配（旧 whos 代理域名也认）', () {
      const entry = FilmLibraryEntry(
        vodId: 'jul-893',
        title: 't',
        site: '',
        playUrl: 'https://v-proxy.imgcaches.cc/a/1.m3u8',
        code: 'jul-893',
      );
      expect(FilmLinkRepairService.filmMatchSiteId(entry, sources), 'whos');
    });

    test('mjv 媒体域名（streamfastpro）匹配 mjv', () {
      const entry = FilmLibraryEntry(
        vodId: 'ssis-123',
        title: 't',
        site: '',
        playUrl: 'https://cdnfc.streamfastpro.com/a/1.m3u8',
        code: 'ssis-123',
      );
      expect(FilmLinkRepairService.filmMatchSiteId(entry, sources), 'mjv');
    });

    test('按站名匹配', () {
      const entry = FilmLibraryEntry(
        vodId: 'x',
        title: 't',
        site: '潮流AV',
        playUrl: '',
      );
      expect(FilmLinkRepairService.filmMatchSiteId(entry, sources), 'chaoliu');
    });

    test('找不到返回 null，不瞎猜', () {
      const entry = FilmLibraryEntry(
        vodId: 'x',
        title: 't',
        site: '黄色仓库',
        playUrl: 'https://dead.example.com/1.m3u8',
      );
      expect(FilmLinkRepairService.filmMatchSiteId(entry, sources), isNull);
    });
  });

  group('FilmLinkRepairService.probePlayUrl（本地 HttpServer）', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/ok.m3u8') {
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 0-0/100');
          request.response.add([0]);
        } else if (request.uri.path == '/gone.m3u8') {
          request.response.statusCode = 404;
        } else {
          request.response.statusCode = 500;
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    FilmLinkRepairService repair() => FilmLinkRepairService(
      service: _FakeFilmService(),
      repository: FixtureRepository(),
      store: _store,
    );

    test('206 为活', () async {
      final probe = await repair().probePlayUrl(
        'http://127.0.0.1:${server.port}/ok.m3u8',
      );
      expect(probe.status, FilmLinkStatus.alive);
      expect(probe.httpCode, 206);
    });

    test('404 为死', () async {
      final probe = await repair().probePlayUrl(
        'http://127.0.0.1:${server.port}/gone.m3u8',
      );
      expect(probe.status, FilmLinkStatus.dead);
      expect(probe.httpCode, 404);
    });

    test('空地址与非法地址为死', () async {
      final service = repair();
      expect(
        (await service.probePlayUrl('')).status,
        FilmLinkStatus.dead,
      );
      expect(
        (await service.probePlayUrl('not a url')).status,
        FilmLinkStatus.dead,
      );
    });
  });

  group('filmPlainText', () {
    test('去 HTML 标签与实体', () {
      expect(
        filmPlainText('<p>正在查看影片的百科</p><b>标签：</b>人妻&nbsp;&amp;美女'),
        '正在查看影片的百科 标签： 人妻 &美女',
      );
    });
  });

  group('ActressJsonFallback 数据库兜底委托（2026-11-20 18:57）', () {    ActressJsonEntry fakeEntry(String code) => ActressJsonEntry(
      site: 'whos',
      vodId: code,
      vodName: '测试 $code',
      vodPic: '',
      vodActor: '波多野結衣',
      vodDirector: '',
      vodRemarks: '',
      vodPubdate: '',
      vodArea: '',
      vodYear: '',
      vodContent: '',
      vodPlayFrom: 'whos.tv',
      vodPlayUrl: '正片\$https://v.hersav.me/x/$code.m3u8',
      typeName: '成人影片',
      vodCode: code,
      vodActressPic: '',
    );

    test('没接提供方时回空（测试注入实例保持老行为）', () async {
      final fallback = ActressJsonFallback();
      expect(await fallback.dbEntriesForActress('波多野結衣'), isEmpty);
      expect(await fallback.dbEntriesForCode('jul-893'), isEmpty);
    });

    test('接了提供方时原样回数据库行', () async {
      final fallback = ActressJsonFallback(
        filmDb: _FakeFilmDb([fakeEntry('jul-893')]),
      );
      final rows = await fallback.dbEntriesForActress('波多野結衣');
      expect(rows.length, 1);
      expect(rows.first.vodCode, 'jul-893');
      expect(rows.first.playUrl, 'https://v.hersav.me/x/jul-893.m3u8');
      final byCode = await fallback.dbEntriesForCode('jul-893');
      expect(byCode.length, 1);
    });

    test('提供方抛错时回空，不拖垮兜底', () async {
      final fallback = ActressJsonFallback(filmDb: _ThrowingFilmDb());
      expect(await fallback.dbEntriesForActress('波多野結衣'), isEmpty);
      expect(await fallback.dbEntriesForCode('jul-893'), isEmpty);
    });
  });

  group('递增追加（2026-11-20 19:01）', () {
    test('toJsonEntry 多女优转镜像分隔符：/ → 、', () {
      const entry = FilmLibraryEntry(
        vodId: 'jul-893',
        title: 't',
        actress: '波多野結衣 / 吉泽明步',
        code: 'jul-893',
        playUrl: 'https://v.hersav.me/x/1.m3u8',
      );
      // 镜像按 [,，、] 拆名，/ 不拆会把两人拼成一个人。
      expect(entry.toJsonEntry().vodActor, '波多野結衣、吉泽明步');
    });

    test('filmEntriesForMirror：跳过无女优名与无番号无标题的行', () {
      const films = [
        FilmLibraryEntry(
          vodId: 'jul-893',
          title: 't',
          actress: '波多野結衣',
          code: 'jul-893',
        ),
        FilmLibraryEntry(vodId: 'x1', title: '无女优', code: 'abc-1'),
        FilmLibraryEntry(vodId: 'x2', title: '有标题', actress: '有人'),
        FilmLibraryEntry(vodId: 'x3', title: '', actress: '有人'),
      ];
      final out = FilmLibraryService.filmEntriesForMirror(films);
      expect(out.length, 2);
      expect(out.first.vodCode, 'jul-893');
      expect(out.last.vodName, '有标题');
    });

    test('追加断点存取：换库作废、完成标记', () {
      final tempDir = Directory.systemTemp.createTempSync('film_append_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final store = FilmLibraryStateStore(
        file: File('${tempDir.path}/影视库状态.json'),
      );
      const fingerprint = 'videos|actresses';
      expect(store.appendCheckpoint(fingerprint), isNull);
      store.saveAppendCheckpoint(fingerprint, {
        'dbPath': '/a/女优库.db',
        'fileSize': 123,
        'offset': 400,
        'done': false,
      });
      final checkpoint = store.appendCheckpoint(fingerprint);
      expect(checkpoint?['offset'], 400);
      expect(checkpoint?['done'], isFalse);
      store.saveAppendCheckpoint(fingerprint, {
        'dbPath': '/a/女优库.db',
        'fileSize': 123,
        'offset': 323798,
        'done': true,
      });
      expect(store.appendCheckpoint(fingerprint)?['done'], isTrue);
    });

    test('镜像进内存库：同蜘蛛同番号只留一条、重跑不重复加', () async {
      final db = MemoryActressDatabase();
      const films = [
        FilmLibraryEntry(
          vodId: 'jul-893',
          title: 't',
          actress: '波多野結衣',
          code: 'jul-893',
          site: 'whos.tv',
          playUrl: 'https://v.hersav.me/x/1.m3u8',
        ),
        FilmLibraryEntry(
          vodId: 'jul-893-uncensored-leak',
          title: 't2',
          actress: '波多野結衣',
          code: 'jul-893',
          site: 'whos.tv',
          playUrl: 'https://v.hersav.me/x/2.m3u8',
        ),
        FilmLibraryEntry(
          vodId: 'ssis-174',
          title: 't3',
          actress: '波多野結衣',
          code: 'ssis-174',
          site: 'whos.tv',
          playUrl: 'https://v.hersav.me/x/3.m3u8',
        ),
      ];
      final batch = FilmLibraryService.filmEntriesForMirror(films);
      expect(batch.length, 3);
      await mirrorActressJsonEntriesToDb(db, batch);
      final persons = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '波多野結衣',
        offset: 0,
        limit: 10,
      );
      expect(persons.length, 1);
      final works = await db.worksForPerson(
        persons.first.localId,
        offset: 0,
        limit: 10,
      );
      // 同站同番号（jul-893 与 -uncensored-leak）只留一条作品行；
      // 不同番号（ssis-174）另起一条。两条可播线路都在影视库 db 里，
      // 播的时候走数据库兜底各取各的地址。
      expect(works.length, 2);
      // 重跑不重复加。
      await mirrorActressJsonEntriesToDb(db, batch);
      final works2 = await db.worksForPerson(
        persons.first.localId,
        offset: 0,
        limit: 10,
      );
      expect(works2.length, 2);
    });
  });
}

/// 兜底委托测试用的假数据库提供方。
class _FakeFilmDb implements FilmDbFallbackProvider {
  _FakeFilmDb(this.rows);

  final List<ActressJsonEntry> rows;

  @override
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  }) async => rows;

  @override
  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  }) async => rows;
}

class _ThrowingFilmDb implements FilmDbFallbackProvider {
  @override
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  }) async => throw StateError('库打不开');

  @override
  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  }) async => throw StateError('库打不开');
}

// 探活测试用的假依赖：probePlayUrl 只用 HttpClient，不碰 service/
// repository/store 的真实现；store 用树里既定做法（模拟偏好值）。
class _FakeFilmService extends FilmLibraryService {
  _FakeFilmService() : super(database: MemoryActressDatabase());
}

late LocalStore _store;
