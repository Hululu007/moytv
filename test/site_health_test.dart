import 'package:moyi/site_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 11, 25, 12);

  SiteHealthStore freshStore() =>
      SiteHealthStore(saveDelay: const Duration(days: 1));

  group('评分与分档', () {
    test('site_health_score_neutral_for_unknown', () {
      final store = freshStore();
      expect(store.scoreOf('ghost'), siteHealthNeutralRate);
      expect(store.tierOf('ghost'), SiteHealthTier.unknown);
      expect(store.recordOf('ghost'), isNull);
    });

    test('site_health_score_weights_search_detail_play', () {
      final store = freshStore();
      // 搜索 3/3 成功（率 1.0）、详情 0/3（率 0）、播放无样本（中性）。
      for (var i = 0; i < 3; i++) {
        store.recordSearch('a', ok: true, items: 2, elapsedMs: 10, at: t0);
        store.recordDetail('a', ok: false, elapsedMs: 10, at: t0);
      }
      expect(store.scoreOf('a'), closeTo(0.4 * 1.0 + 0.3 * 0 + 0.3 * 0.5, 1e-9));
      // 样本 <3 的类按中性计：只记 2 次搜索成功，总分仍是中性。
      store.recordSearch('b', ok: true, at: t0);
      store.recordSearch('b', ok: true, at: t0);
      expect(store.scoreOf('b'), siteHealthNeutralRate);
    });

    test('site_health_tier_thresholds', () {
      final store = freshStore();
      // 绿：搜索 + 详情全成，总分 0.4+0.3+0.15=0.85，且有最近成功。
      for (var i = 0; i < 3; i++) {
        store.recordSearch('good', ok: true, at: t0);
        store.recordDetail('good', ok: true, at: t0);
      }
      expect(store.tierOf('good'), SiteHealthTier.good);
      // 黄：搜索半成半败，总分 0.5。
      for (var i = 0; i < 3; i++) {
        store.recordSearch('fair', ok: true, at: t0);
        store.recordSearch('fair', ok: false, at: t0);
      }
      expect(store.tierOf('fair'), SiteHealthTier.fair);
      // 红（低分）：三类全败，总分 0。
      for (var i = 0; i < 3; i++) {
        store.recordSearch('bad', ok: false, at: t0);
        store.recordDetail('bad', ok: false, at: t0);
        store.recordPlay('bad', ok: false, at: t0);
      }
      expect(store.tierOf('bad'), SiteHealthTier.bad);
      // 红（连续失败）：总分本可 0.75，但最近连败 5 次直接判红。
      for (var i = 0; i < 3; i++) {
        store.recordDetail('streak', ok: true, at: t0);
        store.recordPlay('streak', ok: true, at: t0);
        store.recordSearch('streak', ok: true, at: t0);
      }
      for (var i = 0; i < 5; i++) {
        store.recordSearch('streak', ok: false, at: t0);
      }
      expect(store.scoreOf('streak'), greaterThan(0.7));
      expect(store.tierOf('streak'), SiteHealthTier.bad);
    });
  });

  group('老化与保留期', () {
    test('site_health_aging_halves_after_90_days', () {
      final store = freshStore();
      for (var i = 0; i < 10; i++) {
        store.recordSearch('a', ok: true, items: 1, at: t0);
      }
      expect(store.recordOf('a')!.searchOk, 10);
      // 91 天后再打点：旧计数先减半（10→5）再累加新的一次。
      store.recordSearch(
        'a',
        ok: true,
        items: 1,
        at: t0.add(const Duration(days: 91)),
      );
      expect(store.recordOf('a')!.searchOk, 6);
      expect(store.recordOf('a')!.searchItemsTotal, 6);
    });

    test('site_health_expired_records_dropped', () {
      final store = freshStore();
      store.recordSearch('old', ok: true, at: t0);
      store.recordSearch('fresh', ok: true, at: t0.add(const Duration(days: 80)));
      final encoded = store.encode(at: t0.add(const Duration(days: 91)));
      final reloaded = freshStore()
        ..loadFromJson(encoded, at: t0.add(const Duration(days: 91)));
      expect(reloaded.recordOf('old'), isNull);
      expect(reloaded.recordOf('fresh'), isNotNull);
      // 加载时同样丢弃超期记录。
      final direct = freshStore()
        ..loadFromJson(
          store.encode(at: t0),
          at: t0.add(const Duration(days: 91)),
        );
      expect(direct.recordOf('old'), isNull);
    });
  });

  group('存取', () {
    test('site_health_json_roundtrip_and_clear', () {
      String? saved;
      final store = freshStore();
      store.onSave = (json) => saved = json;
      for (var i = 0; i < 3; i++) {
        store.recordSearch('a', ok: true, items: 4, elapsedMs: 25, at: t0);
      }
      store.recordPlay('a', ok: false, at: t0);
      final encoded = store.encode(at: t0);
      final reloaded = freshStore()..loadFromJson(encoded, at: t0);
      final record = reloaded.recordOf('a')!;
      expect(record.searchOk, 3);
      expect(record.searchItemsTotal, 12);
      expect(record.searchMsTotal, 75);
      expect(record.playFail, 1);
      expect(record.lastOkAtMs, t0.millisecondsSinceEpoch);
      expect(record.lastFailAtMs, t0.millisecondsSinceEpoch);
      // 清空：内存回未知，落盘回调收到空表。
      store.clear();
      expect(store.recordOf('a'), isNull);
      expect(store.tierOf('a'), SiteHealthTier.unknown);
      expect(saved, isNotNull);
      final afterClear = freshStore()..loadFromJson(saved, at: t0);
      expect(afterClear.records, isEmpty);
      // 坏 JSON 不抛错、回空表。
      final broken = freshStore()..loadFromJson('{not json', at: t0);
      expect(broken.records, isEmpty);
      final wrongShape = freshStore()..loadFromJson('{"sites": 42}', at: t0);
      expect(wrongShape.records, isEmpty);
    });

    test('site_health_record_search_counts_items_and_failures', () {
      final store = freshStore();
      store.recordSearch('a', ok: true, items: 5, elapsedMs: 100, at: t0);
      store.recordSearch(
        'a',
        ok: true,
        items: 3,
        elapsedMs: 50,
        at: t0.add(const Duration(seconds: 1)),
      );
      store.recordSearch(
        'a',
        ok: false,
        elapsedMs: 30,
        at: t0.add(const Duration(seconds: 2)),
      );
      final record = store.recordOf('a')!;
      expect(record.searchOk, 2);
      expect(record.searchFail, 1);
      expect(record.searchItemsTotal, 8);
      expect(record.searchMsTotal, 150);
      expect(record.lastOkAtMs, t0.add(const Duration(seconds: 1)).millisecondsSinceEpoch);
      expect(record.lastFailAtMs, t0.add(const Duration(seconds: 2)).millisecondsSinceEpoch);
      expect(record.consecutiveFails, 1);
      // 空结果记成功、条数为 0（搜不到不算站坏）。
      store.recordSearch('a', ok: true, items: 0, at: t0.add(const Duration(seconds: 3)));
      expect(store.recordOf('a')!.searchOk, 3);
      expect(store.recordOf('a')!.consecutiveFails, 0);
      // 总开关关：不打点。
      store.enabled = false;
      store.recordSearch('a', ok: false, at: t0);
      expect(store.recordOf('a')!.searchFail, 1);
    });
  });

  group('调度排序', () {
    test('search_dispatch_order_health_first_stable_and_switch', () {
      final store = freshStore();
      for (var i = 0; i < 3; i++) {
        store.recordSearch('good', ok: true, at: t0);
        store.recordSearch('bad', ok: false, at: t0);
      }
      // 健康站先发起、未知站居中、坏站最后；同分保持入参顺序。
      expect(
        store.orderSources(['bad', 'mid1', 'good', 'mid2']),
        ['good', 'mid1', 'mid2', 'bad'],
      );
      // 总开关关：入参顺序原样。
      store.enabled = false;
      expect(store.orderSources(['bad', 'good']), ['bad', 'good']);
      expect(store.scoreOf('good'), siteHealthNeutralRate);
    });
  });
}
