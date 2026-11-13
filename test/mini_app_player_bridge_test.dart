import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/miniapp/mini_app_bridge.dart';
import 'package:moyi/miniapp/mini_app_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MiniAppBridge makeBridge(
    MiniAppManifest manifest,
    SharedPreferences prefs, {
    Future<bool> Function(MiniAppPlayTarget target)? openPlayer,
    Map<String, dynamic> Function()? playerState,
  }) {
    return MiniAppBridge(
      manifest: manifest,
      appDir: Directory.systemTemp,
      prefs: prefs,
      callbacks: MiniAppBridgeCallbacks(
        evaluateJavascript: (_) async {},
        showToast: (_) {},
        showLoading: (_) {},
        hideLoading: () {},
        confirm: ({required title, required content}) async => true,
        actionSheet: (_) async => 0,
        navigateTo: (_) async {},
        navigateBack: () async {},
        exit: () {},
        openMiniApp: (_) async {},
        resolveMiniAppUrl: (_) async => null,
        log: (_) {},
        openPlayer: openPlayer,
        playerState: playerState,
      ),
    );
  }

  const manifest = MiniAppManifest(
    appId: 'com.ant.emby',
    name: '影视库',
    permissions: ['ui', 'storage', 'navigate', 'player', 'source'],
  );

  group('播放目标分流 resolvePlayTarget', () {
    test('直链媒体地址直接播，请求头带上', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(
          url: 'https://cdn.example.com/v.m3u8?token=1',
          title: '剧A · 第1集',
          headers: {'Referer': 'https://site.example.com/'},
        ),
      );
      expect(target.isDirect, isTrue);
      expect(target.url, 'https://cdn.example.com/v.m3u8?token=1');
      expect(target.title, '剧A · 第1集');
      expect(target.headers['Referer'], 'https://site.example.com/');
    });

    test('parse=1 时走嗅探，优先嗅探 playUrl 解析服务地址', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(
          url: 'https://site.example.com/play/123',
          parse: '1',
          playUrl: 'https://jx.example.com/?url=https://site.example.com/play/123',
        ),
      );
      expect(target.isSniff, isTrue);
      expect(target.url, startsWith('https://jx.example.com/'));
    });

    test('parse=1 且无 playUrl 时嗅探 url 本身', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(
          url: 'https://site.example.com/play/123',
          jx: '1',
        ),
      );
      expect(target.isSniff, isTrue);
      expect(target.url, 'https://site.example.com/play/123');
    });

    test('parse 声明优先于媒体特征：嵌着 .mp4 的解析地址也走嗅探', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(
          url: 'https://jx.example.com/?url=https://cdn.example.com/v.mp4',
          parse: '1',
        ),
      );
      expect(target.isSniff, isTrue);
    });

    test('无解析声明的普通网页地址走嗅探', () {
      final target = MiniAppBridge.resolvePlayTarget(
        const MiniAppPlayRequest(url: 'https://site.example.com/watch/9'),
      );
      expect(target.isSniff, isTrue);
      expect(target.url, 'https://site.example.com/watch/9');
    });
  });

  group('player.open / player.getState 分发', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('player.open 把解析好的目标交给宿主回调并回 opened', () async {
      MiniAppPlayTarget? received;
      final bridge = makeBridge(
        manifest,
        prefs,
        openPlayer: (target) async {
          received = target;
          return true;
        },
      );
      final result = await bridge.invoke('player.open', {
        'url': 'https://cdn.example.com/v.mp4',
        'title': '剧A · 第1集',
        'headers': {'Referer': 'https://site.example.com/'},
        'parse': '0',
      });
      expect(received, isNotNull);
      expect(received!.isDirect, isTrue);
      expect(received!.headers['Referer'], 'https://site.example.com/');
      expect(result['opened'], isTrue);
      expect(result['kind'], 'direct');
    });

    test('宿主回调返回 false 时回 opened:false，不抛错（嗅探被取消）', () async {
      final bridge = makeBridge(
        manifest,
        prefs,
        openPlayer: (_) async => false,
      );
      final result = await bridge.invoke('player.open', {
        'url': 'https://site.example.com/play/1',
        'parse': '1',
      });
      expect(result['opened'], isFalse);
      expect(result['kind'], 'sniff');
    });

    test('地址为空报 INVALID_PARAMS', () async {
      final bridge = makeBridge(
        manifest,
        prefs,
        openPlayer: (_) async => true,
      );
      expect(
        () => bridge.invoke('player.open', {'title': '无地址'}),
        throwsA(
          isA<MiniAppApiException>().having((e) => e.code, 'code', 'INVALID_PARAMS'),
        ),
      );
    });

    test('宿主没提供播放回调时报 NOT_IMPLEMENTED', () async {
      final bridge = makeBridge(manifest, prefs);
      expect(
        () => bridge.invoke('player.open', {'url': 'https://cdn.example.com/v.mp4'}),
        throwsA(
          isA<MiniAppApiException>().having((e) => e.code, 'code', 'NOT_IMPLEMENTED'),
        ),
      );
    });

    test('未声明 player 权限报 PERMISSION_DENIED', () async {
      const noPlayer = MiniAppManifest(
        appId: 'com.example.noplayer',
        name: '无播放权限',
        permissions: ['ui'],
      );
      final bridge = makeBridge(
        noPlayer,
        prefs,
        openPlayer: (_) async => true,
      );
      expect(
        () => bridge.invoke('player.open', {'url': 'https://cdn.example.com/v.mp4'}),
        throwsA(
          isA<MiniAppApiException>().having((e) => e.code, 'code', 'PERMISSION_DENIED'),
        ),
      );
    });

    test('player.getState 回宿主快照；无回调时回 opened:false', () async {
      final withState = makeBridge(
        manifest,
        prefs,
        playerState: () => {
          'opened': true,
          'url': 'https://cdn.example.com/v.mp4',
          'playing': true,
          'positionMs': 5000,
          'durationMs': 60000,
        },
      );
      final state = await withState.invoke('player.getState', {});
      expect(state['opened'], isTrue);
      expect(state['playing'], isTrue);
      expect(state['positionMs'], 5000);

      final withoutState = makeBridge(manifest, prefs);
      final closed = await withoutState.invoke('player.getState', {});
      expect(closed, {'opened': false});
    });
  });
}
