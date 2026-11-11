import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/core_bridge.dart';
import 'package:moyi/hongguo_account.dart';
import 'package:moyi/hongguo_account_store.dart';
import 'package:moyi/hongguo_cloud_records.dart';
import 'package:moyi/models.dart';

class _FakeAccountRepository implements AppRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  bool statusLoggedIn = false;
  String statusAccountId = '';
  Map<String, dynamic> info = {
    'userId': 'u1',
    'userName': '道友1',
    'avatar': '',
  };
  bool failSiteSend = false;
  bool failSiteVerify = false;
  int sendRetrySeconds = 60;
  bool qrPollLoggedIn = false;
  final List<Map<String, dynamic>> uploadCalls = [];
  bool failUpload = false;
  int clearSessionCalls = 0;
  int setSessionCalls = 0;
  int exportCalls = 0;
  Map<String, dynamic> exportResult = {'loggedIn': false};
  Map<String, dynamic>? lastSetSession;
  final List<String> calls = [];

  List<Map<String, dynamic>> favorites = [
    {'seriesId': '100', 'title': '云端收藏剧', 'cover': '', 'badge': ''},
  ];
  List<Map<String, dynamic>> history = [
    {
      'seriesId': '100',
      'title': '云端历史剧',
      'cover': '',
      'episodeId': 'ep1',
      'episodeIndex': 2,
      'positionMs': 30000,
      'durationMs': 60000,
      'updatedAtMs': 2000,
      'episodeCount': 10,
    },
  ];
  List<Map<String, dynamic>> reservationsOnline = [
    {'seriesId': '200', 'title': '已上线预约剧', 'online': true},
  ];
  List<Map<String, dynamic>> reservationsOffline = [
    {
      'seriesId': 'reservation:300',
      'title': '待上线预约剧',
      'online': false,
    },
  ];
  bool reserveOk = true;
  bool reserveListContains = true;

  @override
  Future<Map<String, dynamic>> hongguoAccountStatus() async {
    calls.add('status');
    return {
      'loggedIn': statusLoggedIn,
      'accountId': statusAccountId,
      'hasDevice': true,
    };
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountExportSession() async {
    calls.add('export');
    exportCalls++;
    return exportResult;
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountSetSession(
    Map<String, dynamic> session,
  ) async {
    calls.add('set');
    setSessionCalls++;
    lastSetSession = session;
    return {'loggedIn': true, 'accountId': session['accountId'] ?? ''};
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountClearSession() async {
    calls.add('clear');
    clearSessionCalls++;
    return {'loggedIn': false, 'accountId': ''};
  }

  @override
  Future<Map<String, dynamic>> hongguoLoginQr() async => {
    'imageBase64': 'aGVsbG8=',
    'expiresSeconds': 60,
  };

  @override
  Future<Map<String, dynamic>> hongguoLoginQrPoll() async => {
    'loggedIn': qrPollLoggedIn,
    'accountId': qrPollLoggedIn ? 'u1' : '',
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountInfo() async => info;

  @override
  Future<Map<String, dynamic>> hongguoLoginSendCode(String phone) async {
    if (failSiteSend) throw AppFailure('站内发码失败');
    return {'maskedMobile': '138****8000', 'retrySeconds': sendRetrySeconds};
  }

  @override
  Future<Map<String, dynamic>> hongguoLoginAppSendCode(String phone) async =>
      {'maskedMobile': '138****8000', 'retrySeconds': sendRetrySeconds};

  @override
  Future<Map<String, dynamic>> hongguoLoginSms(
    String phone,
    String code,
  ) async {
    if (failSiteVerify) throw AppFailure('站内校验失败');
    return {'userId': 'u1', 'userName': '道友1'};
  }

  @override
  Future<Map<String, dynamic>> hongguoLoginAppSms(
    String phone,
    String code,
  ) async => {'loggedIn': true, 'accountId': 'u1'};

  @override
  Future<Map<String, dynamic>> hongguoAccountFavorites() async => {
    'items': favorites,
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountSetFavorite(
    String seriesId,
    bool add,
  ) async => {
    'items': favorites,
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountHistory() async => {
    'items': history,
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountUploadProgress(
    Map<String, dynamic> progress,
  ) async {
    uploadCalls.add(progress);
    if (failUpload) throw AppFailure('上传失败');
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountReservations(
    bool online,
  ) async => {
    'items': online ? reservationsOnline : reservationsOffline,
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountReserve(String seriesId) async {
    if (!reserveOk) return {'ok': false};
    if (reserveListContains &&
        !reservationsOffline.any((row) => row['seriesId'] == seriesId)) {
      reservationsOffline.add({
        'seriesId': seriesId,
        'title': '新预约剧',
        'online': false,
      });
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountRelated(String seriesId) async =>
      {
        'items': [
          {
            'seriesId': '301',
            'title': '下一季',
            'season': 2,
            'upcoming': true,
          },
        ],
      };
}

Future<HongguoAccountStore> _openStore(_FakeAccountRepository repo) async {
  final prefs = await SharedPreferences.getInstance();
  return HongguoAccountStore(repository: repo, preferences: prefs);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('会话存取往返', () {
    test('登录后落盘，建新 store 再 load 能恢复', () async {
      final repo = _FakeAccountRepository()..statusLoggedIn = true;
      final store = await _openStore(repo);
      final account = await store.signInFromBridge(
        method: 'sms',
        maskedPhone: '138****8000',
      );
      expect(account.userId, 'u1');
      expect(account.displayName, '道友1');
      expect(store.loggedIn, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(hongguoAccountStorageKey), contains('u1'));

      final repo2 = _FakeAccountRepository()
        ..statusLoggedIn = true
        ..statusAccountId = 'u1';
      final store2 = await _openStore(repo2);
      await store2.load();
      expect(store2.account?.userId, 'u1');
      expect(store2.loggedIn, isTrue);
    });

    test('资料在但 Go 会话不在时标登录过期，不冒充已登录', () async {
      final repo = _FakeAccountRepository()..statusLoggedIn = true;
      final store = await _openStore(repo);
      await store.signInFromBridge(method: 'sms');
      final repo2 = _FakeAccountRepository()..statusLoggedIn = false;
      final store2 = await _openStore(repo2);
      await store2.load();
      expect(store2.account?.userId, 'u1');
      expect(store2.sessionLive, isFalse);
      expect(store2.loggedIn, isFalse);
    });

    test('有 Cookie 才调 SetSession，没有不调', () async {
      final repo = _FakeAccountRepository();
      final store = await _openStore(repo);
      await store.signInWithSession(
        session: const HongguoAccountSession(accountId: 'u1'),
        account: const HongguoAccount(
          userId: 'u1',
          displayName: '道友1',
          method: 'sms',
        ),
      );
      expect(repo.setSessionCalls, 0);
      await store.signInWithSession(
        session: const HongguoAccountSession(
          accountCookie: 'cookie-value',
          accountId: 'u1',
        ),
        account: const HongguoAccount(
          userId: 'u1',
          displayName: '道友1',
          method: 'sms',
        ),
      );
      expect(repo.setSessionCalls, 1);
    });
  });

  group('登出只清账号侧', () {
    test('三个账号键清掉，本机键与无关键不动', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(hongguoAccountStorageKey, '{"userId":"u1"}');
      await prefs.setString(hongguoAccountSessionStorageKey, '{}');
      await prefs.setString(hongguoCloudUploadQueueKey, '[]');
      await prefs.setString('other-key', 'keep-me');
      await prefs.setString('profile-default/history', 'local-history');
      final repo = _FakeAccountRepository()..statusLoggedIn = true;
      final store = await _openStore(repo);
      await store.load();
      await store.signOut();
      expect(prefs.getString(hongguoAccountStorageKey), isNull);
      expect(prefs.getString(hongguoAccountSessionStorageKey), isNull);
      expect(prefs.getString(hongguoCloudUploadQueueKey), isNull);
      expect(prefs.getString('other-key'), 'keep-me');
      expect(prefs.getString('profile-default/history'), 'local-history');
      expect(repo.clearSessionCalls, 1);
      expect(store.loggedIn, isFalse);
    });
  });

  group('续播决策', () {
    const localDrama = Drama(id: '100', source: 'hongguo', title: '剧');
    final local = WatchEntry(
      drama: localDrama,
      episode: 1,
      position: 10,
      duration: 60,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    const cloud = HongguoCloudHistoryItem(
      seriesId: '100',
      title: '剧',
      episodeIndex: 2,
      positionMs: 30000,
      durationMs: 60000,
      updatedAtMs: 2000,
      episodeCount: 10,
    );

    test('云端较新用云端', () {
      final decision = decideHongguoResume(local: local, cloud: cloud);
      expect(decision.source, HongguoResumeSource.cloud);
      expect(decision.episodeIndex, 2);
      expect(decision.positionMs, 30000);
    });

    test('时间相同优先本机', () {
      const sameTime = HongguoCloudHistoryItem(
        seriesId: '100',
        title: '剧',
        episodeIndex: 2,
        positionMs: 30000,
        updatedAtMs: 1000,
      );
      final decision = decideHongguoResume(local: local, cloud: sameTime);
      expect(decision.source, HongguoResumeSource.local);
      expect(decision.episodeIndex, 1);
      expect(decision.positionMs, 10000);
    });

    test('云端较旧用本机，明确点账号历史时优先云端', () {
      const older = HongguoCloudHistoryItem(
        seriesId: '100',
        title: '剧',
        episodeIndex: 0,
        positionMs: 5000,
        updatedAtMs: 500,
      );
      expect(
        decideHongguoResume(local: local, cloud: older).source,
        HongguoResumeSource.local,
      );
      expect(
        decideHongguoResume(
          local: local,
          cloud: older,
          preferCloud: true,
        ).source,
        HongguoResumeSource.cloud,
      );
    });

    test('只有一方时用那一方，两方都没有是 none', () {
      expect(
        decideHongguoResume(local: local).source,
        HongguoResumeSource.local,
      );
      expect(
        decideHongguoResume(cloud: cloud).source,
        HongguoResumeSource.cloud,
      );
      expect(
        decideHongguoResume().source,
        HongguoResumeSource.none,
      );
    });
  });

  group('预约列表两类分流', () {
    test('已上线能播，待上线 reservation: 键不可播', () async {
      final repo = _FakeAccountRepository();
      final records = HongguoCloudRecords(repo);
      final online = await records.fetchReservations(online: true);
      final offline = await records.fetchReservations(online: false);
      expect(online.single.isPlayable, isTrue);
      expect(offline.single.isPlayable, isFalse);
      expect(offline.single.seriesId, startsWith('reservation:'));
    });

    test('写后读回在列才算已预约，不在列不写死已预约', () async {
      final repo = _FakeAccountRepository();
      final records = HongguoCloudRecords(repo);
      final confirmed = await records.reserve('reservation:300');
      expect(confirmed.requested, isTrue);
      expect(confirmed.confirmedInList, isTrue);
      expect(confirmed.confirmed, isTrue);

      repo.reserveListContains = false;
      final unconfirmed = await records.reserve('reservation:999');
      expect(unconfirmed.requested, isTrue);
      expect(unconfirmed.confirmedInList, isFalse);
      expect(unconfirmed.confirmed, isFalse);
    });

    test('相关季只对未上线项预约', () async {
      final repo = _FakeAccountRepository();
      final records = HongguoCloudRecords(repo);
      final related = await records.fetchRelated('100');
      expect(related.single.upcoming, isTrue);
      expect(related.single.seasonLabel, '第 2 季');
    });
  });

  group('手机号校验与发码回退', () {
    test('+86 必须 11 位 1 开头，其他区号 5–15 位', () {
      expect(HongguoPhoneNumber.isValid('+86', '13812345678'), isTrue);
      expect(HongguoPhoneNumber.isValid('+86', '3812345678'), isFalse);
      expect(HongguoPhoneNumber.isValid('+86', '1381234567'), isFalse);
      expect(HongguoPhoneNumber.isValid('+86', '138 1234 5678'), isTrue);
      expect(HongguoPhoneNumber.isValid('+852', '91234567'), isTrue);
      expect(HongguoPhoneNumber.isValid('+852', '123'), isFalse);
      expect(HongguoPhoneNumber.forBridge('+86', '13812345678'), '+86 13812345678');
    });

    test('站内发码失败回退 App 形态，倒计时用返回的 retrySeconds', () async {
      final repo = _FakeAccountRepository()
        ..failSiteSend = true
        ..sendRetrySeconds = 45;
      final store = await _openStore(repo);
      final sent = await store.sendCode(
        areaCode: '+86',
        phone: '13812345678',
      );
      expect(sent.route, 'app');
      expect(sent.retrySeconds, 45);
      expect(sent.maskedMobile, '138****8000');
    });

    test('站内校验失败回退 App 校验，成功后落盘', () async {
      final repo = _FakeAccountRepository()..failSiteVerify = true;
      final store = await _openStore(repo);
      final account = await store.verifyCode(
        areaCode: '+86',
        phone: '13812345678',
        code: '123456',
      );
      expect(account.userId, 'u1');
      expect(store.loggedIn, isTrue);
    });
  });

  group('扫码取码', () {
    test('取到 base64 与 60 秒有效期', () async {
      final repo = _FakeAccountRepository();
      final store = await _openStore(repo);
      final qr = await store.fetchQrCode();
      expect(qr.imageBase64, 'aGVsbG8=');
      expect(qr.expiresSeconds, 60);
      expect(await store.pollQrOnce(), isFalse);
      repo.qrPollLoggedIn = true;
      expect(await store.pollQrOnce(), isTrue);
    });
  });

  group('云端进度上传队列', () {
    test('未登录不发，已登录入队即发且毫秒换算正确', () async {
      final repo = _FakeAccountRepository()..statusLoggedIn = true;
      final store = await _openStore(repo);
      await store.enqueueCloudProgress(
        seriesId: '100',
        itemId: 'ep1',
        episodeIndex: 0,
        episodeCount: 10,
        positionSeconds: 12.5,
        totalSeconds: 60,
      );
      expect(repo.uploadCalls, isEmpty);

      await store.signInFromBridge(method: 'sms');
      await store.enqueueCloudProgress(
        seriesId: '100',
        itemId: 'ep1',
        episodeIndex: 0,
        episodeCount: 10,
        positionSeconds: 12.5,
        totalSeconds: 60,
      );
      expect(repo.uploadCalls, hasLength(1));
      expect(repo.uploadCalls.single['progressMs'], 12500);
      expect(repo.uploadCalls.single['totalMs'], 60000);
      expect(repo.uploadCalls.single['seriesId'], '100');
    });

    test('换号丢弃旧队列：旧账号条目不发，登出后不再发', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = _FakeAccountRepository()..statusLoggedIn = true;
      final store = await _openStore(repo);
      await store.signInFromBridge(method: 'sms');
      repo.failUpload = true;
      await store.enqueueCloudProgress(
        seriesId: '100',
        itemId: 'ep1',
        episodeIndex: 0,
        episodeCount: 10,
        positionSeconds: 5,
        totalSeconds: 60,
      );
      expect(repo.uploadCalls, hasLength(1));
      expect(store.cloudQueue.pending, hasLength(1));

      await store.signOut();
      expect(prefs.getString(hongguoCloudUploadQueueKey), isNull);
      await store.enqueueCloudProgress(
        seriesId: '100',
        itemId: 'ep1',
        episodeIndex: 0,
        episodeCount: 10,
        positionSeconds: 5,
        totalSeconds: 60,
      );
      expect(repo.uploadCalls, hasLength(1));
    });

    test('旧账号的队里条目在新账号下被过滤', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = _FakeAccountRepository();
      final store = await _openStore(repo);
      await prefs.setString(
        hongguoCloudUploadQueueKey,
        '[{"accountId":"other","seriesId":"100","itemId":"ep1",'
        '"episodeIndex":0,"episodeCount":10,"progressMs":1000,'
        '"totalMs":60000,"updatedAtMs":1,"attempts":0}]',
      );
      expect(store.cloudQueue.pending, isEmpty);
    });
  });

  group('账号收藏读写', () {
    test('读账号收藏与写后回读列表', () async {
      final repo = _FakeAccountRepository();
      final records = HongguoCloudRecords(repo);
      final favorites = await records.fetchFavorites();
      expect(favorites.single.title, '云端收藏剧');
      final afterWrite = await records.setFavorite('100', true);
      expect(afterWrite.single.seriesId, '100');
    });
  });

  group('会话导出与冷启动恢复', () {
    const exportedSession = {
      'loggedIn': true,
      'accountCookie': 'sessionid=abc123',
      'deviceId': 'd1',
      'installId': 'i1',
      'accountId': 'u1',
      'userName': '道友1',
      'expiresAtMs': 1790000000000,
      'cookieSource': 'web',
    };

    test('登录成功后导出会话并存入，冷启动先交回再确认状态', () async {
      final repo = _FakeAccountRepository()
        ..statusLoggedIn = true
        ..exportResult = exportedSession;
      final store = await _openStore(repo);
      final account = await store.signInFromBridge(method: 'sms');
      expect(account.userId, 'u1');
      expect(repo.exportCalls, 1);
      final prefs = await SharedPreferences.getInstance();
      final savedRaw = prefs.getString(hongguoAccountSessionStorageKey);
      expect(savedRaw, contains('sessionid=abc123'));
      expect(savedRaw, contains('web'));

      final repo2 = _FakeAccountRepository()
        ..statusLoggedIn = true
        ..statusAccountId = 'u1';
      final store2 = await _openStore(repo2);
      await store2.load();
      expect(repo2.calls, ['set', 'status']);
      expect(repo2.setSessionCalls, 1);
      expect(repo2.lastSetSession?['accountCookie'], 'sessionid=abc123');
      expect(repo2.lastSetSession?['cookieSource'], 'web');
      expect(repo2.lastSetSession?['expiresAtMs'], 1790000000000);
      expect(store2.sessionLive, isTrue);
      expect(store2.loggedIn, isTrue);
    });

    test('扫码登录成功后同样导出会话', () async {
      final repo = _FakeAccountRepository()
        ..statusLoggedIn = true
        ..exportResult = exportedSession;
      final store = await _openStore(repo);
      final account = await store.signInFromBridge(method: 'qr');
      expect(account.userId, 'u1');
      expect(repo.exportCalls, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(hongguoAccountSessionStorageKey),
        contains('sessionid=abc123'),
      );
    });

    test('导出报未登录时清掉旧存的会话', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        hongguoAccountSessionStorageKey,
        '{"accountCookie":"sessionid=old","accountId":"u1"}',
      );
      final repo = _FakeAccountRepository()
        ..statusLoggedIn = true
        ..exportResult = {'loggedIn': false};
      final store = await _openStore(repo);
      await store.signInFromBridge(method: 'sms');
      expect(repo.exportCalls, 1);
      expect(prefs.getString(hongguoAccountSessionStorageKey), isNull);
    });

    test('存的会话没 Cookie 时不调 SetSession，只确认状态', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        hongguoAccountSessionStorageKey,
        '{"accountCookie":"","deviceId":"d1","accountId":"u1"}',
      );
      hongguoAccountNotifier.value = const HongguoAccount(
        userId: 'u1',
        displayName: '道友1',
        method: 'sms',
      );
      final repo = _FakeAccountRepository()..statusLoggedIn = true;
      final store = await _openStore(repo);
      await store.load();
      expect(repo.setSessionCalls, 0);
      expect(repo.calls, ['status']);
      expect(store.sessionLive, isTrue);
    });

    test('冷启动恢复：交回后状态说没会话，显示登录已过期', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        hongguoAccountSessionStorageKey,
        '{"accountCookie":"sessionid=abc123","deviceId":"d1",'
        '"installId":"i1","accountId":"u1","cookieSource":"web"}',
      );
      hongguoAccountNotifier.value = const HongguoAccount(
        userId: 'u1',
        displayName: '道友1',
        method: 'sms',
      );
      final repo = _FakeAccountRepository()..statusLoggedIn = false;
      final store = await _openStore(repo);
      await store.load();
      expect(repo.calls, ['set', 'status']);
      expect(store.account?.userId, 'u1');
      expect(store.sessionLive, isFalse);
      expect(store.loggedIn, isFalse);
    });

    test('登出时 Go 核与 Dart 侧两边都清', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        hongguoAccountSessionStorageKey,
        '{"accountCookie":"sessionid=abc123","accountId":"u1"}',
      );
      hongguoAccountNotifier.value = const HongguoAccount(
        userId: 'u1',
        displayName: '道友1',
        method: 'sms',
      );
      final repo = _FakeAccountRepository()..statusLoggedIn = true;
      final store = await _openStore(repo);
      await store.load();
      expect(store.loggedIn, isTrue);
      await store.signOut();
      expect(repo.clearSessionCalls, 1);
      expect(repo.calls, contains('clear'));
      expect(prefs.getString(hongguoAccountSessionStorageKey), isNull);
      expect(prefs.getString(hongguoAccountStorageKey), isNull);
      expect(store.account, isNull);
      expect(store.loggedIn, isFalse);
    });
  });
}
