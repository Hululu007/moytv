import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'hongguo_cloud_records.dart';
import 'models.dart';

class HongguoAccount {
  const HongguoAccount({
    required this.userId,
    required this.displayName,
    this.maskedPhone = '',
    required this.method,
  });

  final String userId;
  final String displayName;
  final String maskedPhone;
  final String method;

  bool get loggedIn => userId.isNotEmpty;

  String get methodLabel => switch (method) {
    'sms' => '短信登录',
    'qr' => '扫码登录',
    _ => method,
  };

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'displayName': displayName,
    'maskedPhone': maskedPhone,
    'method': method,
  };

  factory HongguoAccount.fromJson(Map<String, dynamic> json) => HongguoAccount(
    userId: json['userId'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
    maskedPhone: json['maskedPhone'] as String? ?? '',
    method: json['method'] as String? ?? '',
  );

  static String maskPhone(String phone) {
    if (phone.length != 11) return phone;
    return '${phone.substring(0, 3)}****${phone.substring(7)}';
  }
}

const hongguoAccountStorageKey = 'hongguoAccount';

final hongguoAccountNotifier = ValueNotifier<HongguoAccount?>(null);

bool _hongguoAccountLoaded = false;

Future<void> ensureHongguoAccountLoaded() async {
  if (_hongguoAccountLoaded) return;
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(hongguoAccountStorageKey);
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        hongguoAccountNotifier.value = HongguoAccount.fromJson(decoded);
      }
    } catch (_) {}
  }
  _hongguoAccountLoaded = true;
}

Future<void> saveHongguoAccount(HongguoAccount account) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    hongguoAccountStorageKey,
    jsonEncode(account.toJson()),
  );
  hongguoAccountNotifier.value = account;
}

Future<void> clearHongguoAccount() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.remove(hongguoAccountStorageKey);
  hongguoAccountNotifier.value = null;
}

/// 账号会话：Cookie 与设备标识。
/// Go 核的 hongguoAccountExportSession 导出当前会话（含 Cookie），
/// Dart 侧登录成功后调它取回并直存 SharedPreferences（未加密，
/// 与账号资料同口径）；冷启动时再经 hongguoAccountSetSession 交回
/// Go 核。expiresAtMs 为 0 表示服务端没给过期时间，不是已过期；
/// cookieSource 为 web / app / 空（未知）。
class HongguoAccountSession {
  const HongguoAccountSession({
    this.accountCookie = '',
    this.deviceId = '',
    this.installId = '',
    this.accountId = '',
    this.userName = '',
    this.expiresAtMs = 0,
    this.cookieSource = '',
  });

  final String accountCookie;
  final String deviceId;
  final String installId;
  final String accountId;

  /// Go 侧导出时带的用户名（App 短信路可能为空，属正常）。
  final String userName;

  /// 服务端给的会话过期时间（毫秒时间戳），0 表示未知。
  final int expiresAtMs;

  /// Cookie 来源：web（站内扫码/短信）/ app（App 短信）/ 空。
  final String cookieSource;

  bool get hasCookie => accountCookie.isNotEmpty;

  /// Cookie 只截断显示，绝不完整打出。
  String get maskedCookie {
    if (accountCookie.isEmpty) return '未保存';
    if (accountCookie.length <= 8) return '****';
    return '${accountCookie.substring(0, 4)}…${accountCookie.substring(accountCookie.length - 4)}（${accountCookie.length} 字符）';
  }

  Map<String, dynamic> toJson() => {
    'accountCookie': accountCookie,
    'deviceId': deviceId,
    'installId': installId,
    'accountId': accountId,
    'userName': userName,
    'expiresAtMs': expiresAtMs,
    'cookieSource': cookieSource,
  };

  factory HongguoAccountSession.fromJson(Map<String, dynamic> json) =>
      HongguoAccountSession(
        accountCookie: json['accountCookie'] as String? ?? '',
        deviceId: json['deviceId'] as String? ?? '',
        installId: json['installId'] as String? ?? '',
        accountId: json['accountId'] as String? ?? '',
        userName: json['userName'] as String? ?? '',
        expiresAtMs: (json['expiresAtMs'] as num?)?.toInt() ?? 0,
        cookieSource: json['cookieSource'] as String? ?? '',
      );

  /// 交回 Go 核的入参：Go 侧 hongguoAccountSetSession 收
  /// accountCookie / deviceId / installId / accountId /
  /// userName / expiresAtMs / cookieSource。
  Map<String, dynamic> toBridgeJson() => {
    'accountCookie': accountCookie,
    'deviceId': deviceId,
    'installId': installId,
    'accountId': accountId,
    'userName': userName,
    'expiresAtMs': expiresAtMs,
    'cookieSource': cookieSource,
  };
}

