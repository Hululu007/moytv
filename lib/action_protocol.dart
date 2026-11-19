import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'web_game_page.dart';

/// 浏览器动作：py 源以 vod_tag='action'、vod_id 为动作 JSON 的条目
/// 描述“点开即在 WebView 里打开某网页”的动作（游戏源用它承载
/// JS 模拟器游戏页，无视频流）。动作 JSON 形如：
/// `{"actionId":"browser","type":"browser","title":"拳皇97",
///   "url":"https://www.yikm.net/play?id=5326",
///   "header":{"User-Agent":"..."}}`。
class BrowserAction {
  const BrowserAction({
    required this.title,
    required this.url,
    this.headers = const {},
  });

  final String title;
  final String url;
  final Map<String, String> headers;

  /// 放行主机 = 动作地址自身的主机（单主机口径，与桌面游戏窗
  /// 一致；跨主机跳转会被拦截）。
  String get allowedHost => Uri.tryParse(url)?.host ?? '';
}

/// 解析动作 JSON：actionId 与 type 须同为 browser，url 须是带
/// 主机的 http/https 地址；任一条件不满足回 null（调用方回落
/// 原有视频路径，不硬开）。
BrowserAction? parseBrowserAction(String sourceId) {
  final trimmed = sourceId.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final map = Map<String, dynamic>.from(decoded);
  if (map['actionId']?.toString() != 'browser') return null;
  if (map['type']?.toString() != 'browser') return null;
  final url = map['url']?.toString() ?? '';
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  final headers = <String, String>{};
  final rawHeaders = map['header'];
  if (rawHeaders is Map) {
    for (final entry in rawHeaders.entries) {
      headers[entry.key.toString()] = entry.value.toString();
    }
  }
  return BrowserAction(
    title: map['title']?.toString() ?? '',
    url: url,
    headers: headers,
  );
}

/// 打开浏览器动作：push 带标题栏的游戏窗，标题用动作自带标题
///（为空时回落“游戏”），不走详情页、不走视频嗅探。
Future<void> openBrowserAction(BuildContext context, BrowserAction action) {
  return Navigator.of(context).push<void>(
    appPageRoute<void>(
      settings: const RouteSettings(name: 'web-game'),
      builder: (_) => WebGameScreen(
        title: action.title.isEmpty ? '游戏' : action.title,
        gameUrl: action.url,
        allowedHost: action.allowedHost,
        headers: action.headers,
      ),
    ),
  );
}
