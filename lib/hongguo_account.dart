import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
