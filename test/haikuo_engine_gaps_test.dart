import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

void main() {
  group('引擎缺口：裸 require 分流', () {
    test('requireForRule 存在且接管四种本地前缀', () {
      expect(
        haikuoRuntimeHtml,
        contains('function requireForRule(path, headers, version)'),
      );
      expect(
        haikuoRuntimeHtml,
        contains("p.indexOf('hiker://page/') === 0"),
      );
      expect(
        haikuoRuntimeHtml,
        contains("p.indexOf('hiker://files/') === 0"),
      );
      expect(
        haikuoRuntimeHtml,
        contains("p.indexOf('hiker://assets/') === 0"),
      );
      expect(haikuoRuntimeHtml, contains("p.indexOf('file://') === 0"));
      expect(haikuoRuntimeHtml, contains('return loadModule(p);'));
      expect(haikuoRuntimeHtml, contains('return requireRemote(p, headers, version);'));
    });

    test('规则作用域的裸 require 绑分流函数', () {
      expect(haikuoRuntimeHtml, contains('require: requireForRule,'));
    });
  });

  group('引擎缺口：模块收集收对象字面量', () {
    test('collectModuleNames 收 var/let/const 对象字面量声明', () {
      expect(haikuoRuntimeHtml, contains('var re4 = '));
      expect(
        haikuoRuntimeHtml,
        contains('while ((m = re4.exec(src)) !== null) add(m[1]);'),
      );
    });
  });

  group('引擎缺口：evalPrivateJS 桩', () {
    test('桩存在、抛明确错误、不回假数据', () {
      expect(haikuoRuntimeHtml, contains('function evalPrivateJSStub()'));
      expect(
        haikuoRuntimeHtml,
        contains('evalPrivateJS: evalPrivateJSStub,'),
      );
      expect(
        haikuoRuntimeHtml,
        contains('该规则用了官方私有脚本（evalPrivateJS），壳子不支持'),
      );
    });
  });
}
