import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/external_py_import.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/novel_source_store.dart';
import 'package:moyi/plugin_share_intent.dart';
import 'package:moyi/shared_json_import.dart';
import 'package:moyi/tvbox_config.dart';

const _ruleJson =
    '{"title":"测试规则","find_rule":"js:var a=1;setResult(d)","search_url":"https://example.com/s?wd=**"}';
const _ruleJson2 =
    '{"title":"测试规则二","find_rule":"js:var b=2;setResult(d)","search_url":"https://example.com/s?wd=**"}';
const _legadoJson =
    '{"bookSourceName":"测试书源","bookSourceUrl":"https://example.com","bookSourceType":0,'
    '"searchUrl":"https://example.com/s?q={{key}}",'
    '"ruleSearch":{"bookList":"x"},"ruleBookInfo":{"name":"x"},'
    '"ruleToc":{"chapterList":"x"},"ruleContent":{"content":"x"}}';
const _configJson =
    '{"sites":[{"key":"a","name":"A站","type":3,"api":"https://example.com/api"}],'
    '"spider":"https://example.com/spider.jar"}';
const _listJson =
    '{"list":[{"vod_id":"1","vod_name":"AV","vod_play_from":"直播",'
    '"vod_play_url":"1\$http://x/1.m3u8#2\$http://x/2.m3u8"}],'
    '"parse":0,"jx":0}';

NovelImportRecord _record(String name) =>
    NovelImportRecord(id: 'novel_1', name: name, fileName: 'f.json');

