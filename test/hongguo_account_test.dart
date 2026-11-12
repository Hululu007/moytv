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

  // 新路（GoHongguoAccountTransport）用的 6 个桥接方法。
  bool failAccountSend = false;
  bool sendRateLimited = false;
  int accountSendRetrySeconds = 60;
  bool failAccountVerify = false;
  bool verifyCode1102 = false;
  String verifyCookie = 'sessionid=abc123';
  String qrPollResult = 'waiting';
  Map<String, dynamic> profile = {
    'profile': {'biz_user_id': 'u1', 'user_name': '道友1'},
  };
  bool failProfile = false;
  int verifySmsCalls = 0;
  bool failHistory = false;
  Map<String, dynamic> claimDailyCoinsResult = {
    'claimed': true,
    'status': 'AVAILABLE',
    'rewardType': 'gold',
    'rewardAmount': 100,
  };
  int claimDailyCoinsCalls = 0;

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
  Future<Map<String, dynamic>> hongguoAccountHistory() async {
    if (failHistory) throw AppFailure('云端历史拉取失败');
    return {
      'items': history,
    };
  }

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

  @override
  Future<Map<String, dynamic>> hongguoAccountSendSms(String mobile) async {
    if (sendRateLimited) throw AppFailure('发送太频繁（错误码 7）');
    if (failAccountSend) throw AppFailure('新路发码失败');
    return {
      'maskedMobile': '138****8000',
      'retrySeconds': accountSendRetrySeconds,
    };
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountVerifySms(
    String mobile,
    String code,
  ) async {
    verifySmsCalls++;
    if (verifyCode1102) throw AppFailure('验证码错误（错误码 1102）');
    if (failAccountVerify) throw AppFailure('新路校验失败');
    return {
      'cookie': verifyCookie,
      'deviceId': 'd1',
      'installId': 'i1',
    };
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountQrCode() async => {
    'imageBase64': 'aGVsbG8=',
    'expiresInSeconds': 90,
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountQrPoll() async => {
    'result': qrPollResult,
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountQrConfirm() async => {
    'cookie': verifyCookie,
    'deviceId': '',
    'installId': '',
  };

  @override
  Future<Map<String, dynamic>> hongguoAccountProfile(String cookie) async {
    if (failProfile) throw AppFailure('账号资料为空');
    return profile;
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountClaimDailyCoins() async {
    claimDailyCoinsCalls++;
    return claimDailyCoinsResult;
  }
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
      expect(HongguoPhoneNumber.forBridge('+86', '13812345678'), '13812345678');
      expect(HongguoPhoneNumber.forBridge('+86', '138 1234 5678'), '13812345678');
      expect(HongguoPhoneNumber.forBridge('+852', '91234567'), '+852 91234567');
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

  group('新 transport：错误码映射', () {
    test('发码错误码 7 映射成 HongguoLoginFailure(errorCode 7)', () async {
      final repo = _FakeAccountRepository()..sendRateLimited = true;
      final transport = GoHongguoAccountTransport(repo);
      expect(
        () => transport.sendSmsCode('+86 13812345678'),
        throwsA(
          isA<HongguoLoginFailure>()
              .having((error) => error.errorCode, 'errorCode', 7),
        ),
      );
    });

    test('发码成功回掩码手机与倒计时', () async {
      final repo = _FakeAccountRepository()..accountSendRetrySeconds = 45;
      final transport = GoHongguoAccountTransport(repo);
      final sent = await transport.sendSmsCode('+86 13812345678');
      expect(sent.maskedMobile, '138****8000');
      expect(sent.retrySeconds, 45);
    });

    test('验码错误码 1102 映射成可重填验证码的失败', () async {
      final repo = _FakeAccountRepository()..verifyCode1102 = true;
      final transport = GoHongguoAccountTransport(repo);
      expect(
        () => transport.verifySmsCode(
          mobile: '+86 13812345678',
          code: '000000',
        ),
        throwsA(
          isA<HongguoLoginFailure>()
              .having((error) => error.errorCode, 'errorCode', 1102)
              .having((error) => error.canRetryCode, 'canRetryCode', isTrue),
        ),
      );
    });

    test('验码不回 Cookie 时经导出取回', () async {
      final repo = _FakeAccountRepository()
        ..verifyCookie = ''
        ..exportResult = {
          'loggedIn': true,
          'accountCookie': 'sessionid=exported',
          'deviceId': 'd9',
          'installId': 'i9',
          'accountId': 'u1',
        };
      final transport = GoHongguoAccountTransport(repo);
      final credentials = await transport.verifySmsCode(
        mobile: '+86 13812345678',
        code: '123456',
      );
      expect(credentials.cookie, 'sessionid=exported');
      expect(credentials.deviceId, 'd9');
    });

    test('扫码取码/轮询/确认走新动作', () async {
      final repo = _FakeAccountRepository()..qrPollResult = 'confirmed';
      final transport = GoHongguoAccountTransport(repo);
      final qr = await transport.fetchQrCode();
      expect(qr.imageBase64, 'aGVsbG8=');
      expect(qr.expiresSeconds, 90);
      expect(await transport.pollQrCode(), HongguoQrPollResult.confirmed);
      final credentials = await transport.confirmQrCode();
      expect(credentials.cookie, 'sessionid=abc123');
    });

    test('云端动作复用会话制桥接方法，items 与 rows 都认', () async {
      final repo = _FakeAccountRepository();
      final transport = GoHongguoAccountTransport(repo);
      const credentials = HongguoAccountCredentials(cookie: 'c');
      final favorites = await transport.fetchCloudFavorites(credentials);
      expect(favorites.single.title, '云端收藏剧');
      final history = await transport.fetchCloudHistory(credentials);
      expect(history.single.episodeIndex, 2);
      final offline = await transport.fetchReservations(
        credentials,
        online: false,
      );
      expect(offline.single.seriesId, 'reservation:300');
    });

    test('未接线 transport 处处报不可用', () async {
      const transport = HongguoAccountTransport.unavailable;
      expect(
        () => transport.sendSmsCode('138'),
        throwsA(isA<HongguoAccountUnavailable>()),
      );
      expect(
        () => transport.fetchQrCode(),
        throwsA(isA<HongguoAccountUnavailable>()),
      );
    });

    test('凭证 toString 打码不泄漏 Cookie', () {
      const credentials = HongguoAccountCredentials(cookie: 'sessionid=secret');
      expect(credentials.toString(), isNot(contains('secret')));
    });
  });

  group('新控制器：短信登录全链路', () {
    Future<HongguoAccountController> openController(
      _FakeAccountRepository repo,
    ) async {
      final controller = HongguoAccountController.withTransport(
        GoHongguoAccountTransport(repo),
        repository: repo,
      );
      await controller.load();
      return controller;
    }

    test('loginWithSms：验码→资料→存凭证+账号→刷新云端', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      final account = await controller.loginWithSms(
        mobile: '+86 13812345678',
        code: '123456',
      );
      expect(account.userId, 'u1');
      expect(account.displayName, '道友1');
      expect(controller.loggedIn, isTrue);
      expect(controller.cloudFavorites.single.title, '云端收藏剧');
      expect(controller.cloudHistory.single.title, '云端历史剧');
      expect(controller.onlineReservations.single.title, '已上线预约剧');
      expect(controller.upcomingReservations.single.title, '待上线预约剧');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(hongguoAccountCredentialsKey),
        contains('sessionid=abc123'),
      );
      expect(prefs.getString(hongguoAccountStorageKey), contains('u1'));
    });

    test('loginWithQr：确认→资料→登录', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      final account = await controller.loginWithQr();
      expect(account.userId, 'u1');
      expect(account.method, 'qr');
      expect(controller.loggedIn, isTrue);
    });

    test('资料为空时登录失败，不算登录', () async {
      final repo = _FakeAccountRepository()
        ..profile = {
          'profile': {'biz_user_id': '', 'user_name': ''},
        };
      final controller = await openController(repo);
      expect(
        () => controller.loginWithSms(
          mobile: '+86 13812345678',
          code: '123456',
        ),
        throwsA(isA<HongguoLoginFailure>()),
      );
      expect(controller.loggedIn, isFalse);
    });

    test('云端缓存落盘后新建控制器能读回', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      await controller.loginWithSms(
        mobile: '+86 13812345678',
        code: '123456',
      );
      final controller2 = await openController(repo);
      expect(controller2.loggedIn, isTrue);
      expect(controller2.cloudFavorites.single.title, '云端收藏剧');
      expect(controller2.cloudHistory.single.seriesId, '100');
    });

    test('logout 清凭证+账号+云端缓存', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      await controller.loginWithSms(
        mobile: '+86 13812345678',
        code: '123456',
      );
      expect(controller.loggedIn, isTrue);
      await controller.logout();
      expect(controller.loggedIn, isFalse);
      expect(controller.cloudFavorites, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(hongguoAccountCredentialsKey), isNull);
      expect(prefs.getString(hongguoAccountStorageKey), isNull);
    });

    test('changeCloudFavorite：hongguo: 前缀剥掉，非数字编号拒绝', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      await controller.loginWithSms(
        mobile: '+86 13812345678',
        code: '123456',
      );
      await controller.changeCloudFavorite(
        const Drama(id: 'hongguo:100', source: 'hongguo', title: '剧'),
        true,
      );
      expect(controller.isCloudFavorite('100'), isTrue);
      expect(
        () => controller.changeCloudFavorite(
          const Drama(id: 'abc', source: 'hongguo', title: '剧'),
          true,
        ),
        throwsA(isA<HongguoLoginFailure>()),
      );
    });

    test('recordPlayback 入队即发，失败留队', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      await controller.loginWithSms(
        mobile: '+86 13812345678',
        code: '123456',
      );
      await controller.recordPlayback(
        const HongguoCloudProgressItem(
          accountId: 'u1',
          seriesId: '100',
          itemId: 'ep1',
          episodeIndex: 0,
          episodeCount: 10,
          progressMs: 5000,
          totalMs: 60000,
          updatedAtMs: 1,
        ),
      );
      expect(repo.uploadCalls, hasLength(1));
      expect(controller.pendingUploads, isEmpty);

      repo.failUpload = true;
      await controller.recordPlayback(
        const HongguoCloudProgressItem(
          accountId: 'u1',
          seriesId: '100',
          itemId: 'ep2',
          episodeIndex: 1,
          episodeCount: 10,
          progressMs: 1000,
          totalMs: 60000,
          updatedAtMs: 2,
        ),
      );
      expect(repo.uploadCalls, hasLength(2));
      expect(controller.pendingUploads, hasLength(1));
    });

    test('reserveSeries：写后刷新待上线列表，非法编号拒绝', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      await controller.loginWithSms(
        mobile: '+86 13812345678',
        code: '123456',
      );
      await controller.reserveSeries('300');
      expect(controller.isReserved('300'), isTrue);
      expect(
        () => controller.reserveSeries('abc'),
        throwsA(isA<HongguoLoginFailure>()),
      );
    });

    test('资料核对失败时保留已验会话，重试核对不重验', () async {
      final repo = _FakeAccountRepository()..failProfile = true;
      final controller = await openController(repo);
      // await 等登录 Future 走完（stash 发生在 catch 里），再断言待重试。
      await expectLater(
        () => controller.loginWithSms(
          mobile: '13812345678',
          code: '123456',
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.loggedIn, isFalse);
      expect(controller.hasPendingVerifiedLogin, isTrue);
      expect(repo.verifySmsCalls, 1);
      repo.failProfile = false;
      final account = await controller.retryPendingVerifiedLogin();
      expect(account.userId, 'u1');
      expect(controller.loggedIn, isTrue);
      expect(controller.hasPendingVerifiedLogin, isFalse);
      expect(repo.verifySmsCalls, 1);
    });

    test('无待验会话时重试直接报错', () async {
      final repo = _FakeAccountRepository();
      final controller = await openController(repo);
      expect(
        () => controller.retryPendingVerifiedLogin(),
        throwsA(isA<HongguoLoginFailure>()),
      );
    });

    test('发新码清掉待重试的已验会话', () async {
      final repo = _FakeAccountRepository()..failProfile = true;
      final controller = await openController(repo);
      await expectLater(
        () => controller.loginWithSms(
          mobile: '13812345678',
          code: '123456',
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.hasPendingVerifiedLogin, isTrue);
      await controller.transportSendSmsCode('13812345678');
      expect(controller.hasPendingVerifiedLogin, isFalse);
    });

    test('刷新云端失败不掀翻已登录态', () async {
      final repo = _FakeAccountRepository()..failHistory = true;
      final controller = await openController(repo);
      final account = await controller.loginWithSms(
        mobile: '13812345678',
        code: '123456',
      );
      expect(account.userId, 'u1');
      expect(controller.loggedIn, isTrue);
    });
  });

  group('登入奖励领金币', () {
    test('claimDailyCoins 映射已领 gold 奖励', () async {
      const credentials = HongguoAccountCredentials(cookie: 'sessionid=s1');
      final transport = GoHongguoAccountTransport(_FakeAccountRepository());
      final claim = await transport.claimDailyCoins(credentials);
      expect(claim.claimed, isTrue);
      expect(claim.isCoins, isTrue);
      expect(claim.rewardAmount, 100);
    });

    test('claimDailyCoins 映射冷却是未领', () async {
      final repo = _FakeAccountRepository()
        ..claimDailyCoinsResult = {
          'claimed': false,
          'status': 'COOLDOWN',
          'reason': 'not-available',
        };
      const credentials = HongguoAccountCredentials(cookie: 'sessionid=s1');
      final transport = GoHongguoAccountTransport(repo);
      final claim = await transport.claimDailyCoins(credentials);
      expect(claim.claimed, isFalse);
      expect(claim.status, 'COOLDOWN');
    });

    test('loginWithSms 后只领一次金币', () async {
      final repo = _FakeAccountRepository();
      final controller = HongguoAccountController.withTransport(
        GoHongguoAccountTransport(repo),
        repository: repo,
      );
      await controller.load();
      await controller.loginWithSms(
        mobile: '13812345678',
        code: '123456',
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(repo.claimDailyCoinsCalls, 1);
      expect(controller.lastDailyCoinClaim?.claimed, isTrue);
      expect(controller.lastDailyCoinClaim?.rewardAmount, 100);
      await controller.claimDailyCoins();
      expect(repo.claimDailyCoinsCalls, 1);
    });
  });
}
