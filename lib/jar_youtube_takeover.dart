import 'dart:io';

import 'package:flutter/services.dart';

import 'import_file_store.dart';
import 'jar_bridge.dart';
import 'models.dart';
import 'py_bridge.dart';
import 'py_contract.dart';

class JarYoutubeTakeover {
  JarYoutubeTakeover._();

  static const className = 'com.github.catvod.spider.ZakaYouTubeAmns';

  static const assetPath = 'assets/py_spiders/youtube.py';

  static String? _spiderPath;

  static bool isJarYoutubeSite(JarSiteSpec spec) =>
      spec.className == className;

  static bool isUsablePlan(PlaybackPlan plan) {
    if (plan.url.isEmpty || plan.needsParse) return false;
    if (plan.url.startsWith('proxy://') || plan.url.startsWith('proxy:')) {
      return false;
    }
    return plan.url.startsWith('http://') || plan.url.startsWith('https://');
  }

  static Future<String> _materializeSpider() async {
    final cached = _spiderPath;
    if (cached != null && await File(cached).exists()) return cached;
    final bytes = await rootBundle.load(assetPath);
    final fileName = await ImportFileStore.save(
      'builtin_jar_youtube',
      'py',
      bytes.buffer.asUint8List(),
    );
    final resolved = await ImportFileStore.pathOf(fileName);
    _spiderPath = resolved;
    return resolved;
  }

  static String? videoIdFromWatchUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final isYoutube =
        host == 'youtu.be' ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com');
    if (!isYoutube) return null;
    final queryId = uri.queryParameters['v'];
    if (queryId != null && queryId.isNotEmpty) return queryId;
    final segments = uri.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.isEmpty) return null;
    if (host == 'youtu.be') return segments.first;
    if (segments.first == 'embed' ||
        segments.first == 'shorts' ||
        segments.first == 'live' ||
        segments.first == 'v') {
      return segments.length > 1 ? segments[1] : null;
    }
    return null;
  }

  static Future<PlaybackPlan?> tryResolveWatchUrl(String url) async {
    try {
      final videoId = videoIdFromWatchUrl(url);
      if (videoId == null) return null;
      final status = await PyBridge.status();
      if (!status.available) return null;
      final spiderPath = await _materializeSpider();
      final result = await PyBridge.call(spiderPath, {
        'action': 'resolve',
        'flag': '',
        'playId': videoId,
        'extend': '{"gl":"US","hl":"zh-CN"}',
      });
      final plan = PyContract.planFromResult(result);
      if (!isUsablePlan(plan)) return null;
      return plan;
    } catch (_) {
      return null;
    }
  }

  static Future<PlaybackPlan?> tryResolve(
    JarSiteSpec spec,
    Drama drama,
    Episode episode,
  ) async {
    try {
      if (!isJarYoutubeSite(spec)) return null;
      if (!JarBridge.supported) return null;
      final status = await PyBridge.status();
      if (!status.available) return null;
      final flag = episode.raw['flag'] as String? ?? '';
      final playId = episode.raw['playId'] as String? ?? episode.id;
      if (playId.isEmpty) return null;
      final spiderPath = await _materializeSpider();
      final result = await PyBridge.call(spiderPath, {
        'action': 'resolve',
        'flag': flag,
        'playId': playId,
        'extend': spec.ext,
      });
      final plan = PyContract.planFromResult(result);
      if (!isUsablePlan(plan)) return null;
      return plan;
    } catch (_) {
      return null;
    }
  }
}
