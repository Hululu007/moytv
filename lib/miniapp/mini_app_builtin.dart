import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mini_app_manifest.dart';
import 'mini_app_store.dart';

class MiniAppBuiltinFailure {
  const MiniAppBuiltinFailure({required this.appId, required this.reason});

  final String appId;
  final String reason;
}

class MiniAppBuiltinResult {
  const MiniAppBuiltinResult({
    required this.installed,
    required this.skipped,
    required this.failed,
    this.unavailable = const [],
  });

  final List<String> installed;
  final List<String> skipped;
  final List<MiniAppBuiltinFailure> failed;
  final List<String> unavailable;

  bool get hasFailures => failed.isNotEmpty;
}

/// 内置小程序播种：与火蚁TV 同款机制。首次打开小程序页时，把包内
/// assets/miniapps/builtin/ 下的 17 个小程序（market.json 清单）装进
/// 宿主目录；已装过或已播种过的跳过，zip 包验 md5，manifest-only 的
/// 只写 manifest.json。播种失败不拦页面，只记进返回结果。
class MiniAppBuiltin {
  static const String marketAsset = 'assets/miniapps/builtin/market.json';
  static const String seededKey = 'moyi_miniapp_builtin_seeded_v1';
  static const String seededAppIdsKey =
      'moyi_miniapp_builtin_seeded_ids_v1';

  static Future<MiniAppBuiltinResult> ensureSeeded(
    MiniAppStore store, {
    SharedPreferences? prefs,
    Future<ByteData> Function(String asset)? loadAsset,
  }) async {
    final preferences = prefs ?? await SharedPreferences.getInstance();
    final load = loadAsset ?? rootBundle.load;
    List<MiniAppMarketItem> items;
    try {
      final raw = await load(marketAsset);
      items = parseMiniAppMarketJson(
        utf8.decode(raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes)),
      );
    } catch (_) {
      return const MiniAppBuiltinResult(
        installed: [],
        skipped: [],
        failed: [],
      );
    }
    final seededIds =
        preferences.getStringList(seededAppIdsKey) ?? const <String>[];
    final seeded = seededIds.toSet();
    final installed = <String>[];
    final skipped = <String>[];
    final failed = <MiniAppBuiltinFailure>[];
    final unavailable = <String>[];
    for (final item in items) {
      if (seeded.contains(item.appId)) {
        skipped.add(item.appId);
        continue;
      }
      final existing = await store.installedDir(item.appId);
      if (existing != null) {
        skipped.add(item.appId);
        continue;
      }
      List<int> bytes;
      try {
        final raw = await load(
          item.url.endsWith('.json')
              ? 'assets/miniapps/builtin/${item.appId}.manifest.json'
              : 'assets/miniapps/builtin/${item.appId}.zip',
        );
        bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
      } catch (_) {
        unavailable.add(item.appId);
        continue;
      }
      try {
        if (item.url.endsWith('.json')) {
          await store.installFromManifestJson(utf8.decode(bytes));
        } else {
          await store.installFromZipBytes(
            bytes,
            expectedMd5: item.md5,
          );
        }
        installed.add(item.appId);
      } catch (error) {
        failed.add(
          MiniAppBuiltinFailure(appId: item.appId, reason: error.toString()),
        );
      }
    }
    if (items.isNotEmpty && failed.isEmpty) {
      await preferences.setBool(seededKey, true);
      final nextSeeded = <String>{...seeded, ...installed, ...skipped};
      await preferences.setStringList(
        seededAppIdsKey,
        nextSeeded.toList(),
      );
    }
    return MiniAppBuiltinResult(
      installed: installed,
      skipped: skipped,
      failed: failed,
      unavailable: unavailable,
    );
  }
}