const hongguoAccountSessionStorageKey = 'hongguoAccountSession';

Future<void> saveHongguoAccountSession(HongguoAccountSession session) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    hongguoAccountSessionStorageKey,
    jsonEncode(session.toJson()),
  );
}

Future<HongguoAccountSession?> loadHongguoAccountSession() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(hongguoAccountSessionStorageKey);
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return HongguoAccountSession.fromJson(decoded);
    }
  } catch (_) {}
  return null;
}

Future<void> clearHongguoAccountSession() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.remove(hongguoAccountSessionStorageKey);
}

// ------------------------------------------------------------------
// 以下自火蚁TV tree_104 的 lib/hongguo_account.dart 移植（Dart 侧，
// 手机验通过的版本）：凭证分键存、transport、控制器。
// 魔蚁适配点（与 tree_104 不同，照魔蚁约定走）：
// ① 魔蚁云端模型已在 hongguo_cloud_records.dart（HongguoCloudFavorite /
//    HongguoCloudHistoryItem / HongguoCloudReservation /
//    HongguoCloudProgressItem），直接复用，不重复定义；
// ② 魔蚁 Go 核是会话制（会话在 Go 进程内，Dart 侧经
//    hongguoAccountExportSession / SetSession 持久化恢复），
//    云端 6 个动作（收藏/历史/预约/进度）已有同名会话制桥接方法，
//    transport 复用它们，不再以 cookie 为参另建同名方法（Dart 无重载）；
//    只新增确实缺失的 6 个桥接方法（发码/验码/扫码取码/轮询/确认/资料）；
// ③ 控制器上传队列另用 hongguoAccountControllerUploadQueueKey，
//    不碰 HongguoAccountStore 的 hongguoCloudUploadQueue 键。
// HongguoQrCode / HongguoSmsSent 原在 hongguo_account_store.dart，
// 挪到这里（transport 与登录页共用，store 仍经本文件引用）。

class HongguoQrCode {
  const HongguoQrCode({
    required this.imageBase64,
    required this.expiresSeconds,
  });

  factory HongguoQrCode.fromJson(Map<String, dynamic> json) =>
      HongguoQrCode(
        imageBase64: json['imageBase64'] as String? ?? '',
        expiresSeconds: (json['expiresSeconds'] as num?)?.toInt() ?? 60,
      );

  /// base64 不带 data: 前缀，界面用 base64Decode 后 Image.memory 显示。
  final String imageBase64;
  final int expiresSeconds;
}

class HongguoSmsSent {
  const HongguoSmsSent({
    required this.maskedMobile,
    required this.retrySeconds,
    required this.route,
  });

  factory HongguoSmsSent.fromJson(Map<String, dynamic> json, String route) =>
      HongguoSmsSent(
        maskedMobile: json['maskedMobile'] as String? ?? '',
        retrySeconds: (json['retrySeconds'] as num?)?.toInt() ?? 60,
        route: route,
      );

  final String maskedMobile;
  final int retrySeconds;

  /// 发码走的路：site 站内 / app 官方 App 形态。
  final String route;
}

const hongguoAccountCredentialsKey = 'hongguoAccountCredentials';
const hongguoCloudHistoryKey = 'hongguoCloudHistory';
const hongguoCloudFavoritesKey = 'hongguoCloudFavorites';
const hongguoCloudReservationsKey = 'hongguoCloudReservations';
const hongguoAccountControllerUploadQueueKey =
    'hongguoAccountControllerUploadQueue';

/// 登录凭证：Cookie 与设备标识，分键存 SharedPreferences
///（hongguoAccountCredentials，与账号资料 hongguoAccount 分开）。
/// 未加密存，与魔蚁现有账号口径一致；toString 打码，绝不打出 Cookie。
class HongguoAccountCredentials {
  const HongguoAccountCredentials({
    required this.cookie,
    this.deviceId = '',
    this.installId = '',
  });

  final String cookie;
  final String deviceId;
  final String installId;

  bool get valid => cookie.isNotEmpty;

  String get cookieHeader => cookie;

  Map<String, dynamic> toJson() => {
    'cookie': cookie,
    'deviceId': deviceId,
    'installId': installId,
  };

  factory HongguoAccountCredentials.fromJson(Map<String, dynamic> json) =>
      HongguoAccountCredentials(
        cookie: json['cookie'] as String? ?? '',
        deviceId: json['deviceId'] as String? ?? '',
        installId: json['installId'] as String? ?? '',
      );

