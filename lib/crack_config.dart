import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class CrackShieldConfig {
  const CrackShieldConfig({
    this.hosts = const [],
    this.cfClearance = '',
    this.cookies = '',
    this.headers = const <String, String>{},
    this.userAgent = '',
  });

  final List<String> hosts;
  final String cfClearance;
  final String cookies;
  final Map<String, String> headers;
  final String userAgent;

  bool get isEmpty =>
      hosts.isEmpty &&
      cfClearance.isEmpty &&
      cookies.isEmpty &&
      headers.values.every((value) => value.isEmpty) &&
      userAgent.isEmpty;

  Map<String, dynamic> toJson() => {
    'hosts': hosts,
    'cf_clearance': cfClearance,
    'cookies': cookies,
    'headers': headers,
    'userAgent': userAgent,
  };
}

class CrackVipConfig {
  const CrackVipConfig({this.token = '', this.account = '', this.unlock = ''});

  final String token;
  final String account;
  final String unlock;

  bool get isEmpty => token.isEmpty && account.isEmpty && unlock.isEmpty;

  Map<String, dynamic> toJson() => {
    'token': token,
    'account': account,
    'unlock': unlock,
  };
}

class CrackSiteConfig {
  const CrackSiteConfig({required this.slot, this.shield, this.vip});

  final String slot;
  final CrackShieldConfig? shield;
  final CrackVipConfig? vip;

  bool get hasShield => shield != null && !shield!.isEmpty;
  bool get hasVip => vip != null && !vip!.isEmpty;

  Map<String, dynamic> toJson() => {
    'slot': slot,
    if (shield != null) 'shield': shield!.toJson(),
    if (vip != null) 'vip': vip!.toJson(),
  };
}

class CrackConfig {
  const CrackConfig({required this.sites});

  final List<CrackSiteConfig> sites;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'sites': sites.map((site) => site.toJson()).toList(),
  };
}

class CrackConfigParseResult {
  const CrackConfigParseResult({this.config, this.errors = const []});

  final CrackConfig? config;
  final List<String> errors;

  bool get ok => config != null && errors.isEmpty;
}

String? _asString(dynamic value) => value is String ? value : null;

List<String>? _asStringList(dynamic value) {
  if (value is! List) return null;
  final out = <String>[];
  for (final item in value) {
    if (item is! String) return null;
    out.add(item);
  }
  return out;
}

Map<String, String>? _asStringMap(dynamic value) {
  if (value is! Map) return null;
  final out = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) return null;
    out[entry.key as String] = entry.value as String;
  }
  return out;
}

