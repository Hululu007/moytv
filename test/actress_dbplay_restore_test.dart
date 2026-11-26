import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_av_style.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 本地库秒开秒播恢复回归（2026-11-26 23:54，诊断报告
/// moyi_dbplay_diag_20261126 第七节 7.4）：
/// 1. 库里有 who's 直链的作品，点播不等竞速即以库里第一条
///    地址开详情页（探针全程挂起也照样开）；
/// 2. 库地址腿探针慢首字节（12 秒才回 #EXTM3U）：预算须
///    ≥15 秒，慢行验进会话缓存，第二次点播直接用已验活行；
/// 3. 库里无此番号：仍走竞速等待，全灭提示走「暂无可播
///    线路」口径，不提「库里没读出」。

class _DbPlayRepository extends FixtureRepository {
  Map<String, DramaDetail> detailsById = {};
  Map<String, String> resolveUrls = {};
  final resolveCalls = <String>[];

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      detailsById[drama.id] ?? super.detail(drama);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async {
    resolveCalls.add(drama.id);
    return PlaybackPlan(
      url: resolveUrls[drama.id] ?? 'https://example.test/synthetic.mp4',
    );
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

/// 假影视库（第一档）：按番号回 DB 行；名字路回空。
class _FakeFilmDb implements FilmDbFallbackProvider {
  _FakeFilmDb(this.rowsByCode);

  final Map<String, List<ActressJsonEntry>> rowsByCode;

  @override
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  }) async => const [];

  @override
  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  }) async => rowsByCode[codeKey] ?? const [];
}

ActressJsonEntry _dbEntry({
  required String vodId,
  required String playUrl,
  required String vodName,
  String site = 'whos',
}) => ActressJsonEntry(
  site: site,
  vodId: vodId,
  vodName: vodName,
  vodPic: '',
  vodActor: '女演员甲',
  vodDirector: '',
  vodRemarks: '',
  vodPubdate: '',
  vodArea: '',
  vodYear: '',
  vodContent: '',
  vodPlayFrom: site,
  vodPlayUrl: '正片\$$playUrl',
  typeName: '',
  vodCode: 'SSIS-00123',
  vodActressPic: '',
);

/// 探针永远不回（竞速永远产不出赢家）：首播若等竞速就永远
/// 开不了页。
Future<FeedProbeResponse> _hangingProbe(
  String url,
  Map<String, String> headers,
  Duration timeout,
) => Completer<FeedProbeResponse>().future;