  @override
  String toString() => 'HongguoAccountCredentials([redacted])';
}

Future<HongguoAccountCredentials?> loadHongguoAccountCredentials() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(hongguoAccountCredentialsKey);
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      final credentials = HongguoAccountCredentials.fromJson(decoded);
      return credentials.valid ? credentials : null;
    }
  } catch (_) {}
  return null;
}

Future<void> saveHongguoAccountCredentials(
  HongguoAccountCredentials credentials,
) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    hongguoAccountCredentialsKey,
    jsonEncode(credentials.toJson()),
  );
}

Future<void> clearHongguoAccountCredentials() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.remove(hongguoAccountCredentialsKey);
}

class HongguoLoginFailure implements Exception {
  const HongguoLoginFailure(
    this.message, {
    this.errorCode,
    this.canRetryCode = false,
  });

  final String message;
  final int? errorCode;
  final bool canRetryCode;

  @override
  String toString() => message;
}

class HongguoAccountUnavailable implements Exception {
  const HongguoAccountUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

class HongguoCloudProfile {
  const HongguoCloudProfile({required this.id, required this.nickname});

  final String id;
  final String nickname;

  factory HongguoCloudProfile.fromJson(Map<String, dynamic> json) =>
      HongguoCloudProfile(
        id:
            json['biz_user_id'] as String? ??
            json['id'] as String? ??
            json['userId'] as String? ??
            '',
        nickname:
            json['user_name'] as String? ??
            json['nickname'] as String? ??
            json['userName'] as String? ??
            '',
      );
}

enum HongguoQrPollResult { waiting, scanned, confirmed, expired }

class HongguoDailyCoinClaim {
  const HongguoDailyCoinClaim({
    required this.claimed,
    this.status = '',
    this.rewardType = '',
    this.rewardAmount = 0,
    this.reason = '',
  });

  factory HongguoDailyCoinClaim.fromJson(Map<String, dynamic> json) =>
      HongguoDailyCoinClaim(
        claimed: json['claimed'] as bool? ?? false,
        status: json['status'] as String? ?? '',
        rewardType: json['rewardType'] as String? ?? '',
        rewardAmount: (json['rewardAmount'] as num?)?.toInt() ?? 0,
        reason: json['reason'] as String? ?? '',
      );

  final bool claimed;
  final String status;
  final String rewardType;
  final int rewardAmount;
  final String reason;

  bool get isCoins => rewardType.toLowerCase() == 'gold';
}

abstract class HongguoAccountTransport {
  const HongguoAccountTransport();

  static const HongguoAccountTransport unavailable =
      _HongguoUnavailableTransport();

  Future<HongguoSmsSent> sendSmsCode(String mobile);
  Future<HongguoAccountCredentials> verifySmsCode({
    required String mobile,
    required String code,
  });
  Future<HongguoQrCode> fetchQrCode();
  Future<HongguoQrPollResult> pollQrCode();
  Future<HongguoAccountCredentials> confirmQrCode();
  Future<HongguoCloudProfile> fetchProfile(
    HongguoAccountCredentials credentials,
  );
  Future<List<HongguoCloudFavorite>> fetchCloudFavorites(
    HongguoAccountCredentials credentials,
  );
  Future<void> setCloudFavorite(
    HongguoAccountCredentials credentials, {
    required String seriesId,
    required bool add,
  });
  Future<List<HongguoCloudHistoryItem>> fetchCloudHistory(
    HongguoAccountCredentials credentials,
  );
  Future<void> uploadCloudProgress(
    HongguoAccountCredentials credentials, {
    required HongguoCloudProgressItem progress,
  });
  Future<List<HongguoCloudReservation>> fetchReservations(
    HongguoAccountCredentials credentials, {
    required bool online,
  });
  Future<void> reserveWork(
    HongguoAccountCredentials credentials, {
    required String seriesId,
  });
  Future<HongguoDailyCoinClaim> claimDailyCoins(
    HongguoAccountCredentials credentials,
  );
}

class _HongguoUnavailableTransport extends HongguoAccountTransport {
  const _HongguoUnavailableTransport();

  static const _message = '红果账号接口尚未接线：Go 核没有对应的账号动作';

  @override
  Future<HongguoSmsSent> sendSmsCode(String mobile) async =>
      throw const HongguoAccountUnavailable(_message);

  @override
  Future<HongguoAccountCredentials> verifySmsCode({
    required String mobile,
    required String code,
  }) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<HongguoQrCode> fetchQrCode() async =>
      throw const HongguoAccountUnavailable(_message);

