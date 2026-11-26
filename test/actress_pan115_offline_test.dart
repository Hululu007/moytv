// 115 离线接入（2026-11-26）：接口参照星辰115 源码
// （Pan115Repository/ApiModels/CodeExtractor）造夹具——
// ssp 提交载荷与响应判读、任务列表解析（info_hash/
// percentDone/status）、配额与默认目录解析、提码规则与
// 番号分档匹配、infohash 提取纯逻辑验；详情页 115 区用
// 假网关验四态：未登录提示、已存出播放行、无文件有磁力
// 自动提交一次、无文件无磁力不显示。真提交要真账号 +
// 出口，属手机终验，这里只验解析与接线。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/javdb_api.dart';
import 'package:moyi/cloud_drive/cloud_115_offline.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart' show CloudDirectLink;
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

String _envelope(Object? data) => jsonEncode({'success': true, 'data': data});

void main() {
  group('提交响应判读', () {
    test('明文 state true 算成功、false 不算', () {
      expect(
        pan115SubmitResultOf(utf8.encode('{"state":true}')).ok,
        isTrue,
      );
      expect(
        pan115SubmitResultOf(utf8.encode('{"state":false}')).ok,
        isFalse,
      );
      expect(pan115SubmitResultOf(utf8.encode('<html>')).ok, isFalse);
    });

    test('data 是加密字符串时解出 info_hash（解密走注入替身验分支）', () {
      final result = pan115SubmitResultOf(
        utf8.encode(jsonEncode({'state': true, 'data': 'CIPHER'})),
        decrypt: (_) =>
            utf8.encode(jsonEncode({'info_hash': 'ABCDEF0123'})),
      );
      expect(result.ok, isTrue);
      expect(result.infoHash, 'abcdef0123');
      final fromMap = pan115SubmitResultOf(
        utf8.encode(
          jsonEncode({
            'state': true,
            'data': {'info_hash': 'ABCDEF0123'},
          }),
        ),
      );
      expect(fromMap.infoHash, 'abcdef0123');
    });

    test('提交载荷照星辰 payload：ac 在载荷里、app_ver 36.2.28', () {
      final payload = jsonDecode(
        pan115SubmitPayloadOf('magnet:?xt=urn:btih:abc', '777'),
      ) as Map<String, dynamic>;
      expect(payload, {
        'url': 'magnet:?xt=urn:btih:abc',
        'wp_path_id': '777',
        'ac': 'add_task_url',
        'app_ver': '36.2.28',
      });
    });
  });

  group('任务列表解析', () {
    test('顶层 tasks：percentDone 字符串、status 1 下载中', () {
      final tasks = pan115TasksOf(
        jsonEncode({
          'state': true,
          'count': 1,
          'tasks': [
            {
              'info_hash': 'ABCDEF0123',
              'name': 'SSIS-001.mp4',
              'size': 1234,
              'percentDone': '45',
              'status': 1,
              'wp_path_id': '0',
            },
          ],
        }),
      );
      expect(tasks, hasLength(1));
      expect(tasks.single.infoHash, 'abcdef0123');
      expect(tasks.single.name, 'SSIS-001.mp4');
      expect(tasks.single.percent, 0.45);
      expect(tasks.single.done, isFalse);
    });

    test('status 2 判完成、进度满格也判完成', () {
      final tasks = pan115TasksOf(
        jsonEncode({
          'tasks': [
            {'info_hash': 'h1', 'name': '甲', 'percentDone': 30, 'status': 2},
            {'info_hash': 'h2', 'name': '乙', 'percentDone': 100, 'status': 1},
            {'info_hash': 'h3', 'name': '丙', 'percentDone': 0, 'status': -1},
          ],
        }),
      );
      expect(tasks[0].done, isTrue);
      expect(tasks[1].done, isTrue);
      expect(tasks[2].done, isFalse);
    });

    test('坏响应回空表', () {
      expect(pan115TasksOf('not json'), isEmpty);
      expect(pan115TasksOf('{"state":true}'), isEmpty);
    });
  });

  group('客户端（星辰 ssp 通道）', () {
    test('提交走 /lixianssp/ 加密表单、列表走 web task_lists、配额可读', () async {
      final calls = <(String, Uri, Map<String, String>?, String?)>[];
      final client = Pan115OfflineClient(
        client: http.Client(),
        cookie: 'UID=1',
        send: (method, url, {form, userAgent}) async {
          calls.add((method, url, form, userAgent));
          if (url.path.contains('downpath')) {
            return utf8.encode(
              jsonEncode({
                'state': true,
                'data': [
                  {'file_name': '云下载', 'file_id': '777'},
                ],
              }),
            );
          }
          if (url.path.endsWith('/lixianssp/')) {
            return utf8.encode(jsonEncode({'state': true, 'data': ''}));
          }
          if (url.query.contains('get_quota_info')) {
            return utf8.encode(
              jsonEncode({
                'data': {'quota': 100, 'used': 30},
              }),
            );
          }
          return utf8.encode(
            jsonEncode({
              'state': true,
              'tasks': [
                {
                  'info_hash': 'AA',
                  'name': 'x.mp4',
                  'percentDone': 10,
                  'status': 1,
                },
              ],
            }),
          );
        },
      );
      List<int>? sentPlain;
      final submit = await client.submitOffline(
        'magnet:?xt=urn:btih:abc',
        encrypt: (data) {
          sentPlain = data;
          return 'ENC';
        },
      );
      expect(submit.ok, isTrue);
      final post = calls.firstWhere((c) => c.$1 == 'POST');
      expect(post.$2.path, '/lixianssp/');
      expect(post.$3, {'data': 'ENC'});
      expect(post.$4, pan115CloudUserAgent);
      final plain = jsonDecode(utf8.decode(sentPlain!));
      expect(plain['url'], 'magnet:?xt=urn:btih:abc');
      expect(plain['ac'], 'add_task_url');
      expect(plain['app_ver'], '36.2.28');
      expect(plain['wp_path_id'], '777');
      final tasks = await client.listTasks();
      expect(tasks.single.percent, 0.1);
      final listCall = calls.firstWhere(
        (c) => c.$2.query.contains('task_lists'),
      );
      expect(listCall.$2.query, contains('stat=0'));
      expect(await client.quota(), (total: 100, used: 30));
      expect(await client.downpathName(), '云下载');
    });

    test('默认目录读不到时 wp_path_id 回落 0', () async {
      List<int>? sentPlain;
      final client = Pan115OfflineClient(
        client: http.Client(),
        cookie: 'UID=1',
        send: (method, url, {form, userAgent}) async {
          if (url.path.contains('downpath')) throw StateError('网络断');
          return utf8.encode('{"state":true}');
        },
      );
      await client.submitOffline(
        'magnet:?xt=urn:btih:abc',
        encrypt: (data) {
          sentPlain = data;
          return 'ENC';
        },
      );
      final plain = jsonDecode(utf8.decode(sentPlain!));
      expect(plain['wp_path_id'], '0');
    });

    test('配额凑不齐回 null，不糊弄', () {
      expect(pan115QuotaOf('{"data":{"used":5}}'), isNull);
      expect(
        pan115QuotaOf('{"data":{"total_count":200,"used_count":50}}'),
        (total: 200, used: 50),
      );
      expect(
        pan115QuotaOf('{"data":{"used":30,"surplus":70}}'),
        (total: 100, used: 30),
      );
    });
  });

  group('提码与番号挑文件', () {
    CloudDriveFile file(
      String id,
      String name, {
      bool folder = false,
      CloudFileKind kind = CloudFileKind.video,
    }) => CloudDriveFile(
      id: id,
      name: name,
      isFolder: folder,
      kind: kind,
      extra: {'pickcode': 'pc-$id'},
    );

    test('提码各制式（照 CodeExtractor）', () {
      expect(pan115ExtractCode('SSIS-001.mp4'), 'SSIS-001');
      expect(pan115ExtractCode('[sev] SSIS-001-C.mp4'), 'SSIS-001');
      expect(pan115ExtractCode('FC2-PPV-1234567.mkv'), 'FC2-PPV-1234567');
      expect(pan115ExtractCode('HEYZO-1234.mp4'), 'HEYZO-1234');
      expect(pan115ExtractCode('050115-071.mp4'), '050115-071');
      expect(pan115ExtractCode('SSIS001.mp4'), 'SSIS-001');
      expect(pan115ExtractCode('T28-512.mp4'), 'T28-512');
      expect(pan115ExtractCode('91CM-189.mp4'), '91CM-189');
      expect(pan115ExtractCode('n1234.mp4'), 'N1234');
    });

    test('提码挡假番号（年份/编码词/假日期）', () {
      expect(pan115ExtractCode('Movie.2024.1080p.mp4'), isNull);
      expect(pan115ExtractCode('HEVC-123.mp4'), isNull);
      expect(pan115ExtractCode('131224-01.mp4'), isNull);
      expect(pan115ExtractCode('普通电影.mp4'), isNull);
    });

    test('精确档优先、提码不同不回退包含档', () {
      final files = [
        file('a', 'SSIS-0010.mp4'),
        file('b', 'ssis001-c.mp4'),
      ];
      expect(pan115FileForCode(files, 'SSIS-001')?.id, 'b');
      expect(
        pan115FileForCode([file('a', 'SSIS-0010.mp4')], 'SSIS-001'),
        isNull,
      );
    });

    test('提不出码才走包含档', () {
      final files = [file('a', 'ABC-1234567.mp4')];
      expect(pan115FileForCode(files, 'ABC-1234567')?.id, 'a');
    });

    test('跳过文件夹与非视频、找不到回 null', () {
      final files = [
        file('d', 'SSIS-001', folder: true),
        file('t', 'SSIS-001.txt', kind: CloudFileKind.other),
        file('v', 'SSIS-001.mp4'),
      ];
      expect(pan115FileForCode(files, 'SSIS-001')?.id, 'v');
      expect(pan115FileForCode(files, 'IPX-999'), isNull);
      expect(pan115FileForCode(files, ''), isNull);
    });
  });

  group('已提交记录', () {
    test('recordSubmitted 后 submittedHashes 能读回、重复记不膨胀', () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = EnginePan115Gateway(
        engine: () async => throw StateError('测试不该用到引擎'),
      );
      expect(await gateway.submittedHashes(), isEmpty);
      await gateway.recordSubmitted('abc');
      await gateway.recordSubmitted('abc');
      await gateway.recordSubmitted('def');
      expect(await gateway.submittedHashes(), {'abc', 'def'});
    });
  });

  group('详情页 115 区', () {
    setUpAll(() {
      SourceSite.importedSites['chaoliu'] = const SourceSite(
        'chaoliu',
        '潮流',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originImport,
        importType: 'py',
      );
    });

    tearDownAll(() {
      SourceSite.importedSites.remove('chaoliu');
    });

    const drama = Drama(
      id: 'chaoliu:SSIS-001',
      source: 'chaoliu',
      title: 'SSIS-001 样本影片',
      category: '成人影片',
      onlineDate: '2024-06-15',
      tags: ['SSIS-001'],
      episodes: 1,
    );

    Future<void> pumpDetail(
      WidgetTester tester, {
      required Pan115Gateway gateway,
      JavdbApiClient? javdbClient,
    }) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            drama: drama,
            repository: _EmptyDetailRepository(),
            store: store,
            javdbStillsClient: javdbClient,
            pan115Gateway: gateway,
          ),
        ),
      );
    }

    Future<bool> waitFor(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (finder.evaluate().isNotEmpty) return true;
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 100));
      }
      return false;
    }

    JavdbApiClient javdbClient({required bool withMagnet}) {
      return JavdbApiClient(
        fetch: (url) async {
          if (url.contains('api/v2/search')) {
            return _envelope({
              'movies': [
                {
                  'id': 'm1',
                  'number': 'SSIS-001',
                  'title': '标题',
                  'thumb_url': 'https://c0.jdbstatic.com/thumbs/m1.jpg',
                  'cover_url': 'https://c0.jdbstatic.com/covers/m1.jpg',
                },
              ],
            });
          }
          if (url.contains('/magnets')) {
            return _envelope({
              'magnets': withMagnet
                  ? [
                      {
                        'hash': 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
                        'name': 'SSIS-001 HD',
                        'size': 2048,
                        'created_at': '2024-06-15',
                      },
                    ]
                  : const [],
            });
          }
          if (url.contains('/reviews')) {
            return _envelope({'reviews': const []});
          }
          if (url.contains('api/v1/movies/')) {
            return _envelope({'preview_images': const []});
          }
          throw StateError('未预期的网址：$url');
        },
      );
    }

    testWidgets('未登录 115 只显示一行提示、不提交', (tester) async {
      final gateway = _FakePan115Gateway(loggedIn: false);
      await pumpDetail(tester, gateway: gateway);
      expect(
        await waitFor(
          tester,
          find.byKey(const ValueKey('actress-pan115-section')),
        ),
        isTrue,
      );
      expect(find.textContaining('115 未登录'), findsOneWidget);
      expect(gateway.submitCalls, isEmpty);
    });

    testWidgets('网盘已存该番号文件时出播放行', (tester) async {
      final gateway = _FakePan115Gateway(
        loggedIn: true,
        file: const CloudDriveFile(
          id: 'f1',
          name: 'SSIS-001.mp4',
          isFolder: false,
          kind: CloudFileKind.video,
        ),
      );
      await pumpDetail(tester, gateway: gateway);
      expect(
        await waitFor(tester, find.byKey(const ValueKey('actress-pan115-play'))),
        isTrue,
      );
      expect(find.text('SSIS-001.mp4'), findsOneWidget);
      expect(gateway.submitCalls, isEmpty);
    });

    testWidgets('没存但有 JavDB 磁力时自动提交一次并明示', (tester) async {
      final gateway = _FakePan115Gateway(loggedIn: true);
      await pumpDetail(
        tester,
        gateway: gateway,
        javdbClient: javdbClient(withMagnet: true),
      );
      expect(
        await waitFor(tester, find.textContaining('已提交 115 离线')),
        isTrue,
      );
      expect(gateway.submitCalls, [
        'magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01'
        '&dn=${Uri.encodeComponent('[javdb.com]SSIS-001 HD')}',
      ]);
      expect(gateway.recordedHashes, [
        'abcdef0123456789abcdef0123456789abcdef01',
      ]);
    });

    testWidgets('没存也没磁力时整区不显示、不提交', (tester) async {
      final gateway = _FakePan115Gateway(loggedIn: true);
      await pumpDetail(
        tester,
        gateway: gateway,
        javdbClient: javdbClient(withMagnet: false),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('actress-pan115-section')), findsNothing);
      expect(gateway.submitCalls, isEmpty);
    });
  });
}

class _FakePan115Gateway implements Pan115Gateway {
  _FakePan115Gateway({required this.loggedIn, this.file});

  final bool loggedIn;
  final CloudDriveFile? file;
  final submitCalls = <String>[];
  final recordedHashes = <String>[];
  final _submitted = <String>{};

  @override
  Future<bool> isLoggedIn() async => loggedIn;

  @override
  Future<CloudDriveFile?> findFileByCode(String code) async => file;

  @override
  Future<CloudDirectLink?> directLink(CloudDriveFile file) async =>
      const CloudDirectLink(url: 'https://cdn.example.com/v.mp4');

  @override
  Future<List<Pan115OfflineTask>> listOfflineTasks() async => const [];

  @override
  Future<bool> submitOffline(String url) async {
    submitCalls.add(url);
    return true;
  }

  @override
  Future<Set<String>> submittedHashes() async => {..._submitted};

  @override
  Future<void> recordSubmitted(String hash) async {
    recordedHashes.add(hash);
    _submitted.add(hash);
  }
}

class _EmptyDetailRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async =>
      DramaDetail(drama, const []);
}
