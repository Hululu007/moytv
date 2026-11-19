import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/jar_site_config.dart';
import 'package:moyi/player_core.dart';
import 'package:moyi/zakatv_builtin.dart';

/// 读 dex 类定义表，返回全部已定义类的描述符（如
/// `Lcom/github/catvod/spider/EroShort;`）。只解析头、string_ids、
/// type_ids、class_defs 四段，不碰 code 段。
List<String> dexDefinedClasses(List<int> dexBytes) {
  final bytes = Uint8List.fromList(dexBytes);
  final data = ByteData.sublistView(bytes);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  final stringIdsSize = u32(56);
  final stringIdsOff = u32(60);
  final typeIdsOff = u32(68);
  final classDefsSize = u32(96);
  final classDefsOff = u32(100);
  String readString(int index) {
    final off = u32(stringIdsOff + index * 4);
    var pos = off;
    // uleb128 长度前缀（类描述符均为 ASCII，跳过即可）。
    while (bytes[pos] & 0x80 != 0) {
      pos++;
    }
    pos++;
    final start = pos;
    while (bytes[pos] != 0) {
      pos++;
    }
    return utf8.decode(bytes.sublist(start, pos));
  }

  final strings = [for (var i = 0; i < stringIdsSize; i++) readString(i)];
  final classes = <String>[];
  for (var i = 0; i < classDefsSize; i++) {
    final classIdx = u32(classDefsOff + i * 32);
    final stringIdx = u32(typeIdsOff + classIdx * 4);
    classes.add(strings[stringIdx]);
  }
  return classes;
}