  @override
  Future<HongguoQrPollResult> pollQrCode() async =>
      throw const HongguoAccountUnavailable(_message);

  @override
  Future<HongguoAccountCredentials> confirmQrCode() async =>
      throw const HongguoAccountUnavailable(_message);

  @override
  Future<HongguoCloudProfile> fetchProfile(
    HongguoAccountCredentials credentials,
  ) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<List<HongguoCloudFavorite>> fetchCloudFavorites(
    HongguoAccountCredentials credentials,
  ) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<void> setCloudFavorite(
    HongguoAccountCredentials credentials, {
    required String seriesId,
    required bool add,
  }) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<List<HongguoCloudHistoryItem>> fetchCloudHistory(
    HongguoAccountCredentials credentials,
  ) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<void> uploadCloudProgress(
    HongguoAccountCredentials credentials, {
    required HongguoCloudProgressItem progress,
  }) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<List<HongguoCloudReservation>> fetchReservations(
    HongguoAccountCredentials credentials, {
    required bool online,
  }) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<void> reserveWork(
    HongguoAccountCredentials credentials, {
    required String seriesId,
  }) async => throw const HongguoAccountUnavailable(_message);

  @override
  Future<HongguoDailyCoinClaim> claimDailyCoins(
    HongguoAccountCredentials credentials,
  ) async => throw const HongguoAccountUnavailable(_message);
}

List<Map<String, dynamic>> _hongguoAccountRows(Map<String, dynamic> result) {
  // 魔蚁 Go 核回 {"items": [...]}，tree_104 回 {"rows": [...]}，两边都认。
  final raw = result['items'] ?? result['rows'];
  if (raw is! List) return const [];
  return [
    for (final row in raw)
      if (row is Map) Map<String, dynamic>.from(row),
  ];
}

/// Go 核 transport：发码/验码/扫码/资料走新增的 6 个桥接方法；
/// 云端 6 个动作走魔蚁已有的会话制桥接方法（Go 核进程内持有会话，
/// 不用再传 Cookie，credentials 参数只作调用方凭证校验用）。
class GoHongguoAccountTransport extends HongguoAccountTransport {
  GoHongguoAccountTransport(this._repository);

  final AppRepository _repository;

  @override
  Future<HongguoSmsSent> sendSmsCode(String mobile) async {
    try {
      final result = await _repository.hongguoAccountSendSms(mobile);
      return HongguoSmsSent(
        maskedMobile: result['maskedMobile'] as String? ?? mobile,
        retrySeconds: (result['retrySeconds'] as num?)?.toInt() ?? 60,
        route: 'app',
      );
    } on AppFailure catch (error) {
      if (error.message.contains('错误码 7')) {
        throw const HongguoLoginFailure(
          '平台限流：请求太频繁，请等 60 秒后再试（错误码 7）',
          errorCode: 7,
        );
      }
      rethrow;
    }
  }

  @override
  Future<HongguoAccountCredentials> verifySmsCode({
    required String mobile,
    required String code,
  }) async {
    try {
      final result = await _repository.hongguoAccountVerifySms(mobile, code);
      return await _credentialsFromVerifyResult(result);
    } on AppFailure catch (error) {
      if (error.message.contains('错误码 1102')) {
        throw HongguoLoginFailure(
          error.message,
          errorCode: 1102,
          canRetryCode: true,
        );
      }
      rethrow;
    }
  }

  /// 验码返回优先取 {cookie, deviceId, installId}；Go 核若只把会话
  /// 落到进程内（不回 Cookie），经 hongguoAccountExportSession 导出取回。
  Future<HongguoAccountCredentials> _credentialsFromVerifyResult(
    Map<String, dynamic> result,
  ) async {
    var cookie = result['cookie'] as String? ?? '';
    var deviceId = result['deviceId'] as String? ?? '';
    var installId = result['installId'] as String? ?? '';
    if (cookie.isEmpty) {
      try {
        final exported = await _repository.hongguoAccountExportSession();
        cookie = exported['accountCookie'] as String? ?? '';
        deviceId = exported['deviceId'] as String? ?? deviceId;
        installId = exported['installId'] as String? ?? installId;
      } catch (_) {}
    }
    return HongguoAccountCredentials(
      cookie: cookie,
      deviceId: deviceId,
      installId: installId,
    );
  }

  @override
  Future<HongguoQrCode> fetchQrCode() async {
    final result = await _repository.hongguoAccountQrCode();
    return HongguoQrCode(
      imageBase64: result['imageBase64'] as String? ?? '',
      expiresSeconds:
          (result['expiresInSeconds'] as num?)?.toInt() ??
          (result['expiresSeconds'] as num?)?.toInt() ??
          60,
    );
  }

