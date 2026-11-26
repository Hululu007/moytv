import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/cloud_drive/cloud_115_upload.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_screen.dart';
import 'package:moyi/cloud_drive/cloud_m115_crypto.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 115 上传界面批（2026-11-26）：流式读本地文件 + 网盘页上传入口
/// 与账号信息位。协议向量沿用二期口径（独立参考实现生成）；
/// 真上传要真账号，列手机终验，这里只验本机能验的：流式来源的
/// SHA1/分片读与内存版逐字一致、uploadLocalFile 编排全链、界面
/// 三态（账号信息位/上传进度/失败原因）。
void main() {
  const cookieCreds = CloudCredentials(
    fields: {'cookie': 'UID=U1; CID=C1; SEID=S1'},
    savedAtMs: 1,
  );

  group('FilePan115UploadSource 流式来源', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('pan115_src_');
    });
    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('小文件：全量/区间 SHA1 与独立向量一致，按区间读字节', () async {
      final file = File('${dir.path}/a.mp4')
        ..writeAsBytesSync(utf8.encode('abcdefghij'));
      final source = FilePan115UploadSource(file, 10);
      expect(source.length, 10);
      // 向量与二期内存版同一组（SHA1('abcdefghij')、SHA1('cdef'))。
      expect(
        await source.sha1All(),
        'D68C19A0A345B7EAB78D5E11E991C026EC60DB63',
      );
      expect(
        await source.sha1Range(2, 5),
        '25BF58983B8AB103FA88B4032503FC8B65651CA1',
      );
      expect(await source.readRange(2, 6), utf8.encode('cdef'));
      expect(await source.readRange(0, 10), utf8.encode('abcdefghij'));
    });

    test('大文件：流式 SHA1 与一次性 SHA1 一致，跨界区间读正确', () async {
      // 3MB 规律内容：流式实现若整读/错位，结果都会与一次性算的对不上。
      final bytes = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
      final file = File('${dir.path}/big.bin')..writeAsBytesSync(bytes);
      final source = FilePan115UploadSource(file, bytes.length);
      expect(
        await source.sha1All(),
        crypto.sha1.convert(bytes).toString().toUpperCase(),
      );
      const start = 1024 * 1024 - 7;
      const end = 1024 * 1024 + 13;
      expect(
        await source.readRange(start, end),
        bytes.sublist(start, end),
      );
      expect(
        await source.sha1Range(start, end - 1),
        crypto.sha1.convert(bytes.sublist(start, end)).toString().toUpperCase(),
      );
    });
  });

  group('uploadLocalFile 编排（MockClient 全链）', () {
    final provider = Pan115Provider();
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('pan115_up_');
    });
    tearDown(() {
      dir.deleteSync(recursive: true);
    });

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

    test('秒传：文件名默认取文件本身的名字，fileid 是流式 SHA1', () async {
      final file = File('${dir.path}/a.mp4')
        ..writeAsBytesSync(utf8.encode('abcdefghij'));
      final client = MockClient((request) async {
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        if (request.url.path.contains('initupload')) {
          final form = Uri.splitQueryString(
            utf8.decode(m115AesCbcDecrypt(request.bodyBytes)),
          );
          expect(form['fileid'], 'D68C19A0A345B7EAB78D5E11E991C026EC60DB63');
          expect(form['filename'], 'a.mp4');
          expect(form['target'], 'U_1_42');
          return jsonResponse({'statuscode': 0, 'status': 2});
        }
        return http.Response('', 404);
      });
      await provider.uploadLocalFile(
        client,
        cookieCreds,
        file: file,
        targetFolderId: '42',
      );
    });

    test('二次校验：区间 SHA1 走流式读，第二轮表单可验', () async {
      final file = File('${dir.path}/a.mp4')
        ..writeAsBytesSync(utf8.encode('abcdefghij'));
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
            return jsonResponse({
              'statuscode': 0,
              'status': 7,
              'sign_key': 'key123',
              'sign_check': '2-5',
            });
          }
          expect(
            form['sign_val'],
            '25BF58983B8AB103FA88B4032503FC8B65651CA1',
          );
          return jsonResponse({'statuscode': 0, 'status': 2});
        }
        return http.Response('', 404);
      });
      await provider.uploadLocalFile(
        client,
        cookieCreds,
        file: file,
        targetFolderId: '42',
      );
      expect(initCalls, 2);
    });

    test('全链：OSS 分片体与文件内容逐字一致，进度报到全长', () async {
      final content = utf8.encode('abcdefghij');
      final file = File('${dir.path}/a.mp4')..writeAsBytesSync(content);
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
            expect(request.bodyBytes, content);
            return http.Response('', 200, headers: {'etag': '"E1"'});
          }
          if (request.method == 'POST') {
            seen.add('oss-complete');
            return http.Response('{"state":true}', 200);
          }
        }
        return http.Response('', 404);
      });
      final progress = <int>[];
      await provider.uploadLocalFile(
        client,
        cookieCreds,
        file: file,
        targetFolderId: '42',
        onProgress: (sent, total) => progress.add(sent),
      );
      expect(seen, ['gettoken', 'oss-init', 'oss-part', 'oss-complete']);
      expect(progress, [10]);
    });

    test('超过单片大小：按 10MB 切两片流式上传，每片只读自己那段', () async {
      // 10MB + 3 字节：第二片必须只有 3 字节，证明按片读而不是整读。
      final bytes = List<int>.generate(
        pan115OssPartSize + 3,
        (i) => (i * 7) % 256,
      );
      final file = File('${dir.path}/big.bin')..writeAsBytesSync(bytes);
      final partLengths = <int>[];
      final client = MockClient((request) async {
        final host = request.url.host;
        if (request.url.path == '/files/uploadinfo') {
          return jsonResponse(uploadInfoBody());
        }
        if (request.url.path.contains('initupload')) {
          final form = Uri.splitQueryString(
            utf8.decode(m115AesCbcDecrypt(request.bodyBytes)),
          );
          expect(
            form['fileid'],
            crypto.sha1.convert(bytes).toString().toUpperCase(),
          );
          expect(form['filesize'], '${bytes.length}');
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
        if (host == 'bucket1.oss-cn-shenzhen.aliyuncs.com') {
          if (request.method == 'POST' &&
              request.url.queryParameters.containsKey('uploads')) {
            return http.Response('<UploadId>U123</UploadId>', 200);
          }
          if (request.method == 'PUT') {
            partLengths.add(request.bodyBytes.length);
            if (request.url.queryParameters['partNumber'] == '2') {
              expect(request.bodyBytes, bytes.sublist(pan115OssPartSize));
            }
            return http.Response(
              '',
              200,
              headers: {'etag': '"E${request.url.queryParameters['partNumber']}"'},
            );
          }
          if (request.method == 'POST') {
            return http.Response('{"state":true}', 200);
          }
        }
        return http.Response('', 404);
      });
      var lastSent = 0;
      await provider.uploadLocalFile(
        client,
        cookieCreds,
        file: file,
        targetFolderId: '0',
        onProgress: (sent, total) {
          expect(total, bytes.length);
          lastSent = sent;
        },
      );
      expect(partLengths, [pan115OssPartSize, 3]);
      expect(lastSent, bytes.length);
    });

    test('文件不存在：干净中文错；空文件：先拦', () async {
      final client = MockClient((request) async => http.Response('', 404));
      await expectLater(
        provider.uploadLocalFile(
          client,
          cookieCreds,
          file: File('${dir.path}/missing.mp4'),
          targetFolderId: '0',
        ),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('读取所选文件失败'),
          ),
        ),
      );
      final empty = File('${dir.path}/empty.mp4')..writeAsBytesSync(const []);
      await expectLater(
        provider.uploadLocalFile(
          client,
          cookieCreds,
          file: empty,
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
    });
  });

  group('网盘页 115 界面（假 provider）', () {
    late LocalStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      store = LocalStore(prefs);
      await CloudCredentialStore(prefs).save('pan115', cookieCreds);
    });

    Future<void> pumpScreen(
      WidgetTester tester,
      _FakePan115Provider fake, {
      Pan115UploadPick? pick,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CloudDriveScreen(
            store: store,
            providers: [fake],
            uploadPicker: () async => pick,
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('账号信息位：昵称/ID/会员/容量都是接口真返回才显示', (tester) async {
      final fake = _FakePan115Provider();
      await pumpScreen(tester, fake);
      expect(find.text('昵称：测试昵称'), findsOneWidget);
      expect(find.text('账号 ID：123456'), findsOneWidget);
      expect(find.text('会员：永久会员'), findsOneWidget);
      expect(find.textContaining('容量：已用 512 MB / 共 1.0 GB'), findsOneWidget);
      expect(find.text('上传文件到根目录'), findsOneWidget);
    });

    testWidgets('账号信息位：字段没返回写缺省态，不编数据', (tester) async {
      final fake = _FakePan115Provider()
        ..account = const Pan115AccountInfo(userId: '123456')
        ..spaceError = CloudDriveException('容量接口坏了');
      await pumpScreen(tester, fake);
      expect(find.text('昵称：未返回'), findsOneWidget);
      expect(find.text('容量：未获取到'), findsOneWidget);
      // 会员字段没返回就不出现会员行。
      expect(find.textContaining('会员'), findsNothing);
    });

    testWidgets('账号信息位：两个接口都失败显示原因 + 重试，重试再拉', (tester) async {
      final fake = _FakePan115Provider()
        ..accountError = CloudDriveException('115 账号信息获取失败：未获取到用户信息')
        ..spaceError = CloudDriveException('115 容量信息获取失败');
      await pumpScreen(tester, fake);
      expect(
        find.text('账号信息获取失败：115 账号信息获取失败：未获取到用户信息'),
        findsOneWidget,
      );
      expect(fake.accountCalls, 1);
      fake.accountError = null;
      fake.spaceError = null;
      await tester.tap(find.text('重试'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(fake.accountCalls, 2);
      expect(find.text('昵称：测试昵称'), findsOneWidget);
    });

    testWidgets('上传：进度弹窗走到完成，关弹窗后有完成提示', (tester) async {
      final fake = _FakePan115Provider();
      final gate = Completer<void>();
      fake.uploadGate = gate;
      await pumpScreen(
        tester,
        fake,
        pick: (path: '/tmp/not-real/a.mp4', name: 'a.mp4'),
      );
      await tester.ensureVisible(find.text('上传文件到根目录'));
      await tester.pump();
      await tester.tap(find.text('上传文件到根目录'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('上传到 115 网盘'), findsOneWidget);
      expect(find.text('正在上传：4 B / 10 B'), findsOneWidget);
      expect(fake.uploadTarget, '0');
      expect(fake.uploadName, 'a.mp4');
      gate.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('上传完成，文件已存入网盘根目录。'), findsOneWidget);
      await tester.tap(find.text('完成'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('上传完成，文件已存入 115 网盘根目录'), findsOneWidget);
      // SnackBar 计时器走完，免得测试收尾报挂起。
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('上传失败：弹窗显示 provider 的中文原因', (tester) async {
      final fake = _FakePan115Provider()
        ..uploadError = CloudDriveException('115 上传初始化失败：服务器没有返回上传回调');
      await pumpScreen(
        tester,
        fake,
        pick: (path: '/tmp/not-real/a.mp4', name: 'a.mp4'),
      );
      await tester.ensureVisible(find.text('上传文件到根目录'));
      await tester.pump();
      await tester.tap(find.text('上传文件到根目录'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        find.text('上传失败：115 上传初始化失败：服务器没有返回上传回调'),
        findsOneWidget,
      );
      await tester.tap(find.text('关闭'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('上传到 115 网盘'), findsNothing);
    });
  });
}

/// 假 115 provider：只覆写本批用到的三个方法，其余走真实实现
/// （测试里不会被调到）。
class _FakePan115Provider extends Pan115Provider {
  Pan115AccountInfo account = const Pan115AccountInfo(
    userId: '123456',
    nickname: '测试昵称',
    vipForever: true,
  );
  Pan115SpaceInfo space = const Pan115SpaceInfo(
    totalBytes: 1024 * 1024 * 1024,
    usedBytes: 512 * 1024 * 1024,
    remainBytes: 512 * 1024 * 1024,
  );
  Object? accountError;
  Object? spaceError;
  Object? uploadError;
  Completer<void>? uploadGate;
  int accountCalls = 0;
  String? uploadTarget;
  String? uploadName;

  @override
  Future<Pan115AccountInfo> accountInfo(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    accountCalls++;
    final error = accountError;
    if (error != null) throw error;
    return account;
  }

  @override
  Future<Pan115SpaceInfo> spaceInfo(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    final error = spaceError;
    if (error != null) throw error;
    return space;
  }

  @override
  Future<void> uploadLocalFile(
    http.Client client,
    CloudCredentials credentials, {
    required File file,
    String? fileName,
    required String targetFolderId,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    uploadTarget = targetFolderId;
    uploadName = fileName;
    final error = uploadError;
    if (error != null) throw error;
    onProgress?.call(4, 10);
    final gate = uploadGate;
    if (gate != null) await gate.future;
    onProgress?.call(10, 10);
  }
}
