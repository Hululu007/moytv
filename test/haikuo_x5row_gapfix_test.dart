import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_helpers.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// W5（G11 原生 x5 行 + R6§14 页内桥）回归测试：helpers 纯函数行为
/// 单测 + 运行时 HTML/跑页落点钉串。JS 行为级断言见
/// impl/w5/w5_verify.cjs（Node 抽取真实函数跑，含拦截器三路决策）。
void main() {
  group('haikuoX5RowLayout（照搬 parseX5Desc）', () {
    const vh = 800.0;
    const vw = 400.0;

    test('数字/list/auto 缺省', () {
      var r = haikuoX5RowLayout(
        desc: '216&&list',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 216);
      expect(r.floatMode, isFalse);
      expect(r.topMode, isFalse);
      r = haikuoX5RowLayout(
        desc: 'auto',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 240);
      r = haikuoX5RowLayout(
        desc: '',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 240);
      r = haikuoX5RowLayout(
        desc: '1300',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 800, reason: '超高夹到视口高');
    });

    test('video 按宽 9/16', () {
      final r = haikuoX5RowLayout(
        desc: 'list&&video',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 225);
      expect(r.videoMode, isTrue);
    });

    test('screen/screen-N/100%/百分比', () {
      var r = haikuoX5RowLayout(
        desc: 'list&&screen',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 800);
      r = haikuoX5RowLayout(
        desc: 'list&&screen-100',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 700);
      r = haikuoX5RowLayout(
        desc: 'float&&100%',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 800);
      expect(r.floatMode, isTrue);
      r = haikuoX5RowLayout(
        desc: '50%',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 400);
    });

    test('float 带空格与 float&&320', () {
      var r = haikuoX5RowLayout(
        desc: 'float && screen',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 800);
      expect(r.floatMode, isTrue);
      r = haikuoX5RowLayout(
        desc: 'float&&320',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 48,
      );
      expect(r.height, 320);
      expect(r.floatMode, isTrue);
    });

    test('top 无显式高度时铺到底（视口高减实测顶栏高）', () {
      final r = haikuoX5RowLayout(
        desc: 'float&&top',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 52,
      );
      expect(r.height, 748);
      expect(r.topMode, isTrue);
      expect(r.floatMode, isTrue);
    });

    test('top 有显式高度时用显式高度', () {
      final r = haikuoX5RowLayout(
        desc: 'top&&320',
        viewportHeight: vh,
        viewportWidth: vw,
        topOffset: 52,
      );
      expect(r.height, 320);
      expect(r.topMode, isTrue);
    });

    test('负尺寸输入按 0 计，不出负高', () {
      final r = haikuoX5RowLayout(
        desc: 'screen',
        viewportHeight: -10,
        viewportWidth: -5,
        topOffset: -3,
      );
      expect(r.height, 0);
    });
  });

  group('haikuoParseX5Intercept（三路决策）', () {
    test('block 形态', () {
      expect(
        haikuoParseX5Intercept('{"d":"block"}'),
        (action: 'block', code: ''),
      );
    });

    test('exec 形态带代码', () {
      final d = haikuoParseX5Intercept(
        '{"d":"exec","code":"fba.open(1)"}',
      );
      expect(d.action, 'exec');
      expect(d.code, 'fba.open(1)');
    });

    test('allow 与 fail-open', () {
      expect(
        haikuoParseX5Intercept('{"d":"allow"}').action,
        'allow',
      );
      expect(haikuoParseX5Intercept('').action, 'allow');
      expect(haikuoParseX5Intercept('not json').action, 'allow');
      expect(haikuoParseX5Intercept('{"d":"weird"}').action, 'allow');
      expect(
        haikuoParseX5Intercept('{"d":"exec","code":""}').action,
        'allow',
        reason: '空代码无可执行，按放行',
      );
      expect(haikuoParseX5Intercept('[1,2]').action, 'allow');
    });
  });

  group('haikuoX5BridgeScript（页内桥脚本）', () {
    final script = haikuoX5BridgeScript();

    test(r'通道投递与 $$$ 序列化器', () {
      expect(script, contains('HaikuoX5Bridge.postMessage'));
      expect(script, contains('window.\$\$\$=function'));
      expect(script, contains('chained.lazyRule'));
      expect(script, contains('"@lazyRule="'));
      expect(script, contains('chained.rule'));
      expect(script, contains('chained.image'));
      expect(script, contains('chained.input'));
      expect(script, contains('chained.confirm'));
      expect(script, contains('chained.select'));
      expect(script, contains('chained.b64'));
      expect(script, isNot(contains('lazyMap')));
    });

    test('桥方法齐全', () {
      for (final name in [
        'b.open=',
        'b.playVideo=',
        'b.parseLazyRule=',
        'b.parseLazyRuleAsync=',
        'b.putVar=',
        'b.clearVar=',
        'b.putMyVar=',
        'b.clearMyVar=',
        'b.base64Encode=',
        'b.setWebUa=',
        'b.hideLoading=',
        'b.refreshPage=',
        'b.back=',
        'b.toast=',
        'b.fetch=',
      ]) {
        expect(script, contains(name), reason: name);
      }
      expect(script, contains('__hkX5Fetches'));
      expect(script, contains('__hkX5ResolveFetch'));
      expect(script, contains('window.base64Encode'));
    });

    test('UNFILLABLE 四方法绝不伪造', () {
      for (final name in [
        'getHeaderUrl',
        'getInternalJs',
        'openThirdApp',
      ]) {
        expect(script, isNot(contains(name)), reason: name);
      }
      // getVar 只许出现在 putVar/clearVar 的名字里，不得有独立 b.getVar。
      expect(script, isNot(contains('b.getVar=')));
    });

    test('脚本无单引号（供 Node 按 r 段抽取原文）', () {
      expect(script.contains("'"), isFalse);
    });
  });

  group('运行时 HTML 落点（G11）', () {
    final html = haikuoRuntimeHtml;

    void has(String needle) {
      expect(html, contains(needle), reason: '缺失：$needle');
    }

    test('x5 行函数与占位协议', () {
      has('function parseX5Desc');
      has('function x5RowHtml');
      has('function refreshX5WebView');
      has('function refreshX5Desc');
      has('function x5RenderBegin');
      has('function x5IframeWrapHtml');
      has('function x5EvalSilent');
      has('function x5BlockRules');
      has('function x5JsCode');
      has('data-x5-slot="1"');
      has("type: 'x5row'");
      has("type: 'x5rowClear'");
      has("type: 'x5rowRefresh'");
      has("type: 'x5rowBack'");
      has('x5RowCountThisRender');
      has('x5FallbackActive');
    });

    test('bindX5Frames 已废止，iframe 只剩回落路径', () {
      expect(html, isNot(contains('bindX5Frames')));
      expect(html, contains('iframe data-x5'));
    });

    test('Dart 求值入口齐全', () {
      has('window.__haikuoUrlInterceptor');
      has('window.__haikuoX5Open');
      has('window.__haikuoX5Play');
      has('window.__haikuoX5ParseLazy');
      has('window.__haikuoX5Var');
      has('window.__haikuoX5Fetch');
      has('window.__haikuoX5Fallback');
      has('window.__haikuoX5CanGoBack');
      has('x5fetchResult');
    });

    test('渲染漏斗与返回键联调', () {
      // 7 处渲染/加载入口各调一次 x5RenderBegin（showListLoading、
      // render、renderDetail、renderText、renderGallery、
      // renderCollectionList、renderDownloadList）。
      final calls = 'x5RenderBegin();'.allMatches(html).length;
      expect(calls, 7, reason: '实际调用处：$calls');
      expect(html, contains('__haikuoX5CanGoBack === true'));
    });

    test('扫修 3 处修复仍在', () {
      expect(
        html,
        contains("out.replace(/fyAll/g, String(selectedCls || ''))"),
      );
      expect(
        html,
        contains('function getResCode() { try { return fetchPageHtml(); }'),
      );
      expect(html, contains('JavaPBEKeySpec'));
      expect(html, contains('JavaSecretKeyFactory'));
    });

    test('W1–W4 符号回归', () {
      for (final name in [
        'normalizePlayHeadersList',
        'sharePaste',
        'splitTopLevel',
        'queryAlternatives',
        'MY_INDEX',
        'nextNavQuiet',
        'captureNavFlags',
        'pushNavEntry',
        'pageThemeOf',
        'computeNextTitle',
        'armPageCache',
        'sessionVars',
        'ensureSessionVars',
        'syncMyTitle',
        'MY_KEYWORD',
        'JavaByteArrayInputStream',
        'JavaBigInteger',
        'isImageBytes',
        'parseBase64',
      ]) {
        expect(html, contains(name), reason: name);
      }
    });
  });

  group('跑页落点（G11）', () {
    final runner = File(
      'lib/miniapp/haikuo/haikuo_runner_page.dart',
    ).readAsStringSync();

    void has(String needle) {
      expect(runner, contains(needle), reason: '缺失：$needle');
    }

    test('会话与控制器槽位', () {
      has('class _X5RowSession');
      has('WebViewController? _x5RowController');
      has('_X5RowSession? _x5RowSession');
      has('_x5CanGoBack');
      has('_x5InterceptorChain');
      has('_x5VarChain');
    });

    test('消息 case 与桥通道', () {
      has("case 'x5row':");
      has("case 'x5rowClear':");
      has("case 'x5rowRefresh':");
      has("case 'x5rowBack':");
      has("case 'x5fetchResult':");
      has('HaikuoX5Bridge');
      has('_onX5BridgeMessage');
      has('_handleX5Row');
      has('_hideX5Row');
      has('_refreshX5Row');
      has('_x5RowBack');
      has('_decideX5Navigation');
      has('_evalUrlInterceptorNow');
      has('_execX5InterceptorCode');
      has('_injectX5Bridge');
      has('_x5RowFallback');
      has('_buildX5RowOverlay');
      has('haikuoBridgePadScript(cookies) + haikuoX5BridgeScript()');
      has('haikuoParseX5Intercept');
      has('expectInitialNavigation');
    });

    test('返回键与叠放', () {
      has('canPop: _inline == null && !_x5CanGoBack');
      has('_buildX5RowOverlay(context)');
      has('haikuoX5RowLayout(');
    });

    test('W3/W4 跑页符号回归', () {
      for (final name in [
        '_handleDownloads',
        '_handleShare',
        '_handleVars',
        '_pageCookiesFor',
        '_drainBridgeWriteFiles',
        '_sniffTick',
        '_fetchHtmlByWebView',
      ]) {
        expect(runner, contains(name), reason: name);
      }
    });
  });
}
