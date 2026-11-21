import 'dart:convert';

import 'package:http/http.dart' as http;

/// 实时翻译字幕的翻译段：把 Whisper 识别出的原文翻成中文。
///
/// Whisper 自带翻译只出英文（translate 模式目标语言固定是英语），
/// 日→中必须再接一段机器翻译。本文件只实现能落地的那段：
/// LibreTranslate（用户自填服务器地址，默认空）。
/// 端侧 Opus-MT ONNX 本批未落地（见 REPORT.md：需要 onnxruntime
/// 插件 + Marian 分词器 + 模型 ONNX 导出，三件都没在树上验过），
/// 翻译器接口已留好，后续接上 Opus-MT 实现即可替换，不用改服务层。
abstract class LiveSubtitleTranslator {
  /// 把 [text] 从 [source]（ja/en/ko/auto）翻成 [target]（首版只做 zh）。
  /// 返回 null 表示本次不翻译（调用方原样显示原文）。
  /// 翻译失败抛 [LiveSubtitleTranslationException]，调用方按失败处理。
  Future<String?> translate(
    String text, {
    required String source,
    required String target,
  });
}

class LiveSubtitleTranslationException implements Exception {
  const LiveSubtitleTranslationException(this.message);

  final String message;

  @override
  String toString() => 'LiveSubtitleTranslationException: $message';
}

/// LibreTranslate 翻译器：POST {baseUrl}/translate
/// {q, source, target, format: 'text'} → {translatedText}。
/// baseUrl 由用户在设置里自填（默认空）；构造时不校验地址，
/// 调用时地址为空直接抛错，调用方据此显示“未配置翻译服务”。
class LibreTranslateTranslator implements LiveSubtitleTranslator {
  LibreTranslateTranslator({required String baseUrl, http.Client? client})
    : _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;

  @override
  Future<String?> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    if (text.trim().isEmpty) return null;
    if (_baseUrl.isEmpty) {
      throw const LiveSubtitleTranslationException('未填写翻译服务器地址');
    }
    final uri = Uri.parse('$_baseUrl/translate');
    late final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'q': text,
              'source': source,
              'target': target,
              'format': 'text',
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw LiveSubtitleTranslationException('翻译请求失败：$e');
    }
    if (response.statusCode != 200) {
      throw LiveSubtitleTranslationException(
        '翻译服务器返回 ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['translatedText'] is! String) {
      throw const LiveSubtitleTranslationException('翻译服务器返回格式不对');
    }
    final translated = (decoded['translatedText'] as String).trim();
    return translated.isEmpty ? null : translated;
  }
}
