import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/seamless_switch.dart';

PlaybackPlan _plan({String session = 'session-1', String url = 'https://x/1.m3u8'}) =>
    PlaybackPlan(url: url, session: session);

void main() {
  group('seamlessStandbyKey', () {
    test('有会话按会话认，没会话按地址认', () {
      expect(
        seamlessStandbyKey(index: 2, plan: _plan()),
        '2|s:session-1',
      );
      expect(
        seamlessStandbyKey(index: 2, plan: _plan(session: '')),
        '2|u:https://x/1.m3u8',
      );
    });
  });

  group('seamlessPlanWarmable', () {
    test('直链 m3u8 可预热', () {
      expect(seamlessPlanWarmable(_plan()), isTrue);
    });
    test('本地 / 需解析 / 带密钥 / 音频 / 网页都不可预热', () {
      expect(seamlessPlanWarmable(PlaybackPlan(url: 'https://x/1.m3u8', local: true)), isFalse);
      expect(seamlessPlanWarmable(PlaybackPlan(url: 'https://x/1.m3u8', needsParse: true)), isFalse);
      expect(seamlessPlanWarmable(PlaybackPlan(url: 'https://x/1.m3u8', decryptionKey: 'k')), isFalse);
      expect(seamlessPlanWarmable(PlaybackPlan(url: 'https://x/1.mp3')), isFalse);
      expect(seamlessPlanWarmable(PlaybackPlan(url: 'https://x/play.html')), isFalse);
      expect(seamlessPlanWarmable(PlaybackPlan(url: '')), isFalse);
    });
  });

  group('SeamlessStandbyManager', () {
    test('首帧到达后 ready，take 命中返回 plan 并复位', () async {
      final manager = SeamlessStandbyManager();
      final frame = Completer<bool>();
      final plan = _plan();
      final key = seamlessStandbyKey(index: 1, plan: plan);
      final warming = manager.warm(
        key: key,
        targetIndex: 1,
        kernel: SeamlessKernel.mpv,
        plan: plan,
        firstFrame: frame.future,
      );
      expect(manager.phase, SeamlessPhase.warming);
      expect(manager.take(key), isNull, reason: '还没就绪不能取');
      frame.complete(true);
      await warming;
      expect(manager.phase, SeamlessPhase.ready);
      expect(manager.isReady, isTrue);
      expect(manager.take('wrong-key'), isNull);
      expect(manager.phase, SeamlessPhase.ready, reason: '取错 key 不消耗待命');
      expect(manager.take(key), same(plan));
      expect(manager.phase, SeamlessPhase.idle);
    });

    test('首帧失败回落 failed，take 不命中', () async {
      final manager = SeamlessStandbyManager();
      final plan = _plan();
      final key = seamlessStandbyKey(index: 1, plan: plan);
      await manager.warm(
        key: key,
        targetIndex: 1,
        kernel: SeamlessKernel.exo,
        plan: plan,
        firstFrame: Future.value(false),
      );
      expect(manager.phase, SeamlessPhase.failed);
      expect(manager.take(key), isNull);
    });

    test('首帧超时回落 failed', () async {
      final manager = SeamlessStandbyManager(
        firstFrameTimeout: const Duration(milliseconds: 30),
      );
      final plan = _plan();
      final key = seamlessStandbyKey(index: 1, plan: plan);
      await manager.warm(
        key: key,
        targetIndex: 1,
        kernel: SeamlessKernel.mpv,
        plan: plan,
        firstFrame: Completer<bool>().future,
      );
      expect(manager.phase, SeamlessPhase.failed);
      expect(manager.take(key), isNull);
    });

    test('首帧 Future 抛错回落 failed', () async {
      final manager = SeamlessStandbyManager();
      final plan = _plan();
      await manager.warm(
        key: seamlessStandbyKey(index: 1, plan: plan),
        targetIndex: 1,
        kernel: SeamlessKernel.mpv,
        plan: plan,
        firstFrame: Future.error(StateError('boom')),
      );
      expect(manager.phase, SeamlessPhase.failed);
    });

    test('同 key 重复 warm 不顶掉正在进行的预热', () async {
      final manager = SeamlessStandbyManager();
      final plan = _plan();
      final key = seamlessStandbyKey(index: 1, plan: plan);
      final frame = Completer<bool>();
      final first = manager.warm(
        key: key,
        targetIndex: 1,
        kernel: SeamlessKernel.mpv,
        plan: plan,
        firstFrame: frame.future,
      );
      await manager.warm(
        key: key,
        targetIndex: 1,
        kernel: SeamlessKernel.mpv,
        plan: plan,
        firstFrame: Future.value(false),
      );
      expect(manager.phase, SeamlessPhase.warming);
      frame.complete(true);
      await first;
      expect(manager.phase, SeamlessPhase.ready);
    });

    test('不同 key 顶掉旧待命，旧首帧迟到不污染新状态', () async {
      final manager = SeamlessStandbyManager();
      final planA = _plan(session: 'a');
      final planB = _plan(session: 'b');
      final keyA = seamlessStandbyKey(index: 1, plan: planA);
      final keyB = seamlessStandbyKey(index: 2, plan: planB);
      final frameA = Completer<bool>();
      final warmingA = manager.warm(
        key: keyA,
        targetIndex: 1,
        kernel: SeamlessKernel.mpv,
        plan: planA,
        firstFrame: frameA.future,
      );
      final warmingB = manager.warm(
        key: keyB,
        targetIndex: 2,
        kernel: SeamlessKernel.mpv,
        plan: planB,
        firstFrame: Future.value(true),
      );
      await warmingB;
      expect(manager.phase, SeamlessPhase.ready);
      expect(manager.key, keyB);
      frameA.complete(true);
      await warmingA;
      expect(manager.phase, SeamlessPhase.ready);
      expect(manager.key, keyB);
      expect(manager.take(keyB), same(planB));
    });

    test('discard 后迟到的首帧结果被丢弃', () async {
      final manager = SeamlessStandbyManager();
      final plan = _plan();
      final frame = Completer<bool>();
      final warming = manager.warm(
        key: seamlessStandbyKey(index: 1, plan: plan),
        targetIndex: 1,
        kernel: SeamlessKernel.exo,
        plan: plan,
        firstFrame: frame.future,
      );
      manager.discard();
      expect(manager.phase, SeamlessPhase.idle);
      frame.complete(true);
      await warming;
      expect(manager.phase, SeamlessPhase.idle);
      expect(manager.hasStandby, isFalse);
    });
  });
}
