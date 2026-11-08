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

  static Future<String> fetchAndSave(String siteId, String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    List<int> bytes;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'okhttp/4.12.0');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('py 文件下载失败：HTTP ${response.statusCode}');
      }
      bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
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
