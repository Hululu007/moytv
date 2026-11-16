import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 小程序非视频分流与本批运行时补丁的静态 + 纯函数断言。
/// 行为级验证在 jsdom harness（T24–T29）；这里只断言 Dart 侧
/// 可直接测的决策函数与运行时 HTML 里补丁的存在性。
void main() {
  group('play 内容分流判定', () {
    test('novel:// 判为小说', () {
      expect(
        classifyHaikuoPlayContent(
          'novel://{"title":"第一章","content":"正文"}',
        ),
        HaikuoPlayContent.novel,
      );
    });

    test('novel:// 无正文不判为小说', () {
      expect(
        classifyHaikuoPlayContent('novel://{"title":"空章","content":""}'),
        HaikuoPlayContent.video,
      );
    });

    test('pics:// 判为图片集', () {
      expect(
        classifyHaikuoPlayContent(
          'pics://https://example.com/1.jpg&&https://example.com/2.jpg',
        ),
        HaikuoPlayContent.pics,
      );
    });

    test('普通视频地址判为视频', () {
      expect(
        classifyHaikuoPlayContent('https://example.com/v.m3u8'),
        HaikuoPlayContent.video,
      );
      expect(
        classifyHaikuoPlayContent(
          'https://example.com/live/64k.mp3#isMusic=true#',
        ),
        HaikuoPlayContent.video,
      );
    });
  });

  group('重定向最终地址解析', () {
    test('无重定向回原地址', () {
      expect(
        haikuoResolveFinalUri(
          Uri.parse('https://example.com/a'),
          const [],
        ).toString(),
        'https://example.com/a',
      );
    });

    test('单次绝对重定向', () {
      expect(
        haikuoResolveFinalUri(
          Uri.parse('https://example.com/a'),
          [Uri.parse('https://other.example.com/b')],
        ).toString(),
        'https://other.example.com/b',
      );
    });

    test('链式相对重定向逐级解析', () {
      expect(
        haikuoResolveFinalUri(
          Uri.parse('https://example.com/dir/a'),
          [Uri.parse('b'), Uri.parse('/final')],
        ).toString(),
        'https://example.com/final',
      );
    });
  });

  group('运行时 HTML 补丁存在性', () {
    test('setPreResult 已接入桥', () {
      expect(haikuoRuntimeHtml, contains('function setPreResult'));
      expect(haikuoRuntimeHtml, contains('setPreResult: setPreResult'));
      expect(haikuoRuntimeHtml, contains('preResultItems = [];'));
    });

    test('Java 桥最小垫片已接入', () {
      expect(haikuoRuntimeHtml, contains('JavaMessageDigest'));
      expect(haikuoRuntimeHtml, contains('JavaCipher'));
      expect(haikuoRuntimeHtml, contains('window.java = java'));
      expect(haikuoRuntimeHtml, contains('window.javax = javax'));
      expect(haikuoRuntimeHtml, contains('window.android = android'));
    });

    test('onlyHeaders 形态与最终地址透传', () {
      expect(haikuoRuntimeHtml, contains('opt.onlyHeaders'));
      expect(haikuoRuntimeHtml, contains('obj.url = finalUrl'));
    });

    test('对象 body 自动 JSON 头', () {
      expect(haikuoRuntimeHtml, contains('bodyWasObject'));
      expect(
        haikuoRuntimeHtml,
        contains("headers['Content-Type'] = 'application/json'"),
      );
    });

    test('novel 分流与 lazy 对象结果', () {
      expect(haikuoRuntimeHtml, contains("url.indexOf('novel://') === 0"));
      expect(haikuoRuntimeHtml, contains('Array.isArray(result.urls)'));
    });

    test('pd 回字符串（指南语义）', () {
      expect(haikuoRuntimeHtml, contains('if (!nodes.length) return \'\';'));
      expect(haikuoRuntimeHtml, contains('pd: parseDom'));
    });
  });
}
