import 'package:flutter/foundation.dart';

class AudioContinue {
  static final ValueNotifier<bool> playing = ValueNotifier<bool>(true);
  static final ValueNotifier<String> title = ValueNotifier<String>('');
  static final ValueNotifier<String> episode = ValueNotifier<String>('');

  static void show({required String title, required String episode}) {
    AudioContinue.title.value = title;
    AudioContinue.episode.value = episode;
    AudioContinue.playing.value = true;
  }

  static void hide() {
    title.value = '';
    episode.value = '';
  }
}
