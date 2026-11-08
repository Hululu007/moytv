import 'dart:convert';

import 'package:moyi/jar_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

JarSiteSpec biliSpec() => const JarSiteSpec(
  siteId: 'jar:zakatv:bili',
  configId: 'zakatv',
  name: 'B站Java版',
  className: 'com.github.catvod.spider.Bili',
  jarUrl: 'https://example.invalid/zakatv.jar',
  jarMd5: '0',
  ext: '{"type":"舞蹈#音乐#游戏#科技#生活#美食#动画#影视","cookie":""}',
);

void main() {
  test('Bili proxy url parses to exact params', () {
    final params = JarBridge.parseProxyParams(
      'proxy://do=bili&aid=12345&cid=67890&qn=32&type=mpd',
    );
    expect(params, {
      'do': 'bili',
      'aid': '12345',
      'cid': '67890',
      'qn': '32',
      'type': 'mpd',
    });
  });

  test('proxy params decode url-encoded values', () {
    final params = JarBridge.parseProxyParams(
      'proxy://do=bili&aid=1&title=%E8%88%9E%E8%B9%88',
    );
    expect(params['title'], '舞蹈');
  });

  test('proxy url without query falls back to url param', () {
    expect(JarBridge.parseProxyParams('proxy://bili'), {'url': 'bili'});
    expect(JarBridge.parseProxyParams('proxy://'), {'url': ''});
    expect(JarBridge.parseProxyParams('proxy:do=bili'), {'do': 'bili'});
  });

  test('config api maps to the Bili class', () {
    expect(
      JarSiteSpec.classNameForApi('csp_Bili'),
      'com.github.catvod.spider.Bili',
    );
  });

  test('jar proxy payload carries the spec itself, never another station', () {
    final spec = biliSpec();
    final payload = JarBridge.jarProxyPayload(spec, {
      'do': 'bili',
      'aid': '12345',
      'cid': '67890',
      'qn': '32',
      'type': 'mpd',
    });
    expect(payload['siteId'], 'jar:zakatv:bili');
    expect(payload['configId'], 'zakatv');
    expect(payload['className'], 'com.github.catvod.spider.Bili');
    expect(payload['param'], {
      'do': 'bili',
      'aid': '12345',
      'cid': '67890',
      'qn': '32',
      'type': 'mpd',
    });
    final other = JarBridge.jarProxyPayload(
      spec.copyWith(ext: '{}'),
      {'do': 'bili'},
    );
    expect(other['className'], payload['className']);
    final foreign = JarBridge.jarProxyPayload(
      const JarSiteSpec(
        siteId: 'jar:zakatv:hgtv',
        configId: 'zakatv',
        name: '红果镜像',
        className: 'com.github.catvod.spider.Hgtv',
        jarUrl: 'https://example.invalid/zakatv.jar',
        jarMd5: '0',
        ext: '',
      ),
      {'do': 'bili'},
    );
    expect(foreign['className'], isNot(payload['className']));
    expect(foreign['siteId'], isNot(payload['siteId']));
  });

  test('jar proxy local url uses jarproxy path and round-trips', () {
    final spec = biliSpec();
    final payload = JarBridge.jarProxyPayload(spec, {
      'do': 'bili',
      'aid': '12345',
      'cid': '67890',
      'qn': '32',
      'type': 'mpd',
    });
    final local = JarBridge.jarProxyLocalUrl(18080, payload);
    expect(local.startsWith('http://127.0.0.1:18080/jarproxy?d='), isTrue);
    expect(local.contains('/pyproxy'), isFalse);
    final encoded = local.split('?d=').last;
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(encoded)),
    ) as Map;
    expect(decoded['siteId'], 'jar:zakatv:bili');
    expect(decoded['className'], 'com.github.catvod.spider.Bili');
    expect(decoded['param'], {
      'do': 'bili',
      'aid': '12345',
      'cid': '67890',
      'qn': '32',
      'type': 'mpd',
    });
  });
}
