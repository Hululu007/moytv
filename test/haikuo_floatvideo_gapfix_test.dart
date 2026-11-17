import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_helpers.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// W6（floatVideo 悬浮嗅探播放）回归测试：helpers 纯函数行为单测 +
/// 运行时 HTML/跑页落点钉串。JS 门控的行为级断言见
/// impl/w6/w6_verify.cjs（Node 抽取真实 x5RowHtml 跑在 vm/jsdom 里）。
/// 真机 WebView 行为（轮询时序、浮层体感）须 15 版构建后手机终验。
void main() {
  group('haikuoFloatVideoGate（严格 true 门）', () {
    test('true 开门', () {
      expect(haikuoFloatVideoGate(true), isTrue);
    });

    test('false/缺失/真值形态一律不开', () {
      expect(haikuoFloatVideoGate(false), isFalse);
      expect(haikuoFloatVideoGate(null), isFalse);
      expect(haikuoFloatVideoGate(1), isFalse, reason: '数字 1 不是 true');
      expect(haikuoFloatVideoGate(0), isFalse);
      expect(haikuoFloatVideoGate('true'), isFalse, reason: '字符串不是 true');
      expect(haikuoFloatVideoGate(''), isFalse);
      expect(haikuoFloatVideoGate(<String>[]), isFalse);
    });
  });

  group('haikuoFloatVideoShouldPoll（轮询五项全满足）', () {
    bool poll({
      bool floatVideo = true,
      bool visible = true,
      bool hasVideo = false,
      bool dismissed = false,
      int consecutiveFailures = 0,
    }) => haikuoFloatVideoShouldPoll(
      floatVideo: floatVideo,
      visible: visible,
      hasVideo: hasVideo,
      dismissed: dismissed,
      consecutiveFailures: consecutiveFailures,
    );

    test('门开+可见+未检出+未关闭+无失败时轮询', () {
      expect(poll(), isTrue);
    });

    test('门关/行藏/已检出/已关闭时停', () {
      expect(poll(floatVideo: false), isFalse);
      expect(poll(visible: false), isFalse);
      expect(poll(hasVideo: true), isFalse);
      expect(poll(dismissed: true), isFalse);
    });

    test('失败回落：连续失败未超上限继续，达上限停', () {
      expect(
        poll(consecutiveFailures: haikuoFloatVideoMaxFailures - 1),
        isTrue,
      );
      expect(
        poll(consecutiveFailures: haikuoFloatVideoMaxFailures),
        isFalse,
        reason: '达上限停轮询，静默回落只显示网页',
      );
      expect(
        poll(consecutiveFailures: haikuoFloatVideoMaxFailures + 5),
        isFalse,
      );
      expect(haikuoFloatVideoMaxFailures, 10);
    });
  });

  group('haikuoFloatVideoPick（复用 pickSniffedVideoUrl）', () {
    test('挑首个可播地址，非媒体跳过', () {
      expect(
        haikuoFloatVideoPick([
          'https://cdn.example/page.html',
          'https://cdn.example/logo.png',
          'https://cdn.example/v/index.m3u8?token=1',
          'https://cdn.example/v2.mp4',
        ], []),
        'https://cdn.example/v/index.m3u8?token=1',
      );
    });

    test('blockRules 命中的地址不进浮层', () {
      expect(
        haikuoFloatVideoPick(
          ['https://ad.example/a.mp4', 'https://cdn.example/v.mp4'],
          ['*ad.example*'],
        ),
        'https://cdn.example/v.mp4',
      );
      expect(
        haikuoFloatVideoPick(['https://ad.example/a.mp4'], ['*ad.example*']),
        '',
      );
    });

    test('无可播地址回空串，不抛错', () {
      expect(haikuoFloatVideoPick([], []), '');
      expect(haikuoFloatVideoPick(['https://cdn.example/a.js'], []), '');
      expect(
        haikuoFloatVideoPick(['about:blank', 'blob:https://x/y.mp4'], []),
        '',
        reason: '非 http(s) 地址不认',
      );
    });
  });

  group('共享脚本常量（嗅探/暂停同一串，不得各写一份）', () {
    test('资源枚举脚本与 _sniffTick 原串一致', () {
      expect(
        haikuoResourceEntriesScript,
        '(function(){try{return performance.getEntriesByType("resource")'
        '.map(function(e){return e.name;});}catch(e){return [];}})()',
      );
    });

    test('暂停脚本覆盖全部 video 元素且静默', () {
      expect(
        haikuoPausePageVideosScript,
        contains('document.querySelectorAll("video")'),
      );
      expect(haikuoPausePageVideosScript, contains('v.pause()'));
      expect(haikuoPausePageVideosScript, startsWith('try{'));
    });
  });

  group('运行时 HTML 落点（W6 门控）', () {
    final html = haikuoRuntimeHtml;

    test('x5RowHtml 严格门控：=== true，真值形态不开', () {
      expect(html, contains('floatVideo: extra.floatVideo === true'));
      expect(html, isNot(contains('floatVideo: !!extra.floatVideo')));
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

    test('W1–W5 符号回归', () {
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
        'function x5RowHtml',
        'function x5RenderBegin',
        'function x5IframeWrapHtml',
        'function x5EvalSilent',
        'window.__haikuoUrlInterceptor',
        'window.__haikuoX5Open',
        'window.__haikuoX5Play',
        'window.__haikuoX5ParseLazy',
        'window.__haikuoX5Var',
        'window.__haikuoX5Fetch',
        'window.__haikuoX5Fallback',
        'window.__haikuoX5CanGoBack',
      ]) {
        expect(html, contains(name), reason: name);
      }
      expect(html, isNot(contains('bindX5Frames')));
    });
  });

  group('跑页落点（W6）', () {
    final runner = File(
      'lib/miniapp/haikuo/haikuo_runner_page.dart',
    ).readAsStringSync();

    void has(String needle) {
      expect(runner, contains(needle), reason: '缺失：$needle');
    }

    test('状态字段与定时器', () {
      has('Timer? _floatVideoTimer');
      has('String _floatVideoUrl');
      has('_X5RowSession? _floatVideoSession');
      has('bool _floatVideoDismissed');
      has('bool _floatVideoTickBusy');
      has('int _floatVideoFailures');
      has('bool _floatVideoFullscreen');
      has('int _floatVideoGeneration');
    });

    test('轮询方法齐全且复用嗅探现成件', () {
      has('void _stopFloatVideoPolling()');
      has('void _resetFloatVideoState()');
      has('void _syncFloatVideoPolling()');
      has('Future<void> _floatVideoTick(_X5RowSession session)');
      has('void _closeFloatVideo()');
      has('Widget _buildFloatVideoOverlay()');
      has('_floatVideoTick(session)');
      has('haikuoResourceEntriesScript');
      has('haikuoFloatVideoPick(');
      has('_sniffUrlList(raw)');
      has('haikuoPausePageVideosScript');
      // 枚举常量在 _sniffTick 与 _floatVideoTick 两处共用。
      expect(
        'haikuoResourceEntriesScript'.allMatches(runner).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('门控两赋值点都走严格 gate', () {
      expect(
        "haikuoFloatVideoGate(extraMap['floatVideo'])"
            .allMatches(runner)
            .length,
        2,
        reason: '复用更新与新建会话两处赋值',
      );
      expect(
        runner,
        isNot(contains("floatVideo = extraMap['floatVideo'] == true")),
      );
      expect(
        runner,
        isNot(contains("floatVideo: extraMap['floatVideo'] == true")),
      );
    });

    test('失败回落：连续失败计数与上限停轮询', () {
      has('_floatVideoFailures++');
      has('haikuoFloatVideoMaxFailures');
      has('generation != _floatVideoGeneration');
      has('_floatVideoGeneration++');
    });

    test('导航/刷新/回落重检接线', () {
      // 重置调用点：换地址、首建、刷新两分支、页开始、回落。
      expect(
        '_resetFloatVideoState()'.allMatches(runner).length,
        greaterThanOrEqualTo(6),
      );
      expect(
        '_syncFloatVideoPolling()'.allMatches(runner).length,
        greaterThanOrEqualTo(4),
      );
    });

    test('悬浮层复用现有播放器视图 + 关闭入口', () {
      has('HaikuoPlayerView(');
      has('onClose: _closeFloatVideo');
      has("tooltip: '关闭悬浮播放'");
      has('identical(_floatVideoSession, _x5RowSession)');
      has('_buildFloatVideoOverlay()');
      // 不动共享播放器核心：跑页内不得出现 DanmakuController 引用。
      expect(runner, isNot(contains('DanmakuController')));
    });

    test('W3–W5 跑页符号回归', () {
      for (final name in [
        'class _X5RowSession',
        'WebViewController? _x5RowController',
        '_x5RowSession',
        '_x5CanGoBack',
        '_x5InterceptorChain',
        '_x5VarChain',
        "case 'x5row':",
        'HaikuoX5Bridge',
        '_onX5BridgeMessage',
        '_handleX5Row',
        '_hideX5Row',
        '_refreshX5Row',
        '_x5RowBack',
        '_decideX5Navigation',
        '_evalUrlInterceptorNow',
        '_execX5InterceptorCode',
        '_injectX5Bridge',
        '_x5RowFallback',
        '_buildX5RowOverlay',
        'haikuoBridgePadScript(cookies) + haikuoX5BridgeScript()',
        'haikuoParseX5Intercept',
        'expectInitialNavigation',
        'canPop: _inline == null && !_x5CanGoBack',
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
