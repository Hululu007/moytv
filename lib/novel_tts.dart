import 'package:flutter_tts/flutter_tts.dart';

abstract class NovelTtsEngine {
  Future<void> setLanguage(String language);
  Future<void> setRate(double rate);

  /// 手机里有没有可用的中文语音。
  ///
  /// 返回 false 只在“明确查到没有”时（装机检查否 + 语言列表里
  /// 也没有中文）；查不到/查出错时返回 true（放行去试，失败再
  /// 由 speak 的抛错/错误回调明说），避免误判拦住能用的手机。
  Future<bool> hasChineseVoice();

  /// 朗读一段文本；读完调 [onComplete]，引擎报错调 [onError]。
  /// 平台明确返回失败时抛错，调用方不要静默吞掉。
  Future<void> speak(
    String text,
    void Function() onComplete, {
    void Function()? onError,
  });
  Future<void> stop();
}

class FlutterTtsNovelTtsEngine implements NovelTtsEngine {
  final FlutterTts _tts = FlutterTts();
  int _generation = 0;

  @override
  Future<void> setLanguage(String language) async {
    await _tts.setLanguage(language);
  }

  @override
  Future<void> setRate(double rate) async {
    await _tts.setSpeechRate(rate);
  }

  @override
  Future<bool> hasChineseVoice() async {
    var installedChecked = false;
    try {
      final installed = await _tts.isLanguageInstalled('zh-CN');
      installedChecked = installed == false;
      if (installed == true) return true;
    } catch (_) {}
    try {
      final languages = await _tts.getLanguages;
      if (languages is Iterable) {
        var sawAny = false;
        for (final language in languages) {
          sawAny = true;
          final normalized = '$language'.toLowerCase().replaceAll('_', '-');
          if (normalized == 'zh-cn' ||
              normalized == 'zh-hans' ||
              normalized == 'zh') {
            return true;
          }
        }
        // 装机检查明确否、且语言列表非空又无中文：明确没有。
        if (installedChecked && sawAny) return false;
      }
    } catch (_) {}
    // 查不到：放行，speak 失败时再明说。
    return true;
  }

  @override
  Future<void> speak(
    String text,
    void Function() onComplete, {
    void Function()? onError,
  }) async {
    final generation = ++_generation;
    _tts.setCompletionHandler(() {
      if (generation == _generation) onComplete();
    });
    _tts.setErrorHandler((_) {
      if (generation == _generation) onError?.call();
    });
    // 先把上一条残留清掉：有的引擎在队列未清空时再 speak 会直接返回 0，
    // 表现就是“点了朗读没声音”。
    try {
      await _tts.stop();
    } catch (_) {}
    var result = await _tts.speak(text);
    if (result == 0 || result == false) {
      // 部分机型第一次调用必返 0（引擎冷启动），重试一次就正常。
      try {
        await _tts.stop();
      } catch (_) {}
      result = await _tts.speak(text);
    }
    if (result == 0 || result == false) {
      throw StateError('flutter_tts speak 失败（平台返回 $result）');
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _tts.stop();
  }
}

List<String> splitTtsText(String text, [int maxLength = 1500]) {
  final chunks = <String>[];
  var current = StringBuffer();
  void flush() {
    final value = current.toString().trim();
    if (value.isNotEmpty) chunks.add(value);
    current = StringBuffer();
  }

  for (final paragraph in text.split('\n')) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) continue;
    if (current.length + trimmed.length + 1 > maxLength) flush();
    if (trimmed.length > maxLength) {
      for (var i = 0; i < trimmed.length; i += maxLength) {
        final end = (i + maxLength).clamp(0, trimmed.length);
        chunks.add(trimmed.substring(i, end));
      }
      continue;
    }
    if (current.isNotEmpty) current.writeln();
    current.write(trimmed);
  }
  flush();
  return chunks.isEmpty ? const [''] : chunks;
}
