import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_clipboard.dart';
import 'package:moyi/miniapp/haikuo/haikuo_codec.dart';

Map<String, dynamic> _rule({String title = '测试规则'}) => {
  'title': title,
  'author': '作者',
  'type': 'video',
  'url': 'hiker://empty##https://example.com/list',
  'col_type': 'movie_3',
  'find_rule': 'js:\nsetResult([]);',
  'searchFind': '',
};

String _shareCode(String title) {
  final payload = base64Encode(utf8.encode(jsonEncode(_rule(title: title))));
  return '海阔视界规则分享，当前分享的是：小程序￥home_rule￥$payload￥';
}

void main() {
  group('剪贴板检测：空与非口令', () {
    test('null、空、纯空白都没有候选', () {
      expect(HaikuoClipboardScan.extract(null), isEmpty);
      expect(HaikuoClipboardScan.extract(''), isEmpty);
      expect(HaikuoClipboardScan.extract('  \n  '), isEmpty);
    });

    test('普通聊天文本没有候选', () {
      expect(
        HaikuoClipboardScan.extract('今晚吃什么？火锅还是烧烤'),
        isEmpty,
      );
    });

    test('裸链接故意不认（避免任何链接都弹窗）', () {
      expect(
        HaikuoClipboardScan.extract('https://example.com/rules.json'),
        isEmpty,
      );
    });

    test('裸 base64 块没有口令标记时不认', () {
      final blob = base64Encode(utf8.encode(jsonEncode(_rule())));
      expect(HaikuoClipboardScan.extract(blob), isEmpty);
    });

    test('￥ 段数不足或载荷太短不认', () {
      expect(HaikuoClipboardScan.extract('名字￥标识'), isEmpty);
      expect(HaikuoClipboardScan.extract('名字￥标识￥短'), isEmpty);
    });
  });

  group('剪贴板检测：单口令', () {
    test('官方 ￥ 口令认出 1 个，名字取规则标题', () {
      final candidates = HaikuoClipboardScan.extract(_shareCode('甲规则'));
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '甲规则');
      expect(candidates.single.text, contains('home_rule'));
    });

    test('口令嵌在聊天正文里也能捞出来', () {
      final text = '分享给你一个好用的规则：\n${_shareCode('乙规则')}\n快导入试试';
      final candidates = HaikuoClipboardScan.extract(text);
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '乙规则');
    });

    test('口令后面跟中文标点不影响识别', () {
      final candidates = HaikuoClipboardScan.extract('${_shareCode('丙规则')}，快导入！');
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '丙规则');
    });

    test('载荷解析不出时名字显示口令前半截', () {
      const code = '海阔视界小程序￥home_rule￥aGVsbG8gd29ybGQhISEhISEhISEh￥';
      final candidates = HaikuoClipboardScan.extract(code);
      expect(candidates, hasLength(1));
      expect(candidates.single.label, startsWith('海阔视界小程序￥'));
      expect(candidates.single.label, endsWith('…'));
    });
  });

  group('剪贴板检测：多口令与去重', () {
    test('两条口令各占一行，认出 2 个且保序', () {
      final text = '${_shareCode('甲规则')}\n${_shareCode('乙规则')}';
      final candidates = HaikuoClipboardScan.extract(text);
      expect(candidates.map((c) => c.label), ['甲规则', '乙规则']);
    });

    test('同一条口令重复出现只算 1 个', () {
      final code = _shareCode('甲规则');
      final candidates = HaikuoClipboardScan.extract('$code\n$code');
      expect(candidates, hasLength(1));
    });

    test('两条口令用空格隔开也能分开', () {
      final text = '${_shareCode('甲规则')} ${_shareCode('乙规则')}';
      final candidates = HaikuoClipboardScan.extract(text);
      expect(candidates.map((c) => c.label), ['甲规则', '乙规则']);
    });
  });

  group('剪贴板检测：其他形态', () {
    test('rule:// 口令认出 1 个，名字能解出来', () {
      final inner = _shareCode('丁规则');
      final code = 'rule://${base64Encode(utf8.encode(inner))}';
      final candidates = HaikuoClipboardScan.extract(code);
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '丁规则');
    });

    test('base64://@ 形态认出 1 个', () {
      final payload = base64Encode(utf8.encode(jsonEncode(_rule())));
      final candidates = HaikuoClipboardScan.extract(
        'base64://@测试规则@$payload',
      );
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '测试规则');
    });

    test('云口令短码认出 1 个，名字显示短码本身', () {
      final candidates = HaikuoClipboardScan.extract(
        '分享：云6oooole/xxxxxx/abc123',
      );
      expect(candidates, hasLength(1));
      expect(candidates.single.label, contains('云6oooole'));
    });

    test('整段 JSON 只当 1 个候选，名字是规则标题', () {
      final candidates = HaikuoClipboardScan.extract(jsonEncode(_rule()));
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '测试规则');
    });

    test('JSON 数组一次认出多条规则，名字并列', () {
      final text = jsonEncode([_rule(title: '甲'), _rule(title: '乙')]);
      final candidates = HaikuoClipboardScan.extract(text);
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '甲、乙');
    });

    test('JSON 嵌在正文里也能捞出来', () {
      final text = '规则如下：\n${jsonEncode(_rule())}\n导入试试';
      final candidates = HaikuoClipboardScan.extract(text);
      expect(candidates, hasLength(1));
      expect(candidates.single.label, '测试规则');
    });
  });

  group('剪贴板摘要与已处理记忆', () {
    test('同一内容摘要相同，首尾空白不影响', () {
      final a = HaikuoClipboardScan.digestOf(_shareCode('甲规则'));
      final b = HaikuoClipboardScan.digestOf('  ${_shareCode('甲规则')} \n');
      expect(a, b);
      expect(a, isNotEmpty);
    });

    test('不同内容摘要不同', () {
      expect(
        HaikuoClipboardScan.digestOf(_shareCode('甲规则')),
        isNot(HaikuoClipboardScan.digestOf(_shareCode('乙规则'))),
      );
    });

    test('空剪贴板摘要稳定', () {
      expect(
        HaikuoClipboardScan.digestOf(null),
        HaikuoClipboardScan.digestOf(''),
      );
    });

    test('内存版已处理记忆 round-trip', () async {
      final store = InMemoryHaikuoClipboardSeenStore();
      expect(await store.readDigest(), isNull);
      await store.writeDigest('abc');
      expect(await store.readDigest(), 'abc');
    });
  });

  group('检测与现有导入链一致', () {
    test('扫出的 ￥ 口令能被现有解析链认回同一条规则', () {
      final candidates = HaikuoClipboardScan.extract(_shareCode('甲规则'));
      final programs = HaikuoCodec.parseText(
        HaikuoCodec.extractCandidates(candidates.single.text).firstWhere(
          (c) => HaikuoCodec.tryBase64(c) != null,
        ),
      );
      expect(programs.single.name, '甲规则');
    });
  });
}
