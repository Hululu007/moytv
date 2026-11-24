import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_subtitle_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认设置：总开关关、自动检测、tiny、仅 Wi-Fi 下载', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final loaded = await LiveSubtitleSettings.load(prefs);
    expect(loaded.enabled, isFalse);
    expect(loaded.sourceLanguage, 'auto');
    expect(loaded.modelId, 'tiny');
    expect(loaded.wifiOnlyDownload, isTrue);
    expect(loaded.modelMirrorUrl, '');
    expect(loaded.whisperLanguageCode, 'auto');
  });

  test('保存后再读回：每一项都原样', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const settings = LiveSubtitleSettings(
      enabled: true,
      sourceLanguage: 'ja',
      modelId: 'base',
      wifiOnlyDownload: false,
      modelMirrorUrl: 'https://mirror.example/models/',
    );
    await settings.save(prefs);
    final loaded = await LiveSubtitleSettings.load(prefs);
    expect(loaded.enabled, isTrue);
    expect(loaded.sourceLanguage, 'ja');
    expect(loaded.modelId, 'base');
    expect(loaded.wifiOnlyDownload, isFalse);
    expect(loaded.modelMirrorUrl, 'https://mirror.example/models/');
  });

  test('模型选项：byId 找不到回落 tiny，大小标签正确', () {
    expect(LiveSubtitleModelOption.byId('nope').id, 'tiny');
    expect(LiveSubtitleModelOption.byId('base').fileName, 'ggml-base.bin');
    expect(LiveSubtitleModelOption.byId('tiny').sizeLabel, '约 74 MB');
    expect(LiveSubtitleModelOption.byId('base').sizeLabel, '约 141 MB');
  });

  test('源语言选项：labelOf 找不到回落自动检测', () {
    expect(LiveSubtitleLanguageOption.labelOf('ja'), '日语');
    expect(LiveSubtitleLanguageOption.labelOf('xx'), '自动检测');
  });
}
