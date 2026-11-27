// 本地库 lsp 作品门禁回归测试（2026-11-27 用户实报修复）：
// 女优库定版里 vod_play_from='lsp' 的作品有 107,844 部（占
// 24%），ActressJsonEntry.toDramaDetail 对它不做映射、原样
// 当 Drama.source='lsp'，而 'lsp' 此前在任何登记表里都不
// 存在，详情页进页门禁 allowsSource 恒为假——点开必落
// 「当前用户无权访问」面板（whos.tv 那批经 spiderIdForSite
// 映射到已登记的 chaoliu 所以能播，形态吻合）。
// 修法：'lsp' 补进 SourceSite.actressOnlySites 专用登记表
// （它只是库内数据来源标记，不进选站列表），allowsSource
// 本身不放宽。
//
// 口径同 actress_source_gate_test：全程按正式 App 的真实
// 登记状态跑，不做任何测试侧登记。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ActressJsonEntry _lspEntry() => ActressJsonEntry(
  site: 'lsp',
  vodId: 'same-711',
  vodName: 'SAME-711 本地库回归作品',
  vodPic: '',
  vodActor: '',
  vodDirector: '',
  vodRemarks: '',
  vodPubdate: '',
  vodArea: '',
  vodYear: '',
  vodContent: '',
  vodPlayFrom: 'lsp',
  vodPlayUrl: '正片\$https://example.com/lsp/same-711.m3u8',
  typeName: '',
  vodCode: 'SAME-711',
  vodActressPic: '',
);

void main() {
  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  test('lsp 补登记：isAvailable / isKnown / byId 认得且不回落', () {
    expect(SourceSite.isAvailable('lsp'), isTrue);
    expect(SourceSite.isKnown('lsp'), isTrue);
    expect(SourceSite.byId('lsp').id, 'lsp');
  });

  test('本地库 lsp 条目转换出的 Drama.source 就是 lsp 且门禁放行', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final detail = _lspEntry().toDramaDetail();
    expect(detail.drama.source, 'lsp');
    expect(store.allowsSource(detail.drama.source), isTrue);
    // lsp 不进选站列表（只是库内数据来源标记）。
    final listed = store.sources.map((site) => site.id).toSet();
    expect(listed.contains('lsp'), isFalse);
  });

  testWidgets('本地库 lsp 作品进详情页出内容、不落没权限面板', (tester) async {
    viewport(tester);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final detail = _lspEntry().toDramaDetail();
    await tester.pumpWidget(
      MaterialApp(
        home: DetailScreen(
          drama: detail.drama,
          repository: FixtureRepository(),
          store: store,
          initialDetail: detail,
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('当前用户无权访问'), findsNothing);
    expect(find.text('SAME-711 本地库回归作品'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