  @override
  Future<HongguoQrPollResult> pollQrCode() async {
    final result = await _repository.hongguoAccountQrPoll();
    return switch (result['result'] as String?) {
      'scanned' => HongguoQrPollResult.scanned,
      'confirmed' => HongguoQrPollResult.confirmed,
      'expired' => HongguoQrPollResult.expired,
      _ => HongguoQrPollResult.waiting,
    };
  }

  @override
  Future<HongguoAccountCredentials> confirmQrCode() async {
    final result = await _repository.hongguoAccountQrConfirm();
    return _credentialsFromVerifyResult(result);
  }

  @override
  Future<HongguoCloudProfile> fetchProfile(
    HongguoAccountCredentials credentials,
  ) async {
    final result = await _repository.hongguoAccountProfile(
      credentials.cookie,
    );
    final raw = result['profile'];
    final map =
        raw is Map<String, dynamic>
            ? raw
            : raw is Map
            ? Map<String, dynamic>.from(raw)
            : result;
    final profile = HongguoCloudProfile.fromJson(map);
    if (profile.id.isEmpty) {
      throw const HongguoLoginFailure('账号资料为空');
    }
    return profile;
  }

  @override
  Future<List<HongguoCloudFavorite>> fetchCloudFavorites(
    HongguoAccountCredentials credentials,
  ) async {
    final result = await _repository.hongguoAccountFavorites();
    return [
      for (final row in _hongguoAccountRows(result))
        HongguoCloudFavorite.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }

  @override
  Future<void> setCloudFavorite(
    HongguoAccountCredentials credentials, {
    required String seriesId,
    required bool add,
  }) async {
    await _repository.hongguoAccountSetFavorite(seriesId, add);
  }

  @override
  Future<List<HongguoCloudHistoryItem>> fetchCloudHistory(
    HongguoAccountCredentials credentials,
  ) async {
    final result = await _repository.hongguoAccountHistory();
    return [
      for (final row in _hongguoAccountRows(result))
        HongguoCloudHistoryItem.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }

  @override
  Future<void> uploadCloudProgress(
    HongguoAccountCredentials credentials, {
    required HongguoCloudProgressItem progress,
  }) async {
    await _repository.hongguoAccountUploadProgress(progress.toBridgeJson());
  }

  @override
  Future<List<HongguoCloudReservation>> fetchReservations(
    HongguoAccountCredentials credentials, {
    required bool online,
  }) async {
    final result = await _repository.hongguoAccountReservations(online);
    return [
      for (final row in _hongguoAccountRows(result))
        HongguoCloudReservation.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }

  @override
  Future<void> reserveWork(
    HongguoAccountCredentials credentials, {
    required String seriesId,
  }) async {
    await _repository.hongguoAccountReserve(seriesId);
  }

  @override
  Future<HongguoDailyCoinClaim> claimDailyCoins(
    HongguoAccountCredentials credentials,
  ) async {
    final result = await _repository.hongguoAccountClaimDailyCoins();
    return HongguoDailyCoinClaim.fromJson(result);
  }
}

class HongguoAccountController extends ChangeNotifier {
  HongguoAccountController({HongguoAccountTransport? transport, this.repository})
    : _transport = transport ?? HongguoAccountTransport.unavailable;

  HongguoAccountController.withTransport(this._transport, {this.repository});

  final HongguoAccountTransport _transport;

  /// 可空：只用于登录成功后导出 Go 核会话落盘（冷启动恢复）与登出时
  /// 通知 Go 核清会话；不传时控制器只管 Dart 侧凭证与云端缓存。
  final AppRepository? repository;

  HongguoAccountCredentials? _credentials;
  List<HongguoCloudFavorite> _cloudFavorites = const [];
  List<HongguoCloudHistoryItem> _cloudHistory = const [];
  List<HongguoCloudReservation> _onlineReservations = const [];
  List<HongguoCloudReservation> _upcomingReservations = const [];
  List<HongguoCloudProgressItem> _uploadQueue = const [];
  HongguoDailyCoinClaim? _lastDailyCoinClaim;
  bool _dailyCoinClaimAttempted = false;
  bool _uploading = false;

  bool get loggedIn =>
      hongguoAccountNotifier.value?.loggedIn == true &&
      _credentials?.valid == true;

  List<HongguoCloudFavorite> get cloudFavorites =>
      List.unmodifiable(_cloudFavorites);
  List<HongguoCloudHistoryItem> get cloudHistory =>
      List.unmodifiable(_cloudHistory);
  List<HongguoCloudReservation> get onlineReservations =>
      List.unmodifiable(_onlineReservations);
  List<HongguoCloudReservation> get upcomingReservations =>
      List.unmodifiable(_upcomingReservations);
  List<HongguoCloudProgressItem> get pendingUploads =>
      List.unmodifiable(_uploadQueue);

  HongguoDailyCoinClaim? get lastDailyCoinClaim => _lastDailyCoinClaim;

  Future<void> claimDailyCoins() async {
    final credentials = _credentials;
    if (credentials == null || !credentials.valid) return;
    if (_dailyCoinClaimAttempted) return;
    _dailyCoinClaimAttempted = true;
    try {
      _lastDailyCoinClaim = await _transport.claimDailyCoins(credentials);
    } catch (_) {}
  }

  Set<String> get cloudFavoriteIds =>
      _cloudFavorites.map((item) => item.seriesId).toSet();

  bool isCloudFavorite(String seriesId) =>
      _cloudFavorites.any((item) => item.seriesId == seriesId);

  HongguoCloudHistoryItem? cloudProgress(String seriesId) {
    for (final item in _cloudHistory) {
      if (item.seriesId == seriesId) return item;
    }
    return null;
  }

  bool isReserved(String seriesId) =>
      _onlineReservations.any((item) => item.seriesId == seriesId) ||
      _upcomingReservations.any((item) => item.seriesId == seriesId);

  Future<void> load() async {
    await ensureHongguoAccountLoaded();
    _credentials = await loadHongguoAccountCredentials();
    final preferences = await SharedPreferences.getInstance();
    _cloudHistory = _decodeHistory(
      preferences.getString(hongguoCloudHistoryKey),
    );
    _cloudFavorites = _decodeFavorites(
      preferences.getString(hongguoCloudFavoritesKey),
    );
    final reservations = _decodeReservations(
      preferences.getString(hongguoCloudReservationsKey),
    );
    _onlineReservations =
        reservations.where((item) => item.online).toList();
    _upcomingReservations =
        reservations.where((item) => !item.online).toList();
    _uploadQueue = _decodeUploadQueue(
      preferences.getString(hongguoAccountControllerUploadQueueKey),
    );
    if (hongguoAccountNotifier.value?.loggedIn != true ||
        _credentials?.valid != true) {
      _cloudHistory = const [];
      _cloudFavorites = const [];
      _onlineReservations = const [];
      _upcomingReservations = const [];
    }
    notifyListeners();
  }

  Future<HongguoSmsSent> transportSendSmsCode(String mobile) async {
    final sent = await _transport.sendSmsCode(mobile);
    // 新码已发：上次的已验会话作废，清掉待重试（修仙版 sendCode 同款）。
    _pendingVerifiedCredentials = null;
    _pendingVerifiedMobile = '';
    return sent;
  }

  Future<HongguoQrCode> transportFetchQrCode() => _transport.fetchQrCode();

  Future<HongguoQrPollResult> transportPollQrCode() =>
      _transport.pollQrCode();

  /// 已验会话保留（修仙版 _pendingVerifiedSession 同款）：验码已换到
  /// 会话、失败在后面的资料核对/落盘时（100103 那类），验证码已被消
  /// 费——留住本次凭证与手机号，再点登录直接重试核对，不重打验码接
  /// 口、不重发短信；发码/扫码成功/退出时清掉。
  HongguoAccountCredentials? _pendingVerifiedCredentials;
  String _pendingVerifiedMobile = '';

  bool get hasPendingVerifiedLogin => _pendingVerifiedCredentials != null;

  /// 验码路（重点）：verify → fetchProfile → 存凭证+账号 → 刷新云端。
  /// 验码报错误码 100103 之类服务端问题时 verifySmsCode 直接抛，
  /// 这里不吞、不重试、不回退旧路（验证码可能已被消费）。
  Future<HongguoAccount> loginWithSms({
    required String mobile,
    required String code,
  }) async {
    final credentials = await _transport.verifySmsCode(
      mobile: mobile,
      code: code,
    );
    try {
      return await _acceptCredentials(
        credentials,
        method: 'sms',
        mobile: mobile,
      );
    } catch (_) {
      // 验码已成功、失败在后面的资料核对/落盘：留住已验会话，
      // 下次直接重试核对。验码本身失败时这里走不到（上面已抛）。
      _pendingVerifiedCredentials = credentials;
      _pendingVerifiedMobile = mobile;
      rethrow;
    }
  }

  /// 直接重试上次已验会话的资料核对：不重打验码接口。成功清掉待重试；
  /// 失败保留，可再重试。
  Future<HongguoAccount> retryPendingVerifiedLogin() async {
    final credentials = _pendingVerifiedCredentials;
    final mobile = _pendingVerifiedMobile;
    if (credentials == null) {
      throw const HongguoLoginFailure('没有可重试的登录，请重新发码');
    }
    return _acceptCredentials(
      credentials,
      method: 'sms',
      mobile: mobile,
    );
  }

  Future<HongguoAccount> loginWithQr() async {
    final credentials = await _transport.confirmQrCode();
    return _acceptCredentials(credentials, method: 'qr', mobile: '');
  }

  Future<HongguoAccount> _acceptCredentials(
    HongguoAccountCredentials credentials, {
    required String method,
    required String mobile,
  }) async {
    final profile = await _transport.fetchProfile(credentials);
    if (profile.id.isEmpty) {
      throw const HongguoLoginFailure(
        '该手机号还没有红果账号资料，请先用官方红果 App 登录一次再回来试',
      );
    }
    // 先写盘再赋值（修仙版 _saveSession 同款）：写盘失败时内存里
    // 不留“已登录”的假态。
    await saveHongguoAccountCredentials(credentials);
    _credentials = credentials;
    final account = HongguoAccount(
      userId: profile.id,
      displayName:
          profile.nickname.isNotEmpty ? profile.nickname : '红果用户',
      maskedPhone:
          mobile.isEmpty
              ? ''
              : mobile.length == 11
              ? HongguoAccount.maskPhone(mobile)
              : mobile,
      method: method,
    );
    await saveHongguoAccount(account);
    // 会话制补充：把 Go 核进程内会话导出落盘，供冷启动恢复用；
    // 导出失败不影响本次登录。
    final repository = this.repository;
    if (repository != null) {
      try {
        final exported = await repository.hongguoAccountExportSession();
        final session = HongguoAccountSession.fromJson(exported);
        if (exported['loggedIn'] == true && session.hasCookie) {
          await saveHongguoAccountSession(session);
        }
      } catch (_) {}
    }
    // 登录已成：云端记录拉取失败只记一笔，不掀翻已登录态（修仙版
    // refresh 通用兜底同款），下次打开账号页再拉。
    try {
      await refreshCloudData();
    } catch (_) {}
    _pendingVerifiedCredentials = null;
    _pendingVerifiedMobile = '';
    unawaited(claimDailyCoins());
    notifyListeners();
    return account;
  }

  Future<void> logout() async {
    _pendingVerifiedCredentials = null;
    _pendingVerifiedMobile = '';
    _credentials = null;
    _lastDailyCoinClaim = null;
    _dailyCoinClaimAttempted = false;
    _cloudFavorites = const [];
    _cloudHistory = const [];
    _onlineReservations = const [];
    _upcomingReservations = const [];
    _uploadQueue = const [];
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(hongguoCloudHistoryKey);
    await preferences.remove(hongguoCloudFavoritesKey);
    await preferences.remove(hongguoCloudReservationsKey);
    await preferences.remove(hongguoAccountControllerUploadQueueKey);
    await clearHongguoAccountCredentials();
    await clearHongguoAccount();
    await clearHongguoAccountSession();
    final repository = this.repository;
    if (repository != null) {
      try {
        await repository.hongguoAccountClearSession();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> refreshCloudData() async {
    await refreshCloudHistory();
    await refreshCloudFavorites();
    await refreshReservations(online: true);
    await refreshReservations(online: false);
  }

  Future<void> refreshCloudHistory() async {
    final credentials = _credentials;
    if (credentials == null || !credentials.valid) return;
    final history = await _transport.fetchCloudHistory(credentials);
    _cloudHistory = history;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      hongguoCloudHistoryKey,
      jsonEncode(history.map((item) => item.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> refreshCloudFavorites() async {
    final credentials = _credentials;
    if (credentials == null || !credentials.valid) return;
    final favorites = await _transport.fetchCloudFavorites(credentials);
    _cloudFavorites = favorites;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      hongguoCloudFavoritesKey,
      jsonEncode(favorites.map((item) => item.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> changeCloudFavorite(Drama drama, bool add) async {
    final credentials = _credentials;
    if (credentials == null || !credentials.valid) {
      throw const HongguoLoginFailure('请先登录红果账号');
    }
    // 魔蚁 Drama.id 常带 hongguo: 前缀，先剥掉再按数字编号校验。
    final seriesId =
        drama.id.startsWith('hongguo:')
            ? drama.id.substring('hongguo:'.length)
            : drama.id;
    if (!RegExp(r'^[0-9]{1,30}$').hasMatch(seriesId)) {
      throw const HongguoLoginFailure('剧集编号无效');
    }
    await _transport.setCloudFavorite(
      credentials,
      seriesId: seriesId,
      add: add,
    );
    await refreshCloudFavorites();
  }

  Future<void> refreshReservations({required bool online}) async {
    final credentials = _credentials;
    if (credentials == null || !credentials.valid) return;
    final rows = await _transport.fetchReservations(
      credentials,
      online: online,
    );
    if (online) {
      _onlineReservations = rows;
    } else {
      _upcomingReservations = rows;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      hongguoCloudReservationsKey,
      jsonEncode([
        ..._onlineReservations.map((item) => item.toJson()),
        ..._upcomingReservations.map((item) => item.toJson()),
      ]),
    );
    notifyListeners();
  }

  Future<void> reserveSeries(String seriesId) async {
    final credentials = _credentials;
    if (credentials == null || !credentials.valid) {
      throw const HongguoLoginFailure('请先登录红果账号');
    }
    if (!RegExp(r'^[0-9]{1,19}$').hasMatch(seriesId)) {
      throw const HongguoLoginFailure('预约编号无效');
    }
    await _transport.reserveWork(credentials, seriesId: seriesId);
    await refreshReservations(online: false);
  }

  /// 播放进度入队上传：播放页仍走 HongguoAccountStore 的队列，
  /// 这里是控制器同名入口，供新路调用；两队列键分开，不互相覆盖。
  Future<void> recordPlayback(HongguoCloudProgressItem progress) async {
    _uploadQueue = [..._uploadQueue, progress];
    await _persistUploadQueue();
    notifyListeners();
    await drainUploads();
  }

  Future<void> drainUploads() async {
    final credentials = _credentials;
    if (_uploading ||
        credentials == null ||
        !credentials.valid ||
        _uploadQueue.isEmpty) {
      return;
    }
    _uploading = true;
    try {
      final remaining = [..._uploadQueue];
      for (final item in List.of(remaining)) {
        try {
          await _transport.uploadCloudProgress(
            credentials,
            progress: item,
          );
          remaining.remove(item);
        } catch (_) {
          break;
        }
      }
      _uploadQueue = remaining;
      await _persistUploadQueue();
      notifyListeners();
    } finally {
      _uploading = false;
    }
  }

  Future<void> _persistUploadQueue() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      hongguoAccountControllerUploadQueueKey,
      jsonEncode(_uploadQueue.map((item) => item.toJson()).toList()),
    );
  }

  static List<HongguoCloudHistoryItem> _decodeHistory(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final items = <HongguoCloudHistoryItem>[];
      for (final row in decoded) {
        if (row is Map) {
          try {
            items.add(
              HongguoCloudHistoryItem.fromJson(
                Map<String, dynamic>.from(row),
              ),
            );
          } catch (_) {}
        }
      }
      final seen = <String>{};
      items.retainWhere(
        (item) => item.seriesId.isNotEmpty && seen.add(item.seriesId),
      );
      items.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      return items;
    } catch (_) {
      return const [];
    }
  }

  static List<HongguoCloudFavorite> _decodeFavorites(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final items = <HongguoCloudFavorite>[];
      for (final row in decoded) {
        if (row is Map) {
          try {
            items.add(
              HongguoCloudFavorite.fromJson(Map<String, dynamic>.from(row)),
            );
          } catch (_) {}
        }
      }
      final seen = <String>{};
      items.retainWhere(
        (item) => item.seriesId.isNotEmpty && seen.add(item.seriesId),
      );
      return items;
    } catch (_) {
      return const [];
    }
  }

  static List<HongguoCloudReservation> _decodeReservations(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final items = <HongguoCloudReservation>[];
      for (final row in decoded) {
        if (row is Map) {
          try {
            items.add(
              HongguoCloudReservation.fromJson(
                Map<String, dynamic>.from(row),
              ),
            );
          } catch (_) {}
        }
      }
      final seen = <String>{};
      items.retainWhere(
        (item) => item.seriesId.isNotEmpty && seen.add(item.seriesId),
      );
      return items;
    } catch (_) {
      return const [];
    }
  }

  static List<HongguoCloudProgressItem> _decodeUploadQueue(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final items = <HongguoCloudProgressItem>[];
      for (final row in decoded) {
        if (row is Map) {
          try {
            items.add(
              HongguoCloudProgressItem.fromJson(
                Map<String, dynamic>.from(row),
              ),
            );
          } catch (_) {}
        }
      }
      return items;
    } catch (_) {
      return const [];
    }
  }
}
