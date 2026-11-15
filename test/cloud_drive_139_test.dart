import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/cloud_drive/cloud_aes.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';
import 'package:moyi/cloud_drive/cloud_provider_139.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 与 provider 内常量一致的测试用密钥（协议事实值，Mock 服务端用它们
/// 说同一套线上协议，验证 provider 的加解密与字段）。
const _apiKey = '2olBaQGYnEKoStYomsd1n7ax';
const _puzzleKey = 'CREATPUZZLE03F9A';
const _loginKey = 'gB^gGdQHX1l+XteY';
const _sliderKey = 'qPqDw263XgFgL3u8';
const _phone = '13800138000';

Uint8List _hexBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexOf(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

http.Response _jsonResponse(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _envelopeResponse(Map<String, dynamic> body) => http.Response(
  yun139ApiEnvelopeEncrypt(jsonEncode(body), _apiKey),
  200,
);

Yun139DeviceInfo _fixedDevice() {
  final deviceInfo = [
    '1',
    '127.0.0.1',
    '1',
    '13.1.0',
    'Xiaomi',
    '2211133C',
    'AABBCCDDEEFF00112233445566778899',
    '02-00-00-00-00-00',
    'android 14',
    '1220X2712',
    'zh',
    '',
    '',
    '',
    '000',
    '0',
    '',
  ].join('|');
  return Yun139DeviceInfo(
    brand: 'Xiaomi',
    model: '2211133C',
    os: 'android 14',
    screen: '1220X2712',
    deviceId: 'AABBCCDDEEFF00112233445566778899',
    deviceInfo: deviceInfo,
    userAgent: 'android|2211133C|android 14|mCloud13.1.0-000',
  );
}

CloudCredentials _credentials139({
  String token = 'tok-1',
  String tokenExpireTime = '',
  int savedAtMs = 1,
}) {
  final device = _fixedDevice();
  return CloudCredentials(
    fields: {
      'authorization':
          'Basic ${base64Encode(utf8.encode('mobile:$_phone:$token'))}',
      'x-yun-uni': 'ud-1',
      'user_domain_id': 'ud-1',
      'token': token,
      'phone': _phone,
      'account': _phone,
      'device_info': device.deviceInfo,
      'device_user_agent': device.userAgent,
      'token_expire_time': tokenExpireTime,
    },
    savedAtMs: savedAtMs,
    label: '138****8000',
  );
}

/// 假 139 服务端：说真实线上协议（信封加解密、字段、滑块回落），
/// 行为由开关控制，调用次数与请求内容可断言。
class _Fake139Server {
  /// 加密短信通道：ok | risk（风控）| protocol（响应解不开）| fail（发送失败）。
  String smsEncryptedMode = 'ok';

  /// 明文短信通道：sent | captcha（要滑块）| fail。
  String smsPlainMode = 'sent';
  String validCode = '123456';

  Map<String, dynamic> loginData = {
    'token': 'tok-123',
    'authToken': 'tok-123',
    'account': _phone,
    'userDomainId': 'ud-1',
  };

  int encryptedSmsCalls = 0;
  int verifyCalls = 0;
  int plainSmsCalls = 0;
  int loginCalls = 0;
  bool loginWasPlain = false;
  bool loginWasEncrypted = false;
  final List<Map<String, dynamic>> encryptedBodies = [];
  final List<Map<String, String>> loginHeaders = [];
  final List<Map<String, dynamic>> loginBodies = [];

  Future<http.Response> handler(http.Request request) async {
    final path = request.url.path;
    if (path == '/user/sms/getSmsCode') {
      if (request.body.startsWith('{')) {
        plainSmsCalls++;
        switch (smsPlainMode) {
          case 'captcha':
            return _jsonResponse({
              'success': false,
              'code': '200059554',
              'message': '需要安全验证',
              'data': {'captchaType': 2},
            });
          case 'fail':
            return _jsonResponse({'success': false, 'message': '发送过于频繁'});
          default:
            return _jsonResponse({'success': true, 'message': '验证码已发送'});
        }
      }
      encryptedSmsCalls++;
      final body =
          jsonDecode(yun139ApiEnvelopeDecrypt(request.body, _apiKey))
              as Map<String, dynamic>;
      encryptedBodies.add(body);
      if (body.containsKey('puzzleVerfycode')) {
        if (smsEncryptedMode == 'fail') {
          return _envelopeResponse({
            'success': false,
            'message': '发送失败',
            'code': '500',
          });
        }
        return _envelopeResponse({'success': true, 'message': '验证码已发送'});
      }
      return _envelopeResponse({'success': true});
    }
    if (path == '/user/verfycode') {
      verifyCalls++;
      final body =
          jsonDecode(yun139ApiEnvelopeDecrypt(request.body, _apiKey))
              as Map<String, dynamic>;
      encryptedBodies.add(body);
      switch (smsEncryptedMode) {
        case 'risk':
          return _envelopeResponse({
            'success': false,
            'code': '200059554',
            'message': '需要安全验证',
            'data': {'captchaType': 2},
          });
        case 'protocol':
          return http.Response('not-a-valid-envelope!!!', 200);
        default:
          return _envelopeResponse({
            'success': true,
            'data': {
              'puzzleLeft': yun139ApiEnvelopeEncrypt(
                'puzzle-answer',
                _puzzleKey,
              ),
            },
          });
      }
    }
    if (path == '/user/thirdlogin') {
      loginCalls++;
      if (request.body.startsWith('{')) {
        loginWasPlain = true;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        loginBodies.add(body);
        loginHeaders.add({
          for (final e in request.headers.entries)
            e.key.toLowerCase(): e.value,
        });
        if (body['dycpwd'] != validCode) {
          return _jsonResponse({'success': false, 'message': '验证码错误'});
        }
        final dataHex = _hexOf(
          aesEcbEncrypt(
            Uint8List.fromList(utf8.encode(_sliderKey)),
            Uint8List.fromList(utf8.encode(jsonEncode(loginData))),
          ),
        );
        return _jsonResponse({'success': true, 'data': dataHex});
      }
      loginWasEncrypted = true;
      final body =
          jsonDecode(yun139LoginPayloadDecrypt(request.body, _loginKey))
              as Map<String, dynamic>;
      loginBodies.add(body);
      if (body['dycpwd'] != validCode) {
        return _jsonResponse({'success': false, 'message': '验证码错误'});
      }
      return _jsonResponse({
        'success': true,
        'data': yun139LoginPayloadEncrypt(jsonEncode(loginData), _loginKey),
      });
    }
    return http.Response('unexpected path: $path', 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Yun139Provider provider;
  late _Fake139Server server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    provider = Yun139Provider(fixedDevice: _fixedDevice());
    server = _Fake139Server();
  });

  group('AES', () {
    test('ECB 标准向量：128/192/256 加密与解密', () {
      const plainHex = '00112233445566778899aabbccddeeff';
      const vectors = {
        16: '69c4e0d86a7b0430d8cdb78070b4c55a',
        24: 'dda97ca4864cdfe06eaf70a0ec0d7191',
        32: '8ea2b7ca516745bfeafc49904b496089',
      };
      for (final entry in vectors.entries) {
        final key = Uint8List.fromList(List<int>.generate(entry.key, (i) => i));
        final cipher = aesEncryptBlock(key, _hexBytes(plainHex));
        expect(_hexOf(cipher), entry.value);
        expect(
          aesDecryptBlock(key, cipher),
          _hexBytes(plainHex),
        );
      }
    });

    test('CBC 标准向量首块 + 往返', () {
      final key = _hexBytes('2b7e151628aed2a6abf7158809cf4f3c');
      final iv = _hexBytes('000102030405060708090a0b0c0d0e0f');
      final plain = _hexBytes('6bc1bee22e409f96e93d7e117393172a');
      final cipher = aesCbcEncrypt(key, iv, plain);
      expect(_hexOf(cipher.sublist(0, 16)), '7649abac8119b246cee98e9b12e9197d');
      expect(aesCbcDecrypt(key, iv, cipher), plain);
    });

    test('CBC/ECB 往返：空输入、整块、非整块、三种密钥长度', () {
      for (final keyLength in [16, 24, 32]) {
        final key = Uint8List.fromList(
          List<int>.generate(keyLength, (i) => i * 7 + 1),
        );
        final iv = Uint8List.fromList(List<int>.generate(16, (i) => i));
        for (final length in [0, 1, 15, 16, 17, 64]) {
          final plain = Uint8List.fromList(
            List<int>.generate(length, (i) => (i * 31 + 5) % 256),
          );
          expect(aesCbcDecrypt(key, iv, aesCbcEncrypt(key, iv, plain)), plain);
          expect(aesEcbDecrypt(key, aesEcbEncrypt(key, plain)), plain);
        }
      }
    });

    test('填充被改抛错、密钥长度不对抛错', () {
      final key = Uint8List(16);
      final cipher = aesEcbEncrypt(key, Uint8List.fromList([1, 2, 3]));
      final tampered = Uint8List.fromList(cipher);
      tampered[cipher.length - 1] ^= 0xFF;
      expect(() => aesEcbDecrypt(key, tampered), throwsFormatException);
      expect(
        () => aesEcbEncrypt(Uint8List(15), Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('接口信封往返：24 字节密钥与 16 字节密钥，过短抛错', () {
      const text = '{"clientType":"414","phoneNumber":"13800138000"}';
      for (final key in [_apiKey, _puzzleKey]) {
        final envelope = yun139ApiEnvelopeEncrypt(text, key);
        expect(yun139ApiEnvelopeDecrypt(envelope, key), text);
        // 每次加密 IV 不同，密文不同。
        expect(yun139ApiEnvelopeEncrypt(text, key), isNot(envelope));
      }
      expect(
        () => yun139ApiEnvelopeDecrypt(base64Encode([1, 2, 3]), _apiKey),
        throwsFormatException,
      );
    });

    test('登录载荷往返：旋转格式与滑块格式各走各的解密', () {
      const text = '{"msisdn":"13800138000","dycpwd":"123456"}';
      final payload = yun139LoginPayloadEncrypt(text, _loginKey);
      expect(yun139LoginPayloadDecrypt(payload, _loginKey), text);
      // 旋转确实发生了：载荷 hex 与不旋转的 ECB hex 不同。
      final plainEcbHex = _hexOf(
        aesEcbEncrypt(
          Uint8List.fromList(utf8.encode(_loginKey)),
          Uint8List.fromList(utf8.encode(text)),
        ),
      );
      expect(payload, isNot(plainEcbHex));
      // 滑块格式：ECB hex 直接解密。
      final sliderHex = _hexOf(
        aesEcbEncrypt(
          Uint8List.fromList(utf8.encode(_sliderKey)),
          Uint8List.fromList(utf8.encode(text)),
        ),
      );
      expect(yun139SliderLoginDecrypt(sliderHex, _sliderKey), text);
    });
  });

  group('滑块头与滑块页地址', () {
    test('滑块登录头固定可复现：15 段设备串', () {
      final first = yun139SliderLoginHeaders();
      final second = yun139SliderLoginHeaders();
      expect(first, second);
      expect(first.keys, containsAll(
        ['x-DeviceInfo', 'x-yun-client-info', 'x-NationCode'],
      ));
      expect(first['x-NationCode'], '+86');
      final segments = first['x-DeviceInfo']!.split('|');
      expect(segments.length, 15);
      expect(segments[3], '7.17.7');
      expect(segments[4], 'Win32');
      expect(segments[5], 'Win32');
      expect(segments[8], 'Chrome 126.0.0.0');
      expect(segments[9], '1920X1080');
    });

    test('滑块页地址：data 参数解出手机号与设备头', () {
      final url = yun139CaptchaUrl(_phone, _fixedDevice());
      expect(url, startsWith('https://yun.139.com/fe/captcha/?data='));
      final encoded = url.substring(url.indexOf('data=') + 5);
      final payload =
          jsonDecode(utf8.decode(base64Decode(encoded))) as Map<String, dynamic>;
      expect(payload['captchaType'], 2);
      final params = payload['params'] as Map<String, dynamic>;
      expect(params['clientType'], '414');
      expect(params['nationCode'], '+86');
      expect(params['phoneNumber'], _phone);
      expect(params['reqType'], '3');
      final headers = payload['headers'] as Map<String, dynamic>;
      expect(headers['x-yun-app-channel'], '10000023');
      expect(headers['x-yun-client-info'], _fixedDevice().deviceInfo);
    });
  });

  group('短信 + 登录（免滑块通道）', () {
    test('发短信走三次加密请求，登录走加密载荷，凭证存入 store', () async {
      final client = MockClient(server.handler);
      final result = await provider.sendSms(client, _phone);
      expect(result.requiresCaptcha, isFalse);
      expect(result.mode, Yun139SmsMode.noSlider);
      expect(server.encryptedSmsCalls, 2);
      expect(server.verifyCalls, 1);
      expect(server.plainSmsCalls, 0);
      // 预验证与终发短信的字段。
      final first = server.encryptedBodies[0];
      expect(first['clientType'], '414');
      expect(first['mode'], '0');
      expect(first['phoneNumber'], _phone);
      expect(first['reqType'], '3');
      expect((first['random'] as String).length, 6);
      // 验证接口的字段。
      final verify = server.encryptedBodies[1];
      expect(verify['account'], _phone);
      expect(verify['type'], '2');
      // 终发带拼图校验码。
      final second = server.encryptedBodies[2];
      expect((second['puzzleVerfycode'] as String).isNotEmpty, isTrue);

      final credentials = await provider.loginWithSms(client, _phone, '123456');
      expect(server.loginWasEncrypted, isTrue);
      expect(server.loginWasPlain, isFalse);
      final loginBody = server.loginBodies.single;
      expect(loginBody['clienttype'], '414');
      expect(loginBody['cpid'], '58');
      expect(loginBody['dycpwd'], '123456');
      expect(loginBody['msisdn'], _phone);
      expect(loginBody['pintype'], '8');
      expect(loginBody['loginMode'], '1');
      expect(loginBody['version'], '30131040');
      expect(credentials.fields['token'], 'tok-123');
      expect(credentials.fields['x-yun-uni'], 'ud-1');
      expect(credentials.fields['phone'], _phone);
      expect(credentials.fields['device_info'], _fixedDevice().deviceInfo);
      expect(
        credentials.fields['device_user_agent'],
        _fixedDevice().userAgent,
      );
      expect(
        credentials.fields['authorization'],
        'Basic ${base64Encode(utf8.encode('mobile:$_phone:tok-123'))}',
      );
      expect(credentials.label, '138****8000');

      final prefs = await SharedPreferences.getInstance();
      final store = CloudCredentialStore(prefs);
      await store.save('yun139', credentials);
      final loaded = store.load('yun139');
      expect(loaded, isNotNull);
      expect(loaded!.fields, credentials.fields);
    });

    test('验证码错误：抛错不断言成功', () async {
      final client = MockClient(server.handler);
      await provider.sendSms(client, _phone);
      await expectLater(
        provider.loginWithSms(client, _phone, '000000'),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('验证码错误'),
          ),
        ),
      );
    });

    test('手机号/验证码格式不对：不发任何请求', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 404);
      });
      await expectLater(
        provider.sendSms(client, '123'),
        throwsA(isA<CloudDriveException>()),
      );
      await expectLater(
        provider.loginWithSms(client, _phone, '12345'),
        throwsA(isA<CloudDriveException>()),
      );
      await expectLater(
        provider.loginWithSms(client, 'abc', '123456'),
        throwsA(isA<CloudDriveException>()),
      );
      expect(requests, 0);
    });

    test('扫码方法抛 UnsupportedError', () async {
      final client = MockClient((_) async => http.Response('', 404));
      await expectLater(
        provider.startQrLogin(client),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        provider.pollQrLogin(
          client,
          QrLoginSession(
            qrContent: '',
            qrImageUrl: '',
            message: '',
            state: const {},
            expiresAt: DateTime.now(),
          ),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('短信 + 登录（滑块回落）', () {
    test('风控回落：返回滑块页与滑块头，带头登录走明文通道', () async {
      server.smsEncryptedMode = 'risk';
      server.smsPlainMode = 'captcha';
      final client = MockClient(server.handler);
      final result = await provider.sendSms(client, _phone);
      expect(result.requiresCaptcha, isTrue);
      expect(result.mode, Yun139SmsMode.slider);
      expect(result.captchaUrl, startsWith('https://yun.139.com/fe/captcha/'));
      expect(
        result.sliderHeaders.keys,
        containsAll(
          ['x-DeviceInfo', 'x-yun-client-info', 'x-NationCode'],
        ),
      );
      expect(server.plainSmsCalls, 1);

      final credentials = await provider.loginWithSms(
        client,
        _phone,
        '123456',
        sliderHeaders: result.sliderHeaders,
      );
      expect(server.loginWasPlain, isTrue);
      expect(server.loginWasEncrypted, isFalse);
      expect(
        server.loginHeaders.single['x-deviceinfo'],
        result.sliderHeaders['x-DeviceInfo'],
      );
      expect(credentials.fields['token'], 'tok-123');
    });

    test('协议对不上回落：明文短信直发成功，登录按普通通道记忆走', () async {
      server.smsEncryptedMode = 'protocol';
      server.smsPlainMode = 'sent';
      final client = MockClient(server.handler);
      final result = await provider.sendSms(client, _phone);
      expect(result.requiresCaptcha, isFalse);
      expect(result.mode, Yun139SmsMode.slider);
      await provider.loginWithSms(client, _phone, '123456');
      expect(server.loginWasPlain, isTrue);
    });

    test('两条通道都失败：抛服务端文案', () async {
      server.smsEncryptedMode = 'risk';
      server.smsPlainMode = 'fail';
      final client = MockClient(server.handler);
      await expectLater(
        provider.sendSms(client, _phone),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('发送过于频繁'),
          ),
        ),
      );
    });
  });

  group('列表解析', () {
    late List<Map<String, dynamic>> seenBodies;
    late List<Map<String, String>> seenHeaders;

    MockClient listClient() {
      seenBodies = [];
      seenHeaders = [];
      return MockClient((request) async {
        expect(request.url.path, '/hcy/file/list');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        seenBodies.add(body);
        seenHeaders.add({
          for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
        });
        final cursor = (body['pageInfo'] as Map)['pageCursor'];
        if (cursor == null) {
          return _jsonResponse({
            'success': true,
            'data': {
              'items': [
                {
                  'fileId': 'f1',
                  'name': '剧集',
                  'type': 'folder',
                  'size': 0,
                  'updatedAt': '2026-11-01T10:00:00Z',
                },
                {
                  'fileId': 'v1',
                  'name': '正片.mp4',
                  'type': 'file',
                  'size': 123456,
                  'updatedAt': 1762000000000,
                  'thumbnailUrls': {
                    'Small': 'https://t/s.jpg',
                    'Big': 'https://t/b.jpg',
                  },
                  'mediaMetaInfo': {'duration': 3661},
                },
                {
                  'fileId': 'v2',
                  'name': '短片.mp4',
                  'contentType': 'content',
                  'fileSize': '999',
                  'createdAt': '2026-10-01T00:00:00Z',
                  'thumbnailUrls': ['https://t/only.jpg'],
                  'mediaMetaInfo': {'duration': 90000},
                },
              ],
              'nextPageCursor': 'cur2',
            },
          });
        }
        return _jsonResponse({
          'success': true,
          'data': {'items': [], 'nextPageCursor': 'cur2'},
        });
      });
    }

    test('第一页字段解析：文件夹/视频、大小、时间、缩略图、时长', () async {
      final client = listClient();
      final page = await provider.listFolder(client, _credentials139(), '/', 1);
      expect(page.hasMore, isTrue);
      expect(page.files.length, 3);
      final folder = page.files[0];
      expect(folder.isFolder, isTrue);
      expect(folder.kind, CloudFileKind.folder);
      expect(folder.name, '剧集');
      expect(
        folder.modifiedMs,
        DateTime.parse('2026-11-01T10:00:00Z').millisecondsSinceEpoch,
      );
      final video = page.files[1];
      expect(video.isFolder, isFalse);
      expect(video.kind, CloudFileKind.video);
      expect(video.sizeBytes, 123456);
      expect(video.modifiedMs, 1762000000000);
      expect(video.thumbnailUrl, 'https://t/b.jpg');
      expect(video.durationSeconds, 3661);
      final short = page.files[2];
      expect(short.isFolder, isFalse);
      expect(short.sizeBytes, 999);
      expect(short.thumbnailUrl, 'https://t/only.jpg');
      // 90000 按毫秒算成 90 秒。
      expect(short.durationSeconds, 90);

      // 请求体与请求头按源头格式。
      final body = seenBodies.single;
      expect(body['parentFileId'], '/');
      expect(body['orderBy'], 'updated_at');
      expect(body['orderDirection'], 'DESC');
      expect(body['parentFilePath'], isTrue);
      expect(
        (body['fields'] as String),
        contains('thumbnailUrls'),
      );
      expect(
        (body['fields'] as String),
        contains('mediaMetaInfo'),
      );
      expect(body['imageThumbnailStyleList'], ['Small', 'Big']);
      final pageInfo = body['pageInfo'] as Map<String, dynamic>;
      expect(pageInfo['pageSize'], 100);
      expect(pageInfo['pageCursor'], isNull);
      final headers = seenHeaders.single;
      expect(headers['x-yun-api-version'], 'v2');
      expect(headers['x-yun-uni'], 'ud-1');
      expect(headers['authorization'], contains('Basic '));
      expect(headers['x-yun-client-info'], _fixedDevice().deviceInfo);
    });

    test('第二页走游标：游标重复/无数据时 hasMore 为假', () async {
      final client = listClient();
      final page = await provider.listFolder(client, _credentials139(), '/', 2);
      expect(seenBodies.length, 2);
      expect(
        (seenBodies[1]['pageInfo'] as Map)['pageCursor'],
        'cur2',
      );
      expect(page.files, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('列表失败：抛服务端文案', () async {
      final client = MockClient((_) async => _jsonResponse({
            'success': false,
            'message': '登录已失效',
          }));
      await expectLater(
        provider.listFolder(client, _credentials139(), '/', 1),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('登录已失效'),
          ),
        ),
      );
    });

    test('搜索抛 UnsupportedError（引擎走列表过滤兜底）', () async {
      final client = MockClient((_) async => http.Response('', 404));
      await expectLater(
        provider.search(client, _credentials139(), '正片', '/'),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('直链解析', () {
    test('直链请求体与头按源头格式，返回可播地址与播放头', () async {
      Map<String, dynamic>? seenBody;
      Map<String, String>? seenHeaders;
      final client = MockClient((request) async {
        expect(request.url.path, '/hcy/file/getDownloadUrl');
        seenBody = jsonDecode(request.body) as Map<String, dynamic>;
        seenHeaders = {
          for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
        };
        return _jsonResponse({
          'success': true,
          'data': {'url': 'https://cdn.example.com/play.mp4?token=abc'},
        });
      });
      final file = CloudDriveFile(
        id: 'v1',
        name: '正片.mp4',
        isFolder: false,
        kind: CloudFileKind.video,
      );
      final link = await provider.directLink(client, _credentials139(), file);
      expect(link.url, 'https://cdn.example.com/play.mp4?token=abc');
      expect(link.headers['Referer'], 'https://yun.139.com/');
      expect(link.headers['User-Agent'], contains('Chrome/111.0.0.0'));
      expect(seenBody!['fileId'], 'v1');
      expect(seenBody!['fileName'], '正片.mp4.mcloud.downloading');
      expect(seenHeaders!['x-yun-url-type'], '1');
      expect(seenHeaders!['x-yun-api-version'], 'v1');
      expect(seenHeaders!['x-yun-uni'], 'ud-1');
    });

    test('直链为空抛错', () async {
      final client = MockClient((_) async => _jsonResponse({
            'success': true,
            'data': {'url': ''},
          }));
      final file = CloudDriveFile(
        id: 'v1',
        name: '正片.mp4',
        isFolder: false,
        kind: CloudFileKind.video,
      );
      await expectLater(
        provider.directLink(client, _credentials139(), file),
        throwsA(isA<CloudDriveException>()),
      );
    });
  });

  group('刷新', () {
    test('刷新换新 token，设备与账号保留', () async {
      Map<String, dynamic>? seenBody;
      final client = MockClient((request) async {
        expect(request.url.path, '/user/auth/refreshToken');
        seenBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonResponse({
          'success': true,
          'data': {'token': 'tok-2', 'expireTime': 7200},
        });
      });
      final refreshed = await provider.refreshCredentials(
        client,
        _credentials139(),
      );
      expect(seenBody, {'clientType': '414'});
      expect(refreshed.fields['token'], 'tok-2');
      expect(
        refreshed.fields['authorization'],
        'Basic ${base64Encode(utf8.encode('mobile:$_phone:tok-2'))}',
      );
      expect(refreshed.fields['token_expire_time'], '7200');
      expect(refreshed.fields['x-yun-uni'], 'ud-1');
      expect(refreshed.fields['device_info'], _fixedDevice().deviceInfo);
      expect(refreshed.fields['phone'], _phone);
    });

    test('token 将过期时列表先刷新，并通知引擎落盘', () async {
      var refreshCalls = 0;
      String? listAuthorization;
      CloudCredentials? notified;
      provider.onCredentialsRefreshed = (_, creds) => notified = creds;
      final client = MockClient((request) async {
        if (request.url.path == '/user/auth/refreshToken') {
          refreshCalls++;
          return _jsonResponse({
            'success': true,
            'data': {'token': 'tok-2', 'expireTime': 7200},
          });
        }
        listAuthorization = request.headers.entries
            .firstWhere((e) => e.key.toLowerCase() == 'authorization')
            .value;
        return _jsonResponse({
          'success': true,
          'data': {'items': [], 'nextPageCursor': ''},
        });
      });
      // expireTime '1' = 保存后 1 秒过期，savedAtMs=1 早已过期。
      await provider.listFolder(
        client,
        _credentials139(tokenExpireTime: '1'),
        '/',
        1,
      );
      expect(refreshCalls, 1);
      expect(
        listAuthorization,
        'Basic ${base64Encode(utf8.encode('mobile:$_phone:tok-2'))}',
      );
      expect(notified, isNotNull);
      expect(notified!.fields['token'], 'tok-2');
    });

    test('算不出过期时间时不刷新', () async {
      var refreshCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/user/auth/refreshToken') {
          refreshCalls++;
          return _jsonResponse({'success': true, 'data': {'token': 'x'}});
        }
        return _jsonResponse({
          'success': true,
          'data': {'items': [], 'nextPageCursor': ''},
        });
      });
      await provider.listFolder(client, _credentials139(), '/', 1);
      expect(refreshCalls, 0);
    });

    test('刷新失败抛错', () async {
      final client = MockClient((_) async => _jsonResponse({
            'success': false,
            'message': '刷新失败',
          }));
      await expectLater(
        provider.refreshCredentials(client, _credentials139()),
        throwsA(isA<CloudDriveException>()),
      );
    });
  });

  group('注册', () {
    test('注册表含 yun139 且 id 不冲突', () {
      final providers = createCloudDriveProviders();
      final ids = providers.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids, contains('yun139'));
      expect(ids.where((id) => id == 'yun139').length, 1);
      expect(cloudDriveDisplayNames['yun139'], '移动云盘');
      final yun139 = providers.firstWhere((p) => p.id == 'yun139');
      expect(yun139, isA<Yun139Provider>());
      expect(yun139.displayName, '移动云盘');
      expect(yun139.rootFolderId, '/');
    });
  });
}
