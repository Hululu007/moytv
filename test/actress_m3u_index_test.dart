// 女优库 whos m3u 分片索引（2026-11-19）：9 个女优合集 m3u（310,028 条）
// 转 32 分片 gzip 索引 + manifest，随包进 assets/actress_json/whos_m3u/。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_m3u_index.dart';

Uint8List _gz(Map<String, dynamic> doc) =>
    Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(doc))));

/// 假 m3u 索引：2 个女优、3 条（同一番号 ABC-123 在两女优名下各一条）、2 分片。
WhosM3uIndex _fakeIndex(Map<String, int> calls) {
  final manifest = <String, dynamic>{
    'actress': {
      '测试女优': 0,
      '二号女优': 1,
    },
    'code': {
      'ABC123': [0, 1],
      'XYZ9': [1],
    },
    'videos': 3,
    'appearances': 3,
    'actresses': 2,
    'codes': 2,
    'entries': 3,
    'shards': 32,
  };
  final shards = <int, Map<String, dynamic>>{
    0: {
      'a': {
        '测试女优': [
          ['aaa111', 'ABC-123', '标题一'],
          ['bbb222', '', '无番号标题'],
        ],
      },
    },
    1: {
      'a': {
        '二号女优': [
          ['ccc333', 'ABC-123', '标题二同番号'],
          ['ddd444', 'XYZ-9', '标题三'],
        ],
      },
    },
  };
  return WhosM3uIndex(
    bytesReader: (asset) async {
      calls[asset] = (calls[asset] ?? 0) + 1;
      if (asset == WhosM3uIndex.manifestAsset) return _gz(manifest);
      final m = RegExp(r'shard_(\d+)\.json\.gz').firstMatch(asset);
      return _gz(shards[int.parse(m!.group(1)!)]!);
    },
  );
}

void main() {
  // 真实索引测试走 rootBundle 读随包 asset，纯 test() 需先初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('假索引总数与按女优查：行转条目、播图地址由 hash 拼、直链可播', () async {
    final index = _fakeIndex({});
    final stats = await index.stats();
    expect(stats.videos, 3);
    expect(stats.appearances, 3);
    expect(stats.actresses, 2);
    expect(stats.codes, 2);
    expect(stats.entries, 3);

    final rows = await index.entriesForActress('测试女优');
    expect(rows.length, 2);
    final first = rows.first;
    expect(first.site, 'whos');
    expect(first.vodId, 'aaa111');
    expect(first.vodCode, 'ABC-123');
    expect(first.codeKey, 'ABC123');
    expect(first.typeName, '日本AV');
    expect(first.vodPic, 'https://v.hersav.me/images/av/aaa111.jpg');
    expect(
      first.playUrl,
      'https://v.hersav.me/aaa111/aaa111.m3u8',
    );
    expect(first.playable, isTrue);
    expect(first.vodPlayUrl, '正片\$https://v.hersav.me/aaa111/aaa111.m3u8');
    // 没番号的行也能播，只是番号键为空。
    expect(rows.last.codeKey, isEmpty);
    expect(rows.last.playable, isTrue);
  });

  test('按女优查认归一化名（去空白），查不到回空', () async {
    final index = _fakeIndex({});
    expect((await index.entriesForActress('测试 女优')).length, 2);
    expect(await index.entriesForActress('没有这个人'), isEmpty);
  });

  test('按番号查：同一番号在多女优名下各留一条，大小写不敏感', () async {
    final index = _fakeIndex({});
    final rows = await index.entriesForCode('ABC-123');
    expect(rows.length, 2);
    expect(rows.map((e) => e.vodActor).toSet(), {'测试女优', '二号女优'});
    expect(rows.every((e) => e.codeKey == 'ABC123'), isTrue);
    expect((await index.entriesForCode('abc123')).length, 2);
    expect((await index.entriesForCode('XYZ-9')).length, 1);
    expect((await index.entriesForCode('XYZ-9')).first.vodId, 'ddd444');
    expect(await index.entriesForCode('NOPE-1'), isEmpty);
  });

  test('有没有条目只查 manifest 不解分片；manifest 与分片只读一次', () async {
    final calls = <String, int>{};
    final index = _fakeIndex(calls);
    expect(
      await index.hasEntriesForPerson(
        names: ['二号女优'],
        codeKeys: {},
      ),
      isTrue,
    );
    expect(
      await index.hasEntriesForPerson(
        names: ['没有这个人'],
        codeKeys: {'ABC123'},
      ),
      isTrue,
    );
    expect(
      await index.hasEntriesForPerson(
        names: ['没有这个人'],
        codeKeys: {'NOPE1'},
      ),
      isFalse,
    );
    // 上面三问只解了 manifest，没碰任何分片。
    expect(
      calls.keys.where((k) => k.contains('shard_')),
      isEmpty,
    );
    await index.entriesForActress('测试女优');
    await index.entriesForActress('测试女优');
    expect(calls[WhosM3uIndex.manifestAsset], 1);
    expect(calls[WhosM3uIndex.shardAsset(0)], 1);
  });

  // 2026-11-21：包里内置的 whos_m3u 分片（32 个 shard + manifest，约 24MB）
  // 已删除——实测 224,456 条地址里 224,454 条在用户库里按番号就能取到，
  // 库里还多 9.8 万条。索引读取逻辑的用例（上面那批用假分片的）保留，
  // 依赖真实分片资产的三个用例随资产一起去掉。
}
