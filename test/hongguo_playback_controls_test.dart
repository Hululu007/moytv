import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/hongguo_playback_page.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('恢复预算', () {
    test('延迟表是 1s/2.5s/5s/15s/30s/60s/90s/105s，累计约 5 分钟', () {
      expect(HongguoRecoveryBudget.delaysSeconds, [
        1,
        2.5,
        5,
        15,
        30,
        60,
        90,
        105,
      ]);
      expect(HongguoRecoveryBudget.totalSeconds, 308.5);
      final budget = HongguoRecoveryBudget();
      expect(budget.exhausted, isFalse);
      expect(budget.remaining, 8);
      expect(budget.nextDelay(), const Duration(seconds: 1));
      expect(budget.nextDelay(), const Duration(milliseconds: 2500));
      expect(budget.nextDelay(), const Duration(seconds: 5));
      expect(budget.nextDelay(), const Duration(seconds: 15));
      expect(budget.nextDelay(), const Duration(seconds: 30));
      expect(budget.nextDelay(), const Duration(seconds: 60));
      expect(budget.nextDelay(), const Duration(seconds: 90));
      expect(budget.nextDelay(), const Duration(seconds: 105));
      expect(budget.used, 8);
      expect(budget.remaining, 0);
      expect(budget.exhausted, isTrue);
    });

    test('预算耗尽后不再给延迟，用户显式重试重置预算', () {
      final budget = HongguoRecoveryBudget();
      for (var i = 0; i < 8; i++) {
        expect(budget.nextDelay(), isNotNull);
      }
      expect(budget.nextDelay(), isNull);
      expect(budget.nextDelay(), isNull);
      budget.reset();
      expect(budget.exhausted, isFalse);
      expect(budget.used, 0);
      expect(budget.nextDelay(), const Duration(seconds: 1));
    });
  });

  group('清晰度档位', () {
    test('上限是 1080，超上限的档标注兼容资源', () {
      expect(HongguoQualityOptions.maxQuality, 1080);
      expect(HongguoQualityOptions.standard, [1080, 720, 480]);
      expect(HongguoQualityOptions.label(1080), '1080P');
      expect(HongguoQualityOptions.label(720), '720P');
      expect(HongguoQualityOptions.label(480), '480P');
      expect(HongguoQualityOptions.label(2160), contains('兼容资源'));
      expect(HongguoQualityOptions.label(0), '自动');
      expect(HongguoQualityOptions.isCompatibleResource(2160), isTrue);
      expect(HongguoQualityOptions.isCompatibleResource(1080), isFalse);
    });

    test('可选档位降序去重，失败高度跳过', () {
      expect(
        HongguoQualityOptions.available([2160, 1080, 720, 480, 720]),
        [2160, 1080, 720, 480],
      );
      expect(
        HongguoQualityOptions.available(
          [1080, 720, 480],
          failedHeights: {1080},
        ),
        [720, 480],
      );
    });

    test('自动降档取比当前低的最大可选档，没有就返回空', () {
      const qualities = [2160, 1080, 720, 480];
      expect(HongguoQualityOptions.nextLower(qualities, 1080), 720);
      expect(HongguoQualityOptions.nextLower(qualities, 720), 480);
      expect(HongguoQualityOptions.nextLower(qualities, 480), isNull);
      expect(HongguoQualityOptions.nextLower(qualities, 2160), 1080);
      expect(
        HongguoQualityOptions.nextLower(
          qualities,
          1080,
          failedHeights: {720},
        ),
        480,
      );
      expect(
        HongguoQualityOptions.nextLower(
          qualities,
          1080,
          failedHeights: {720, 480},
        ),
        isNull,
      );
    });
  });

  group('解码失败教训', () {
    test('记高度失败后跳过该高度，别的高度不受影响', () {
      final lessons = HongguoDecoderLessons();
      expect(lessons.isEmpty, isTrue);
      lessons.remember(height: 1080);
      expect(lessons.failsHeight(1080), isTrue);
      expect(lessons.failsHeight(720), isFalse);
      expect(lessons.failedHeights, {1080});
      expect(
        HongguoQualityOptions.available(
          [1080, 720, 480],
          failedHeights: lessons.failedHeights,
        ),
        [720, 480],
      );
    });

    test('键是“编码|宽|高”，完整组合精确匹配，未知项当通配', () {
      expect(
        HongguoDecoderLessons.key(codec: 'h264', width: 1920, height: 1080),
        'h264|1920|1080',
      );
      final lessons = HongguoDecoderLessons();
      lessons.remember(codec: 'h264', width: 1920, height: 1080);
      expect(
        lessons.fails(codec: 'h264', width: 1920, height: 1080),
        isTrue,
      );
      expect(
        lessons.fails(codec: 'hevc', width: 1920, height: 1080),
        isFalse,
      );
      expect(lessons.fails(codec: 'h264', width: 1280, height: 1080), isFalse);
      // 只问高度时，编码与宽未知当通配，仍命中。
      expect(lessons.fails(height: 1080), isTrue);
      expect(lessons.fails(height: 720), isFalse);
    });

    test('JSON 存取往返，坏数据不炸', () {
      final lessons = HongguoDecoderLessons();
      lessons.remember(height: 1080);
      lessons.remember(height: 1080);
      lessons.remember(codec: 'h264', width: 1920, height: 720);
      final restored = HongguoDecoderLessons.fromJson(lessons.toJson());
      expect(restored.failsHeight(1080), isTrue);
      expect(restored.failsHeight(720), isTrue);
      expect(restored.counts['|0|1080'], 2);
      expect(HongguoDecoderLessons.fromJson('不是 JSON').isEmpty, isTrue);
      expect(HongguoDecoderLessons.fromJson(null).isEmpty, isTrue);
    });
  });

  group('跨季连播', () {
    test('默认关，且必须同时开着自动连播才生效', () {
      expect(
        hongguoSeasonAutoplayAllowed(autoNext: true, seasonAutoplay: true),
        isTrue,
      );
      expect(
        hongguoSeasonAutoplayAllowed(autoNext: false, seasonAutoplay: true),
        isFalse,
      );
      expect(
        hongguoSeasonAutoplayAllowed(autoNext: true, seasonAutoplay: false),
        isFalse,
      );
      expect(
        hongguoSeasonAutoplayAllowed(autoNext: false, seasonAutoplay: false),
        isFalse,
      );
    });

    test('播完本季找比当前季大的最小一季', () {
      const anchor = Drama(
        id: 'hongguo:1',
        source: 'hongguo',
        title: '测试剧 第1季',
      );
      const season2 = Drama(
        id: 'hongguo:2',
        source: 'hongguo',
        title: '测试剧 第2季',
      );
      const season3 = Drama(
        id: 'hongguo:3',
        source: 'hongguo',
        title: '测试剧 第3季',
      );
      const other = Drama(
        id: 'hongguo:9',
        source: 'hongguo',
        title: '别的剧 第2季',
      );
      expect(
        hongguoNextSeasonDrama(
          anchor: anchor,
          candidates: [season3, other, season2],
        ),
        season2,
      );
      expect(
        hongguoNextSeasonDrama(anchor: anchor, candidates: [other]),
        isNull,
      );
      expect(
        hongguoNextSeasonDrama(anchor: anchor, candidates: const []),
        isNull,
      );
    });

    test('没有下一季时返回空，不硬跳别的剧', () {
      const anchor = Drama(
        id: 'hongguo:1',
        source: 'hongguo',
        title: '测试剧 第1季',
      );
      const sameSeason = Drama(
        id: 'hongguo:1b',
        source: 'hongguo',
        title: '测试剧 第1季',
      );
      expect(
        hongguoNextSeasonDrama(
          anchor: anchor,
          candidates: [sameSeason],
        ),
        isNull,
      );
    });
  });

  group('画面模式缩放', () {
    test('适配不动，等比铺满按宽高比放大，拉伸铺满各向拉满', () {
      expect(
        HongguoFrameFit.scale(
          mode: HongguoFrameMode.fit,
          videoAspect: 9 / 16,
          containerAspect: 16 / 9,
        ),
        (scaleX: 1.0, scaleY: 1.0),
      );
      final zoom = HongguoFrameFit.scale(
        mode: HongguoFrameMode.zoom,
        videoAspect: 9 / 16,
        containerAspect: 16 / 9,
      );
      expect(zoom.scaleX, closeTo(256 / 81, 0.001));
      expect(zoom.scaleY, closeTo(256 / 81, 0.001));
      final same = HongguoFrameFit.scale(
        mode: HongguoFrameMode.zoom,
        videoAspect: 16 / 9,
        containerAspect: 16 / 9,
      );
      expect(same.scaleX, closeTo(1, 0.001));
      final fill = HongguoFrameFit.scale(
        mode: HongguoFrameMode.fill,
        videoAspect: 9 / 16,
        containerAspect: 16 / 9,
      );
      expect(fill.scaleX, closeTo(256 / 81, 0.001));
      expect(fill.scaleY, closeTo(1, 0.001));
      final fillTall = HongguoFrameFit.scale(
        mode: HongguoFrameMode.fill,
        videoAspect: 16 / 9,
        containerAspect: 9 / 16,
      );
      expect(fillTall.scaleX, closeTo(1, 0.001));
      expect(fillTall.scaleY, closeTo(256 / 81, 0.001));
    });

    test('画面模式存取：非法值回落到适配', () {
      expect(HongguoFrameMode.fromStored('zoom'), HongguoFrameMode.zoom);
      expect(HongguoFrameMode.fromStored('fill'), HongguoFrameMode.fill);
      expect(HongguoFrameMode.fromStored('bogus'), HongguoFrameMode.fit);
      expect(HongguoFrameMode.fromStored(null), HongguoFrameMode.fit);
      expect(HongguoFrameMode.fit.label, '适配');
      expect(HongguoFrameMode.zoom.label, '等比铺满');
      expect(HongguoFrameMode.fill.label, '拉伸铺满');
    });
  });

  group('常驻进度千分比', () {
    test('进度值按千分比算，越界夹住', () {
      expect(hongguoProgressPermille(0, 100), 0);
      expect(hongguoProgressPermille(50, 100), 500);
      expect(hongguoProgressPermille(1, 3), 333);
      expect(hongguoProgressPermille(100, 100), 1000);
      expect(hongguoProgressPermille(150, 100), 1000);
      expect(hongguoProgressPermille(10, 0), 0);
      expect(hongguoProgressPermille(-5, 100), 0);
    });
  });

  group('红果播放设置落盘', () {
    test('默认关/自动，非法值归位，写读往返', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.hongguoFrameMode, 'fit');
      expect(store.hongguoVideoRotation, 0);
      expect(store.hongguoAlwaysShowProgress, isFalse);
      expect(store.hongguoSeasonAutoplay, isFalse);
      expect(store.hongguoQuality, 0);
      expect(store.hongguoDecoderLessonsRaw, '');

      await store.setHongguoFrameMode('zoom');
      await store.setHongguoVideoRotation(90);
      await store.setHongguoAlwaysShowProgress(true);
      await store.setHongguoSeasonAutoplay(true);
      await store.setHongguoQuality(720);
      await store.setHongguoDecoderLessons('{"|0|1080":2}');
      expect(store.hongguoFrameMode, 'zoom');
      expect(store.hongguoVideoRotation, 90);
      expect(store.hongguoAlwaysShowProgress, isTrue);
      expect(store.hongguoSeasonAutoplay, isTrue);
      expect(store.hongguoQuality, 720);
      expect(store.hongguoDecoderLessonsRaw, '{"|0|1080":2}');

      // 新开一个 LocalStore 仍读到同一份值。
      final reopened = LocalStore(await SharedPreferences.getInstance());
      expect(reopened.hongguoFrameMode, 'zoom');
      expect(reopened.hongguoVideoRotation, 90);
      expect(reopened.hongguoSeasonAutoplay, isTrue);
      expect(reopened.hongguoQuality, 720);

      // 非法值归位：超上限的清晰度与不存在的旋转角都不存。
      await reopened.setHongguoQuality(2160);
      expect(reopened.hongguoQuality, 0);
      await reopened.setHongguoVideoRotation(45);
      expect(reopened.hongguoVideoRotation, 0);
      await reopened.setHongguoFrameMode('bogus');
      expect(reopened.hongguoFrameMode, 'fit');
    });
  });
}
