import 'models.dart';

/// 网络与资源设置：目录请求并发/间隔与下载并发/分源。
/// 应用内代理机件已删（2026-11-17），不再有代理模式与代理地址；
/// 网络一律直连，手机系统 VPN 在系统层生效。
class ResourceSettings {
  const ResourceSettings({
    this.catalogConcurrency = 3,
    this.catalogIntervalMs = 250,
    this.downloadConcurrency = 2,
    this.downloadBySource = false,
    this.warning = '',
  });
  final String warning;
  final int catalogConcurrency, catalogIntervalMs, downloadConcurrency;
  final bool downloadBySource;

  factory ResourceSettings.fromJson(Map<String, dynamic> data) =>
      ResourceSettings(
        catalogConcurrency: intValue(data['catalogConcurrency']),
        catalogIntervalMs: intValue(data['catalogIntervalMs']),
        downloadConcurrency: intValue(data['downloadConcurrency']),
        downloadBySource: data['downloadBySource'] == true,
        warning: data['warning'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'catalogConcurrency': catalogConcurrency,
    'catalogIntervalMs': catalogIntervalMs,
    'downloadConcurrency': downloadConcurrency,
    'downloadBySource': downloadBySource,
  };
}
