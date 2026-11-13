# 网页爬取源码移植说明（NexHub → 魔蚁）

## 出处

- 来源仓库：https://github.com/nexhub-app/NexHub
- 提交：37ddbdd（2026-11-12 拉取的浅克隆 `~/workspace/nexhub_ref/`，只读参考）
- 许可证：Apache-2.0（仓库内 LICENSE / NOTICE 为准；本目录文件头均注出处）
- 移植日期：2026-11-12；移植范围：NexHub `lib/core/scraper/`、`lib/core/resolver/`、
  `lib/core/network/` 三组 + 闭包必需的 `lib/core/utils/` 两个文件。

## 分级结果

### 原文复制（仅加出处注，逻辑未改）

- `scraper/verification_detector.dart`（验证特征判定 + 三个异常类）
- `resolver/parse_diagnostics.dart`、`resolver/m3u8_parser.dart`、
  `resolver/m3u8_ad_filter.dart`、`resolver/video_extractor.dart`、
  `resolver/image_extractor.dart`
- `network/model/` 全部 4 个文件（network_config / network_validators /
  source_network_config / effective_network_profile）
- `network/runtime/dns_resolver.dart`、`host_order_relay.dart`、
  `network_client_builder.dart`、`sni_policy.dart`、`webview_proxy_rule.dart`、
  `nexhub_http_overrides.dart`
- `utils/json_path.dart`

### 改编（缺失依赖，见各文件头“魔蚁改编”注）

- `scraper/cookie_store.dart`：Hive → SharedPreferences，API 与 TTL 语义不变。
- `scraper/web_scrape_service.dart`：抓取改走魔蚁 ContentHttp.getRaw + 解码；
  验证判定改走随本批移植的 VerificationDetector，契约（抛
  VerificationRequiredException）不变。
- `utils/html_utils.dart`：无 xpath 引擎，XPath 分支抛 UnsupportedError；
  CSS 路径原文保留。
- `network/network_config_service.dart`：代理密码改存 SharedPreferences
  （安全性降级，原文存系统钥匙串）；不再重建 HttpFetcher 连接池；
  effectiveFor 入参由 PluginConfig 改为 sourceId + fileOverride。
- `network/source_network_override_store.dart`：Hive → SharedPreferences。
- `network/runtime/system_proxy_resolver.dart`：AppLog 日志改 debugPrint。

### 未移植（缺失依赖/模型，如实记录，不编假接口）

- `scraper/http_fetcher.dart`：dio + fast_gbk + 平台/配置服务；魔蚁已有
  ContentHttp 覆盖抓取（代理/超时/GBK），不重复造轮子。
- `scraper/browser_faithful_adapter.dart`：dio。
- `scraper/silent_html_capture.dart`：flutter_inappwebview；魔蚁用
  webview_flutter 且已有 SniffWebViewPage 嗅探页。
- `scraper/collect_api_parser.dart`、`scraper/media_api_service.dart`、
  `scraper/publish_page_mirror_extractor.dart`、
  `scraper/verification_navigator.dart`：依赖 NexHub 源规则模型
  （plugin_config / media_item / episode / category_entry）与配置加载器，
  移植等于搬入整套源规则系统，超出本批范围。
- `resolver/source_resolver.dart`、`resolver/builtin_resolver.dart`、
  `resolver/script_resolver.dart`、`resolver/webview_resolver.dart`、
  `resolver/resolver_registry.dart`、`resolver/video_source_cache.dart`、
  `resolver/js_context.dart`：同上，另加 flutter_js（QuickJS）引擎依赖；
  魔蚁已有 py/jar/Go 核三条蜘蛛链路。
- `network/dio_image_file_service.dart`：flutter_cache_manager + 图片解密注册表。
- `network/runtime/webview_source_network.dart`：flutter_inappwebview +
  源规则模型 + 平台服务。

## 已知限制（上游原文行为，移植未改）

- `M3u8AdFilter.filter`：`#EXT-X-KEY` 行只随其所在分片组保留；位于第一个
  分片之前的头部 KEY 行会被丢弃（`_writeHeader` 只保留
  TARGETDURATION/VERSION/MEDIA-SEQUENCE/PLAYLIST-TYPE）。加密清单调用前须
  自行处理 KEY 行，不可直接用本过滤器。
- `HtmlUtils`：XPath 选择器抛 `UnsupportedError`（见上文改编说明）。
- `NetworkConfigService`：代理密码存 SharedPreferences（非钥匙串）。

## 接线状态

- 已接通：`WebScrapeService`（走 ContentHttp）与网址探站
  （`lib/url_site_probe.dart`）→ 网页爬取分析（`lib/web_scrape_analyzer.dart`）
  → 网页爬取页（`lib/web_scrape_page.dart`，首页搜索行地球图标进入）。
- 独立服务（已移植、可调用、未接入主链路）：`CookieStore`、
  `NetworkConfigService`、`SourceNetworkOverrideStore`、`NexHubHttpOverrides`
  （未安装为全局 HttpOverrides，魔蚁代理走 ProxyKernelTraffic）、
  `DnsResolver`、`NetworkClientBuilder`、`SniPolicy`、`HostOrderRelay`、
  `SystemProxyResolver`、m3u8 解析/去广告、`VideoExtractor`、`ImageExtractor`、
  `JsonPath`（utils/json_path.dart）、`HtmlUtils`、`VerificationDetector`。
- 界面中不出现 NexHub 品牌字样；代码内类名保留原文（如 NexHubHttpOverrides）
  以便与上游对照，出处见各文件头。