/// 探针全判死。
Future<FeedProbeResponse> _allDeadProbe(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async =>
    const FeedProbeResponse(statusCode: 404, headers: {}, headBytes: []);

void main() {
  late MemoryActressDatabase db;
  late _DbPlayRepository repository;
  late LocalStore store;

  setUp(() async {
    db = MemoryActressDatabase();
    repository = _DbPlayRepository();
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    // MissAV 竞速腿对测试番号回空详情（没集数），不抢戏；
    // MissAV 竞速本身另有专测。
    repository.detailsById['SSIS123'] = DramaDetail(
      Drama(id: 'SSIS123', source: 'missav', title: 'SSIS-00123'),
      const [],
    );
    repository.detailsById['ABF404'] = DramaDetail(
      Drama(id: 'ABF404', source: 'missav', title: 'ABF-404'),
      const [],
    );
  });

  /// 错误面板渲染会触发一条既有框架断言（StatusPanel 内
  /// ExpansionTile 含 ListTile），与本批改动无关，只放行这一条。
  void suppressKnownListTileAssertion() {
    final original = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.toString().contains(
        'ListTile background color or ink splashes',
      )) {
        return;
      }
      original?.call(details);
    };
    addTearDown(() {
      FlutterError.onError = original;
    });
  }

  Future<ActressPerson> seedPerson(String code) async {
    final person = (await db.upsertRosterPerson(
      const RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'X1',
        name: '女演员甲',
        sex: 'female',
      ),
    ))!;
    await db.upsertWorks(person.localId, [
      RosterFilm(code: code, date: '2024-01-01'),
    ]);
    return (await db.personById(person.localId))!;
  }

  Future<void> pumpDetailPage(
    WidgetTester tester, {
    required String code,
    FilmDbFallbackProvider? filmDb,
    FeedProbeFetch? verifyFetch,
  }) async {
    final person = await seedPerson(code);
    await tester.pumpWidget(
      MaterialApp(
        home: ActressDetailPage(
          localId: person.localId,
          repository: repository,
          store: store,
          database: db,
          filmDb: filmDb,
          verifyFetch: verifyFetch,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 有界等待详情页出现（播放器内有定时器，不用 pumpAndSettle）。
  Future<bool> pumpUntilDetail(
    WidgetTester tester, {
    int rounds = 30,
    Duration step = const Duration(milliseconds: 100),
  }) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(step);
      if (find.byType(DetailScreen).evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('库里有地址：探针全程挂起也不等竞速，第一条直开详情页', (tester) async {
    suppressKnownListTileAssertion();
    await pumpDetailPage(
      tester,
      code: 'SSIS-00123',
      filmDb: _FakeFilmDb({
        'SSIS123': [
          _dbEntry(
            vodId: 'db-row-1',
            playUrl: 'https://example.test/whos-ssis.m3u8',
            vodName: 'SSIS-00123 库里标题',
          ),
        ],
      }),
      verifyFetch: _hangingProbe,
    );
    await tester.tap(find.byType(AvWorkCard).first);
    // 3 秒（假时间）内必须开页：旧口径要等竞速赢家、探针
    // 挂起时 40 秒也开不了。
    final opened = await pumpUntilDetail(tester);
    expect(opened, isTrue);
    expect(find.text('SSIS-00123 库里标题'), findsWidgets);
    expect(find.text('正在搜索可播线路…'), findsNothing);
    // 收尾：把竞速各路的超时计时器（在线 25 秒 / py 30 秒
    // 等）在假时间里放干，免得测试框架报「还有计时器没走
    // 完」。探针本身挂起不产生计时器，竞速永远不产出赢家
    // 也不影响已开的页。
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });

  testWidgets('慢首字节：库地址腿预算≥15 秒，慢行验进缓存、二次点播用已验活行', (tester) async {
    suppressKnownListTileAssertion();
    final probeTimeouts = <String, Duration>{};
    Future<FeedProbeResponse> slowProbe(
      String url,
      Map<String, String> headers,
      Duration timeout,
    ) async {
      probeTimeouts[url] = timeout;
      if (url.contains('slow-whos')) {
        // who's 式慢首字节：12 秒才回 #EXTM3U。预算不够
        // 12 秒的探针等不到，直接按探针超时处理。
        if (timeout < const Duration(seconds: 12)) {
          throw TimeoutException('慢首字节');
        }
        await Future<void>.delayed(const Duration(seconds: 12));
        return FeedProbeResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
          headBytes: '#EXTM3U\n#EXT-X-VERSION:3\n'.codeUnits,
        );
      }
      return const FeedProbeResponse(
        statusCode: 404,
        headers: {},
        headBytes: [],
      );
    }

    repository.resolveUrls = {
      'json:mjv:dead-row': 'https://example.test/dead-first.mp4',
      'json:whos:slow-row': 'https://example.test/slow-whos.m3u8',
    };
    await pumpDetailPage(
      tester,
      code: 'SSIS-00123',
      filmDb: _FakeFilmDb({
        'SSIS123': [
          // 两行分属不同站：地址池按 站|番号 去重，同站同番号
          // 只留一条（既有口径），同番号双地址本就来自不同站。
          _dbEntry(
            vodId: 'dead-row',
            playUrl: 'https://example.test/dead-first.mp4',
            vodName: 'SSIS-00123 死行标题',
            site: 'mjv',
          ),
          _dbEntry(
            vodId: 'slow-row',
            playUrl: 'https://example.test/slow-whos.m3u8',
            vodName: 'SSIS-00123 慢行标题',
          ),
        ],
      }),
      verifyFetch: slowProbe,
    );
    await tester.tap(find.byType(AvWorkCard).first);
    // 首播直开库里第一条（死行）——秒开口径下首播不归探针管。
    expect(await pumpUntilDetail(tester), isTrue);
    expect(find.text('SSIS-00123 死行标题'), findsWidgets);
    // 让后台竞速跑完：死行判死、慢行 12 秒后验活进缓存。
    for (var i = 0; i < 160; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (probeTimeouts.containsKey('https://example.test/slow-whos.m3u8')) {
        break;
      }
    }
    for (var i = 0; i < 140; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 库地址腿给慢行的探针预算必须 ≥15 秒（5 秒旧尺下慢行
    // 永远验不过、缓存永远建不起来）。
    expect(
      probeTimeouts['https://example.test/slow-whos.m3u8'],
      greaterThanOrEqualTo(const Duration(seconds: 15)),
    );
    // 关掉详情页，再点同一部：缓存里已有验活的慢行，直接
    // 用它开页（不再是库里第一条死行）。
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(DetailScreen).evaluate().isEmpty) break;
    }
    expect(find.byType(DetailScreen), findsNothing);
    await tester.tap(find.byType(AvWorkCard).first);
    expect(await pumpUntilDetail(tester), isTrue);
    expect(find.text('SSIS-00123 慢行标题'), findsWidgets);
    expect(find.text('SSIS-00123 死行标题'), findsNothing);
    // 收尾：放干第二轮竞速的窗口/超时计时器（同第一条）。
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });

  testWidgets('库里无此番号：走竞速等待，全灭提示不提库里没读出', (tester) async {
    suppressKnownListTileAssertion();
    await pumpDetailPage(
      tester,
      code: 'ABF-404',
      filmDb: _FakeFilmDb(const {}),
      verifyFetch: _allDeadProbe,
    );
    await tester.tap(find.byType(AvWorkCard).first);
    // 竞速全灭后出提示：最多等 45 秒（假时间）。
    var messaged = false;
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.textContaining('暂无可播线路').evaluate().isNotEmpty) {
        messaged = true;
        break;
      }
    }
    expect(messaged, isTrue);
    expect(find.byType(DetailScreen), findsNothing);
    expect(find.textContaining('库里没读出'), findsNothing);
  });
}
