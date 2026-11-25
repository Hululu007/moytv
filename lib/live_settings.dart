import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_playback.dart';

/// 直播设置：原直播页顶栏齿轮菜单里的三项（解码模式、睡眠定时、
/// 恢复默认）已按用户口径挪进软件主设置页的「直播设置」节，偏好
/// 落在这里：不可变模型 + `moyi_live_*` 键 + load/save，口径与
/// live_subtitle_settings.dart 一致。
///
/// 睡眠定时在这里存的是「默认时长」：0 = 关闭，其余是分钟数
/// （15/30/60/90，与原齿轮单打开的时长选项一致，原单不带
/// 「播完本集」）。直播播放控制器订阅 [LiveSettingsStore]，进直播
/// 时按默认时长给睡眠计时器起算，到点停播的运行时行为不变。
class LiveSettings {
  const LiveSettings({
    this.decoderMode = LiveDecoderMode.auto,
    this.sleepMinutes = 0,
  });

  static const String keyDecoderMode = 'moyi_live_decoder_mode';
  static const String keySleepMinutes = 'moyi_live_sleep_minutes';

  /// 睡眠定时可选项（分钟）：0 关闭，其余与原时长单一致。
  static const List<int> sleepChoices = [0, 15, 30, 60, 90];

  final LiveDecoderMode decoderMode;

  /// 睡眠定时默认时长（分钟），0 = 关闭。
  final int sleepMinutes;

  String get sleepLabel => sleepMinutes <= 0 ? '关闭' : '$sleepMinutes 分钟';

  bool get isDefault =>
      decoderMode == LiveDecoderMode.auto && sleepMinutes == 0;

  LiveSettings copyWith({LiveDecoderMode? decoderMode, int? sleepMinutes}) =>
      LiveSettings(
        decoderMode: decoderMode ?? this.decoderMode,
        sleepMinutes: sleepMinutes ?? this.sleepMinutes,
      );

  static Future<LiveSettings> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    final mode =
        LiveDecoderMode.values.asNameMap()[store.getString(keyDecoderMode)] ??
        LiveDecoderMode.auto;
    final minutes = store.getInt(keySleepMinutes) ?? 0;
    return LiveSettings(
      decoderMode: mode,
      sleepMinutes: sleepChoices.contains(minutes) ? minutes : 0,
    );
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setString(keyDecoderMode, decoderMode.name);
    await store.setInt(keySleepMinutes, sleepMinutes);
  }
}

/// 直播设置的全局一份：设置页写、直播播放控制器读并订阅，
/// 两边永远看同一份值——设置页改了解码模式，正在跑的直播
/// 控制器收到通知立刻应用（切模式并重播当前频道），不是摆样子。
class LiveSettingsStore extends ChangeNotifier {
  LiveSettingsStore._();

  static final LiveSettingsStore instance = LiveSettingsStore._();

  LiveSettings _settings = const LiveSettings();
  bool _loaded = false;
  bool _loading = false;

  LiveSettings get settings => _settings;
  bool get loaded => _loaded;

  /// 首次访问时从 SharedPreferences 读回；读失败不抛，用默认值
  /// 顶着，下次再试，不让设置链断掉。
  Future<void> ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      _settings = await LiveSettings.load();
      _loaded = true;
      notifyListeners();
    } catch (_) {
      // 保持默认值与未加载标记，后续访问可重试。
    } finally {
      _loading = false;
    }
  }

  Future<void> setDecoderMode(LiveDecoderMode mode) async {
    if (_settings.decoderMode == mode) return;
    _settings = _settings.copyWith(decoderMode: mode);
    notifyListeners();
    await _settings.save();
  }

  Future<void> setSleepMinutes(int minutes) async {
    final value = LiveSettings.sleepChoices.contains(minutes) ? minutes : 0;
    if (_settings.sleepMinutes == value) return;
    _settings = _settings.copyWith(sleepMinutes: value);
    notifyListeners();
    await _settings.save();
  }

  /// 恢复默认：解码回到自动、睡眠定时关闭。返回是否真的改动过，
  /// 调用方据此决定提示文案（与原齿轮单的恢复默认口径一致）。
  Future<bool> resetDefaults() async {
    if (_settings.isDefault) return false;
    _settings = const LiveSettings();
    notifyListeners();
    await _settings.save();
    return true;
  }

  @visibleForTesting
  void resetForTest() {
    _settings = const LiveSettings();
    _loaded = false;
    _loading = false;
  }
}