JarSiteSpec eroShortSpec() => const JarSiteSpec(
  siteId: 'jar:zakatv:EroShort',
  configId: 'zakatv',
  name: '🔞EroShort',
  className: 'com.github.catvod.spider.EroShort',
  jarUrl: 'https://example.invalid/zakatv.jar',
  jarMd5: '0',
  ext: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('zakatv jar asset md5 matches the const', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), zakatvJarMd5);
  });

  test('classes20.dex defines exactly the EroShort classes, no Json', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names, contains('classes20.dex'));
    final dex = List<int>.from(
      archive.files.singleWhere((f) => f.name == 'classes20.dex').content
          as List<int>,
    );
    final classes = dexDefinedClasses(dex);
    expect(
      classes,
      unorderedEquals([
        'Lcom/github/catvod/spider/EroShort;',
        'Lcom/github/catvod/spider/EroShort\$1;',
        'Lcom/github/catvod/spider/EroShort\$2;',
        'Lcom/github/catvod/spider/EroShort\$Cred;',
        'Lcom/github/catvod/spider/EroShort\$Resp;',
      ]),
    );
    // Json 助手类已有 classes17.dex 一份定义，新 dex 绝不重定义，
    // 否则加载器先赢规则下 EroShort 可能拿到不兼容的实现。
    expect(classes, isNot(contains('Lcom/github/catvod/spider/Json;')));
  });

  test('EroShort registered in the Dart registry', () {
    expect(zakatvBuiltinSites.length, 140);
    final site = zakatvBuiltinSites.singleWhere(
      (site) => site.key == 'EroShort',
    );
    expect(site.name, '🔞EroShort');
    expect(site.className, 'com.github.catvod.spider.EroShort');
    expect(site.ext, '');
  });

  test('EroShort mirrored in jar_site_configs.json', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    final matched = matchJarSiteConfig(
      'com.github.catvod.spider.EroShort',
      configs,
    );
    expect(matched, isNotNull);
    expect(matched!.key, 'EroShort');
    expect(matched.name, '🔞EroShort');
    expect(matched.api, 'csp_EroShort');
    expect(matched.ext, '');
  });

  test('api/class/siteId mapping for EroShort', () {
    expect(
      JarSiteSpec.classNameForApi('csp_EroShort'),
      'com.github.catvod.spider.EroShort',
    );
    expect(JarSiteSpec.siteIdFor('zakatv', 'EroShort'), 'jar:zakatv:EroShort');
  });

  test('EroShort playback is pinned to ijk', () {
    for (final stored in PlayerCore.values) {
      expect(
        effectivePlayerCore(stored: stored, siteId: 'jar:zakatv:EroShort'),
        PlayerCore.ijk,
      );
    }
    expect(pinnedSitePlayerCores, {'jar:zakatv:EroShort': PlayerCore.ijk});
  });

  test('other sites keep the stored core', () {
    expect(
      effectivePlayerCore(
        stored: PlayerCore.exo,
        siteId: 'jar:zakatv:ZakaMjv011',
      ),
      PlayerCore.exo,
    );
    expect(
      effectivePlayerCore(stored: PlayerCore.mpv, siteId: 'chaoliu'),
      PlayerCore.mpv,
    );
    expect(effectivePlayerCore(stored: PlayerCore.ijk), PlayerCore.ijk);
  });

  test('loopback proxy urls parse to params', () {
    expect(
      JarBridge.loopbackProxyParams(
        'http://127.0.0.1:9978/proxy?do=csp_EroShort&act=master&ep=abc123&dur=61.5',
      ),
      {'do': 'csp_EroShort', 'act': 'master', 'ep': 'abc123', 'dur': '61.5'},
    );
    expect(
      JarBridge.loopbackProxyParams(
        'http://localhost:9978/proxy?do=csp_EroShort&act=video&ep=x',
      ),
      {'do': 'csp_EroShort', 'act': 'video', 'ep': 'x'},
    );
    // 非 9978 /proxy 形态一律不认，原样不动。
    expect(
      JarBridge.loopbackProxyParams('http://127.0.0.1:9979/proxy?do=x'),
      isNull,
    );
    expect(
      JarBridge.loopbackProxyParams('http://127.0.0.1:9978/other?do=x'),
      isNull,
    );
    expect(
      JarBridge.loopbackProxyParams('https://127.0.0.1:9978/proxy?do=x'),
      isNull,
    );
    expect(
      JarBridge.loopbackProxyParams('http://example.com/proxy?do=x'),
      isNull,
    );
    expect(JarBridge.loopbackProxyParams('proxy://do=bili'), isNull);
    expect(JarBridge.loopbackProxyParams('not a url'), isNull);
  });

  test('master playlist loopback urls rewrite to jarproxy urls', () {
    const playlist =
        '#EXTM3U\n'
        '#EXT-X-VERSION:7\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="http://127.0.0.1:9978/proxy?do=csp_EroShort&act=audio&ep=abc123"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3500000,RESOLUTION=1080x1920,AUDIO="aud"\n'
        'http://127.0.0.1:9978/proxy?do=csp_EroShort&act=video&ep=abc123\n';
    final rewritten = JarBridge.rewriteLoopbackProxyUrls(
      playlist,
      port: 54321,
      spec: eroShortSpec(),
    );
    expect(rewritten.contains('9978'), isFalse);
    final urls = RegExp(
      r'http://127\.0\.0\.1:54321/jarproxy\?d=[A-Za-z0-9\-_]+=*',
    ).allMatches(rewritten).map((m) => m.group(0)!).toList();
    expect(urls.length, 2);
    for (final url in urls) {
      final payload =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(Uri.parse(url).queryParameters['d']!),
                ),
              )
              as Map;
      expect(payload['siteId'], 'jar:zakatv:EroShort');
      expect(payload['configId'], 'zakatv');
      expect(payload['className'], 'com.github.catvod.spider.EroShort');
      final param = Map<String, dynamic>.from(payload['param'] as Map);
      expect(param['do'], 'csp_EroShort');
      expect(param['ep'], 'abc123');
    }
    final acts = urls
        .map(
          (url) =>
              (jsonDecode(
                        utf8.decode(
                          base64Url.decode(
                            Uri.parse(url).queryParameters['d']!,
                          ),
                        ),
                      )
                      as Map)['param']['act']
                  as String,
        )
        .toSet();
    expect(acts, {'audio', 'video'});
  });

  test('rewrite leaves other text untouched', () {
    const plain = '#EXTM3U\n#EXTINF:2.0,\nhttps://cdn.example.com/seg1.m4s\n';
    expect(
      JarBridge.rewriteLoopbackProxyUrls(
        plain,
        port: 54321,
        spec: eroShortSpec(),
      ),
      same(plain),
    );
  });
}
