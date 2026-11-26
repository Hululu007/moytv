import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_screen.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 扫码轮询网络抖动自动重试（2026-11-18）：用户手机上 115 扫码报
/// “轮询出错：ClientException: Software caused connection abort”，根因是
/// 轮询里任何一次异常就停定时器、判失败。修法：瞬时网络错继续轮询并
/// 提示“正在重试”，连续 5 次失败才判失败；失败文案一律干净，绝不把
/// 异常原文（含请求地址）显示出来。

/// 假网盘：按脚本返回轮询结果或抛错，并记调用次数。
class _ScriptedProvider implements CloudDriveProvider {
  _ScriptedProvider(this.script);

  /// 脚本：每个元素是 [QrPollResult]（返回）或 [Object]（抛错）；
  /// 脚本耗尽后重复最后一个元素。
  final List<Object> script;
  int pollCalls = 0;

  @override
  String get id => 'fake115';

  @override
  String get displayName => '测试网盘';

  @override
  String get appName => '测试 App';

  @override
  String get rootFolderId => '0';

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    return QrLoginSession(
      qrContent: 'https://example.com/qr-test',
      qrImageUrl: '',
      message: '请用测试 App 扫码确认',
      state: const {},
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final index = pollCalls++;
    final action = index < script.length ? script[index] : script.last;
    if (action is QrPollResult) return action;
    throw action;
  }

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) {
    throw UnimplementedError();
  }

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  @override
  void Function(String providerId, String expiredCookie)? onSessionExpired;
}

/// 与用户截图同类的连接错：异常原文里带完整请求地址与参数。
http.ClientException _connectionAbort() => http.ClientException(
  'Software caused connection abort',
  Uri.parse(
    'https://qrcodeapi.115.com/get/status/?uid=secret-uid&sign=secret-sign',
  ),
);

const _successResult = QrPollResult(
  status: QrPollStatus.success,
  credentials: CloudCredentials(fields: {'cookie': 'UID=test'}, savedAtMs: 1),
  message: '测试网盘登录成功',
);

const _waitingResult = QrPollResult(
  status: QrPollStatus.waiting,
  message: '等待测试 App 扫码确认',
);

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<_ScriptedProvider> _openQrDialog(
  WidgetTester tester,
  List<Object> script,
) async {
  final store = await _makeStore();
  final provider = _ScriptedProvider(script);
  await tester.pumpWidget(
    MaterialApp(
      home: CloudDriveScreen(store: store, providers: [provider]),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('扫码登录'));
  await tester.pump();
  await tester.pump();
  expect(find.text('测试网盘扫码登录'), findsOneWidget);
  return provider;
}

/// 推进 [times] 个 2 秒轮询 tick，并刷出异步回调里的界面更新。
Future<void> _tick(WidgetTester tester, [int times = 1]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  }
}

void main() {
  group('扫码轮询抖动重试', () {
    testWidgets('前两次连接错、第三次成功：重试后登录成功', (tester) async {
      final provider = await _openQrDialog(tester, [
        _connectionAbort(),
        _connectionAbort(),
        _successResult,
      ]);

      await _tick(tester);
      expect(find.text('网络波动，正在重试…'), findsOneWidget);
      expect(find.text('测试网盘扫码登录'), findsOneWidget);
      expect(find.text('重新获取'), findsNothing);
      // 异常原文与请求地址绝不上屏。
      expect(find.textContaining('ClientException'), findsNothing);
      expect(find.textContaining('qrcodeapi'), findsNothing);
      expect(find.textContaining('secret-uid'), findsNothing);

      await _tick(tester);
      expect(find.text('网络波动，正在重试…'), findsOneWidget);

      await _tick(tester);
      await tester.pumpAndSettle();
      expect(provider.pollCalls, 3);
      expect(find.text('测试网盘扫码登录'), findsNothing);
      expect(find.text('已登录'), findsOneWidget);
    });

    testWidgets('连续 5 次连接错才判失败，文案干净且轮询停止', (tester) async {
      final provider = await _openQrDialog(tester, [_connectionAbort()]);

      await _tick(tester, 4);
      expect(find.text('网络波动，正在重试…'), findsOneWidget);
      expect(find.text('重新获取'), findsNothing);
      expect(provider.pollCalls, 4);

      await _tick(tester);
      expect(provider.pollCalls, 5);
      expect(
        find.text('网络不稳定，获取扫码状态失败，请重新获取'),
        findsOneWidget,
      );
      expect(find.text('重新获取'), findsOneWidget);
      expect(find.textContaining('ClientException'), findsNothing);
      expect(find.textContaining('qrcodeapi'), findsNothing);

      // 判失败后定时器已停，不再轮询。
      await _tick(tester, 2);
      expect(provider.pollCalls, 5);
    });

    testWidgets('非瞬时错误立即失败，不重试', (tester) async {
      final provider = await _openQrDialog(tester, [StateError('boom')]);

      await _tick(tester);
      expect(provider.pollCalls, 1);
      expect(find.text('获取扫码状态失败，请重新获取'), findsOneWidget);
      expect(find.text('重新获取'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);

      await _tick(tester, 2);
      expect(provider.pollCalls, 1);
    });

    testWidgets('一次正常结果清零计数：4 失败 + 等待 + 4 失败仍不判失败', (
      tester,
    ) async {
      final error = _connectionAbort();
      final provider = await _openQrDialog(tester, [
        error,
        error,
        error,
        error,
        _waitingResult,
        error,
        error,
        error,
        error,
        error,
      ]);

      await _tick(tester, 4);
      expect(find.text('网络波动，正在重试…'), findsOneWidget);
      await _tick(tester);
      expect(find.text('等待测试 App 扫码确认'), findsOneWidget);
      await _tick(tester, 4);
      expect(find.text('网络波动，正在重试…'), findsOneWidget);
      expect(find.text('重新获取'), findsNothing);
      expect(provider.pollCalls, 9);

      // 再失败一次才是清零后的连续第 5 次，判失败。
      await _tick(tester);
      expect(provider.pollCalls, 10);
      expect(
        find.text('网络不稳定，获取扫码状态失败，请重新获取'),
        findsOneWidget,
      );
    });

    testWidgets('超时与 Socket 错也按抖动重试', (tester) async {
      final provider = await _openQrDialog(tester, [
        TimeoutException('poll timed out', const Duration(seconds: 20)),
        const SocketException('Connection reset by peer'),
        _successResult,
      ]);

      await _tick(tester, 2);
      expect(find.text('网络波动，正在重试…'), findsOneWidget);
      await _tick(tester);
      await tester.pumpAndSettle();
      expect(provider.pollCalls, 3);
      expect(find.text('测试网盘扫码登录'), findsNothing);
      expect(find.text('已登录'), findsOneWidget);
    });

    testWidgets('判失败后点重新获取：计数器重置，轮询恢复', (tester) async {
      final provider = await _openQrDialog(tester, [
        _connectionAbort(),
        _connectionAbort(),
        _connectionAbort(),
        _connectionAbort(),
        _connectionAbort(),
        _successResult,
      ]);

      await _tick(tester, 5);
      expect(find.text('重新获取'), findsOneWidget);
      expect(provider.pollCalls, 5);

      await tester.tap(find.text('重新获取'));
      await tester.pump();
      await tester.pump();
      expect(find.text('请用测试 App 扫码确认'), findsOneWidget);

      await _tick(tester);
      await tester.pumpAndSettle();
      expect(provider.pollCalls, 6);
      expect(find.text('测试网盘扫码登录'), findsNothing);
      expect(find.text('已登录'), findsOneWidget);
    });
  });
}
