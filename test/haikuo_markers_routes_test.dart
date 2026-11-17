import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_helpers.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 标记/路由批（C01/C08/C09/C11/C12/C13、E76、H01/H04/H22、E84 微选项）
/// 落点测试：纯函数单测 + 运行时/Dart 落点钉串。行为级验证见 Node
/// 抽取测试（~/workspace/shell_gap_sweep_20261117/impl/w3/，165 项全过）。
void main() {
  final html = haikuoRuntimeHtml;
  final runner =
      File('lib/miniapp/haikuo/haikuo_runner_page.dart').readAsStringSync();

  void has(String needle) {
    expect(html, contains(needle), reason: '运行时缺失：$needle');
  }

  void runnerHas(String needle) {
    expect(runner, contains(needle), reason: '跑页缺失：$needle');
  }

  group('haikuoImmersiveUi：页面沉浸与播放器全屏取或', () {
    test('全假不沉浸', () {
      expect(
        haikuoImmersiveUi(pageImmersive: false, inlineFullscreen: false),
        isFalse,
      );
    });

    test('任一为真即沉浸', () {
      expect(
        haikuoImmersiveUi(pageImmersive: true, inlineFullscreen: false),
        isTrue,
      );
      expect(
        haikuoImmersiveUi(pageImmersive: false, inlineFullscreen: true),
        isTrue,
      );
      expect(
        haikuoImmersiveUi(pageImmersive: true, inlineFullscreen: true),
        isTrue,
      );
    });
  });

  group('haikuoSafeFileName：只取 basename，禁穿越', () {
    test('普通名原样', () {
      expect(haikuoSafeFileName('a.mp4'), 'a.mp4');
    });

    test('路径只取最后一段', () {
      expect(haikuoSafeFileName('../x.txt'), 'x.txt');
      expect(haikuoSafeFileName('a/b/c.txt'), 'c.txt');
      expect(haikuoSafeFileName(r'a\b.txt'), 'b.txt');
    });

    test('空/点号拒绝', () {
      expect(haikuoSafeFileName(''), isNull);
      expect(haikuoSafeFileName('.'), isNull);
      expect(haikuoSafeFileName('..'), isNull);
      expect(haikuoSafeFileName('../'), isNull);
    });

    test('首尾空白去掉', () {
      expect(haikuoSafeFileName('  spaced.txt  '), 'spaced.txt');
    });
  });

  group('share 目标解析', () {
    test('files 目标判定', () {
      expect(haikuoIsHikerFilesTarget('hiker://files/a.txt'), isTrue);
      expect(haikuoIsHikerFilesTarget('hiker://files/'), isTrue);
      expect(haikuoIsHikerFilesTarget('https://x.example/a.txt'), isFalse);
      expect(haikuoIsHikerFilesTarget('纯文本'), isFalse);
    });

    test('文件键去前缀/去查询串/解码', () {
      expect(haikuoShareFileKey('hiker://files/a.txt'), 'a.txt');
      expect(
        haikuoShareFileKey('hiker://files/rules/x/y.txt?rule=R'),
        'rules/x/y.txt',
      );
      expect(
        haikuoShareFileKey('hiker://files/%E4%B8%AD%E6%96%87.txt'),
        '中文.txt',
      );
      expect(haikuoShareFileKey('https://x.example/a'), '');
    });
  });

  group('sortHaikuoDownloadEntries', () {
    test('mtime 新的在前，同时间按名升序，不改原列表', () {
      final entries = [
        {'name': 'b.mp4', 'mtime': 100},
        {'name': 'a.mp4', 'mtime': 300},
        {'name': 'c.mp4', 'mtime': 300},
      ];
      final sorted = sortHaikuoDownloadEntries(entries);
      expect(
        [for (final e in sorted) e['name']],
        ['a.mp4', 'c.mp4', 'b.mp4'],
      );
      expect(entries.first['name'], 'b.mp4');
    });
  });

  test('C01：noLoading 捕获与统一消费', () {
    has('function consumeNavQuiet');
    has('var nextNavQuiet = false;');
    has('if (nextNavQuiet) { nextNavQuiet = false; return; }');
    has('var lazyQuiet = consumeNavQuiet();');
    has('var quiet = consumeNavQuiet();');
    has('if (!consumeNavQuiet()) showPlayLoading(true);');
    has('nextNavQuiet = hasFlag(raw, \'noLoading\');');
  });

  test('C08/C09/C11：主题捕获与应用', () {
    has('function pageThemeOf');
    has('function applyPageTheme');
    has('function captureNavFlags');
    has('function applyCapturedNavState');
    has('var pendingNavCarried = false;');
    has("native({ type: 'setPageImmersive', immersive: immersive });");
    has('hk-immersive');
    has('if (hasFlag(raw, \'fullTheme\')) return \'full\';');
    has('if (hasFlag(raw, \'gameTheme\')) return \'game\';');
    has('if (hasFlag(raw, \'immersiveTheme\')) return \'immersive\';');
  });

  test('E76：下页标题计算与标题栈', () {
    has('function computeNextTitle');
    has('extra.pageTitle');
    has('params.pageTitle');
    has('extra.inheritTitle === false');
    has('function pushNavEntry');
    has('theme: currentPageTheme, title: pageTitle');
    has('applyPageTheme(prev.theme || \'\');');
    has('setPageTitle(prev.title ? prev.title : (PROGRAM.name');
  });

  test('C12：autoPage 武装/触底/捕获', () {
    has('function armAutoPage');
    has('function bindAutoPageScroll');
    has('function maybeAutoPage');
    has('function loadNextAutoPage');
    has('function captureNextChapter');
    has('resultCapture = collected;');
    has('sh - 200');
    has('clean.indexOf(\'fypage\') >= 0');
  });

  test('C13：页面缓存捕获/读写/清理/hook', () {
    has('function armPageCache');
    has('function cacheCode');
    has('function readPageCache');
    has('function maybeWritePageCache');
    has('function tryServePageCache');
    has('function prunePageCache');
    has('pgc_');
    has('PAGE_CACHE_MAX = 200;');
    has('pageCacheBypass = true;');
    has('pageCacheHook = null;');
    has('cacheCode: cacheCode,');
    has('E76 联动');
    has('maybeWritePageCache(items);');
    has('maybeWritePageCache(parsed);');
  });

  test('C13：fetch 取数语境不触发页面缓存', () {
    final start = html.indexOf('function fetch(url, opt)');
    final end = html.indexOf('function wrapFetchResult', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final fetchBody = html.substring(start, end);
    expect(fetchBody, isNot(contains('tryServePageCache')));
    expect(fetchBody, isNot(contains('pageCacheArmed')));
  });

  test('H01：取数语境 hiker://home@ 补偿链', () {
    has("if (text.indexOf('hiker://home@') === 0) {");
    has("return 'null';");
    has('var found = findRuleTitle(cand);');
  });

  test('H04：下载列表页', () {
    has('function renderDownloadList');
    has('function deleteDownloadAndRefresh');
    has('function formatDownloadDesc');
    has("collectionRequest('/__downloads')");
    has("setPageTitle('下载');");
    has("if (url.indexOf('hiker://download') === 0) {");
  });

  test('E84 微选项：func://background 改 toast 不退出', () {
    has("if (url.indexOf('func://background') === 0) {");
    has("toast('没有可隐藏的窗口');");
  });

  test('H22 JS：share:// 改发 share 消息', () {
    has("native({ type: 'share', target: url.slice('share://'.length) });");
  });

  test('接线：捕获/应用/清理调用点齐全', () {
    has('captureNavFlags(rawUrl, item, clickIndex);');
    has('captureNavFlags(result, item, null);');
    has('pendingNavCarried = true;');
    has('tryServePageCache(true)');
    has('tryServePageCache(false)');
    has('bindAutoPageScroll();');
    has('prunePageCache();');
    has('clearNavCapture();');
    has("setPageTitle(PROGRAM.name || '海阔小程序');");
  });

  test('Dart：setPageImmersive 消息与或逻辑', () {
    runnerHas("case 'setPageImmersive':");
    runnerHas('bool _pageImmersive = false;');
    runnerHas('_applyRunnerSystemUi');
    runnerHas('_reapplyRunnerSystemUiSoon');
    runnerHas('haikuoImmersiveUi(');
    runnerHas('SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);');
  });

  test('Dart：share 消息 partial（落盘 + 回落复制，无分享依赖）', () {
    runnerHas("case 'share':");
    runnerHas('_handleShare');
    runnerHas('_shareFileBytes');
    runnerHas('_stageShareFile');
    runnerHas('haikuo_share');
    runnerHas('文件不存在');
    runnerHas('_fallbackShareCopy');
    expect(runner, isNot(contains("import 'package:share_plus")));
    expect(runner, isNot(contains('Share.shareXFiles')));
    expect(runner, isNot(contains('Share.share(')));
    runnerHas('partial 实现');
  });

  test('Dart：/__downloads 端点', () {
    runnerHas("request.uri.path == '/__downloads'");
    runnerHas('_handleDownloads');
    runnerHas('haikuo_downloads');
    runnerHas('haikuoSafeFileName');
    runnerHas('sortHaikuoDownloadEntries');
    runnerHas("payload['action'] == 'delete'");
  });

  test('扫修 3 处修复与 W1/W2 符号仍在', () {
    has("replace(/fyAll/g, String(selectedCls || ''))");
    has('function getResCode() { try { return fetchPageHtml(); }');
    has('function JavaPBEKeySpec');
    has('function extractPlayHeaderSuffix');
    has('function normalizePlayHeadersList');
    has('function getPastes');
    has('function normalizeAttrSelectors');
    has('function queryAlternatives');
    has('chained.select = function (fn) {');
  });
}
