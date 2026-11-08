import 'package:flutter_tts/flutter_tts.dart';

abstract class NovelTtsEngine {
  Future<void> setLanguage(String language);
  Future<void> setRate(double rate);
  Future<void> speak(String text, void Function() onComplete);
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
  Future<void> speak(String text, void Function() onComplete) async {
    final generation = ++_generation;
    _tts.setCompletionHandler(() {
      if (generation == _generation) onComplete();
    });
    await _tts.speak(text);
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
