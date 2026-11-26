import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_engine.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';
import 'package:moyi/cloud_drive/cloud_m115_crypto.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 115 二期：账号/容量信息、转码安卓路、引擎转码兜底。
/// 转码响应 data 是 RSA 密文字符串，造密文要服务端私钥，单测造不出
/// 来——所以明文解析拆成纯函数 buildPan115TranscodeLink 直接测，
/// transcodeLink 本体测请求构造与剥壳前的错误路；RSA 剥壳本身的
/// 正确性由 cloud_m115_crypto_test 的交叉向量背书（与一期同口径）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cookieCreds = CloudCredentials(
    fields: {'cookie': 'UID=U1; CID=C1; SEID=S1'},
    savedAtMs: 1,
  );
  const videoFile = CloudDriveFile(
    id: 'fid1',
    name: '电影.mp4',
    isFolder: false,
    kind: CloudFileKind.video,
    extra: {'pickcode': 'pc1'},
  );
  const sessionPair =
      '0123456789abcdef0123456789abcdef=fedcba9876543210fedcba9876543210';

  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  group('accountInfo', () {
    final provider = Pan115Provider();

    test('nav 主路：昵称/头像/user_id/VIP 一次解析全', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'my.115.com');
        expect(request.url.queryParameters['ct'], 'ajax');
        expect(request.url.queryParameters['ac'], 'nav');
        expect(request.headers['cookie'], 'UID=U1; CID=C1; SEID=S1');
        return jsonResponse({
          'state': true,
          'data': {
            'user_name': '测试用户',
            'face': '//img.example.com/face.jpg',
            'user_id': 123456,
            'expire': 1893456000,
            'forever': false,
          },
        });
      });
      final info = await provider.accountInfo(client, cookieCreds);
      expect(info.userId, '123456');
      expect(info.nickname, '测试用户');
      // 协议相对头像补成 https。
      expect(info.avatarUrl, 'https://img.example.com/face.jpg');
      expect(info.vipExpireSeconds, 1893456000);
      expect(info.vipForever, isFalse);
    });

    test('nav 拿不到时走 user/info 备路', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (request.url.host == 'my.115.com') {
          return http.Response('<html>login</html>', 200);
        }
        expect(request.url.host, 'webapi.115.com');
        expect(request.url.path, '/user/info');
        return jsonResponse({
          'state': true,
          'data': {'uid': '777', 'nick_name': '备路用户'},
        });
      });
      final info = await provider.accountInfo(client, cookieCreds);
      expect(calls, 2);
      expect(info.userId, '777');
      expect(info.nickname, '备路用户');
    });

    test('两路都拿不到时报错', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'my.115.com') {
          return http.Response('not json', 200);
        }
        return jsonResponse({'state': true, 'data': {}});
      });
      expect(
        provider.accountInfo(client, cookieCreds),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('未获取到用户信息'),
          ),
        ),
      );
    });
  });

  group('spaceInfo', () {
    final provider = Pan115Provider();

    test('index_info 的 space_info 三个 size 解析', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/files/index_info');
        return jsonResponse({
          'state': true,
          'data': {
            'space_info': {
              'all_total': {'size': 1099511627776},
              'all_use': {'size': 12345},
              'all_remain': {'size': 1099511615431},
            },
          },
        });
      });
      final space = await provider.spaceInfo(client, cookieCreds);
      expect(space.totalBytes, 1099511627776);
      expect(space.usedBytes, 12345);
      expect(space.remainBytes, 1099511615431);
    });

    test('总容量为 0 算获取失败', () async {
      final client = MockClient((request) async {
        return jsonResponse({'state': true, 'data': {'space_info': {}}});
      });
      expect(
        provider.spaceInfo(client, cookieCreds),
        throwsA(isA<CloudDriveException>()),
      );
    });
  });

  group('buildPan115TranscodeLink（转码明文解析）', () {
    test('按 height 取最高档，拼 &id=，f=3 带下载会话 Cookie', () {
      final link = buildPan115TranscodeLink(
        {
          'video_url': [
            {'url': 'https://tc.example.com/lo.m3u8?f=3&t=2000000000', 'height': 360},
            {'url': 'https://tc.example.com/hi.m3u8?f=3&t=2000000000', 'height': 1080},
            {'url': 'https://tc.example.com/mid.m3u8?f=3&t=2000000000', 'height': 720},
          ],
        },
        fileId: 'fid1',
        downloadCookie: sessionPair,
      );
      expect(link.url, 'https://tc.example.com/hi.m3u8?f=3&t=2000000000&id=fid1');
      expect(link.isTranscoded, isTrue);
      expect(link.linkF, 3);
      expect(link.expiresAtMs, 2000000000000);
      expect(link.fetchUserAgent, 'Mozilla/5.0');
      expect(link.headers['User-Agent'], 'Mozilla/5.0');
      expect(link.headers['Cookie'], sessionPair);
      expect(link.downloadCookie, sessionPair);
    });

    test('url 没有查询参数时用 ?id= 拼', () {
      final link = buildPan115TranscodeLink(
        {
          'video_url': [
            {'url': 'https://tc.example.com/a.m3u8', 'height': 720},
          ],
        },
        fileId: 'fid9',
      );
      expect(link.url, 'https://tc.example.com/a.m3u8?id=fid9');
      expect(link.linkF, isNull);
      // 没给 f 时保守带 Cookie（这里没给 downloadCookie 所以没有）。
      expect(link.headers.containsKey('Cookie'), isFalse);
    });

    test('f=1 不带 Cookie（UA 一致即可）', () {
      final link = buildPan115TranscodeLink(
        {
          'video_url': [
            {'url': 'https://tc.example.com/a.m3u8?f=1&t=2000000000', 'height': 720},
          ],
        },
        fileId: 'fid1',
        downloadCookie: sessionPair,
      );
      expect(link.headers.containsKey('Cookie'), isFalse);
      expect(link.downloadCookie, sessionPair);
    });

    test('video_url 为空 + queue_url → 正在转码', () {
      expect(
        () => buildPan115TranscodeLink(
          {'video_url': [], 'queue_url': 'https://q.example.com/x'},
          fileId: 'fid1',
        ),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            '视频正在转码，请稍后再试',
          ),
        ),
      );
    });

    test('video_url 为空且没有 queue_url → 没有转码版本', () {
      expect(
        () => buildPan115TranscodeLink({'video_url': []}, fileId: 'fid1'),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            '这个视频没有转码版本',
          ),
        ),
      );
    });
  });

  group('transcodeLink 请求构造与错误路', () {
    final provider = Pan115Provider();

    http.Client clientFor({
      required Object proapiBody,
      int proapiStatus = 200,
      void Function(http.Request request)? onProapi,
    }) {
      return MockClient((request) async {
        if (request.url.host == 'my.115.com') {
          return jsonResponse({
            'state': true,
            'data': {'user_name': '测试用户', 'user_id': '123456'},
          });
        }
        if (request.url.host == 'proapi.115.com') {
          onProapi?.call(request);
          return proapiBody is http.Response
              ? proapiBody
              : jsonResponse(proapiBody, status: proapiStatus);
        }
        throw StateError('unexpected ${request.url}');
      });
    }

    test('请求体是 {pickcode, user_id 数字} 的 m115 密文，UA/Cookie 按契约', () async {
      final client = clientFor(
        proapiBody: {'state': false, 'errno': 999, 'error_msg': '故意失败'},
        onProapi: (request) {
          expect(request.method, 'POST');
          expect(request.url.path, '/android/2.0/video/play');
          expect(request.headers['user-agent'], 'Mozilla/5.0');
          expect(request.headers['cookie'], 'UID=U1; CID=C1; SEID=S1');
          expect(request.bodyFields.keys, ['data']);
          // m115 加密是确定性的（随机槽固定零字节）：密文逐字相等
          // 就证明明文正是期望的 JSON（含 user_id 发数字）。
          final expected = m115RsaEncrypt(
            utf8.encode(jsonEncode({'pickcode': 'pc1', 'user_id': 123456})),
          );
          expect(request.bodyFields['data'], expected);
        },
      );
      await expectLater(
        provider.transcodeLink(client, cookieCreds, videoFile),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('故意失败'),
          ),
        ),
      );
    });

    test('errno 409 也解 data：data 不是密文时报解析失败（说明走到了剥壳）', () async {
      final client = clientFor(
        proapiBody: {'state': false, 'errno': 409, 'data': 'AAAA'},
      );
      await expectLater(
        provider.transcodeLink(client, cookieCreds, videoFile),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('转码地址解析失败'),
          ),
        ),
      );
    });

    test('HTTP 非 200 直接报错', () async {
      final client = clientFor(proapiBody: 'oops', proapiStatus: 500);
      await expectLater(
        provider.transcodeLink(client, cookieCreds, videoFile),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 500'),
          ),
        ),
      );
    });

    test('账号信息拿不到时不调转码接口', () async {
      var proapiCalled = false;
      final client = MockClient((request) async {
        if (request.url.host == 'my.115.com') {
          return http.Response('not json', 200);
        }
        if (request.url.host == 'proapi.115.com') {
          proapiCalled = true;
          return jsonResponse({});
        }
        return jsonResponse({'state': true, 'data': {}});
      });
      await expectLater(
        provider.transcodeLink(client, cookieCreds, videoFile),
        throwsA(isA<CloudDriveException>()),
      );
      expect(proapiCalled, isFalse);
    });
  });

  group('引擎转码兜底', () {
    late CloudCredentialStore credentialStore;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      credentialStore = CloudCredentialStore(prefs);
      await credentialStore.save('pan115', cookieCreds);
    });

    CloudDriveEngine engineFor(
      _Fake115 provider,
      http.Client client,
    ) => CloudDriveEngine(
      credentialStore: credentialStore,
      httpClient: client,
      showSuspectedAds: () => false,
      providers: {'pan115': provider},
    );

    Future<PlaybackPlan> resolveWith(
      _Fake115 provider,
      http.Client client,
    ) async {
      final engine = engineFor(provider, client);
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '电影.mp4');
      final detail = await engine.detail(card);
      return engine.resolve(card, detail.episodes.first);
    }

    http.Client probeClient(int status) => MockClient((request) async {
      if (request.url.host == 'cdn.example.com') {
        return http.Response('', status);
      }
      return http.Response('', 200);
    });

    test('直链取不到 → 回退转码', () async {
      final provider = _Fake115(directFails: true);
      final plan = await resolveWith(provider, probeClient(200));
      expect(plan.url, contains('tc.example.com'));
      expect(plan.headers['User-Agent'], 'Mozilla/5.0');
    });

    test('直链首请求 403 → 回退转码', () async {
      final provider = _Fake115();
      final plan = await resolveWith(provider, probeClient(403));
      expect(plan.url, contains('tc.example.com'));
    });

    test('直链首请求 200 → 用直链，不转码', () async {
      final provider = _Fake115();
      final plan = await resolveWith(provider, probeClient(200));
      expect(plan.url, contains('cdn.example.com'));
      expect(provider.transcodeCalls, 0);
    });

    test('探针网络失败不惩罚 → 仍用直链', () async {
      final provider = _Fake115();
      final client = MockClient((request) async {
        throw http.ClientException('断网');
      });
      final plan = await resolveWith(provider, client);
      expect(plan.url, contains('cdn.example.com'));
      expect(provider.transcodeCalls, 0);
    });

    test('两条路都失败 → 报错带两边原因', () async {
      final provider = _Fake115(directFails: true, transcodeFails: true);
      await expectLater(
        resolveWith(provider, probeClient(200)),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            allOf(contains('直链取不到'), contains('转码兜底也失败')),
          ),
        ),
      );
    });
  });
}

