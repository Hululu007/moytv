import 'package:shared_preferences/shared_preferences.dart';

class ViewingExperienceSettings {
  const ViewingExperienceSettings({
    this.immersive = true,
    this.detailPosterBackground = true,
    this.m3u8DownloadWhilePlaying = false,
    this.deepSniffer = true,
    this.autoRecordPlays = true,
  });

  static const String keyImmersive = 'moyi_viewing_immersive';
  static const String keyDetailPosterBackground =
      'moyi_viewing_detail_poster_background';
  static const String keyM3u8DownloadWhilePlaying =
      'moyi_viewing_m3u8_download_while_playing';
  static const String keyDeepSniffer = 'moyi_viewing_deep_sniffer';
  static const String keyAutoRecordPlays = 'moyi_viewing_auto_record_plays';

  final bool immersive;
  final bool detailPosterBackground;
  final bool m3u8DownloadWhilePlaying;
  final bool deepSniffer;

  /// 播起来后自动把能播的片记进内部工作库（.sql 导入落成的演员库）：
  /// 默认开（2026-11-24 用户令：该功能隐藏、默认开，取代 v62 的
  /// 默认关）；播不了的不写，开关关了也不写。2026-11-25 起不再写
  /// MYTV/db/站点库.db 那个文件（已删），改走新方法。
  final bool autoRecordPlays;

  bool get posterBackgroundActive => immersive && detailPosterBackground;

  ViewingExperienceSettings copyWith({
    bool? immersive,
    bool? detailPosterBackground,
    bool? m3u8DownloadWhilePlaying,
    bool? deepSniffer,
    bool? autoRecordPlays,
  }) => ViewingExperienceSettings(
    immersive: immersive ?? this.immersive,
    detailPosterBackground:
        detailPosterBackground ?? this.detailPosterBackground,
    m3u8DownloadWhilePlaying:
        m3u8DownloadWhilePlaying ?? this.m3u8DownloadWhilePlaying,
    deepSniffer: deepSniffer ?? this.deepSniffer,
    autoRecordPlays: autoRecordPlays ?? this.autoRecordPlays,
  );

  static Future<ViewingExperienceSettings> load([
    SharedPreferences? prefs,
  ]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    return ViewingExperienceSettings(
      immersive: store.getBool(keyImmersive) ?? true,
      detailPosterBackground: store.getBool(keyDetailPosterBackground) ?? true,
      m3u8DownloadWhilePlaying:
          store.getBool(keyM3u8DownloadWhilePlaying) ?? false,
      deepSniffer: store.getBool(keyDeepSniffer) ?? true,
      autoRecordPlays: store.getBool(keyAutoRecordPlays) ?? true,
    );
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setBool(keyImmersive, immersive);
    await store.setBool(keyDetailPosterBackground, detailPosterBackground);
    await store.setBool(keyM3u8DownloadWhilePlaying, m3u8DownloadWhilePlaying);
    await store.setBool(keyDeepSniffer, deepSniffer);
    await store.setBool(keyAutoRecordPlays, autoRecordPlays);
  }
}
