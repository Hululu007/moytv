import 'package:shared_preferences/shared_preferences.dart';

class MiniAppSettings {
  const MiniAppSettings({
    this.basePort = 7810,
    this.maxBackground = 3,
    this.adFilter = true,
    this.hybridComposition = true,
    this.lanShare = false,
    this.marketUrl = MiniAppSettings.defaultMarketUrl,
  });

  static const String defaultMarketUrl =
      'https://ghfast.top/https://raw.githubusercontent.com/ant-video/ant-video/refs/heads/main/mini-app/market/market.json';

  static const String keyBasePort = 'moyi_miniapp_base_port';
  static const String keyMaxBackground = 'moyi_miniapp_max_background';
  static const String keyAdFilter = 'moyi_miniapp_ad_filter';
  static const String keyHybridComposition =
      'moyi_miniapp_hybrid_composition';
  static const String keyLanShare = 'moyi_miniapp_lan_share';
  static const String keyMarketUrl = 'moyi_miniapp_market_url';

  final int basePort;
  final int maxBackground;
  final bool adFilter;
  final bool hybridComposition;
  final bool lanShare;
  final String marketUrl;

  static int clampPort(int value) => value.clamp(1024, 65535);

  static int clampMaxBackground(int value) => value.clamp(1, 10);

  MiniAppSettings copyWith({
    int? basePort,
    int? maxBackground,
    bool? adFilter,
    bool? hybridComposition,
    bool? lanShare,
    String? marketUrl,
  }) {
    return MiniAppSettings(
      basePort: basePort == null
          ? this.basePort
          : clampPort(basePort),
      maxBackground: maxBackground == null
          ? this.maxBackground
          : clampMaxBackground(maxBackground),
      adFilter: adFilter ?? this.adFilter,
      hybridComposition: hybridComposition ?? this.hybridComposition,
      lanShare: lanShare ?? this.lanShare,
      marketUrl: marketUrl ?? this.marketUrl,
    );
  }

  static Future<MiniAppSettings> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    final rawUrl = store.getString(keyMarketUrl);
    return MiniAppSettings(
      basePort: clampPort(store.getInt(keyBasePort) ?? 7810),
      maxBackground: clampMaxBackground(
        store.getInt(keyMaxBackground) ?? 3,
      ),
      adFilter: store.getBool(keyAdFilter) ?? true,
      hybridComposition: store.getBool(keyHybridComposition) ?? true,
      lanShare: store.getBool(keyLanShare) ?? false,
      marketUrl: (rawUrl == null || rawUrl.isEmpty)
          ? defaultMarketUrl
          : rawUrl,
    );
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setInt(keyBasePort, basePort);
    await store.setInt(keyMaxBackground, maxBackground);
    await store.setBool(keyAdFilter, adFilter);
    await store.setBool(keyHybridComposition, hybridComposition);
    await store.setBool(keyLanShare, lanShare);
    await store.setString(keyMarketUrl, marketUrl);
  }
}
