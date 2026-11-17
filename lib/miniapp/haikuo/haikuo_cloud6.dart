import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'haikuo_program.dart';

/// 云剪贴板 6（摆烂剪贴板 pasteme.tyrantg.com）上传。
///
/// 协议来源：2026-11-16 实测（服务端开源 Laravel 项目
/// TyrantG/bailan-paste + 11 组 curl 往返实测，证据见
/// ~/workspace/pasteme_probe/FINDINGS.md）：
/// POST https://pasteme.tyrantg.com/api/create，JSON 体
/// {content, auto_password: 1}，匿名可调、无鉴权、无人机验证；
/// 成功回 {return_code: 0, data: {path, password, auth_code}}。
/// 分享文本两行：`云6oooole/xxxxxx/<path>@<password>` +
/// `小程序：<标题>`（oooole/xxxxxx 是固定字面，不是打码）。
/// 注意 auto_password 的服务端怪癖：只要传了该字段（哪怕 0）就生成
/// 密码；想无密码须整个字段不传。本实现固定传 1，与官方分享形态一致
/// （官方分享一律带 @密码）。上传无幂等，重发会多一条（无害）；
/// 不传 count_limit/time_limit 时永不过期。
class HaikuoCloud6Upload {
  const HaikuoCloud6Upload({required this.path, required this.password});

  /// 短码（默认 16 位小写字母数字）。
  final String path;

  /// 自动生成的 6 位密码（本实现固定带密码，恒非空）。
  final String password;

  /// 拼分享文本两行（纯函数逻辑见 [buildCloud6ShareText]）。
  String shareText(String title) =>
      buildCloud6ShareText(path: path, password: password, title: title);
}

/// 拼云剪贴板 6 分享文本（纯函数）：第 1 行短码行，第 2 行 `小程序：名`。
/// 无密码时第 1 行不带 @ 后缀（取回侧带了 @ 反而报 4001）。
String buildCloud6ShareText({
  required String path,
  required String password,
  required String title,
}) {
  final code = password.isEmpty ? path : '$path@$password';
  return '云6oooole/xxxxxx/$code\n小程序：$title';
}

/// 上传一段口令文本到云剪贴板 6，返回短码与密码。
///
/// 业务失败一律 HTTP 200 + JSON 信封，判成功只看 return_code；
/// HTTP 500 空 body 是路由/方法不匹配，按传输层失败报。
/// [client] 仅供测试注入假传输；默认新建 client（走全局代理配置）。
Future<HaikuoCloud6Upload> uploadCloud6ShareCode(
  String content, {
  http.Client? client,
}) async {
  final text = content.trim();
  if (text.isEmpty) {
    throw const HaikuoFormatException('分享内容为空，无法上传');
  }
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .post(
          Uri.parse('https://pasteme.tyrantg.com/api/create'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'content': text, 'auto_password': 1}),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HaikuoFormatException('云剪贴板 6 上传失败：HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.isEmpty) {
      throw const HaikuoFormatException('云剪贴板 6 上传失败：服务端无响应');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const HaikuoFormatException('云剪贴板 6 上传失败：服务端返回无法解析');
    }
    if (decoded is! Map || decoded['return_code'] != 0) {
      final message = decoded is Map ? '${decoded['message'] ?? ''}' : '';
      throw HaikuoFormatException(
        '云剪贴板 6 上传失败${message.isNotEmpty ? '：$message' : ''}',
      );
    }
    final data = decoded['data'];
    if (data is! Map) {
      throw const HaikuoFormatException('云剪贴板 6 上传失败：服务端返回缺少数据');
    }
    final path = '${data['path'] ?? ''}';
    if (path.isEmpty) {
      throw const HaikuoFormatException('云剪贴板 6 上传失败：服务端没给短码');
    }
    final password = '${data['password'] ?? ''}';
    return HaikuoCloud6Upload(path: path, password: password);
  } on HaikuoFormatException {
    rethrow;
  } on TimeoutException {
    throw const HaikuoFormatException('云剪贴板 6 上传超时，请稍后重试');
  } catch (error) {
    throw HaikuoFormatException('云剪贴板 6 上传失败：$error');
  } finally {
    if (owned) httpClient.close();
  }
}
