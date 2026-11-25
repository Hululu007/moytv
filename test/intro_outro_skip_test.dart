import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/intro_outro_skip.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const settings = IntroOutroSettings(introSeconds: 90, outroSeconds: 60);

  group('片头判定', () {
    test('从头播（进度 0）跳到片头结束处', () {
      final decision = decideIntroSkip(
        enabled: true,
        settings: settings,
        resumePositionSeconds: 0,
        durationSeconds: 1200,
      );
      expect(decision.shouldSkip, isTrue);
      expect(decision.targetSeconds, 90);
    });

    test('进度落在片头段内也跳到片头结束处', () {
      final decision = decideIntroSkip(
        enabled: true,
        settings: settings,
        resumePositionSeconds: 45,
        durationSeconds: 1200,
      );
      expect(decision.shouldSkip, isTrue);
      expect(decision.targetSeconds, 90);
    });

    test('续播进度已越过片头时不跳、保留用户位置', () {
      final decision = decideIntroSkip(
        enabled: true,
        settings: settings,
        resumePositionSeconds: 300,
        durationSeconds: 1200,
      );
      expect(decision.shouldSkip, isFalse);
      expect(decision.suppression, IntroOutroSuppression.beyondIntro);
    });

    test('总开关关时片头不跳', () {
      final decision = decideIntroSkip(
        enabled: false,
        settings: settings,
        resumePositionSeconds: 0,
        durationSeconds: 1200,
      );
      expect(decision.shouldSkip, isFalse);
      expect(decision.suppression, IntroOutroSuppression.disabled);
    });

    test('片头为 0 时不动作', () {
      final decision = decideIntroSkip(
        enabled: true,
        settings: const IntroOutroSettings(outroSeconds: 60),
        resumePositionSeconds: 0,
        durationSeconds: 1200,
      );
      expect(decision.shouldSkip, isFalse);
      expect(decision.suppression, IntroOutroSuppression.notConfigured);
    });

    test('总时长未知时片头仍可跳（片头不依赖总时长）', () {
      final decision = decideIntroSkip(
        enabled: true,
        settings: settings,
        resumePositionSeconds: 0,
      );
      expect(decision.shouldSkip, isTrue);
      expect(decision.targetSeconds, 90);
    });
  });

  group('片尾判定', () {
    test('触发点 = 总时长 - 片尾时长，进入即切下一集', () {
      final before = decideOutroSkip(
        enabled: true,
        settings: settings,
        positionSeconds: 1139,
        durationSeconds: 1200,
        hasNextEpisode: true,
      );
      expect(before.shouldAdvance, isFalse);
      expect(before.suppression, IntroOutroSuppression.beforeOutro);

      final at = decideOutroSkip(
        enabled: true,
        settings: settings,
        positionSeconds: 1140,
        durationSeconds: 1200,
        hasNextEpisode: true,
      );
      expect(at.shouldAdvance, isTrue);
    });

    test('没有下一集时不跳片尾', () {
      final decision = decideOutroSkip(
        enabled: true,
        settings: settings,
        positionSeconds: 1190,
        durationSeconds: 1200,
        hasNextEpisode: false,
      );
      expect(decision.shouldAdvance, isFalse);
      expect(decision.suppression, IntroOutroSuppression.noNextEpisode);
    });

    test('总时长未知时不跳片尾', () {
      final decision = decideOutroSkip(
        enabled: true,
        settings: settings,
        positionSeconds: 500,
        durationSeconds: null,
        hasNextEpisode: true,
      );
      expect(decision.shouldAdvance, isFalse);
      expect(decision.suppression, IntroOutroSuppression.unknownDuration);
    });

    test('总开关关时片尾不跳', () {
      final decision = decideOutroSkip(
        enabled: false,
        settings: settings,
        positionSeconds: 1190,
        durationSeconds: 1200,
        hasNextEpisode: true,
      );
      expect(decision.shouldAdvance, isFalse);
      expect(decision.suppression, IntroOutroSuppression.disabled);
    });

    test('片尾为 0 时不动作', () {
      final decision = decideOutroSkip(
        enabled: true,
        settings: const IntroOutroSettings(introSeconds: 90),
        positionSeconds: 1190,
        durationSeconds: 1200,
        hasNextEpisode: true,
      );
      expect(decision.shouldAdvance, isFalse);
      expect(decision.suppression, IntroOutroSuppression.notConfigured);
    });
  });

  group('短剧防误跳（比例抑制）', () {
    test('片头+片尾超过总时长 50% 时片头片尾都不跳且原因可查', () {
      // 短剧一集 240 秒，片头 90 + 片尾 60 = 150 > 120（50%）。
      final intro = decideIntroSkip(
        enabled: true,
        settings: settings,
        resumePositionSeconds: 0,
        durationSeconds: 240,
      );
      expect(intro.shouldSkip, isFalse);
      expect(intro.suppression, IntroOutroSuppression.ratioExceeded);

      final outro = decideOutroSkip(
        enabled: true,
        settings: settings,
        positionSeconds: 200,
        durationSeconds: 240,
        hasNextEpisode: true,
      );
      expect(outro.shouldAdvance, isFalse);
      expect(outro.suppression, IntroOutroSuppression.ratioExceeded);
    });

    test('刚好等于 50% 时不抑制（超过才抑制）', () {
      const half = IntroOutroSettings(introSeconds: 60, outroSeconds: 60);
      expect(
        skipRatioExceeded(settings: half, durationSeconds: 240),
        isFalse,
      );
      expect(
        skipRatioExceeded(settings: settings, durationSeconds: 240),
        isTrue,
      );
      expect(
        skipRatioExceeded(settings: settings, durationSeconds: null),
        isFalse,
      );
    });
  });

  group('引擎每集只触发一次片尾', () {
    test('同一集重复进入片尾段只切一次，原因记 alreadyTriggered', () {
      final engine = IntroOutroSkipEngine();
      bool fire() => engine.consumeOutro(
        episodeKey: 'drama:0',
        enabled: true,
        settings: settings,
        positionSeconds: 1150,
        durationSeconds: 1200,
        hasNextEpisode: true,
      );
      expect(fire(), isTrue);
      expect(fire(), isFalse);
      expect(
        engine.lastOutroSuppression,
        IntroOutroSuppression.alreadyTriggered,
      );
      // 换一集后可再触发。
      expect(
        engine.consumeOutro(
          episodeKey: 'drama:1',
          enabled: true,
          settings: settings,
          positionSeconds: 1150,
          durationSeconds: 1200,
          hasNextEpisode: true,
        ),
        isTrue,
      );
    });
  });

  group('模型序列化', () {
    test('分段 JSON 往返、超限钳制、整表编解码丢空项', () {
      final restored = IntroOutroSettings.fromJson(settings.toJson());
      expect(restored, settings);
      expect(
        settings.copyWith(introSeconds: 99999).introSeconds,
        lessThanOrEqualTo(maxSkipSeconds),
      );
      expect(
        IntroOutroSettings.fromJson({'intro': -5, 'outro': 'x'}),
        const IntroOutroSettings(),
      );
      final encoded = IntroOutroSettings.encodeMap({
        IntroOutroSettings.keyFor('siteA', 'd1'): settings,
        IntroOutroSettings.keyFor('siteA', 'd2'):
            const IntroOutroSettings(),
      });
      final decoded = IntroOutroSettings.decodeMap(encoded);
      expect(decoded.length, 1);
      expect(decoded[IntroOutroSettings.keyFor('siteA', 'd1')], settings);
      expect(IntroOutroSettings.decodeMap('坏数据'), isEmpty);
      // 不同站同剧 id 键不串。
      expect(
        IntroOutroSettings.keyFor('siteA', 'd1'),
        isNot(IntroOutroSettings.keyFor('siteB', 'd1')),
      );
    });
  });

  group('LocalStore 存储', () {
    test('总开关默认开、分段按剧存取、清空后回空', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      addTearDown(store.dispose);

      expect(store.introOutroSkipEnabled, isTrue);
      expect(store.introOutroFor('siteA', 'd1'), const IntroOutroSettings());

      await store.setIntroOutroFor('siteA', 'd1', settings);
      expect(store.introOutroFor('siteA', 'd1'), settings);
      expect(
        store.introOutroFor('siteB', 'd1'),
        const IntroOutroSettings(),
      );
      expect(
        preferences.getString('introOutroSkipByDrama'),
        contains('siteA::d1'),
      );

      await store.setIntroOutroSkipEnabled(false);
      expect(store.introOutroSkipEnabled, isFalse);

      await store.setIntroOutroFor(
        'siteA',
        'd1',
        const IntroOutroSettings(),
      );
      expect(store.introOutroFor('siteA', 'd1'), const IntroOutroSettings());
    });
  });
}
