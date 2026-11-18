import 'dart:io';

import 'nexhub_scraper/network/model/network_config.dart';

/// DNS 设置的纯逻辑：输入解析、校验、展示文案。
///
/// 与界面分离，供单测直接覆盖；不读偏好、不碰网络。
/// 偏好本体走 [NetworkConfigService] 的 `network_config_v1`（DnsConfig 藏在
/// NetworkConfig.dns 里），本文件只负责“用户填的字 → DnsConfig”这一段。

/// DoH 地址输入框的占位示例（只作提示，永不作为默认值写进配置）。
const dnsDohHint = 'https://dns.google/dns-query';

/// 自定义 UDP 服务器输入框的占位示例（只作提示，永不写进配置）。
const dnsServersHint = '8.8.8.8, 1.1.1.1';

/// DoT 主机输入框的占位示例（只作提示，永不写进配置）。
const dnsDotHostHint = 'dns.google';

/// DNS 测试默认查的主机（只用来看“解析走了哪条路、返回什么地址”）。
const dnsTestDefaultHost = 'www.cloudflare.com';

/// 模式中文名。
String dnsModeLabel(DnsMode mode) => switch (mode) {
  DnsMode.system => '系统 DNS',
  DnsMode.custom => '自定义 DNS',
  DnsMode.doh => 'DoH（加密 DNS）',
  DnsMode.dot => 'DoT（加密 DNS）',
};

/// 设置列表里 DNS 一项的副标题：一行说清当前生效的配置。
String dnsSummary(DnsConfig cfg) {
  switch (cfg.mode) {
    case DnsMode.system:
      return '系统 DNS';
    case DnsMode.custom:
      return cfg.servers.isEmpty
          ? '自定义 DNS · 未填服务器'
          : '自定义 DNS · ${cfg.servers.join(', ')}';
    case DnsMode.doh:
      return cfg.dohUrl.isEmpty ? 'DoH · 未填地址' : 'DoH · ${_hostOf(cfg.dohUrl)}';
    case DnsMode.dot:
      return cfg.dotHost.isEmpty
          ? 'DoT · 未填服务器'
          : 'DoT · ${cfg.dotHost}:${cfg.dotPort}';
  }
}

String _hostOf(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host ?? '';
  return host.isEmpty ? url : host;
}

/// 解析自定义 UDP 服务器输入：逗号 / 分号 / 空白 / 换行分隔，只留合法 IP，
/// 去重保序。返回空表示一个合法的都没填。
List<String> parseDnsServers(String input) {
  final out = <String>[];
  for (final part in input.split(RegExp(r'[\s,;]+'))) {
    final token = part.trim();
    if (token.isEmpty) continue;
    if (InternetAddress.tryParse(token) == null) continue;
    if (!out.contains(token)) out.add(token);
  }
  return out;
}

/// 校验 DoH 地址：须是带主机的 http/https 绝对地址。返回 null 表示合法，
/// 否则返回中文错误原因。
String? validateDohUrl(String input) {
  final url = input.trim();
  if (url.isEmpty) return '请填写 DoH 地址';
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'DoH 地址格式不对，应为 https:// 开头的完整地址';
  }
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    return 'DoH 地址须以 https:// 或 http:// 开头';
  }
  return null;
}

/// 解析 DoT 主机输入：允许 `主机` 或 `主机:端口` 两种写法，端口缺省 853。
/// 校验失败返回中文错误原因；成功返回 (host, port)。
(String, int)? parseDotServer(String input, {int defaultPort = 853}) {
  final text = input.trim();
  if (text.isEmpty) return null;
  var host = text;
  var port = defaultPort;
  // IPv6 字面量带方括号时不按冒号切端口。
  final bracketed = text.startsWith('[');
  final colon = text.lastIndexOf(':');
  if (!bracketed && colon > 0) {
    host = text.substring(0, colon).trim();
    final portText = text.substring(colon + 1).trim();
    final parsed = int.tryParse(portText);
    if (parsed == null || parsed < 1 || parsed > 65535) return null;
    port = parsed;
  }
  if (host.isEmpty) return null;
  if (host.contains('/') || host.contains('?') || host.contains('#')) {
    return null;
  }
  return (host, port);
}

/// 按界面输入拼出新的 [DnsConfig]：只改用户正在编辑的模式相关字段，
/// 其余字段（缓存开关、解析后缀等）沿用旧配置，避免界面把别的配置洗掉。
DnsConfig buildDnsConfig({
  required DnsConfig previous,
  required DnsMode mode,
  required String serversInput,
  required String dohUrlInput,
  required String dotHostInput,
  required String dotPortInput,
}) {
  switch (mode) {
    case DnsMode.system:
      return previous.copyWith(mode: DnsMode.system);
    case DnsMode.custom:
      return previous.copyWith(
        mode: DnsMode.custom,
        servers: parseDnsServers(serversInput),
      );
    case DnsMode.doh:
      return previous.copyWith(
        mode: DnsMode.doh,
        dohUrl: dohUrlInput.trim(),
      );
    case DnsMode.dot:
      final host = dotHostInput.trim();
      final port =
          int.tryParse(dotPortInput.trim()) ?? previous.dotPort;
      final sanePort = port >= 1 && port <= 65535 ? port : 853;
      return previous.copyWith(
        mode: DnsMode.dot,
        dotHost: host,
        dotPort: sanePort,
      );
  }
}

/// 当前模式的输入是否完整到可以保存：缺服务器/地址时不许保存，
/// 免得一个空配置把解析路切到注定失败的模式上（解析器遇到空配置会
/// 回退系统解析，但界面上不应放行这种半吊子配置）。
String? validateDnsInput({
  required DnsMode mode,
  required String serversInput,
  required String dohUrlInput,
  required String dotHostInput,
  required String dotPortInput,
}) {
  switch (mode) {
    case DnsMode.system:
      return null;
    case DnsMode.custom:
      if (parseDnsServers(serversInput).isEmpty) {
        return '请填写至少一个 DNS 服务器 IP，多个用逗号隔开';
      }
      return null;
    case DnsMode.doh:
      return validateDohUrl(dohUrlInput);
    case DnsMode.dot:
      final host = dotHostInput.trim();
      if (host.isEmpty) return '请填写 DoT 服务器主机';
      final portText = dotPortInput.trim();
      if (portText.isNotEmpty) {
        final port = int.tryParse(portText);
        if (port == null || port < 1 || port > 65535) {
          return 'DoT 端口须为 1–65535 的数字';
        }
      }
      return null;
  }
}
