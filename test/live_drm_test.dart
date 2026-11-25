import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_drm.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/models.dart';

LiveChannel _channel({String licenseKey = '', String licenseType = ''}) {
  return LiveChannel(
    key: 'k',
    name: '测试台',
    urls: const ['https://example.com/live.mpd'],
    licenseKey: licenseKey,
    licenseType: licenseType,
  );
}

List<int> _b64urlDecode(String value) {
  var padded = value;
  while (padded.length % 4 != 0) {
    padded += '=';
  }
  return base64Url.decode(padded);
}

List<int> _hexBytes(String hex) {
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}

void main() {
  group('liveDrmForChannel 服务器型', () {
    test('Widevine 地址 + 许可证请求头（| 后参数）', () {
      final drm = liveDrmForChannel(_channel(
        licenseKey:
            'https://lic.example/wv|Authorization=Bearer abc&X-Id=7',
        licenseType: 'com.widevine.alpha',
      ));
      expect(drm, isNotNull);
      expect(drm!.type, 'com.widevine.alpha');
      expect(drm.key, 'https://lic.example/wv');
      expect(drm.headers, {'Authorization': 'Bearer abc', 'X-Id': '7'});
    });

    test('Kodi 模板段（R{SSM} 等）不被当成请求头', () {
      final drm = liveDrmForChannel(_channel(
        licenseKey: 'https://lic.example/wv||R{SSM}|R',
        licenseType: 'com.widevine.alpha',
      ));
      expect(drm, isNotNull);
      expect(drm!.key, 'https://lic.example/wv');
      expect(drm.headers, isEmpty);
    });

    test('type 为空归一化不出（不猜体系）', () {
      expect(
        liveDrmForChannel(_channel(licenseKey: 'https://lic.example/wv')),
        isNull,
      );
    });

    test('Widevine 给本地键（非地址）归一化不出', () {
      expect(
        liveDrmForChannel(_channel(
          licenseKey: '00112233445566778899aabbccddeeff:'
              '000102030405060708090a0b0c0d0e0f',
          licenseType: 'com.widevine.alpha',
        )),
        isNull,
      );
    });
  });

  group('liveDrmForChannel ClearKey 本地键', () {
    const kidHex = '000102030405060708090a0b0c0d0e0f';
    const keyHex = '00112233445566778899aabbccddeeff';

    test('十六进制 kid:key 转 JWK，字节往返一致', () {
      final drm = liveDrmForChannel(_channel(
        licenseKey: '$kidHex:$keyHex',
        licenseType: 'org.w3.clearkey',
      ));
      expect(drm, isNotNull);
      final jwk = jsonDecode(drm!.key) as Map<String, dynamic>;
      expect(jwk['type'], 'temporary');
      final keys = jwk['keys'] as List;
      expect(keys, hasLength(1));
      final entry = keys.single as Map<String, dynamic>;
      expect(entry['kty'], 'oct');
      expect(_b64urlDecode(entry['kid'] as String), _hexBytes(kidHex));
      expect(_b64urlDecode(entry['k'] as String), _hexBytes(keyHex));
    });

    test('多对键全部带上', () {
      final drm = liveDrmForChannel(_channel(
        licenseKey: '$kidHex:$keyHex,$keyHex:$kidHex',
        licenseType: 'org.w3.clearkey',
      ));
      final jwk = jsonDecode(drm!.key) as Map<String, dynamic>;
      expect(jwk['keys'] as List, hasLength(2));
    });

    test('现成 JWK JSON 原样透传', () {
      const jwkIn = '{"keys":[{"kty":"oct","k":"AA","kid":"AQ"}],'
          '"type":"temporary"}';
      final drm = liveDrmForChannel(_channel(
        licenseKey: jwkIn,
        licenseType: 'org.w3.clearkey',
      ));
      expect(drm!.key, jwkIn);
    });

    test('坏十六进制归一化不出', () {
      expect(
        liveDrmForChannel(_channel(
          licenseKey: 'zzzz:$keyHex',
          licenseType: 'org.w3.clearkey',
        )),
        isNull,
      );
    });

    test('drm_legacy 整行（类型|键）能还原', () {
      final drm = liveDrmForChannel(_channel(
        licenseKey: 'org.w3.clearkey|$kidHex:$keyHex',
        licenseType: 'org.w3.clearkey',
      ));
      expect(drm, isNotNull);
      expect(drm!.type, 'org.w3.clearkey');
      final jwk = jsonDecode(drm.key) as Map<String, dynamic>;
      expect(jwk['keys'] as List, hasLength(1));
    });
  });

  group('PlaybackDrm.fromJson', () {
    test('FongMi 形态 {key,type,header,forceKey}', () {
      final drm = PlaybackDrm.fromJson({
        'key': 'https://lic.example/wv',
        'type': 'com.widevine.alpha',
        'header': {'Authorization': 'Bearer x'},
        'forceKey': true,
      });
      expect(drm, isNotNull);
      expect(drm!.key, 'https://lic.example/wv');
      expect(drm.headers, {'Authorization': 'Bearer x'});
      expect(drm.forceKey, isTrue);
    });

    test('本站 toJson 往返', () {
      const src = PlaybackDrm(
        type: 'org.w3.clearkey',
        key: '{"keys":[]}',
        headers: {'A': 'b'},
      );
      final back = PlaybackDrm.fromJson(src.toJson());
      expect(back!.type, src.type);
      expect(back.key, src.key);
      expect(back.headers, src.headers);
    });

    test('字段不全返回 null', () {
      expect(PlaybackDrm.fromJson({'type': 'com.widevine.alpha'}), isNull);
      expect(PlaybackDrm.fromJson(null), isNull);
      expect(PlaybackDrm.fromJson('x'), isNull);
    });
  });

  group('PlaybackPlan 透传', () {
    test('fromJson 带 drm 时 hasDrm 为真，withUrl 不丢', () {
      final plan = PlaybackPlan.fromJson({
        'url': 'https://example.com/a.mpd',
        'drm': {
          'key': 'https://lic.example/wv',
          'type': 'com.widevine.alpha',
        },
      });
      expect(plan.hasDrm, isTrue);
      expect(plan.withUrl('https://example.com/b.mpd').hasDrm, isTrue);
      expect(plan.withHeaders(const {}).drm!.key, 'https://lic.example/wv');
    });

    test('无 drm 时 hasDrm 为假', () {
      final plan = PlaybackPlan.fromJson({'url': 'https://example.com/a'});
      expect(plan.hasDrm, isFalse);
    });
  });

  test('LiveChannel.hasDrm 只看 licenseKey', () {
    expect(_channel().hasDrm, isFalse);
    expect(_channel(licenseKey: 'x').hasDrm, isTrue);
  });
}
