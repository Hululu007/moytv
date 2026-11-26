import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/cloud_drive/cloud_115_upload.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_m115_crypto.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';

/// 115 上传协议的向量与编排测试。加密/签名的期望值由独立参考实现
/// 生成（Python hashlib/binascii/hmac + openssl 的 AES，与 Dart
/// 实现不共享代码）：CRC32、quote_plus 表单编码、k_ec、initupload
/// 表单与 AES body、OSS V1 签名各若干例，逐字比对。
/// 权威性边界（与一期同口径）：向量证明的是「本实现与独立参考实现
/// 对协议公式的理解一致」，公式本身来自星辰115 的实测实现与公开
/// 实现（p115cipher/p115oss）；真上传要真账号，列手机终验。
void main() {
  const cookieCreds = CloudCredentials(
    fields: {'cookie': 'UID=U1; CID=C1; SEID=S1'},
    savedAtMs: 1,
  );

  group('CRC32 向量', () {
    test('空/普通/带盐前缀', () {
      expect(pan115Crc32(const []), 0);
      expect(pan115Crc32(utf8.encode('hello')), 907060870);
      expect(
        pan115Crc32(utf8.encode('^j>WD3Kr?J2gLFjD4W2y@abc')),
        4207738285,
      );
    });
  });

  group('表单编码向量（quote_plus 语义）', () {
    test('四例', () {
      expect(pan115FormEncode('a b*c~d/e.mp4'), 'a+b%2Ac~d%2Fe.mp4');
      expect(pan115FormEncode('测试.mp4'), '%E6%B5%8B%E8%AF%95.mp4');
      expect(pan115FormEncode('100% +x'), '100%25+%2Bx');
      expect(pan115FormEncode('plain-1.2_x~y'), 'plain-1.2_x~y');
    });
  });

  group('k_ec 向量', () {
    test('三个时间戳', () {
      expect(
        pan115EncodeToken(1700000000),
        'HQMOgKF43O7OzaN33hKNAHMAAAAA8VNljtndz1WuYe1G6hIaHPyBAAEAAACWHoRq',
      );
      expect(
        pan115EncodeToken(1893456000),
        'HQMOgKF43O7OzaN33hKNAHMAAACA2Ntwjtndz1WuYe1G6hIaHPyBAAEAAACQvHuO',
      );
      expect(
        pan115EncodeToken(0),
        'HQMOgKF43O7OzaN33hKNAHMAAAAAAAAAjtndz1WuYe1G6hIaHPyBAAEAAAAMfvVI',
      );
      // 总长恒为 48 字节。
      expect(base64Decode(pan115EncodeToken(1700000000)).length, 48);
    });
  });

  group('上传 AES 向量（非标准填充）', () {
    test('空/短/对齐长度', () {
      expect(m115AesCbcEncrypt(const []), isEmpty);
      expect(
        base64Encode(m115AesCbcEncrypt(utf8.encode('abc'))),
        'sdluMUxziasllrsGJsSylw==',
      );
      // 已对齐时不补整块：16 字节进、16 字节出（标准 PKCS#7 会出 32）。
      expect(
        base64Encode(m115AesCbcEncrypt(utf8.encode('0123456789abcdef'))),
        'n/xDMzURlBJnZtliWfunag==',
      );
      expect(
        base64Encode(
          m115AesCbcEncrypt(utf8.encode('0123456789abcdef0123456789abcdef')),
        ),
        'n/xDMzURlBJnZtliWfunai7YhOILqxNmlESIx8WikGo=',
      );
    });

    test('加解密往返', () {
      final plain = utf8.encode('hello 115 upload world!');
      expect(m115AesCbcDecrypt(m115AesCbcEncrypt(plain)), plain);
    });
  });

  group('initupload 表单向量', () {
    test('第一轮（无 sign_key/sign_val）', () {
      final payload = buildPan115UploadPayload(
        userId: '123456',
        userKey: 'abcdef0123456789abcdef0123456789',
        fileId: 'DA39A3EE5E6B4B0D3255BFEF95601890AFD80709',
        fileName: '测试 file.mp4',
        fileSize: 123456789,
        target: 'U_1_0',
        appVersion: '36.2.28',
        timestampSeconds: 1700000000,
      );
      expect(
        payload.kEc,
        'HQMOgKF43O7OzaN33hKNAHMAAAAA8VNljtndz1WuYe1G6hIaHPyBAAEAAACWHoRq',
      );
      expect(
        base64Encode(payload.body),
        '8h+v+9zHZDAPpuMW8OylYa6pIsnLCKIDkvTEm4wVhoph+0acL4HqEbStGnO7bmGt5'
        'FNM//KsmM/r+Sr0L8zlvmx9vf5U862KTg1a7yqOhWcg5omaE3eJQ9mz9xIvWEShtO'
        'ab81dJ7jMG+NTp3LxsfqJSQJdat62gFqYv2XEOqWa3f56BD07db1WscedO9aZzJHG'
        'Wzn9oGTKFuYz+ccx/XFzh83veNuo/E87ZRvKjfGjYW2mQfdqJ/jo5PDdFxKOJS0q'
        'kZfJnd2CxJj54q/dGhKLAImtEvvfQwA4kw1Azgj8yEWb5K1Jkl731gQcu+orVWyx'
        '8Ivl8yQ/h0+pAmndAbpPe8Ah7VVo1RRRAbesRBGlCc6wForEyNC2F1rSaN6FKAYu'
        'o/K8s/+CyZTH2tJveOQ==',
      );
      // 解密回表单逐字比对（sig/token 都在里面）。
      expect(
        utf8.decode(m115AesCbcDecrypt(payload.body)),
        'appversion=36.2.28&fileid=DA39A3EE5E6B4B0D3255BFEF95601890AFD80709'
        '&filename=%E6%B5%8B%E8%AF%95+file.mp4&filesize=123456789'
        '&sig=ECC1538523FEA19BB71163673B1F69BD8F30C1FE&t=1700000000'
        '&target=U_1_0&token=5a21c6be837a14b54cb3fcb762fcd7f0'
        '&topupload=true&userid=123456'
        '&userkey=abcdef0123456789abcdef0123456789',
      );
    });

    test('第二轮（带 sign_key/sign_val，字段按 key 排序插入）', () {
      final payload = buildPan115UploadPayload(
        userId: '987654321',
        userKey: '00112233445566778899aabbccddeeff',
        fileId: '7D793037A0760186574B0282F2F435E7D8E98B',
        fileName: 'a.mp4',
        fileSize: 16,
        target: 'U_1_42',
        signKey: 'key123',
        signVal: 'AAF4C61DDCC5E8A2DABEDE0F3B482CD9AEA9434D',
        appVersion: '36.2.28',
        timestampSeconds: 1893456000,
      );
      expect(
        utf8.decode(m115AesCbcDecrypt(payload.body)),
        'appversion=36.2.28&fileid=7D793037A0760186574B0282F2F435E7D8E98B'
        '&filename=a.mp4&filesize=16'
        '&sig=80508D005CF03DE6027BA500B2CAE7E30F9BE78C'
        '&sign_key=key123'
        '&sign_val=AAF4C61DDCC5E8A2DABEDE0F3B482CD9AEA9434D'
        '&t=1893456000&target=U_1_42'
        '&token=b4bbf18356facae686e45e9e9f92162c'
        '&topupload=true&userid=987654321'
        '&userkey=00112233445566778899aabbccddeeff',
      );
    });
  });

  group('OSS 签名向量', () {
    const token = Pan115OssToken(
      accessKeyId: 'AKID',
      accessKeySecret: 'SECRET',
      securityToken: 'STSTOKEN',
    );
    const date = 'Wed, 26 Nov 2026 10:00:00 GMT';

    test('PUT 分片', () {
      final headers = pan115OssSignHeaders(
        token: token,
        method: 'PUT',
        url: 'https://bucket1.oss-cn-shenzhen.aliyuncs.com/dir/obj.bin'
            '?partNumber=2&uploadId=U123',
        date: date,
      );
      expect(headers['authorization'], 'OSS AKID:2EX92dXV5j81aCFCZRjvPrI0UOQ=');
      expect(headers['x-oss-security-token'], 'STSTOKEN');
      expect(headers['date'], date);
    });

    test('POST complete（带回调头与 Content-Type）', () {
      final headers = pan115OssSignHeaders(
        token: token,
        method: 'POST',
        url: 'https://bucket1.oss-cn-shenzhen.aliyuncs.com/dir/obj.bin'
            '?uploadId=U123',
        extraHeaders: {
          'x-oss-callback':
              'eyJjYWxsYmFja1VybCI6Imh0dHBzOi8vdXBsYi4xMTUuY29tL2NiIn0=',
          'x-oss-callback-var': 'eyJ4OmEiOiIxIn0=',
        },
        contentType: 'text/xml',
        date: date,
      );
      expect(headers['authorization'], 'OSS AKID:qJ/cBprT0Q4p+xD3u4ZbDTgxmE4=');
    });

    test('POST init（子资源排序 sequential 在 uploads 前）', () {
      final headers = pan115OssSignHeaders(
        token: token,
        method: 'POST',
        url: 'https://bucket1.oss-cn-shenzhen.aliyuncs.com/dir/obj.bin'
            '?sequential=1&uploads=1',
        date: date,
      );
      expect(headers['authorization'], 'OSS AKID:z7jrhZ7ja1WDZbAU7QTNSHKrmus=');
    });

    test('RFC1123 格式（2026-11-26 是星期四）', () {
      expect(
        pan115Rfc1123(DateTime.utc(2026, 11, 26, 10, 0, 0)),
        'Thu, 26 Nov 2026 10:00:00 GMT',
      );
      expect(
        pan115Rfc1123(DateTime.utc(2026, 1, 5, 3, 4, 5)),
        'Mon, 05 Jan 2026 03:04:05 GMT',
      );
    });

    test('路径段编码：合法 %XX 保留、裸 % 转义、中文编码', () {
      expect(pan115OssEncodePathSegment('a%20b'), 'a%20b');
      expect(pan115OssEncodePathSegment('a%b'), 'a%25b');
      expect(pan115OssEncodePathSegment('测试'), '%E6%B5%8B%E8%AF%95');
      expect(pan115OssEncodePathSegment('a b'), 'a%20b');
    });
  });

  group('OSS 客户端（MockClient）', () {
    const token = Pan115OssToken(
      accessKeyId: 'AKID',
      accessKeySecret: 'SECRET',
      securityToken: 'STSTOKEN',
    );

    test('initMultipart 解析 UploadId，请求带签名头', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.queryParameters['uploads'], '1');
        expect(request.url.queryParameters['sequential'], '1');
        expect(request.headers['authorization'], startsWith('OSS AKID:'));
        expect(request.headers['x-oss-security-token'], 'STSTOKEN');
        return http.Response(
          '<InitiateMultipartUploadResult><UploadId>U123</UploadId>'
          '</InitiateMultipartUploadResult>',
          200,
        );
      });
      final oss = Pan115OssClient(client);
      expect(await oss.initMultipart(token, 'bucket1', 'obj.bin'), 'U123');
    });

    test('uploadPart 返回带引号的 ETag 原样', () async {
      final client = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.queryParameters['partNumber'], '1');
        expect(request.bodyBytes, [1, 2, 3]);
        return http.Response('', 200, headers: {'etag': '"ABC123"'});
      });
      final oss = Pan115OssClient(client);
      final etag = await oss.uploadPart(
        token, 'bucket1', 'obj.bin', 'U123', 1, [1, 2, 3],
      );
      expect(etag, '"ABC123"');
    });

    test('completeMultipart：XML 按片号排序，203 算回调失败', () async {
      String? sentBody;
      final okClient = MockClient((request) async {
        sentBody = request.body;
        expect(request.headers['content-type'], contains('text/xml'));
        expect(request.headers['x-oss-callback'], isNotEmpty);
        return http.Response('{"state":true}', 200);
      });
      final oss = Pan115OssClient(okClient);
      await oss.completeMultipart(token, 'bucket1', 'obj.bin', 'U123', [
        const Pan115OssPart(partNumber: 2, etag: '"E2"'),
        const Pan115OssPart(partNumber: 1, etag: '"E1"'),
      ], 'cb', 'cbv');
      expect(
        sentBody,
        '<CompleteMultipartUpload>'
        '<Part><PartNumber>1</PartNumber><ETag>"E1"</ETag></Part>'
        '<Part><PartNumber>2</PartNumber><ETag>"E2"</ETag></Part>'
        '</CompleteMultipartUpload>',
      );

      final failClient = MockClient((request) async {
        return http.Response('{"error":"bad callback"}', 203);
      });
      await expectLater(
        Pan115OssClient(failClient).completeMultipart(
          token, 'bucket1', 'obj.bin', 'U123',
          [const Pan115OssPart(partNumber: 1, etag: '"E1"')],
          'cb', 'cbv',
        ),
        throwsA(
          isA<Pan115OssException>()
              .having((e) => e.httpCode, 'httpCode', 203)
              .having((e) => e.message, 'message', contains('bad callback')),
        ),
      );
    });
  });

  group('uploadFile 编排（MockClient 全链）', () {
    final provider = Pan115Provider();

    http.Response jsonResponse(Object body, {int status = 200}) =>
        http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    Map<String, dynamic> uploadInfoBody() => {
      'state': true,
      'data': {
        'user_id': '123456',
        'userkey': 'abcdef0123456789abcdef0123456789',
        'size_limit': 0,
      },
    };

    test('秒传：status 2 直接完成，不碰 OSS', () async {
      var ossCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        if (request.url.path.contains('initupload')) {
          expect(request.headers['user-agent'], pan115UploadUserAgent);
          expect(request.url.queryParameters['k_ec'], isNotEmpty);
          final form = Uri.splitQueryString(
            utf8.decode(m115AesCbcDecrypt(request.bodyBytes)),
          );
          expect(form['fileid'], 'D68C19A0A345B7EAB78D5E11E991C026EC60DB63');
          expect(form['target'], 'U_1_42');
          expect(form['filename'], 'a.mp4');
          return jsonResponse({'statuscode': 0, 'status': 2});
        }
        ossCalls++;
        return http.Response('', 404);
      });
      await provider.uploadFile(
        client,
        cookieCreds,
        fileName: 'a.mp4',
        bytes: utf8.encode('abcdefghij'),
        targetFolderId: '42',
      );
      expect(ossCalls, 0);
    });

    test('二次校验：status 7 带区间 SHA1 再 init，第二轮表单可验', () async {
      var initCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        if (request.url.path.contains('initupload')) {
          initCalls++;
          final form = Uri.splitQueryString(
            utf8.decode(m115AesCbcDecrypt(request.bodyBytes)),
          );
          if (initCalls == 1) {
            expect(form.containsKey('sign_key'), isFalse);
            return jsonResponse({
              'statuscode': 0,
              'status': 7,
              'sign_key': 'key123',
              'sign_check': '2-5',
            });
          }
          expect(form['sign_key'], 'key123');
          // 区间 2-5（闭区间）= 'cdef'，SHA1 大写（独立向量）。
          expect(
            form['sign_val'],
            '25BF58983B8AB103FA88B4032503FC8B65651CA1',
          );
          return jsonResponse({'statuscode': 0, 'status': 2});
        }
        return http.Response('', 404);
      });
      await provider.uploadFile(
        client,
        cookieCreds,
        fileName: 'a.mp4',
        bytes: utf8.encode('abcdefghij'),
        targetFolderId: '42',
      );
      expect(initCalls, 2);
    });

    test('全链：status 1 走 OSS init/part/complete，gettoken 不带鉴权', () async {
      final seen = <String>[];
      final client = MockClient((request) async {
        final host = request.url.host;
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        if (request.url.path.contains('initupload')) {
          return jsonResponse({
            'statuscode': 0,
            'status': 1,
            'bucket': 'bucket1',
            'object': 'dir/obj.bin',
            'callback': {
              'callback': 'cb-content',
              'callback_var': 'cbv-content',
            },
          });
        }
        if (request.url.path.contains('gettoken')) {
          seen.add('gettoken');
          expect(request.headers['cookie'], isNull);
          expect(request.headers['authorization'], isNull);
          return jsonResponse({
            'StatusCode': '200',
            'AccessKeyId': 'AKID',
            'AccessKeySecret': 'SECRET',
            'SecurityToken': 'STSTOKEN',
          });
        }
        if (host == 'bucket1.oss-cn-shenzhen.aliyuncs.com') {
          if (request.method == 'POST' &&
              request.url.queryParameters.containsKey('uploads')) {
            seen.add('oss-init');
            return http.Response(
              '<InitiateMultipartUploadResult><UploadId>U123</UploadId>'
              '</InitiateMultipartUploadResult>',
              200,
            );
          }
          if (request.method == 'PUT') {
            seen.add('oss-part');
            expect(request.bodyBytes, utf8.encode('abcdefghij'));
            return http.Response('', 200, headers: {'etag': '"E1"'});
          }
          if (request.method == 'POST') {
            seen.add('oss-complete');
            expect(request.body, contains('<ETag>"E1"</ETag>'));
            return http.Response('{"state":true}', 200);
          }
        }
        return http.Response('', 404);
      });
      final progress = <int>[];
      await provider.uploadFile(
        client,
        cookieCreds,
        fileName: 'a.mp4',
        bytes: utf8.encode('abcdefghij'),
        targetFolderId: '42',
        onProgress: (sent, total) => progress.add(sent),
      );
      expect(seen, ['gettoken', 'oss-init', 'oss-part', 'oss-complete']);
      expect(progress, [10]);
    });

    test('complete 回 203 → 报错且 abort 收尾', () async {
      var aborted = false;
      final client = MockClient((request) async {
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        if (request.url.path.contains('initupload')) {
          return jsonResponse({
            'statuscode': 0,
            'status': 1,
            'bucket': 'bucket1',
            'object': 'obj.bin',
            'callback': {'callback': 'cb', 'callback_var': 'cbv'},
          });
        }
        if (request.url.path.contains('gettoken')) {
          return jsonResponse({
            'StatusCode': '200',
            'AccessKeyId': 'AKID',
            'AccessKeySecret': 'SECRET',
            'SecurityToken': 'STSTOKEN',
          });
        }
        if (request.method == 'DELETE') {
          aborted = true;
          return http.Response('', 204);
        }
        if (request.url.queryParameters.containsKey('uploads')) {
          return http.Response('<UploadId>U123</UploadId>', 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 200, headers: {'etag': '"E1"'});
        }
        return http.Response('{"error":"bad callback"}', 203);
      });
      await expectLater(
        provider.uploadFile(
          client,
          cookieCreds,
          fileName: 'a.mp4',
          bytes: utf8.encode('abcdefghij'),
          targetFolderId: '42',
        ),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('回调'),
          ),
        ),
      );
      expect(aborted, isTrue);
    });

    test('不允许上传/超限/空文件：先拦，不调 init', () async {
      var initCalls = 0;
      http.Client clientFor(Map<String, dynamic> infoData) =>
          MockClient((request) async {
            if (request.url.path == '/files/uploadinfo') {
              return jsonResponse({'state': true, 'data': infoData});
            }
            initCalls++;
            return jsonResponse({'statuscode': 0, 'status': 2});
          });

      await expectLater(
        provider.uploadFile(
          clientFor({
            'user_id': '1',
            'userkey': 'k',
            'upload_allowed': false,
            'upload_allowed_msg': '账号被限制上传',
          }),
          cookieCreds,
          fileName: 'a.mp4',
          bytes: [1],
          targetFolderId: '0',
        ),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            '账号被限制上传',
          ),
        ),
      );
      await expectLater(
        provider.uploadFile(
          clientFor({'user_id': '1', 'userkey': 'k', 'size_limit': 3}),
          cookieCreds,
          fileName: 'a.mp4',
          bytes: [1, 2, 3, 4],
          targetFolderId: '0',
        ),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('超过大小限制'),
          ),
        ),
      );
      await expectLater(
        provider.uploadFile(
          clientFor({'user_id': '1', 'userkey': 'k'}),
          cookieCreds,
          fileName: 'a.mp4',
          bytes: const [],
          targetFolderId: '0',
        ),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('文件为空'),
          ),
        ),
      );
      expect(initCalls, 0);
    });

    test('initupload 偶尔 401 自动重试一次；statusmsg 如实报', () async {
      var initCalls = 0;
      final retryClient = MockClient((request) async {
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        initCalls++;
        if (initCalls == 1) return http.Response('unauthorized', 401);
        return jsonResponse({'statuscode': 0, 'status': 2});
      });
      await provider.uploadFile(
        retryClient,
        cookieCreds,
        fileName: 'a.mp4',
        bytes: [1, 2, 3],
        targetFolderId: '0',
      );
      expect(initCalls, 2);

      final failClient = MockClient((request) async {
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        return jsonResponse({'statuscode': 999, 'statusmsg': '签名不对'});
      });
      await expectLater(
        provider.uploadFile(
          failClient,
          cookieCreds,
          fileName: 'a.mp4',
          bytes: [1, 2, 3],
          targetFolderId: '0',
        ),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('签名不对'),
          ),
        ),
      );
    });
  });
}
