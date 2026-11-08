import 'dart:convert';

import 'package:path/path.dart' as p;

final RegExp kMiniAppIdPattern =
    RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');

class MiniAppManifest {
  const MiniAppManifest({
    required this.appId,
    required this.name,
    this.version = '',
    this.versionCode = 0,
    this.entry = 'index.html',
    this.renderer = 'webview',
    this.description = '',
    this.permissions = const <String>[],
    this.networkAllowlist = const <String>[],
    this.pythonEntry,
  });

  factory MiniAppManifest.fromJson(Map<String, dynamic> json) {
    final permissions = <String>[];
    final rawPermissions = json['permissions'];
    if (rawPermissions is List) {
      for (final item in rawPermissions) {
        permissions.add(item.toString());
      }
    }
    final allowlist = <String>[];
    final network = json['network'];
    if (network is Map) {
      final rawAllowlist = network['allowlist'];
      if (rawAllowlist is List) {
        for (final item in rawAllowlist) {
          allowlist.add(item.toString());
        }
      }
    }
    String? pythonEntry;
    final python = json['python'];
    if (python is Map && python['entry'] is String) {
      pythonEntry = python['entry'] as String;
    }
    return MiniAppManifest(
      appId: (json['appId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      entry: (json['entry'] ?? 'index.html').toString(),
      renderer: (json['renderer'] ?? 'webview').toString(),
      description: (json['description'] ?? '').toString(),
      permissions: permissions,
      networkAllowlist: allowlist,
      pythonEntry: pythonEntry,
    );
  }

  final String appId;
  final String name;
  final String version;
  final int versionCode;
  final String entry;
  final String renderer;
  final String description;
  final List<String> permissions;
  final List<String> networkAllowlist;
  final String? pythonEntry;

  bool get isValid =>
      kMiniAppIdPattern.hasMatch(appId) && name.isNotEmpty;

  bool hasPermission(String permission) => permissions.contains(permission);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'appId': appId,
    'name': name,
    'version': version,
    'versionCode': versionCode,
    'entry': entry,
    'renderer': renderer,
    'description': description,
    'permissions': permissions,
    'network': <String, dynamic>{'allowlist': networkAllowlist},
    if (pythonEntry != null) 'python': <String, dynamic>{'entry': pythonEntry},
  };
}

class MiniAppMarketItem {
  const MiniAppMarketItem({
    required this.appId,
    required this.name,
    this.version = '',
    this.versionCode = 0,
    required this.url,
    this.md5,
    this.size,
    this.author = '',
    this.description = '',
  });

  factory MiniAppMarketItem.fromJson(Map<String, dynamic> json) {
    return MiniAppMarketItem(
      appId: (json['appId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      url: (json['url'] ?? '').toString(),
      md5: (json['md5'] as String?)?.toLowerCase(),
      size: (json['size'] as num?)?.toInt(),
      author: (json['author'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
    );
  }

  final String appId;
  final String name;
  final String version;
  final int versionCode;
  final String url;
  final String? md5;
  final int? size;
  final String author;
  final String description;

  bool get isValid => appId.isNotEmpty && name.isNotEmpty && url.isNotEmpty;
}

List<MiniAppMarketItem> parseMiniAppMarketJson(String raw) {
  final decoded = _decodeJson(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final apps = decoded['apps'];
  if (apps is! List) return const [];
  final items = <MiniAppMarketItem>[];
  for (final entry in apps) {
    if (entry is Map<String, dynamic>) {
      final item = MiniAppMarketItem.fromJson(entry);
      if (item.isValid) items.add(item);
    }
  }
  return items;
}

dynamic _decodeJson(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

String? safeJoinPath(String base, String relative) {
  final normalized = p.normalize(p.join(base, relative));
  final baseNormalized = p.normalize(base);
  if (normalized == baseNormalized) return normalized;
  if (!p.isWithin(baseNormalized, normalized)) return null;
  return normalized;
}

bool isSafeZipEntryName(String name) {
  if (name.isEmpty) return false;
  if (name.startsWith('/') || name.startsWith('\\')) return false;
  if (name.contains(':')) return false;
  final parts = name.replaceAll('\\', '/').split('/');
  for (final part in parts) {
    if (part == '..') return false;
  }
  return true;
}
