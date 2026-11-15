import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'import_file_store.dart';
import 'legado_gbk.dart';
import 'models.dart';
import 'py_spider_validator.dart';
import 'source_compat.dart';

/// 远程 JS 蜘蛛懒加载：与 PyLazyFetch 同款机制，服务 TVBox 配置里
/// api 指向 .js 文件的站点——注册时只记地址，首次打开该站时再下载
/// 校验并落盘；drpy 声明式规则不落盘（JS 引擎跑不了），直接报错
/// 指明走 drpy-node 小程序或 drpyS 服务。
class JsLazyFetch {
  static const _prefsKey = 'js_lazy_files_v1';

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
        throw FormatException('js 文件下载失败：HTTP ${response.statusCode}');
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
      source = decodeGbkBytes(bytes);
      saveBytes = utf8.encode(source);
    }
    final problem = identifyJsSource(source);
    if (problem != null) {
      throw FormatException('不是有效的 JS 蜘蛛：$problem');
    }
    if (classifyJsSource(source) == JsSourceShape.drpyRule) {
      throw const FormatException(
        '该文件是 drpy 声明式规则（rule 对象 + 一级/二级规则串），JS 引擎无法直接运行，请改走 drpy-node 小程序或 drpyS 服务',
      );
    }
    final fileName = await ImportFileStore.save(siteId, 'js', saveBytes);
    SourceSite.importedJsFiles[siteId] = fileName;
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
