import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_codec.dart';
import 'package:moyi/miniapp/haikuo/haikuo_helpers.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

Map<String, dynamic> _rule(String title) => {
  'title': title,
  'type': 'video',
  'url': 'hiker://empty##https://example.com/$title',
  'col_type': 'movie_3',
  'find_rule': 'js:\nsetResult([{title: "$title"}]);',
};

List<int> _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('导入形态修复', () {
    test('BOM 头的 JSON 能解析', () {
      final text = '\uFEFF${jsonEncode(_rule('甲'))}';
      final programs = HaikuoCodec.parseText(text);
      expect(programs.map((p) => p.name), ['甲']);
    });

    test('decodeText 剥掉 UTF-8 BOM', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('abc')];
      expect(HaikuoCodec.decodeText(bytes), 'abc');
    });

    test('data 字段套 JSON 字符串二次解码', () {
      final text = jsonEncode({
        'data': jsonEncode([_rule('甲'), _rule('乙')]),
      });
      final programs = HaikuoCodec.parseText(text);
      expect(programs.map((p) => p.name).toSet(), {'甲', '乙'});
    });

    test('嵌套 zip 递归一层能解出规则', () {
      final inner = _zip({'inner.json': utf8.encode(jsonEncode(_rule('内')))});
      final outer = _zip({'nested.zip': inner});
      final programs = HaikuoCodec.parseBytes(outer);
      expect(programs.map((p) => p.name), ['内']);
    });

    test('zip 内损坏条目报出名字，不静默跳过', () {
      final dropped = <String>[];
      final bytes = _zip({
        'good.json': utf8.encode(jsonEncode(_rule('好'))),
        'bad.json': utf8.encode('{坏掉的 json'),
      });
      final programs = HaikuoCodec.parseBytes(bytes, dropped: dropped);
      expect(programs.map((p) => p.name), ['好']);
      expect(dropped.any((d) => d.contains('bad.json')), isTrue);
    });

    test('zip 内的 .db 条目提示单独导入', () {
      final dropped = <String>[];
      final bytes = _zip({
        'good.json': utf8.encode(jsonEncode(_rule('好'))),
        'hiker_54.db': [0x53, 0x51, 0x4C, 0x69],
      });
      final programs = HaikuoCodec.parseBytes(bytes, dropped: dropped);
      expect(programs.map((p) => p.name), ['好']);
      expect(dropped.any((d) => d.contains('.db')), isTrue);
    });

    test('尾随逗号与注释的 JSON 宽容解析', () {
      const text = '''
      {
        // 注释行
        "title": "甲",
        "type": "video",
        "url": "hiker://empty",
        "find_rule": "js:setResult([]);",
      }
      ''';
      final programs = HaikuoCodec.parseText(text);
      expect(programs.map((p) => p.name), ['甲']);
    });

    test('实在解析不了的仍诚实报错', () {
      expect(
        () => HaikuoCodec.parseText('{根本不是 json'),
        throwsA(isA<HaikuoFormatException>()),
      );
    });

    test('数组文件里的规则 rawJson 是单个规则对象（不是整段原文）', () {
      final rule = _rule('甲')
        ..['pages'] = [
          {'name': 'detail', 'rule': 'js:setResult([]);'},
        ];
      final programs = HaikuoCodec.parseText(jsonEncode([rule]));
      expect(programs, hasLength(1));
      final decoded = jsonDecode(programs.single.rawJson);
      expect(decoded, isA<Map>());
      expect(decoded['title'], '甲');
      expect(decoded['pages'], hasLength(1));
    });

    test('分组与类型字段从 group_lpcolumn/type 取到程序上', () {
      final rule = _rule('甲')
        ..['group_lpcolumn'] = '影视'
        ..['type'] = 'video';
      final programs = HaikuoCodec.parseText(jsonEncode(rule));
      expect(programs.single.group, '影视');
      expect(programs.single.ruleType, 'video');
    });
  });

  group('备份数据库行转规则', () {
    test('SQLite 魔数识别', () {
      expect(
        isSqliteBytes([...utf8.encode('SQLite format 3\x00'), 1, 2]),
        isTrue,
      );
      expect(isSqliteBytes(utf8.encode('PK\x03\x04')), isFalse);
      expect(isSqliteBytes([]), isFalse);
    });

    test('列名换键 + None 当空 + version 转字符串', () {
      final rule = haikuoDbRowToRule({
        'title': '甲',
        'searchfind': 'js:搜',
        'firstheader': '头',
        'group_lpcolumn': '影视',
        'url': 'None',
        'version': 3,
        'pages': '[]',
      });
      expect(rule, isNotNull);
      expect(rule!['searchFind'], 'js:搜');
      expect(rule['firstHeader'], '头');
      expect(rule['group'], '影视');
      expect(rule['url'], '');
      expect(rule['version'], '3');
    });

    test('标题为空的行返回 null', () {
      expect(haikuoDbRowToRule({'title': 'None'}), isNull);
      expect(haikuoDbRowToRule({'title': ''}), isNull);
    });

    test('store 走注入的数据库读取器导入 .db 字节', () async {
      final temp = await Directory.systemTemp.createTemp('haikuo-db-');
      try {
        final store = HaikuoStore(
          rootOverride: temp,
          dbReader: (_) async => [
            {
              'title': '库里甲',
              'url': 'hiker://empty',
              'find_rule': 'js:setResult([]);',
              'type': 'video',
              'pages': '[]',
            },
          ],
        );
        final magic = [
          ...utf8.encode('SQLite format 3\x00'),
          ...List<int>.filled(100, 0),
        ];
        final result = await store.importBytes(magic, origin: '测试库');
        expect(result.added.map((p) => p.name), ['库里甲']);
      } finally {
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    });

    test('store 导入 zip 时丢条说明进 notes', () async {
      final temp = await Directory.systemTemp.createTemp('haikuo-zip-');
      try {
        final store = HaikuoStore(rootOverride: temp);
        final bytes = _zip({
          'good.json': utf8.encode(jsonEncode(_rule('好'))),
          'bad.json': utf8.encode('{坏掉的'),
        });
        final result = await store.importBytes(bytes, origin: '测试');
        expect(result.added.map((p) => p.name), ['好']);
        expect(result.notes.any((n) => n.contains('bad.json')), isTrue);
      } finally {
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    });
  });

  group('程序 group/ruleType 往返', () {
    test('toJson/fromJson 与 copyWith 保留分组与类型', () {
      const program = HaikuoProgram(
        id: 'x',
        name: '甲',
        group: '影视',
        ruleType: 'video',
      );
      final restored = HaikuoProgram.fromJson(program.toJson());
      expect(restored.group, '影视');
      expect(restored.ruleType, 'video');
      expect(program.copyWith().group, '影视');
      expect(program.copyWith(name: '乙').group, '影视');
      expect(program.copyWith(name: '乙').ruleType, 'video');
    });
  });

  group('代理归一', () {
    test('空与否定写法都不走代理', () {
      expect(parseHaikuoProxy(null), isNull);
      expect(parseHaikuoProxy(''), isNull);
      expect(parseHaikuoProxy('false'), isNull);
      expect(parseHaikuoProxy('FALSE'), isNull);
      expect(parseHaikuoProxy('0'), isNull);
      expect(parseHaikuoProxy('none'), isNull);
      expect(parseHaikuoProxy('off'), isNull);
    });

    test('没 scheme 补 http://，有 scheme 原样留', () {
      expect(parseHaikuoProxy('127.0.0.1:7890'), 'http://127.0.0.1:7890');
      expect(
        parseHaikuoProxy('socks5://127.0.0.1:1080'),
        'socks5://127.0.0.1:1080',
      );
    });
  });

  group('Cookie 罐', () {
    test('Set-Cookie 存取与同名后来居上', () {
      final jar = HaikuoCookieJar();
      expect(jar.isEmpty, isTrue);
      jar.store('a.com', ['id=1; Path=/', 'token=x; HttpOnly']);
      expect(jar.headerFor('a.com'), 'id=1; token=x');
      expect(jar.headerFor('b.com'), '');
      jar.store('a.com', ['id=2; Path=/']);
      expect(jar.headerFor('a.com'), 'id=2; token=x');
    });

    test('setCookie 直接写多条', () {
      final jar = HaikuoCookieJar();
      jar.setCookie('a.com', 'a=1; b=2');
      expect(jar.headerFor('a.com'), 'a=1; b=2');
      final empty = HaikuoCookieJar();
      empty.setCookie('', 'a=1');
      expect(empty.isEmpty, isTrue);
    });
  });

  group('嗅探地址筛选', () {
    test('挑第一个媒体地址，排除规则优先', () {
      const entries = [
        'https://a.com/style.css',
        'https://a.com/ad.mp4',
        'https://a.com/v.m3u8',
      ];
      expect(
        pickSniffedVideoUrl(entries, excludeRules: ['*ad*']),
        'https://a.com/v.m3u8',
      );
      expect(pickSniffedVideoUrl(entries), 'https://a.com/ad.mp4');
    });

    test('包含规则为空不限制，非空则必须命中', () {
      const entries = ['https://a.com/v.mp4'];
      expect(
        pickSniffedVideoUrl(entries, includeRules: ['*cdn*']),
        '',
      );
      expect(
        pickSniffedVideoUrl(entries, includeRules: ['*.mp4']),
        'https://a.com/v.mp4',
      );
    });

    test('没有媒体地址返回空串', () {
      expect(pickSniffedVideoUrl(['https://a.com/x.html']), '');
      expect(pickSniffedVideoUrl([]), '');
    });
  });

  group('摘要与 HMAC', () {
    test('md5/sha1/sha256/sha512 已知向量', () {
      expect(haikuoHashHex('md5', utf8.encode('abc')),
          '900150983cd24fb0d6963f7d28e17f72');
      expect(haikuoHashHex('sha1', utf8.encode('abc')),
          'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(haikuoHashHex('sha256', utf8.encode('abc')),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
        haikuoHashHex('sha512', utf8.encode('abc')),
        'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
        '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
      );
    });

    test('未知 op 返回空串，不编结果', () {
      expect(haikuoHashHex('sha3', utf8.encode('abc')), '');
      expect(haikuoHmacHex('sha3', [1], [2]), '');
    });

    test('HMAC-SHA256 已知向量', () {
      expect(
        haikuoHmacHex(
          'sha256',
          utf8.encode('key'),
          utf8.encode('The quick brown fox jumps over the lazy dog'),
        ),
        'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
      );
      expect(
        haikuoHmacHex('md5', utf8.encode('k'), utf8.encode('m')).length,
        32,
      );
    });

    test('十六进制转字节', () {
      expect(haikuoHexToBytes('deadbeef'), [0xDE, 0xAD, 0xBE, 0xEF]);
      expect(haikuoHexToBytes('abc'), [0xAB]);
      expect(haikuoHexToBytes('zz'), isEmpty);
    });
  });
}
