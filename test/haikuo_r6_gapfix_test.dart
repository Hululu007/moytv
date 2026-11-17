import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_helpers.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// W8（R6 F1–F18）回归测试：Dart 侧 helpers 纯函数行为单测（F17）+
/// 运行时 HTML / 跑页落点钉串。JS 行为级断言见
/// impl/w8/w8_verify.cjs（Node 抽取真实运行时跑在 vm 里，200 断言）。
/// 真机行为须 15 版构建后手机终验；Dart 侧 inflate 分支的首次真编译
/// 靠云构建，本文件只作 flutter test/analyze 级校验。
void main() {
  group('haikuoInflateBytes（F17 Dart 端点，raw deflate）', () {
    test('raw 编码再解压还原', () {
      const text = 'hello inflater world, raw deflate 1234567890';
      final bytes = utf8.encode(text);
      final raw = ZLibEncoder(raw: true).convert(bytes);
      expect(haikuoInflateBytes(raw), bytes);
      expect(haikuoInflateBytes(ZLibEncoder(raw: true).convert([])), isEmpty);
    });

    test('已知 raw 样本解压（与 Node zlib.deflateRawSync 交叉验证）', () {
      // Node: zlib.deflateRawSync('hello inflater world, raw deflate 1234567890')
      const hex =
          'cb48cdc9c957c8cc4bcb492c492d5228cf2fca49d151284a2c574849058b29181a199b989a995b581a0000';
      final raw = <int>[];
      for (var i = 0; i < hex.length; i += 2) {
        raw.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      expect(
        utf8.decode(haikuoInflateBytes(raw)),
        'hello inflater world, raw deflate 1234567890',
      );
    });

    test('非法输入抛错（调用方转为空结果）', () {
      expect(() => haikuoInflateBytes([255, 0, 255, 1]), throwsA(anything));
    });

    test('raw 标志是实质性的：默认解码器解不了 raw 流', () {
      final raw = ZLibEncoder(raw: true).convert(utf8.encode('abc'));
      expect(() => ZLibDecoder().convert(raw), throwsA(anything));
      expect(utf8.decode(haikuoInflateBytes(raw)), 'abc');
    });

    test('gunzip 端点回归（同文件相邻函数未动）', () {
      const text = 'hello gzip round-trip';
      final bytes = utf8.encode(text);
      expect(haikuoGunzipBytes(haikuoGzipBytes(bytes)), bytes);
    });
  });

  group('运行时落点钉串（W8 F1–F18）', () {
    final html = haikuoRuntimeHtml;

    void has(String needle) {
      expect(html, contains(needle), reason: '缺失：$needle');
    }

    test('F1 播放链 @ 后缀提取', () {
      has('function extractPlayAtHeaders(');
      has('extractPlayHeaderSuffix(');
    });

    test('F2 openItem 对象 url', () {
      has('Array.isArray(rawUrl.urls) && rawUrl.urls.length');
      has('handleLazyResult(rawUrl, item, fromDetail);');
    });

    test('F3 putVar 对象形态', () {
      has("if (typeof key.key === 'string') { putVar(key.key, key.value); }");
    });

    test('F4 CryptoJS CFB', () {
      has("CFB: { name: 'CFB' }");
      has("} else if (mode === 'CFB') {");
      has("if (mode === 'CTR' || mode === 'CFB') {");
    });

    test('F5 big_blank_block 四处并入', () {
      final count = 'big_blank_block'.allMatches(html).length;
      expect(count, greaterThanOrEqualTo(4), reason: '四处：单块判定/列表/详情/列型表');
      has("'blank_block', 'big_blank_block'");
    });

    test('F6 extra 字号颜色', () {
      has('function textExtraFontSize(');
      has('function textExtraColor(');
      has('function textFontColorStyle(');
    });

    test('F7 closeMe', () {
      has('function closeMe(s)');
      has('closeMe: closeMe');
    });

    test('F8 fetchCache 三参', () {
      has('function fetchCache(url, hours, opts)');
    });

    test('F9 rawHttpEx 单数 header', () {
      has('opt.headers || opt.header || {}');
    });

    test('F10 runSearch 相对地址补全', () {
      has("myUrl.charAt(0) === '/' && myUrl.charAt(1) !== '/'");
      has('myUrl = getHome(rule.url) + myUrl;');
    });

    test('F11 hiker://browser', () {
      has("url === 'hiker://browser'");
      has("url.indexOf('hiker://browser?') === 0");
    });

    test('F12 MY_RULE.pageList 合成', () {
      has('function ensureRulePageList(ruleObj)');
      expect(
        'ensureRulePageList('.allMatches(html).length,
        greaterThanOrEqualTo(5),
        reason: '定义 1 处 + 调用 4 处',
      );
    });

    test('F13 getMimeDecoder', () {
      has('getMimeDecoder: function () { return makeJavaBase64Coder(false, true); }');
      expect(html, isNot(contains('getMimeEncoder')), reason: 'getMimeEncoder 不做');
    });

    test('F14 reflect.Array', () {
      has('getLength: function (arr)');
      has('getByte: function (arr, index)');
      expect(html, isNot(contains('ZipInputStream')), reason: 'UNFILLABLE');
    });

    test('F15 openConnection', () {
      has('function JavaURLConnection(urlObj)');
      has('JavaURL.prototype.openConnection = function ()');
      has('getResponseCode');
      has('getErrorStream');
    });

    test('F16 android Base64 encodeToString', () {
      has('encodeToString: function (bytes, flags)');
    });

    test('F17 JS 侧 InflaterInputStream', () {
      has('function JavaInflaterInputStream(stream)');
      has("cryptoRequest({ op: 'inflate', hex: bytesToHex(compressed) })");
    });

    test('F18 FileUtil.getFileSuffix', () {
      has('getFileSuffix: function (path)');
    });

    test('UNFILLABLE 均未落地', () {
      expect(html, isNot(contains('getProxy')), reason: 'getProxy 不得裸加');
      expect(html, isNot(contains('getMimeEncoder')));
      expect(html, isNot(contains('ZipInputStream')));
    });
  });

  group('扫修 3 处修复钉串（回归）', () {
    final html = haikuoRuntimeHtml;

    test('fyAll 取分类值', () {
      final count = "String(selectedCls || '')".allMatches(html).length;
      expect(count, greaterThanOrEqualTo(2));
    });

    test('getResCode 回正文', () {
      expect(
        html,
        contains('function getResCode() { try { return fetchPageHtml(); }'),
      );
    });

    test('PBE 垫片', () {
      expect(html, contains('PBEKeySpec'));
    });
  });

  group('W1–W6 符号钉串（回归）', () {
    final html = haikuoRuntimeHtml;

    test('W1–W6 关键符号仍在', () {
      for (final name in [
        'normalizePlayHeadersList', // W1
        'splitTopLevel', // W2
        'MY_INDEX', // W2
        'captureNavFlags', // W3
        'armAutoPage', // W3
        'armPageCache', // W3
        'pageThemeOf', // W3
        'sessionVars', // W4
        'JavaGZIPInputStream', // W4
        'JavaBigInteger', // W4
        'MY_KEYWORD', // W4
        'isImageBytes', // W4
        'x5RowHtml', // W5
        'x5EvalSilent', // W5
        '__haikuoX5ParseLazy', // W5
        'extra.floatVideo === true', // W6
      ]) {
        expect(html, contains(name), reason: name);
      }
    });
  });

  group('跑页与 helpers 落点（F17 Dart 侧）', () {
    final runner = File(
      'lib/miniapp/haikuo/haikuo_runner_page.dart',
    ).readAsStringSync();
    final helpers = File(
      'lib/miniapp/haikuo/haikuo_helpers.dart',
    ).readAsStringSync();

    test('_handleCrypto inflate 分支', () {
      expect(runner, contains("} else if (op == 'inflate') {"));
      expect(runner, contains('haikuoInflateBytes('));
      expect(runner, contains('Java InflaterInputStream'));
    });

    test('gunzip/gzip 分支未动', () {
      expect(runner, contains("op == 'gunzip'"));
      expect(runner, contains("op == 'gzip'"));
    });

    test('helpers 用 ZLibDecoder(raw: true)', () {
      expect(helpers, contains('ZLibDecoder(raw: true)'));
      expect(helpers, contains('List<int> haikuoInflateBytes(List<int> bytes)'));
    });
  });
}
