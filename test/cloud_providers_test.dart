import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';

void main() {
  const cookieCreds = CloudCredentials(
    fields: {'cookie': 'UID=test123'},
    savedAtMs: 1,
  );

  http.Response jsonResponse(Object body, {int status = 200, Map<String, String>? headers}) =>
      http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
      );

  group('Cookie 工具', () {
    test('parseSetCookies：多 cookie 与 Expires 逗号', () {
      final parsed = parseSetCookies(
        'UID=abc; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, BDUSS=xyz; Path=/',
      );
      expect(parsed['UID'], 'abc');
      expect(parsed['BDUSS'], 'xyz');
      expect(parsed.containsKey('Expires'), isFalse);
    });

    test('parseSetCookies：空输入', () {
      expect(parseSetCookies(null), isEmpty);
      expect(parseSetCookies(''), isEmpty);
    });

    test('mergeCookieHeader：合并并覆盖同名', () {
      final merged = mergeCookieHeader('A=1; B=2', 'B=3; Path=/, C=4');
      expect(merged, contains('A=1'));
      expect(merged, contains('B=3'));
      expect(merged, contains('C=4'));
      expect(merged, isNot(contains('B=2')));
    });
  });

  group('resolveRedirects', () {
    test('跟随 302 链并累计 cookie', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path == '/a') {
          return http.Response('', 302, headers: {
            'location': '/b',
            'set-cookie': 'A=1; Path=/',
          });
        }
        if (path == '/b') {
          return http.Response('', 302, headers: {
            'location': 'https://cdn.example.com/final.mp4',
            'set-cookie': 'B=2; Path=/',
          });
        }
        return http.Response('body', 200);
      });
      final result = await resolveRedirects(
        client,
        http.Request('GET', Uri.parse('https://example.com/a')),
      );
      expect(result.url, 'https://cdn.example.com/final.mp4');
      expect(result.setCookie, contains('A=1'));
      expect(result.setCookie, contains('B=2'));
    });

    test('无跳转时返回原地址', () async {
      final client = MockClient((_) async => http.Response('ok', 200));
      final result = await resolveRedirects(
        client,
        http.Request('GET', Uri.parse('https://example.com/x.mp4')),
      );
      expect(result.url, 'https://example.com/x.mp4');
    });
  });

  group('115 网盘', () {
    final provider = Pan115Provider();

    test('startQrLogin 解析 token 接口', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'qrcodeapi.115.com');
        return jsonResponse({
          'state': 1,
          'data': {
            'uid': 'uid-1',
            'time': '1700000000',
            'sign': 'sign-1',
            'qrcode': 'https://115.com/scan/dg-uid-1',
          },
        });
      });
      final session = await provider.startQrLogin(client);
      expect(session.qrContent, 'https://115.com/scan/dg-uid-1');
      expect(session.state['uid'], 'uid-1');
      expect(session.expiresAt.isAfter(DateTime.now()), isTrue);
    });

    test('pollQrLogin 等待态', () async {
      final client = MockClient((_) async => jsonResponse({
            'state': 1,
            'code': 0,
            'data': {'status': 0, 'msg': ''},
          }));
      final session = QrLoginSession(
        qrContent: 'https://115.com/scan/dg-u',
        qrImageUrl: '',
        message: '',
        state: {'uid': 'u', 'time': 't', 'sign': 's'},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final result = await provider.pollQrLogin(client, session);
      expect(result.status, QrPollStatus.waiting);
    });

    test('pollQrLogin 已确认后走 qandroid 通道换取 cookie', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/get/status/') {
          return jsonResponse({
            'state': 1,
            'code': 0,
            'data': {'status': 2},
          });
        }
        if (request.url.path == '/files/index_info') {
          return jsonResponse({'state': true});
        }
        // 取凭证走 qrcodeapi 的 qandroid 路径，凭证在响应体 data.cookie。
        expect(request.url.host, 'qrcodeapi.115.com');
        expect(request.url.path, '/app/1.0/qandroid/1.0/login/qrcode/');
        expect(request.headers['user-agent'], 'Mozilla/5.0');
        return jsonResponse({
          'state': true,
          'data': {'cookie': 'UID=uid1; CID=cid1; SEID=seid1'},
        });
      });
      final session = QrLoginSession(
        qrContent: 'https://115.com/scan/dg-u',
        qrImageUrl: '',
        message: '',
        state: {'uid': 'u', 'time': 't', 'sign': 's'},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final result = await provider.pollQrLogin(client, session);
      expect(result.status, QrPollStatus.success);
      expect(
        result.credentials!.fields['cookie'],
        'UID=uid1; CID=cid1; SEID=seid1',
      );
    });

    test('pollQrLogin 凭证缺 SEID 不算登录成功', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/get/status/') {
          return jsonResponse({
            'state': 1,
            'code': 0,
            'data': {'status': 2},
          });
        }
        return jsonResponse({
          'state': true,
          'data': {'cookie': 'UID=uid1; CID=cid1'},
        });
      });
      final session = QrLoginSession(
        qrContent: 'https://115.com/scan/dg-u',
        qrImageUrl: '',
        message: '',
        state: {'uid': 'u', 'time': 't', 'sign': 's'},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final result = await provider.pollQrLogin(client, session);
      expect(result.status, QrPollStatus.failed);
      expect(result.message, contains('SEID'));
    });

    test('pollQrLogin 二维码过期与取消', () async {
      QrLoginSession session() => QrLoginSession(
            qrContent: 'https://115.com/scan/dg-u',
            qrImageUrl: '',
            message: '',
            state: {'uid': 'u', 'time': 't', 'sign': 's'},
            expiresAt: DateTime.now().add(const Duration(minutes: 1)),
          );
      final expiredClient = MockClient((_) async => jsonResponse({
            'state': 1,
            'code': 0,
            'data': {'status': -1},
          }));
      expect(
        (await provider.pollQrLogin(expiredClient, session())).status,
        QrPollStatus.expired,
      );
      final cancelledClient = MockClient((_) async => jsonResponse({
            'state': 1,
            'code': 0,
            'data': {'status': -2},
          }));
      expect(
        (await provider.pollQrLogin(cancelledClient, session())).status,
        QrPollStatus.failed,
      );
    });

    test('listFolder 映射文件夹与视频', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['cid'], '0');
        return jsonResponse({
          'state': 1,
          'count': 2,
          'data': [
            {'cid': '100', 'n': '剧集', 's': 0, 't': 1700000000},
            {
              'fid': '200', 'cid': '0', 'n': '正片|第一集.mp4',
              's': 1024, 't': 1700000001, 'pc': 'pick-1',
              'play_long': 120, 'thumb': 'https://thumb/x.jpg',
            },
          ],
        });
      });
      final page = await provider.listFolder(client, cookieCreds, '0', 1);
      expect(page.files.length, 2);
      expect(page.hasMore, isFalse);
      final folder = page.files[0];
      expect(folder.isFolder, isTrue);
      expect(folder.kind, CloudFileKind.folder);
      expect(folder.id, '100');
      final video = page.files[1];
      expect(video.isFolder, isFalse);
      expect(video.kind, CloudFileKind.video);
      expect(video.name, '正片 第一集.mp4');
      expect(video.durationSeconds, 120);
      expect(video.thumbnailUrl, 'https://thumb/x.jpg');
      expect(video.extra['pickcode'], 'pick-1');
    });

    // 取链响应里 data 是明文 Map 的形状（真实响应里 data 是 RSA 密文
    // 字符串，那条路的解密正确性由 cloud_m115_crypto_test 的向量覆盖；
    // 服务端密文只能用服务器私钥生成，单测里造不出来）。
    http.Response downloadResponse(
      String fileUrl, {
      String? setCookie,
    }) {
      return jsonResponse(
        {
          'state': true,
          'data': {'file_url': fileUrl, 'file_name': '正片.mp4'},
        },
        headers: {'set-cookie': ?setCookie},
      );
    }

    const videoFile = CloudDriveFile(
      id: '200',
      name: '正片.mp4',
      isFolder: false,
      kind: CloudFileKind.video,
      extra: {'pickcode': 'pick-1'},
    );
    const sessionPair =
        '0123456789abcdef0123456789abcdef=fedcba9876543210fedcba9876543210';

    test('directLink POST m115 取链，f=3 只带下载会话 Cookie', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/files/download');
        // 取链 UA 置空；请求体只有 data 字段（m115 密文）。
        expect(request.headers['user-agent'], '');
        expect(request.bodyFields.keys, ['data']);
        expect(request.bodyFields['data'], isNotEmpty);
        return downloadResponse(
          'https://cdn115.example.com/file.mp4?f=3&t=1893456000&u=1',
          setCookie: 'OTHER=x; Path=/, $sessionPair; Path=/',
        );
      });
      final link = await provider.directLink(client, cookieCreds, videoFile);
      expect(link.url, startsWith('https://cdn115.example.com/file.mp4'));
      expect(link.linkF, 3);
      expect(link.expiresAtMs, 1893456000000);
      expect(link.downloadCookie, sessionPair);
      expect(link.fetchUserAgent, '');
      expect(link.headers['User-Agent'], '');
      // 只带那一对会话 Cookie，绝不带账号 Cookie。
      expect(link.headers['Cookie'], sessionPair);
      expect(link.headers['Cookie'], isNot(contains('UID=test123')));
    });

    test('directLink f=1 不带 Cookie（UA 一致即可）', () async {
      final client = MockClient((request) async {
        return downloadResponse(
          'https://cdn115.example.com/file.mp4?f=1&t=1893456000',
          setCookie: '$sessionPair; Path=/',
        );
      });
      final link = await provider.directLink(client, cookieCreds, videoFile);
      expect(link.linkF, 1);
      expect(link.downloadCookie, sessionPair);
      expect(link.headers.containsKey('Cookie'), isFalse);
      expect(link.headers['User-Agent'], '');
    });

    test('directLink 无 f 参数时保守带下载会话 Cookie', () async {
      final client = MockClient((request) async {
        return downloadResponse(
          'https://cdn115.example.com/file.mp4?t=1893456000',
          setCookie: '$sessionPair; Path=/',
        );
      });
      final link = await provider.directLink(client, cookieCreds, videoFile);
      expect(link.linkF, isNull);
      expect(link.headers['Cookie'], sessionPair);
    });

    test('directLink 无 pickcode 时先取 category', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/category/get') {
          return jsonResponse({'pick_code': 'pick-9'});
        }
        return downloadResponse('https://cdn115.example.com/f.mp4?f=0');
      });
      const file = CloudDriveFile(
        id: '300',
        name: '片.mp4',
        isFolder: false,
        kind: CloudFileKind.video,
      );
      final link = await provider.directLink(client, cookieCreds, file);
      expect(link.url, 'https://cdn115.example.com/f.mp4?f=0');
    });

    test('listFolder 命中过期三码：清登录态并给明确提示', () async {
      final p = Pan115Provider();
      String? clearedCookie;
      p.onSessionExpired = (_, cookie) => clearedCookie = cookie;
      final client = MockClient((_) async => jsonResponse({
            'state': false,
            'errno': 40101032,
            'error_msg': '凭证无效',
          }));
      await expectLater(
        p.listFolder(client, cookieCreds, '0', 1),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            '115 登录已过期，请重新登录',
          ),
        ),
      );
      expect(clearedCookie, 'UID=test123');
    });

    test('listFolder HTTP 405 按限频处理，不清登录态', () async {
      final p = Pan115Provider();
      var cleared = false;
      p.onSessionExpired = (_, cookie) => cleared = true;
      final client = MockClient((_) async => http.Response('', 405));
      await expectLater(
        p.listFolder(client, cookieCreds, '0', 1),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('请求太频繁'),
          ),
        ),
      );
      expect(cleared, isFalse);
    });

    test('旧请求的过期报错不清新登录（世代保护）', () async {
      final p = Pan115Provider();
      var clearCount = 0;
      p.onSessionExpired = (_, cookie) => clearCount++;
      late MockClient client;
      client = MockClient((request) async {
        if (request.url.path == '/get/status/') {
          return jsonResponse({
            'state': 1,
            'code': 0,
            'data': {'status': 2},
          });
        }
        if (request.url.path == '/app/1.0/qandroid/1.0/login/qrcode/') {
          return jsonResponse({
            'state': true,
            'data': {'cookie': 'UID=u2; CID=c2; SEID=s2'},
          });
        }
        if (request.url.path == '/files/index_info') {
          return jsonResponse({'state': true});
        }
        // 列表请求（在途旧请求）：处理它的过程中先完成一次新登录
        //（世代推进），再返回旧凭证的过期报错——不许清新登录。
        final session = QrLoginSession(
          qrContent: 'https://115.com/scan/dg-u',
          qrImageUrl: '',
          message: '',
          state: {'uid': 'u', 'time': 't', 'sign': 's'},
          expiresAt: DateTime.now().add(const Duration(minutes: 1)),
        );
        final login = await p.pollQrLogin(client, session);
        expect(login.status, QrPollStatus.success);
        return jsonResponse({
          'state': false,
          'errno': 40101037,
          'error_msg': '会话已退出',
        });
      });
      await expectLater(
        p.listFolder(client, cookieCreds, '0', 1),
        throwsA(isA<CloudDriveException>()),
      );
      expect(clearCount, 0);
    });

    test('validateCookies 三类结论', () async {
      final okClient = MockClient((_) async => jsonResponse({'state': true}));
      expect(
        await provider.validateCookies(okClient, cookieCreds),
        Pan115CookieVerdict.valid,
      );
      final expiredClient = MockClient((_) async => jsonResponse({
            'state': false,
            'errno': 40101035,
          }));
      expect(
        await provider.validateCookies(expiredClient, cookieCreds),
        Pan115CookieVerdict.expired,
      );
      final limitedClient = MockClient((_) async => http.Response('', 405));
      expect(
        await provider.validateCookies(limitedClient, cookieCreds),
        Pan115CookieVerdict.networkError,
      );
      final downClient = MockClient((_) async => throw Exception('断网'));
      expect(
        await provider.validateCookies(downClient, cookieCreds),
        Pan115CookieVerdict.networkError,
      );
    });

    test('normalizePan115Cookie 三件套与键序', () {
      expect(
        normalizePan115Cookie('SEID=s; UID=u; CID=c; KID=k; OTHER=o'),
        'UID=u; CID=c; SEID=s; KID=k',
      );
      expect(normalizePan115Cookie('UID=u; CID=c'), isNull);
      expect(missingPan115CookieKeys('UID=u'), ['CID', 'SEID']);
    });
  });

  group('夸克网盘', () {
    final provider = QuarkProvider();

    test('startQrLogin 拼二维码地址', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/cas/ajax/getTokenForQrcodeLogin');
        return jsonResponse({
          'status': 200,
          'data': {'members': {'token': 'tok-1'}},
        });
      });
      final session = await provider.startQrLogin(client);
      expect(session.qrContent, contains('token=tok-1'));
      expect(session.qrContent, startsWith('https://su.quark.cn/'));
      expect(session.state['token'], 'tok-1');
    });

    test('pollQrLogin 拿到 ticket 后换 cookie', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('getServiceTicketByQrcodeToken')) {
          return jsonResponse({
            'status': 200,
            'message': 'ok',
            'data': {'members': {'service_ticket': 'st-1'}},
          });
        }
        expect(request.url.path, '/desktop/account/login');
        return http.Response('{}', 200, headers: {
          'set-cookie': 'c-user-id=99; Path=/',
        });
      });
      final session = QrLoginSession(
        qrContent: 'https://su.quark.cn/x',
        qrImageUrl: '',
        message: '',
        state: {'requestId': 'r1', 'token': 'tok-1'},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final result = await provider.pollQrLogin(client, session);
      expect(result.status, QrPollStatus.success);
      expect(result.credentials!.fields['cookie'], contains('c-user-id=99'));
    });

    test('listFolder 映射', () async {
      final client = MockClient((_) async => jsonResponse({
            'status': 200,
            'data': {
              'list': [
                {'fid': 'f1', 'file': false, 'file_name': '文件夹A', 'size': 0, 'updated_at': 1700000000},
                {'fid': 'f2', 'file': true, 'file_name': '歌.mp3', 'size': 5000, 'updated_at': 1700000001, 'duration': 200},
              ],
              'total': 2,
            },
          }));
      final page = await provider.listFolder(client, cookieCreds, '0', 1);
      expect(page.files[0].isFolder, isTrue);
      expect(page.files[1].kind, CloudFileKind.audio);
      expect(page.files[1].durationSeconds, 200);
      expect(page.hasMore, isFalse);
    });

    test('search 抛 UnsupportedError（引擎兜底）', () async {
      final client = MockClient((_) async => http.Response('', 200));
      expect(
        provider.search(client, cookieCreds, '片', '0'),
        throwsUnsupportedError,
      );
    });

    test('directLink 优先原文件直链', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/1/clouddrive/file/download');
        return jsonResponse({
          'status': 200,
          'data': [{'download_url': 'https://cdn.quark.example.com/f.mp4'}],
        });
      });
      const file = CloudDriveFile(id: 'f2', name: '片.mp4', isFolder: false, kind: CloudFileKind.video);
      final link = await provider.directLink(client, cookieCreds, file);
      expect(link.url, 'https://cdn.quark.example.com/f.mp4');
      expect(link.isTranscoded, isFalse);
    });

    test('directLink 直链失败时落转码流兜底', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/download')) {
          return jsonResponse({'status': 200, 'data': []});
        }
        return jsonResponse({
          'status': 200,
          'data': {
            'video_list': [
              {'video_info': {'url': 'https://trans.quark.example.com/v.m3u8'}},
            ],
          },
        });
      });
      const file = CloudDriveFile(id: 'f2', name: '片.mp4', isFolder: false, kind: CloudFileKind.video);
      final link = await provider.directLink(client, cookieCreds, file);
      expect(link.url, 'https://trans.quark.example.com/v.m3u8');
      expect(link.isTranscoded, isTrue);
    });
  });

  group('百度网盘', () {
    final provider = BaiduProvider();

    test('startQrLogin 解析 JSONP', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v2/api/getqrcode');
        return http.Response(
          'tangram_guid_123({"sign":"sign-1","imgurl":"passport.baidu.com/qr.png"})',
          200,
          headers: {'set-cookie': 'BAIDUID=abc; Path=/'},
        );
      });
      final session = await provider.startQrLogin(client);
      expect(session.qrContent, isEmpty);
      expect(session.qrImageUrl, 'https://passport.baidu.com/qr.png');
      expect(session.state['sign'], 'sign-1');
      expect(session.state['cookie'], contains('BAIDUID=abc'));
    });

    test('pollQrLogin 等待态（无 bduss）', () async {
      final client = MockClient((_) async => http.Response('{"channel_v": "{\\"errno\\":0}"}', 200));
      final session = QrLoginSession(
        qrContent: '',
        qrImageUrl: 'https://x/qr.png',
        message: '',
        state: {'gid': 'g', 'sign': 's', 'tangramGuid': 't', 'cookie': ''},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final result = await provider.pollQrLogin(client, session);
      expect(result.status, QrPollStatus.waiting);
    });

    test('pollQrLogin 拿到 bduss 后完成登录', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/channel/unicast') {
          return http.Response('x \\"v\\":\\"0123456789abcdef0123456789abcdef\\" y', 200);
        }
        expect(request.url.path, '/v3/login/main/qrbdusslogin');
        return http.Response(
          'bd__cbs__tro4ll({"errno":0,"data":{"session":{"ubi":"u1","stoken":"s1","bduss":"b1","ptoken":"p1"}}})',
          200,
        );
      });
      final session = QrLoginSession(
        qrContent: '',
        qrImageUrl: 'https://x/qr.png',
        message: '',
        state: {'gid': 'g', 'sign': 's', 'tangramGuid': 't', 'cookie': 'BAIDUID=abc'},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final result = await provider.pollQrLogin(client, session);
      expect(result.status, QrPollStatus.success);
      final cookie = result.credentials!.fields['cookie']!;
      expect(cookie, contains('BDUSS=b1'));
      expect(cookie, contains('STOKEN=s1'));
      expect(cookie, contains('BDUSS_BFESS=b1'));
    });

    test('listFolder 映射与 category 提示', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['method'], 'list');
        return jsonResponse({
          'errno': 0,
          'list': [
            {'fs_id': 11, 'isdir': 1, 'server_filename': '夹', 'size': 0, 'server_mtime': 1700000000, 'path': '/夹'},
            {'fs_id': 22, 'isdir': 0, 'server_filename': '无名', 'size': 100, 'server_mtime': 1700000001, 'path': '/无名', 'category': 1, 'thumbs': {'url1': 'https://t/1.jpg'}},
          ],
        });
      });
      final page = await provider.listFolder(client, cookieCreds, '/', 1);
      expect(page.files[0].isFolder, isTrue);
      // 无扩展名但 category=1 提示视频。
      expect(page.files[1].kind, CloudFileKind.video);
      expect(page.files[1].thumbnailUrl, 'https://t/1.jpg');
      expect(page.files[1].extra['path'], '/无名');
    });

    test('directLink 缺路径时抛错', () async {
      final client = MockClient((_) async => http.Response('', 200));
      const file = CloudDriveFile(id: '22', name: '片.mp4', isFolder: false, kind: CloudFileKind.video);
      expect(
        provider.directLink(client, cookieCreds, file),
        throwsA(isA<CloudDriveException>()),
      );
    });
  });

  group('阿里云盘', () {
    AliyunProvider provider() => AliyunProvider();
    const aliyunCreds = CloudCredentials(
      fields: {
        'refresh_token': 'rt-1',
        'access_token': 'at-1',
        'drive_id': 'drive-1',
      },
      savedAtMs: 1,
    );

    test('startQrLogin 解析 generate.do', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/newlogin/qrcode/generate.do');
        return jsonResponse({
          'content': {
            'data': {'t': 't1', 'ck': 'ck1', 'codeContent': 'https://aliyun/qr?t1'},
          },
        });
      });
      final session = await provider().startQrLogin(client);
      expect(session.qrContent, 'https://aliyun/qr?t1');
      expect(session.state['t'], 't1');
    });

    test('pollQrLogin LOGINED 后换取 token', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('query.do')) {
          return jsonResponse({
            'content': {
              'data': {
                'status': 'LOGINED',
                'bizExt': {
                  'pds_login_result': jsonEncode({'refreshToken': 'rt-9'}),
                },
              },
            },
          });
        }
        expect(request.url.path, '/v2/account/token');
        return jsonResponse({
          'access_token': 'at-9',
          'refresh_token': 'rt-9b',
          'default_drive_id': 'drive-9',
        });
      });
      final session = QrLoginSession(
        qrContent: 'https://aliyun/qr',
        qrImageUrl: '',
        message: '',
        state: {'t': 't1', 'ck': 'ck1'},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final result = await provider().pollQrLogin(client, session);
      expect(result.status, QrPollStatus.success);
      expect(result.credentials!.fields['access_token'], 'at-9');
      expect(result.credentials!.fields['drive_id'], 'drive-9');
    });

    test('pollQrLogin EXPIRED/SCANED 状态', () async {
      final expired = MockClient((_) async => jsonResponse({
            'content': {'data': {'status': 'EXPIRED'}},
          }));
      final session = QrLoginSession(
        qrContent: 'x',
        qrImageUrl: '',
        message: '',
        state: {'t': 't', 'ck': 'c'},
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      expect((await provider().pollQrLogin(expired, session)).status, QrPollStatus.expired);
      final scanned = MockClient((_) async => jsonResponse({
            'content': {'data': {'status': 'SCANED'}},
          }));
      expect((await provider().pollQrLogin(scanned, session)).status, QrPollStatus.scanned);
    });

    test('listFolder 映射与 marker 分页', () async {
      final p = provider();
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['drive_id'], 'drive-1');
        expect(body['parent_file_id'], 'root');
        return jsonResponse({
          'items': [
            {'file_id': 'a1', 'type': 'folder', 'name': '夹', 'size': 0, 'updated_at': '2026-01-01T00:00:00.000Z'},
            {'file_id': 'a2', 'type': 'file', 'name': '片.mp4', 'category': 'video', 'size': 1000, 'updated_at': '2026-01-01T00:00:00.000Z', 'video_media_metadata': {'duration': 90}, 'thumbnail': 'https://t/x.jpg'},
          ],
          'next_marker': 'm1',
        });
      });
      final page = await p.listFolder(client, aliyunCreds, 'root', 1);
      expect(page.hasMore, isTrue);
      expect(page.files[0].isFolder, isTrue);
      expect(page.files[1].kind, CloudFileKind.video);
      expect(page.files[1].durationSeconds, 90);
      expect(page.files[1].modifiedMs, isNot(0));
    });

    test('401 时续期一次并回调落盘', () async {
      final p = provider();
      CloudCredentials? refreshed;
      p.onCredentialsRefreshed = (_, c) => refreshed = c;
      var listCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/openFile/list')) {
          listCalls++;
          if (listCalls == 1) return http.Response('{}', 401);
          return jsonResponse({'items': [], 'next_marker': ''});
        }
        expect(request.url.path, '/v2/account/token');
        return jsonResponse({
          'access_token': 'at-new',
          'refresh_token': 'rt-new',
          'default_drive_id': 'drive-1',
        });
      });
      final page = await p.listFolder(client, aliyunCreds, 'root', 1);
      expect(page.files, isEmpty);
      expect(listCalls, 2);
      expect(refreshed, isNotNull);
      expect(refreshed!.fields['access_token'], 'at-new');
    });

    test('search 抛 UnsupportedError', () async {
      final client = MockClient((_) async => http.Response('', 200));
      expect(
        provider().search(client, aliyunCreds, '片', 'root'),
        throwsUnsupportedError,
      );
    });

    test('directLink 取 getDownloadUrl', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/adrive/v1.0/openFile/getDownloadUrl');
        return jsonResponse({'url': 'https://cdn.aliyun.example.com/f.mp4', 'expiration': '2026-01-01'});
      });
      const file = CloudDriveFile(id: 'a2', name: '片.mp4', isFolder: false, kind: CloudFileKind.video);
      final link = await provider().directLink(client, aliyunCreds, file);
      expect(link.url, 'https://cdn.aliyun.example.com/f.mp4');
    });

    test('credentialsFromRefreshToken 手动粘贴路径', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['refresh_token'], 'rt-pasted');
        return jsonResponse({
          'access_token': 'at-p',
          'refresh_token': 'rt-p2',
          'default_drive_id': 'd-p',
        });
      });
      final creds = await provider().credentialsFromRefreshToken(client, '  rt-pasted  ');
      expect(creds, isNotNull);
      expect(creds!.fields['drive_id'], 'd-p');
    });
  });

  group('注册表', () {
    test('五家齐全', () {
      final providers = createCloudDriveProviders();
      expect(
        providers.map((p) => p.id),
        containsAll(['pan115', 'quark', 'aliyun', 'baidu', 'yun139']),
      );
      expect(cloudDriveDisplayNames.length, 5);
    });
  });
}
