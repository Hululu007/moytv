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

/// 语言码映射：Whisper/设置里的简写 → 各翻译服务的写法。
String liveTranslateLangCode(String code, {required bool target}) {
  final c = code.trim().toLowerCase();
  if (c.isEmpty) return target ? 'zh-CN' : 'auto';
  if (c == 'auto' || c == 'detect') return 'auto';
  if (c == 'zh' || c == 'zh-cn' || c == 'zh_cn' || c == 'cmn') return 'zh-CN';
  if (c == 'zh-tw' || c == 'zh_tw') return 'zh-TW';
  return c;
}

/// 谷歌翻译免费端点（App 常见内置方案，无需 Key、无需用户填地址）：
/// GET translate.googleapis.com/translate_a/single?client=gtx&sl=&tl=&dt=t&q=
/// 返回 [ [ ["译文","原文",...], ... ], ... ]，把所有分段拼起来。
class GoogleTranslateTranslator implements LiveSubtitleTranslator {
  GoogleTranslateTranslator({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const String _endpoint =
      'https://translate.googleapis.com/translate_a/single';

  @override
  Future<String?> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    final q = text.trim();
    if (q.isEmpty) return null;
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'client': 'gtx',
        'sl': liveTranslateLangCode(source, target: false),
        'tl': liveTranslateLangCode(target, target: true),
        'dt': 't',
        'q': q,
      },
    );
    late final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        },
      ).timeout(const Duration(seconds: 12));
    } catch (e) {
      throw LiveSubtitleTranslationException('翻译请求失败：$e');
    }
    if (response.statusCode != 200) {
      throw LiveSubtitleTranslationException('翻译服务器返回 ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List || decoded.isEmpty) {
      throw const LiveSubtitleTranslationException('翻译返回格式不对');
    }
    final segments = decoded[0];
    if (segments is! List) {
      throw const LiveSubtitleTranslationException('翻译返回格式不对');
    }
    final buffer = StringBuffer();
    for (final seg in segments) {
      if (seg is List && seg.isNotEmpty && seg[0] is String) {
        buffer.write(seg[0] as String);
      }
    }
    final out = buffer.toString().trim();
    return out.isEmpty ? null : out;
  }
}

/// 依次尝试多个翻译器：前一个失败自动落到下一个。
/// 全失败时抛最后一个错误，调用方照旧当“翻译失败”处理。
class ChainTranslator implements LiveSubtitleTranslator {
  ChainTranslator(this._translators);

  final List<LiveSubtitleTranslator> _translators;

  @override
  Future<String?> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    Object? lastError;
    for (final t in _translators) {
      try {
        final r = await t.translate(text, source: source, target: target);
        if (r != null && r.trim().isNotEmpty) return r;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) {
      throw LiveSubtitleTranslationException('所有翻译通道均失败：$lastError');
    }
    return null;
  }
}
