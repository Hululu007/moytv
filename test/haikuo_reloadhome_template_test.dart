import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// reloadHome 模板型地址：占位符嵌在路径段里的 ## 地址（如
/// hiker://empty##fyclass/fypage/），点壳分类栏时按模板代入重建
/// MY_URL，不走 ## 分段重建（分段重建会丢模板结构，51吃瓜点分类
/// 后规则拼出 https://.../page##1 取不到数）。行为级验证走 Node
/// 桩验（真实运行时 + jsdom + 假后端，见
/// ~/workspace/haikuo_gaps_fix_20261117/stubs/verify_reloadhome.cjs，
/// 039 模板形 + 034 分段形双过）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('模板判定函数存在', () {
    has('function homeTemplateHasEmbeddedPlaceholder(base)');
    has("if (String(base || '').indexOf('##') < 0) return false;");
    has("if (/(fyclass|fypage|fyarea|fyyear|fysort|fyAll)/.test(s)");
    has(
      "!/^(fyclass|fypage|fyarea|fyyear|fysort|fyAll)\$/.test(s.replace(/^\\s+|\\s+\$/g, ''))",
    );
  });

  test('模板代入函数存在：占位语义与 substituteTemplates 一致', () {
    has('function substituteHomeTemplate(base)');
    has('var fp = /\\[firstPage=([^\\]]*)\\]/.exec(out);');
    has('fypage@(-?\\d+)@\\*(-?\\d+)@');
    has('fypage@(-?\\d+)(?!@)');
    has("out = out.replace(/\\bfypage\\b/g, '1');");
    has("out = out.replace(/\\bfyclass\\b/g, String(selectedCls || ''));");
    has("out = out.replace(/fyAll/g, String(selectedCls || ''));");
  });

  test('reloadHome 模板分支优先于分段重建', () {
    has('if (homeTemplateHasEmbeddedPlaceholder(base)) {');
    has('url = substituteHomeTemplate(base);');
    has("} else if (base.indexOf('##') >= 0");
    has("url = 'hiker://empty##' + selectedCls + '##1'");
  });
}