/// 假 115：列表固定一个视频；直链/转码行为可配（转码本体在
/// provider 测试里覆盖，这里只验引擎的回退接线）。
class _Fake115 extends Pan115Provider {
  _Fake115({this.directFails = false, this.transcodeFails = false});

  final bool directFails;
  final bool transcodeFails;
  var transcodeCalls = 0;

  static const _file = CloudDriveFile(
    id: 'fid1',
    name: '电影.mp4',
    isFolder: false,
    kind: CloudFileKind.video,
    sizeBytes: 100,
    extra: {'pickcode': 'pc1'},
  );

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async => const CloudFolderPage(files: [_file], hasMore: false, total: 1);

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    if (directFails) {
      throw CloudDriveException('115 取直链失败：故意失败');
    }
    return const CloudDirectLink(
      url: 'https://cdn.example.com/v.mp4?f=1&t=2000000000',
      headers: {'User-Agent': ''},
      fetchUserAgent: '',
    );
  }

  @override
  Future<CloudDirectLink> transcodeLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    transcodeCalls++;
    if (transcodeFails) {
      throw CloudDriveException('115 取转码地址失败：故意失败');
    }
    return const CloudDirectLink(
      url: 'https://tc.example.com/v.m3u8?f=1&t=2000000000&id=fid1',
      headers: {'User-Agent': 'Mozilla/5.0'},
      isTranscoded: true,
      fetchUserAgent: 'Mozilla/5.0',
    );
  }
}
