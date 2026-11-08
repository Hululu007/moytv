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
