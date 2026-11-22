import 'dart:async';
import 'dart:convert';

import 'feed_playability.dart';
import 'live_models.dart';

/// 一次直播列表体检的结果：总数、留下的、删掉的、分类数。
class LiveRepairReport {
  const LiveRepairReport({
    required this.total,
    required this.alive,
    required this.removed,
    required this.unknown,
    required this.groups,
    this.cancelled = false,
  });

  final int total;
  final int alive;
  final int removed;

  /// 不确定的（401/403/超时之类，可能是防盗链或临时故障）：一律保留，
  /// 不拿它当死链删，免得把能播的源误删。
  final int unknown;
  final int groups;
  final bool cancelled;

  String get summary =>
      '共 $total 个频道：可用 $alive'
      '${unknown > 0 ? '，待确认 $unknown' : ''}'
      '，删除 ${removed}';
}

/// 单个频道的验活结论。
enum LiveProbeVerdict { alive, dead, unknown }

/// 直播 m3u / txt 列表自愈：逐条验活，去掉确实打不开的频道，
/// 其余原样保留（含线路、分类、台标、请求头）。
class LiveM3uRepair {
  LiveM3uRepair._();

  static const defaultConcurrency = 8;
  static const defaultTimeout = Duration(seconds: 6);

  /// 一条线路的验活：拿到 2xx/3xx 算活；401/403、5xx、超时算“不确定”；
  /// 404/410、域名解析不了、连接被拒算死。
  static Future<LiveProbeVerdict> probeUrl(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = defaultTimeout,
  }) async {
    final target = url.trim();
    if (target.isEmpty) return LiveProbeVerdict.dead;
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return LiveProbeVerdict.dead;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      // rtsp/rtmp/udp 这些播放器能放、HTTP 探针测不了：不删。
      return LiveProbeVerdict.unknown;
    }
    try {
      final response = await probeStreamHead(target, headers, timeout);
      final code = response.statusCode;
      if (code >= 200 && code < 400) return LiveProbeVerdict.alive;
      if (code == 404 || code == 410) return LiveProbeVerdict.dead;
      return LiveProbeVerdict.unknown;
    } on AppFailure {
      return LiveProbeVerdict.dead;
    } catch (error) {
      final text = error.toString().toLowerCase();
      if (text.contains('not found') ||
          text.contains('failed host lookup') ||
          text.contains('connection refused') ||
          text.contains('network is unreachable') ||
          text.contains('no address associated')) {
        return LiveProbeVerdict.dead;
      }
      // 其余（超时、TLS 握手失败、对端重置）一律当不确定，保留。
      return LiveProbeVerdict.unknown;
    }
  }

  /// 一个频道：任一线路活着就算活；全死才删。
  static Future<LiveProbeVerdict> probeChannel(
    LiveChannel channel, {
    Duration timeout = defaultTimeout,
  }) async {
    if (channel.urls.isEmpty) return LiveProbeVerdict.dead;
    var sawUnknown = false;
    for (final url in channel.urls) {
      final verdict = await probeUrl(
        url,
        headers: channel.headers,
        timeout: timeout,
      );
      if (verdict == LiveProbeVerdict.alive) return LiveProbeVerdict.alive;
      if (verdict == LiveProbeVerdict.unknown) sawUnknown = true;
    }
    return sawUnknown ? LiveProbeVerdict.unknown : LiveProbeVerdict.dead;
  }

  /// 体检整份列表，返回「留下的频道」和统计。
  static Future<(List<LiveChannel>, LiveRepairReport)> clean(
    List<LiveChannel> channels, {
    int concurrency = defaultConcurrency,
    Duration timeout = defaultTimeout,
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final total = channels.length;
    final verdicts = List<LiveProbeVerdict?>.filled(total, null);
    var done = 0;
    var index = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelled?.call() ?? false) return;
        final i = index;
        if (i >= total) return;
        index = i + 1;
        verdicts[i] = await probeChannel(channels[i], timeout: timeout);
        done++;
        onProgress?.call(done, total);
      }
    }

    final workers = concurrency.clamp(1, 32);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    final kept = <LiveChannel>[];
    var alive = 0;
    var dead = 0;
    var unknown = 0;
    for (var i = 0; i < total; i++) {
      final verdict = verdicts[i];
      if (verdict == LiveProbeVerdict.dead) {
        dead++;
        continue;
      }
      if (verdict == LiveProbeVerdict.unknown || verdict == null) {
        unknown++;
      } else {
        alive++;
      }
      kept.add(channels[i]);
    }
    final groups = <String>{for (final c in kept) c.group}.length;
    return (
      kept,
      LiveRepairReport(
        total: total,
        alive: alive,
        removed: dead,
        unknown: unknown,
        groups: groups,
        cancelled: cancelled?.call() ?? false,
      ),
    );
  }

  /// 把频道表重新写成标准 m3u8 文本（保留分类、台标、台号、线路与请求头）。
  static String toM3uText(List<LiveChannel> channels) {
    final buffer = StringBuffer('#EXTM3U\n');
    for (final channel in channels) {
      final url = channel.urls.firstWhere(
        (item) => item.trim().isNotEmpty,
        orElse: () => '',
      );
      if (url.isEmpty) continue;
      final attrs = <String>[
        if (channel.tvgId.isNotEmpty) 'tvg-id="${_escape(channel.tvgId)}"',
        'tvg-name="${_escape(channel.name)}"',
        if (channel.logo.isNotEmpty) 'tvg-logo="${_escape(channel.logo)}"',
        if (channel.group.isNotEmpty)
          'group-title="${_escape(channel.group)}"',
        if (channel.number.isNotEmpty) 'tvg-chno="${_escape(channel.number)}"',
        if (channel.headers.isNotEmpty)
          'http-header="${_escape(jsonEncode(channel.headers))}"',
      ];
      buffer
        ..write('#EXTINF:-1 ')
        ..write(attrs.join(' '))
        ..write(',')
        ..write(channel.name)
        ..write('\n')
        ..write(url)
        ..write('\n');
    }
    return buffer.toString();
  }

  static String _escape(String value) =>
      value.replaceAll('"', "'").replaceAll('\n', ' ').replaceAll('\r', ' ');
}