void main() {
  group('分享 JSON 内容判定', () {
    test('单个海阔规则对象', () {
      expect(classifySharedJson(_ruleJson), SharedJsonKind.haikuo);
    });

    test('海阔规则数组', () {
      expect(
        classifySharedJson('[$_ruleJson,$_ruleJson2]'),
        SharedJsonKind.haikuo,
      );
    });

    test('单个阅读书源', () {
      expect(classifySharedJson(_legadoJson), SharedJsonKind.legado);
    });

    test('书源数组里有一条合法即算书源', () {
      expect(
        classifySharedJson('[{"foo":1},$_legadoJson]'),
        SharedJsonKind.legado,
      );
    });

    test('TVBox 配置（含 sites 与 spider）', () {
      expect(classifySharedJson(_configJson), SharedJsonKind.tvboxConfig);
    });

    test('TVBox 配置只有 sites 也认', () {
      expect(
        classifySharedJson('{"sites":[{"key":"a","name":"A","api":"http://x"}]}'),
        SharedJsonKind.tvboxConfig,
      );
    });

    test('TVBox 配置不会被海阔解析抢走', () {
      // 每个站点都有 name 又有 api，海阔解析器会认成小程序，
      // 判定顺序必须保证配置先判。
      expect(classifySharedJson(_configJson), isNot(SharedJsonKind.haikuo));
    });

    test('视频列表 JSON（含 vod_play_url）认作 jsonList', () {
      expect(classifySharedJson(_listJson), SharedJsonKind.jsonList);
    });

    test('带 parse/jx 键的视频列表不进配置分支', () {
      expect(classifySharedJson(_listJson), isNot(SharedJsonKind.tvboxConfig));
    });

    test('base64 包裹的 TVBox 配置', () {
      final encoded = base64Encode(utf8.encode(_configJson));
      expect(classifySharedJson(encoded), SharedJsonKind.tvboxConfig);
    });

    test('缺正文规则的书源不是任何一种', () {
      const broken =
          '{"bookSourceName":"坏源","bookSourceUrl":"https://example.com",'
          '"bookSourceType":0,"searchUrl":"https://example.com/s",'
          '"ruleSearch":{"bookList":"x"},"ruleBookInfo":{"name":"x"},'
          '"ruleToc":{"chapterList":"x"}}';
      expect(classifySharedJson(broken), SharedJsonKind.unsupported);
    });

    test('垃圾文本', () {
      expect(classifySharedJson('hello world'), SharedJsonKind.unsupported);
    });

    test('无关 JSON 对象', () {
      expect(classifySharedJson('{"foo":1}'), SharedJsonKind.unsupported);
    });

    test('无关 JSON 数组', () {
      expect(classifySharedJson('[{"a":1},{"b":2}]'), SharedJsonKind.unsupported);
    });

    test('空内容与坏 JSON', () {
      expect(classifySharedJson(''), SharedJsonKind.unsupported);
      expect(classifySharedJson('   '), SharedJsonKind.unsupported);
      expect(classifySharedJson('{oops'), SharedJsonKind.unsupported);
    });
  });

  group('分享 JSON 分流执行', () {
    test('海阔路由调海阔导入并返回结果摘要', () async {
      var called = false;
      final handler = SharedJsonImportHandler(
        haikuoImport: (bytes, origin) async {
          called = true;
          expect(origin, '分享：rule.json');
          return HaikuoImportResult(
            added: const [
              HaikuoProgram(id: '1', name: '测试规则'),
              HaikuoProgram(id: '2', name: '测试规则二'),
            ],
            updated: const [HaikuoProgram(id: '3', name: '旧规则')],
          );
        },
      );
      final message = await handler.handle(
        utf8.encode('[$_ruleJson,$_ruleJson2]'),
        fileName: 'rule.json',
      );
      expect(called, isTrue);
      expect(message, '新增 2 个，更新 1 个');
    });

    test('海阔导入 notes 超过 3 条时截断并报剩余', () async {
      final handler = SharedJsonImportHandler(
        haikuoImport: (_, _) async => const HaikuoImportResult(
          added: [],
          updated: [],
          notes: ['n1', 'n2', 'n3', 'n4', 'n5'],
        ),
      );
      final message = await handler.handle(
        utf8.encode(_ruleJson),
        fileName: 'rule.json',
      );
      expect(message, '没有新增条目；n1；n2；n3，还有 2 条');
    });

    test('书源路由调书源导入并刷新注册表', () async {
      var imported = false;
      var refreshed = false;
      final handler = SharedJsonImportHandler(
        legadoImport: (text) async {
          imported = true;
          return (records: [_record('测试书源')], skipped: 0);
        },
        onLegadoImported: () async {
          refreshed = true;
        },
      );
      final message = await handler.handle(
        utf8.encode(_legadoJson),
        fileName: 'book.json',
      );
      expect(imported, isTrue);
      expect(refreshed, isTrue);
      expect(message, '已导入 测试书源');
    });

    test('书源批量返回条数与跳过数', () async {
      final handler = SharedJsonImportHandler(
        legadoImport: (_) async => (
          records: [_record('甲'), _record('乙')],
          skipped: 1,
        ),
        onLegadoImported: () async {},
      );
      final message = await handler.handle(
        utf8.encode('[$_legadoJson,$_legadoJson,{"foo":1}]'),
        fileName: 'books.json',
      );
      expect(message, '已导入 2 条，跳过 1 条');
    });

    test('配置路由调配置导入并返回摘要', () async {
      String? identity;
      final handler = SharedJsonImportHandler(
        configImport: (text, sourceIdentity, displayName) async {
          identity = sourceIdentity;
          expect(displayName, '');
          final report = TvBoxImportReport('cfg1', '测试配置');
          report.apiSites = 2;
          report.lives = 1;
          return report;
        },
      );
      final message = await handler.handle(
        utf8.encode(_configJson),
        fileName: 'config.json',
      );
      expect(identity, startsWith('file:config.json:'));
      expect(
        message,
        '已导入「测试配置」：站点 2 个（接口 2 · jar 0 · py 0 · T4 0 · JS 0）、直播 1 个、解析 0 个',
      );
    });

    test('视频列表路由调 JSON 列表导入并返回摘要', () async {
      var called = false;
      final handler = SharedJsonImportHandler(
        jsonListImport: (bytes, fileName) async {
          called = true;
          expect(fileName, 'av.json');
          return '已导入 🔞AV';
        },
      );
      final message = await handler.handle(
        utf8.encode(_listJson),
        fileName: 'av.json',
      );
      expect(called, isTrue);
      expect(message, '已导入 🔞AV');
    });

    test('视频列表默认导入无 store 时指路到站点列表 + 号', () async {
      final handler = SharedJsonImportHandler();
      final message = await handler.handle(
        utf8.encode(_listJson),
        fileName: 'av.json',
      );
      expect(message, contains('导入本地文件'));
    });

    test('配置内容为空时报未导入任何内容', () async {
      final handler = SharedJsonImportHandler(
        configImport: (_, _, _) async => TvBoxImportReport('cfg1', '空配置'),
      );
      final message = await handler.handle(
        utf8.encode(_configJson),
        fileName: 'config.json',
      );
      expect(message, '未导入任何内容「空配置」');
    });

    test('配置超过文件上限时拒收且不调导入', () async {
      var called = false;
      final handler = SharedJsonImportHandler(
        configImport: (_, _, _) async {
          called = true;
          return TvBoxImportReport('cfg1', 'x');
        },
      );
      final pad = 'x' * (TvBoxImporter.maxConfigFileBytes + 1);
      final text = '{"sites":[],"spider":"","pad":"$pad"}';
      final message = await handler.handle(
        utf8.encode(text),
        fileName: 'big.json',
      );
      expect(called, isFalse);
      expect(message, '文件过大，无法导入');
    });

    test('认不出的内容不调任何导入并诚实提示', () async {
      var called = false;
      void mark() => called = true;
      final handler = SharedJsonImportHandler(
        haikuoImport: (_, _) async {
          mark();
          throw UnimplementedError();
        },
        legadoImport: (_) async {
          mark();
          throw UnimplementedError();
        },
        configImport: (_, _, _) async {
          mark();
          throw UnimplementedError();
        },
      );
      final message = await handler.handle(
        utf8.encode('{"foo":1}'),
        fileName: 'weird.json',
      );
      expect(called, isFalse);
      expect(message, contains('不是可识别的 JSON'));
      expect(message, contains('weird.json'));
    });
  });

  group('原生队列的 kind 标记', () {
    test('插件分享文件带 kind=json', () {
      final file = PluginShareFile.fromJson({
        'uri': 'content://x/1',
        'name': 'rule.json',
        'kind': 'json',
      });
      expect(file.kind, 'json');
    });

    test('插件分享文件不带 kind 时留空（旧行为）', () {
      final file = PluginShareFile.fromJson({
        'uri': 'content://x/1',
        'name': 'a.py',
      });
      expect(file.kind, '');
    });

    test('扩展名判定仍拒绝 json（JSON 走 kind 分流，不走安装）', () {
      expect(
        decidePluginShareRoute('content://x/1', fileName: 'rule.json'),
        PluginShareDecision.reject,
      );
    });

    test('暂存文件 kind=json 且不被认成 jar', () {
      final file = ExternalPyFile.fromJson({
        'path': '/cache/jsonimport/1.json',
        'name': 'rule.json',
        'size': 10,
        'kind': 'json',
      });
      expect(file.kind, 'json');
      expect(file.isJar, isFalse);
    });
  });
}
