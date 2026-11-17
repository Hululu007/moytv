import 'dart:async';

import 'package:http/http.dart' as http;

import 'haikuo_cloud6.dart';
import 'haikuo_codec.dart';
import 'haikuo_program.dart';

/// 云剪贴板 JS 桥的 Dart 侧逻辑（仅云 6）：规则的
/// getPastes/sharePaste/parsePaste 经同步 XHR 打到 `POST /__paste`，
/// 跑页把请求体交给 [handlePasteBridgeRequest]，回 `{ok, result/error}`。
///
/// 非 6 号云一律明示失败，绝不静默回落云 6（会改变规则作者的
/// 分享意图）。其余号云的服务端地址未公开，无任何证据可猜。

/// 云名归一：空/缺省 → 云 6（指南语义：paste 为空用第一个可用的，
/// 而壳内唯一可用的就是云 6）；`6` / 含 `云6` / `云剪贴板6` → 云 6；
/// 其余一律不是云 6。
bool pasteNameIsCloud6(String? paste) {
  final name = (paste ?? '').replaceAll(RegExp(r'\s+'), '');
  if (name.isEmpty) return true;
  if (name == '6' || name == '云剪贴板6') return true;
  return name.contains('云6');
}

/// 由分享文本拼取回地址：先认 pasteme 完整链接旧形态
/// （2023 年 10 月前的形态，取最后一段拼 getContent），
/// 再走 [HaikuoCodec.cloudApiUrl]（云 6 取回地址、未知云抛错）。
///
/// 无短码抛错，不回 null（免得调用方把它当普通口令再试一圈）。
String pasteFetchUrl(String input) {
  final text = input.trim();
  if (text.contains('pasteme.tyrantg.com/')) {
    var tail = text.split('pasteme.tyrantg.com/').last;
    tail = tail.split(RegExp(r'[?#\s]')).first;
    final code = tail
        .split('/')
        .lastWhere((segment) => segment.isNotEmpty, orElse: () => '');
    if (code.isEmpty) {
      throw const HaikuoFormatException('无法识别的云剪贴板地址，请确认是云剪贴板 6 的分享文本');
    }
    return 'https://pasteme.tyrantg.com/api/getContent/$code';
  }
  final url = HaikuoCodec.cloudApiUrl(text);
  if (url == null) {
    throw const HaikuoFormatException('无法识别的云剪贴板地址，请确认是云剪贴板 6 的分享文本');
  }
  return url;
}

/// 取回云剪贴板接口的响应正文（与导入侧同一条取回链：http GET、
/// 30 秒超时、非 200 抛错）。[client] 仅供测试注入假传输。
Future<String> fetchPasteText(String url, {http.Client? client}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(
          Uri.parse(url),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
            'Accept': 'application/json, text/plain, */*',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HaikuoFormatException(
        '云剪贴板取回失败：HTTP ${response.statusCode}',
      );
    }
    return HaikuoCodec.decodeText(response.bodyBytes);
  } on HaikuoFormatException {
    rethrow;
  } on TimeoutException {
    throw const HaikuoFormatException('云剪贴板取回超时，请稍后重试');
  } catch (error) {
    throw HaikuoFormatException('云剪贴板取回失败：$error');
  } finally {
    if (owned) httpClient.close();
  }
}

/// 处理一次 /__paste 请求：`{op, content?, paste?, url?}` →
/// 成功 `{ok: true, result}`，失败 `{ok: false, error}`。
///
/// 三个 op 的语义：
/// - list：只回 `['云剪贴板6']`（壳内实际可用的云只有它）。
/// - share：非 6 号云明示失败；成功只回分享文本第一行
///   （`云6oooole/xxxxxx/<短码>@<密码>`，规则自己拼口令包装）。
/// - parse：取回后回 `data` 字符串原文（规则拿到后自行处理）。
/// [upload]/[fetchText] 可注入，单元测试不联网。
Future<Map<String, dynamic>> handlePasteBridgeRequest(
  Map<String, dynamic> payload, {
  required Future<HaikuoCloud6Upload> Function(String content) upload,
  required Future<String> Function(String url) fetchText,
}) async {
  try {
    final op = '${payload['op'] ?? ''}';
    switch (op) {
      case 'list':
        return {
          'ok': true,
          'result': ['云剪贴板6'],
        };
      case 'share': {
        final paste = '${payload['paste'] ?? ''}';
        if (!pasteNameIsCloud6(paste)) {
          return {
            'ok': false,
            'error':
                '“$paste”的服务端地址未公开（官方导入器闭源），暂不能分享到该云；当前仅支持云剪贴板 6',
          };
        }
        final content = '${payload['content'] ?? ''}';
        if (content.trim().isEmpty) {
          return {'ok': false, 'error': '分享内容为空，无法上传'};
        }
        final uploaded = await upload(content);
        final firstLine = buildCloud6ShareText(
          path: uploaded.path,
          password: uploaded.password,
          title: '',
        ).split('\n').first;
        return {'ok': true, 'result': firstLine};
      }
      case 'parse': {
        final url = '${payload['url'] ?? ''}';
        if (url.trim().isEmpty) {
          return {'ok': false, 'error': '云剪贴板地址为空，无法解析'};
        }
        final apiUrl = pasteFetchUrl(url);
        final body = await fetchText(apiUrl);
        final data = HaikuoCodec.parseCloudApiResponse(body);
        return {'ok': true, 'result': data};
      }
      default:
        return {'ok': false, 'error': '未知的云剪贴板操作：$op'};
    }
  } on HaikuoFormatException catch (error) {
    return {'ok': false, 'error': error.message};
  } catch (error) {
    return {'ok': false, 'error': '云剪贴板操作失败：$error'};
  }
}
