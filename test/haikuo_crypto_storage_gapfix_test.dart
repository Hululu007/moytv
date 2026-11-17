import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_helpers.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

/// W4（加密/存储批）回归测试：Dart 侧 helpers/store 的行为单测 +
/// 运行时 HTML 落点钉串。JS 行为级断言见 impl/w4/w4_verify.cjs。
void main() {
  group('HaikuoSessionVars (E33)', () {
    test('set/clear/clearAll', () {
      final vars = HaikuoSessionVars();
      vars.apply({'op': 'set', 'key': 'k', 'value': 'v'});
      vars.apply({'op': 'set', 'key': 'x', 'value': ''});
      expect(vars.snapshot(), {'k': 'v', 'x': ''});
      vars.apply({'op': 'clear', 'key': 'k'});
      expect(vars.snapshot(), {'x': ''});
      vars.apply({'op': 'clearAll'});
      expect(vars.snapshot(), isEmpty);
    });

    test('未知 op 忽略不抛错', () {
      final vars = HaikuoSessionVars();
      vars.apply({'op': 'bogus', 'key': 'k', 'value': 'v'});
      vars.apply({});
      expect(vars.snapshot(), isEmpty);
    });

    test('快照是副本，改不动原表', () {
      final vars = HaikuoSessionVars();
      vars.apply({'op': 'set', 'key': 'k', 'value': 'v'});
      final snap = vars.snapshot();
      snap['k'] = 'hacked';
      snap['new'] = '1';
      expect(vars.snapshot(), {'k': 'v'});
    });
  });

  group('GZIP 往返 (E116-F1 Dart 端点)', () {
    test('压缩再解压还原', () {
      const text = 'hello gzip round-trip 12345';
      final bytes = utf8.encode(text);
      expect(haikuoGunzipBytes(haikuoGzipBytes(bytes)), bytes);
      expect(haikuoGunzipBytes(haikuoGzipBytes([])), isEmpty);
    });

    test('已知样本解压', () {
      // gzip.compress(b'hello world\n', mtime=0)
      const hex =
          '1f8b0800000000000203cb48cdc9c95728cf2fca49e102002d3b08af0c000000';
      final gz = <int>[];
      for (var i = 0; i < hex.length; i += 2) {
        gz.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      expect(utf8.decode(haikuoGunzipBytes(gz)), 'hello world\n');
    });

    test('非法 gzip 抛错（调用方转为空结果）', () {
      expect(() => haikuoGunzipBytes([1, 2, 3]), throwsA(isA<FormatException>()));
    });
  });

  group('haikuoSplitUserAgent (E111-F1)', () {
    test('标准大小写拆出并删键', () {
      final r = haikuoSplitUserAgent({
        'User-Agent': 'UA/1.0',
        'Referer': 'https://x/',
      });
      expect(r.userAgent, 'UA/1.0');
      expect(r.headers, {'Referer': 'https://x/'});
    });

    test('全小写与全大写键名都认', () {
      expect(haikuoSplitUserAgent({'user-agent': 'a'}).userAgent, 'a');
      expect(haikuoSplitUserAgent({'USER-AGENT': 'b'}).userAgent, 'b');
      expect(
        haikuoSplitUserAgent({'user-agent': 'a'}).headers,
        isEmpty,
      );
    });

    test('空值跳过，取第一个非空', () {
      final r = haikuoSplitUserAgent({'user-agent': '', 'User-Agent': 'real'});
      expect(r.userAgent, 'real');
      expect(r.headers, isEmpty);
    });

    test('无 UA 时原样保留全部头', () {
      final r = haikuoSplitUserAgent({'Referer': 'https://x/', 'X-A': '1'});
      expect(r.userAgent, '');
      expect(r.headers, {'Referer': 'https://x/', 'X-A': '1'});
    });
  });

  group('桥垫片与哨兵 (E111-F2/F3)', () {
    test('哨兵常量值', () {
      expect(haikuoCheckJsPassSentinel, '__HK_PASS__');
    });

    test('垫片含全部桥方法与别名', () {
      final pad = haikuoBridgePadScript('cf_clearance=abc');
      for (final needle in [
        '__hkPageCookies',
        '__hkWriteFiles',
        '_getUrls',
        'fy_bridge_app',
        'getCookie',
        'writeFile',
        'getUa',
        'setWebTitle',
        'log:function',
        'window.fba=window.fy_bridge_app',
      ]) {
        expect(pad, contains(needle), reason: '垫片缺失：$needle');
      }
      // 写队列跨拍保留（重注入不清空已攒条目）
      expect(pad, contains('__hkWriteFiles=window.__hkWriteFiles||[]'));
    });

    test('Cookie 含引号/反斜杠时 JSON 转义', () {
      const cookie = 'a="b"; c=\\d; e=1';
      final pad = haikuoBridgePadScript(cookie);
      expect(pad, contains(jsonEncode(cookie)));
      expect(pad, isNot(contains('__hkPageCookies=$cookie;')));
    });
  });

  group('HaikuoSavedFiles (E38)', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('haikuo-saved-');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('写/读/删往返', () async {
      await HaikuoSavedFiles.writeSavedFile(
        temp,
        'dataCache.json',
        utf8.encode('{"a":1}'),
      );
      final back = await HaikuoSavedFiles.readSavedFile(temp, 'dataCache.json');
      expect(back, isNotNull);
      expect(utf8.decode(back!), '{"a":1}');
      await HaikuoSavedFiles.deleteSavedFile(temp, 'dataCache.json');
      expect(
        await HaikuoSavedFiles.readSavedFile(temp, 'dataCache.json'),
        isNull,
      );
    });

    test('读不存在的文件回 null 不抛错', () async {
      expect(await HaikuoSavedFiles.readSavedFile(temp, 'nope.txt'), isNull);
    });

    test('穿越名只落目录内，目录外无文件', () async {
      await HaikuoSavedFiles.writeSavedFile(
        temp,
        '../escape.txt',
        utf8.encode('x'),
      );
      await HaikuoSavedFiles.writeSavedFile(
        temp,
        'a/b/deep.txt',
        utf8.encode('y'),
      );
      expect(
        await HaikuoSavedFiles.readSavedFile(temp, 'escape.txt'),
        isNotNull,
      );
      expect(await HaikuoSavedFiles.readSavedFile(temp, 'deep.txt'), isNotNull);
      expect(await File('${temp.parent.path}/escape.txt').exists(), isFalse);
      final listed = temp
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path)
          .toList();
      expect(
        listed.every((p) => p.startsWith('${temp.path}/saved_files/')),
        isTrue,
      );
    });

    test('坏名静默跳过', () async {
      await HaikuoSavedFiles.writeSavedFile(temp, '', [1]);
      await HaikuoSavedFiles.writeSavedFile(temp, '.', [1]);
      await HaikuoSavedFiles.writeSavedFile(temp, '..', [1]);
      expect(await HaikuoSavedFiles.readSavedFile(temp, ''), isNull);
      expect(await HaikuoSavedFiles.readSavedFile(temp, '..'), isNull);
      expect(await Directory('${temp.path}/saved_files').exists(), isFalse);
    });

    test('同 basename 覆盖（扁平键空间）', () async {
      await HaikuoSavedFiles.writeSavedFile(temp, 'dir/a.txt', utf8.encode('1'));
      await HaikuoSavedFiles.writeSavedFile(
        temp,
        'other/a.txt',
        utf8.encode('2'),
      );
      final back = await HaikuoSavedFiles.readSavedFile(temp, 'a.txt');
      expect(utf8.decode(back!), '2');
    });

    test('字节原样往返', () async {
      final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
      await HaikuoSavedFiles.writeSavedFile(temp, 'bin.dat', bytes);
      expect(await HaikuoSavedFiles.readSavedFile(temp, 'bin.dat'), bytes);
    });
  });

  group('运行时 HTML 落点钉串', () {
    final html = haikuoRuntimeHtml;

    void has(String needle) {
      expect(html, contains(needle), reason: '缺失：$needle');
    }

    test('E116-F1 流/GZIP/Base64', () {
      has('function JavaByteArrayInputStream');
      has('function JavaByteArrayOutputStream');
      has('function JavaGZIPInputStream');
      has('function JavaGZIPOutputStream');
      has('function makeJavaBase64Coder');
      has('getUrlEncoder');
      has('java.io');
      has('java.util.zip');
    });

    test('E116-F2 小件类 + BigInteger', () {
      has('function JavaStringBuilder');
      has('var JavaInteger = {');
      has('var JavaSystem = {');
      has('function JavaObject');
      has('function JavaRunnable');
      has('function JavaAtomicInteger');
      has('function JavaVector');
      has('var JavaPattern = {');
      has('function JavaBigInteger');
      has('modPow');
    });

    test('DES 核心', () {
      has('function desSubkeys');
      has('function desCryptBytes');
      has('DES: DES');
    });

    test('B27-F2/F3', () {
      has('parseBase64');
      has('base64Decode');
      has('NO_WRAP: 2');
      has('function isImageBytes');
    });

    test('MY_TITLE / MY_KEYWORD', () {
      has('var MY_TITLE');
      has('var MY_KEYWORD');
      has('function setSearchKeyword');
      has('function syncMyTitle');
    });

    test('E33 会话变量镜像', () {
      has('sessionVars');
      has('function ensureSessionVars');
      has('function writeThroughSessionVars');
      has("'/__vars'");
      expect(html.contains("getItem('v_'"), isFalse);
      expect(html.contains("setItem('v_'"), isFalse);
      expect(html.contains("removeItem('v_'"), isFalse);
    });

    test('A20 setGlobals 复位', () {
      has("lastChapterRuleText = '';");
    });

    test('扫修 3 处修复仍在', () {
      expect('fyAll'.allMatches(html).length, greaterThanOrEqualTo(2));
      has('function getResCode() { try { return fetchPageHtml(); }');
      has('JavaPBEKeySpec');
    });

    test('W1/W2/W3 符号仍在', () {
      has('normalizePlayHeadersList');
      has('getPastes');
      has('queryAlternatives');
      has('applyPageTheme');
      has('computeNextTitle');
      has('cacheCode');
    });
  });
}
