import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 播放链路 `;{头@值}` 后缀缺口修复的落点测试：断言摘取与合并代码
/// 真实存在于运行时 HTML 里（行为级验证见主会话的 Node 抽取测试，
/// 12 项全过；无 jsdom 环境，故此处只钉关键串，与 gapfix 测试同款）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('后缀摘取函数存在且只认尾部块', () {
    has('function extractPlayHeaderSuffix');
    has(r"/;\{([^{}]*)\}\s*$/.exec(s)");
    has("var pairs = m[1].split('&&');");
    has('if (!keys) return { url: s, headers: null };');
  });

  test('sendPlay 接入摘取：干净地址进播放器，头随消息走', () {
    has('var cleaned = extractPlayHeaderSuffix(url);');
    // R6-F1：两步摘取，`;{...}` 之后再摘 `@头=`，干净地址仍是 playUrl。
    has('var atCleaned = extractPlayAtHeaders(cleaned.url);');
    has('var playUrl = atCleaned.url;');
    has("{ type: 'play', url: playUrl,");
    has('payload.headers = mergedHeaders;');
  });

  test('历史仍记原始地址：重播时后缀头能再次摘出', () {
    has('var historyUrl = (item && (item.url || item.link)) || url;');
  });
}