CrackConfigParseResult parseCrackConfig(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (error) {
    return CrackConfigParseResult(errors: ['JSON 解析失败：$error']);
  }
  if (decoded is! Map<String, dynamic>) {
    return const CrackConfigParseResult(errors: ['顶层必须是对象']);
  }
  final errors = <String>[];
  if (decoded['version'] != 1) {
    return const CrackConfigParseResult(errors: ['version 必须为 1']);
  }
  final rawSites = decoded['sites'];
  if (rawSites is! List || rawSites.isEmpty) {
    return const CrackConfigParseResult(errors: ['sites 必须是非空数组']);
  }
  final sites = <CrackSiteConfig>[];
  final seenSlots = <String>{};
  for (var i = 0; i < rawSites.length; i++) {
    final label = '第 ${i + 1} 站';
    final rawSite = rawSites[i];
    if (rawSite is! Map<String, dynamic>) {
      errors.add('$label：必须是对象');
      continue;
    }
    final slot = _asString(rawSite['slot'])?.trim() ?? '';
    final siteLabel = slot.isEmpty ? label : '$label（$slot）';
    if (slot.isEmpty) {
      errors.add('$label：缺少 slot');
      continue;
    }
    if (!seenSlots.add(slot)) {
      errors.add('$siteLabel：slot 重复');
      continue;
    }
    CrackShieldConfig? shield;
    final rawShield = rawSite['shield'];
    if (rawShield != null) {
      if (rawShield is! Map<String, dynamic>) {
        errors.add('$siteLabel：shield 必须是对象');
        continue;
      }
      final hosts = rawShield.containsKey('hosts')
          ? _asStringList(rawShield['hosts'])
          : <String>[];
      if (hosts == null) {
        errors.add('$siteLabel：shield.hosts 必须是字符串数组');
        continue;
      }
      final cfClearance = rawShield.containsKey('cf_clearance')
          ? _asString(rawShield['cf_clearance'])
          : '';
      final cookies = rawShield.containsKey('cookies')
          ? _asString(rawShield['cookies'])
          : '';
      final userAgent = rawShield.containsKey('userAgent')
          ? _asString(rawShield['userAgent'])
          : '';
      final headers = rawShield.containsKey('headers')
          ? _asStringMap(rawShield['headers'])
          : <String, String>{};
      if (cfClearance == null ||
          cookies == null ||
          userAgent == null ||
          headers == null) {
        errors.add('$siteLabel：shield 字段类型错误');
        continue;
      }
      if (hosts.any((host) => host.trim().isEmpty)) {
        errors.add('$siteLabel：shield.hosts 含空域名');
        continue;
      }
      if (headers.entries.any(
        (entry) => entry.key.trim().isEmpty || entry.value.trim().isEmpty,
      )) {
        errors.add('$siteLabel：shield.headers 含空键或空值');
        continue;
      }
      shield = CrackShieldConfig(
        hosts: hosts,
        cfClearance: cfClearance,
        cookies: cookies,
        headers: headers,
        userAgent: userAgent,
      );
    }
    CrackVipConfig? vip;
    final rawVip = rawSite['vip'];
    if (rawVip != null) {
      if (rawVip is! Map<String, dynamic>) {
        errors.add('$siteLabel：vip 必须是对象');
        continue;
      }
      final token = rawVip.containsKey('token')
          ? _asString(rawVip['token'])
          : '';
      final account = rawVip.containsKey('account')
          ? _asString(rawVip['account'])
          : '';
      final unlock = rawVip.containsKey('unlock')
          ? _asString(rawVip['unlock'])
          : '';
      if (token == null || account == null || unlock == null) {
        errors.add('$siteLabel：vip 字段类型错误');
        continue;
      }
      vip = CrackVipConfig(token: token, account: account, unlock: unlock);
    }
    final site = CrackSiteConfig(slot: slot, shield: shield, vip: vip);
    if (!site.hasShield && !site.hasVip) {
      errors.add('$siteLabel：shield 与 vip 均为空');
      continue;
    }
    sites.add(site);
  }
  if (errors.isNotEmpty) {
    return CrackConfigParseResult(errors: errors);
  }
  return CrackConfigParseResult(config: CrackConfig(sites: sites));
}

class CrackSitePresence {
  const CrackSitePresence({required this.hasShield, required this.hasVip});

  final bool hasShield;
  final bool hasVip;
}

class CrackConfigStore {
  static const prefsKey = 'crack_config_v1';

  static Future<CrackConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return null;
    return parseCrackConfig(raw).config;
  }

  static Future<String> save(CrackConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final text = jsonEncode(config.toJson());
    await prefs.setString(prefsKey, text);
    return text;
  }

  static Future<CrackConfig?> removeSlot(String slot) async {
    final current = await load();
    if (current == null) return null;
    final rest = current.sites.where((site) => site.slot != slot).toList();
    final prefs = await SharedPreferences.getInstance();
    if (rest.isEmpty) {
      await prefs.remove(prefsKey);
      return const CrackConfig(sites: []);
    }
    final updated = CrackConfig(sites: rest);
    await save(updated);
    return updated;
  }

  static Future<Map<String, CrackSitePresence>> summary() async {
    final config = await load();
    final out = <String, CrackSitePresence>{};
    if (config != null) {
      for (final site in config.sites) {
        out[site.slot] = CrackSitePresence(
          hasShield: site.hasShield,
          hasVip: site.hasVip,
        );
      }
    }
    return out;
  }

  static Future<String> exportText() async {
    final config = await load();
    if (config == null || config.sites.isEmpty) return '';
    return jsonEncode(config.toJson());
  }
}
