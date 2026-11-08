import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../relay_cf/cf_relay_constants.dart';

class RelaySettings {
  RelaySettings(this.preferences);

  static const _urlKey = 'relay.url';
  static const _deviceKey = 'relay.deviceId';
  static const _selfIdKey = 'relay.selfId';
  static const _autoFollowKey = 'relay.autoFollow';

  final SharedPreferences preferences;

  String get storedUrl => preferences.getString(_urlKey) ?? '';

  String get url {
    final stored = storedUrl;
    return stored.isNotEmpty ? stored : cfRelayWsUrl;
  }

  String get selfId => preferences.getString(_selfIdKey) ?? '';

  String get deviceId => preferences.getString(_deviceKey) ?? '';

  bool get autoFollow => preferences.getBool(_autoFollowKey) ?? false;

  Future<void> setUrl(String value) => preferences.setString(_urlKey, value);

  Future<void> setSelfId(String value) =>
      preferences.setString(_selfIdKey, value);

  Future<void> setAutoFollow(bool value) =>
      preferences.setBool(_autoFollowKey, value);

  Future<String> ensureDeviceId() async {
    final existing = deviceId;
    if (existing.isNotEmpty) return existing;
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await preferences.setString(_deviceKey, id);
    return id;
  }

  String randomPairId() {
    final random = Random.secure();
    return (100000 + random.nextInt(900000)).toString();
  }
}
