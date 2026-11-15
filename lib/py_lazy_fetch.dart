import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'import_file_store.dart';
import 'legado_gbk.dart';
import 'models.dart';
import 'py_bridge.dart';
import 'py_spider_validator.dart';

class PyLazyFetch {
  static const _prefsKey = 'py_lazy_files_v1';

  /// py 蜘蛛文件上限：蜘蛛是源代码文本，8MB 已极宽裕；原先下载正文
  /// 无上限、无总超时，慢速滴漏的响应会一直占着下载不放。
  static const maxSpiderBytes = 8 << 20;

  /// 下载总预算：建连与等响应头各有自己的超时，正文收集另受此限。
  static const downloadTimeout = Duration(seconds: 60);

  static final Map<String, Future<String>> _inflight = {};

  static Future<String?> savedFileName(String siteId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded[siteId]?.toString();
    } catch (_) {}
    return null;
  }

  static Future<String> fetchAndSave(
    String siteId,
    String url, {
    Duration downloadTimeout = PyLazyFetch.downloadTimeout,
  }) async {
    // 同站去重：并发打开同站时只下载一次；原先每次调用都重新下载，
    // 且两次保存与 prefs 读-改-写会互相覆盖。
    final inflight = _inflight[siteId];
    if (inflight != null) return inflight;
    final future = _fetchAndSaveUncached(
      siteId,
      url,
      downloadTimeout: downloadTimeout,
    );
    _inflight[siteId] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[siteId], future)) _inflight.remove(siteId);
    }
  }

  static Future<String> _fetchAndSaveUncached(
    String siteId,
    String url, {
    required Duration downloadTimeout,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    List<int> bytes;
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(downloadTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'okhttp/4.12.0');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('py 文件下载失败：HTTP ${response.statusCode}');
      }
      try {
        bytes = await collectCappedBytes(
          response,
          maxSpiderBytes,
        ).timeout(downloadTimeout);
      } on TimeoutException {
        throw const FormatException('py 文件下载超时');
      }
    } finally {
      client.close();
    }
    String source;
    List<int> saveBytes;
    try {
      final decoded = utf8.decode(bytes);
      source = decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
      saveBytes = bytes;
    } catch (_) {
      final decoded = decodeGbkBytes(bytes);
      source = decoded;
      final head = decoded.split('\n').take(2).join('\n');
      final hasCookie = RegExp(r'coding[:=]\s*[-\w.]+').hasMatch(head);
      saveBytes = hasCookie
          ? bytes
          : [...utf8.encode('# -*- coding: gbk -*-\n'), ...bytes];
    }
    final validation = validatePySource(source);
    if (!validation.ok) {
      throw FormatException('不是有效的 py 蜘蛛：${validation.message}');
    }
    final hostValidation = await PyBridge.validate(source);
    if (hostValidation != null && !hostValidation.ok) {
      throw FormatException('运行时校验未通过：${hostValidation.error}');
    }
    final fileName = await ImportFileStore.save(siteId, 'py', saveBytes);
    SourceSite.importedPyFiles[siteId] = fileName;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final map = <String, dynamic>{};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) map.addAll(Map<String, dynamic>.from(decoded));
      }
      map[siteId] = fileName;
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (_) {}
    return fileName;
  }
}

/// 收字节流并验上限，超限抛 FormatException（顶层函数，供单测直接验）。
Future<List<int>> collectCappedBytes(
  Stream<List<int>> stream,
  int maxBytes,
) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) {
      throw const FormatException('py 文件过大');
    }
  }
  return bytes;
}
