import 'dart:async';
import 'dart:io';

import 'content_http.dart';
import 'core_bridge.dart';
import 'models.dart';
import 'proxy_kernel_service.dart';

/// 全屏流成人条目验播：取流并验真后才放进流里。
///
/// 只有取流成功且流地址验真（m3u8 拉到清单、直链 Range 206/200）
/// 的条目才进推荐混排与成人频道；验不过的直接排除，一个都验
/// 不过时调用方显示诚实空态（推荐频道只剩基础位），绝不硬塞
/// 不可播的条目。验播失败绝不抛错，一律记为不可播。
///
/// 性能口径：单条总预算 [itemTimeout]（取流 + 验真共用），并发
/// 上限 [concurrency]，整批预算 [batchBudget]（到期后未开始的
/// 不再起探，直接排除）；结果会话内缓存（[FeedPlayabilityVerifier]
/// 实例随戏剧首页 state 存活），同一条目一会话内只验一次。

/// 验播探针响应：状态码 + 响应头 + 响应体首段字节（最多 2KB）。
class FeedProbeResponse {
  const FeedProbeResponse({
    required this.statusCode,
    required this.headers,
    required this.headBytes,
  });

  final int statusCode;

  /// 响应头，键已转小写。
  final Map<String, String> headers;
  final List<int> headBytes;
}

/// 验播探针：取 [url] 的首段字节（Range），供测试注入假实现。
typedef FeedProbeFetch =
    Future<FeedProbeResponse> Function(
      String url,
      Map<String, String> headers,
      Duration timeout,
    );

/// 默认探针：HttpClient GET + Range bytes=0-2047，只读首个数据块
/// 就取消订阅（直链大文件不会整段下载），走代理内核的 findProxy。
Future<FeedProbeResponse> probeStreamHead(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw AppFailure('验播地址无效');
  }
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ProxyKernelTraffic.findProxy;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = true;
    request.maxRedirects = 5;
    headers.forEach((key, value) {
      if (value.isEmpty) return;
      request.headers.set(key, value);
    });
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
    if (request.headers.value(HttpHeaders.userAgentHeader) == null) {
      request.headers.set(HttpHeaders.userAgentHeader, contentUserAgent);
    }
    final response = await request.close().timeout(timeout);
    final head = await _firstChunk(response, timeout);
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) responseHeaders[name.toLowerCase()] = values.join(', ');
    });
    return FeedProbeResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      headBytes: head,
    );
  } finally {
    client.close(force: true);
  }
}

Future<List<int>> _firstChunk(
  HttpClientResponse response,
  Duration timeout,
) async {
  final completer = Completer<List<int>>();
  late StreamSubscription<List<int>> subscription;
  subscription = response.listen(
    (chunk) {
      if (!completer.isCompleted) completer.complete(chunk);
      unawaited(subscription.cancel());
    },
    onError: (_) {
      if (!completer.isCompleted) completer.complete(const []);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(const []);
    },
    cancelOnError: true,
  );
  try {
    return await completer.future.timeout(timeout);
  } on TimeoutException {
    await subscription.cancel();
    return const [];
  }
}

/// 验播判定：m3u8 须 2xx 且首段含 #EXTM3U；直链须 206，或 200
/// 且非 HTML 错误页。其它状态一律不可播。
bool feedProbePlayable(Uri uri, FeedProbeResponse response) {
  final status = response.statusCode;
  final contentType = (response.headers['content-type'] ?? '').toLowerCase();
  final isManifest =
      uri.path.toLowerCase().endsWith('.m3u8') ||
      contentType.contains('mpegurl');
  if (isManifest) {
    if (status < 200 || status >= 300) return false;
    return String.fromCharCodes(response.headBytes).contains('#EXTM3U');
  }
  if (status == 206) return true;
  if (status == 200) {
    return response.headBytes.isNotEmpty &&
        !contentType.contains('text/html');
  }
  return false;
}

class FeedPlayabilityVerifier {
  FeedPlayabilityVerifier({
    required this.detailOf,
    required this.resolveOf,
    this.fetchHead = probeStreamHead,
    this.concurrency = 4,
    this.itemTimeout = const Duration(seconds: 6),
    this.batchBudget = const Duration(seconds: 45),
  });

  /// 取详情：返回 null 或无选集即不可播。调用方可复用已有详情缓存。
  final Future<DramaDetail?> Function(Drama drama) detailOf;

  /// 取流：只验首集。
  final Future<PlaybackPlan> Function(Drama drama, Episode episode) resolveOf;

  final FeedProbeFetch fetchHead;
  final int concurrency;
  final Duration itemTimeout;
  final Duration batchBudget;

  /// 会话内缓存：条目键 → 是否可播（含失败结果）。
  final Map<String, bool> _cache = {};

  static String _key(Drama drama) => '${drama.source}|${drama.id}';

  /// 验一批：只返回验真的条目，原顺序保留；缓存命中不重探。
  /// 预算耗尽时未起探的条目直接排除，不阻塞调用方。
  Future<List<Drama>> verifyAll(List<Drama> candidates) async {
    final results = List<bool?>.filled(candidates.length, null);
    final pending = <int>[];
    for (var i = 0; i < candidates.length; i++) {
      final cached = _cache[_key(candidates[i])];
      if (cached != null) {
        results[i] = cached;
      } else {
        pending.add(i);
      }
    }
    if (pending.isEmpty) return _collect(candidates, results);
    final deadline = DateTime.now().add(batchBudget);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (next >= pending.length) return;
        if (DateTime.now().isAfter(deadline)) return;
        final index = pending[next++];
        results[index] = await verifyOne(candidates[index]);
      }
    }
    await Future.wait([
      for (var w = 0; w < concurrency; w++) worker(),
    ]);
    return _collect(candidates, results);
  }

  List<Drama> _collect(List<Drama> candidates, List<bool?> results) {
    final out = <Drama>[];
    for (var i = 0; i < candidates.length; i++) {
      if (results[i] == true) out.add(candidates[i]);
    }
    return out;
  }

  /// 验一条：缓存命中直接返回；否则取流验真，全程 [itemTimeout]
  /// 封顶，任何异常/超时都记不可播，绝不抛错。
  Future<bool> verifyOne(Drama drama) async {
    final key = _key(drama);
    final cached = _cache[key];
    if (cached != null) return cached;
    final ok = await _probe(
      drama,
    ).timeout(itemTimeout, onTimeout: () => false);
    _cache[key] = ok;
    return ok;
  }

  Future<bool> _probe(Drama drama) async {
    try {
      final detail = await detailOf(drama);
      if (detail == null || detail.episodes.isEmpty) return false;
      final plan = await resolveOf(drama, detail.episodes.first);
      if (plan.needsParse) return false;
      final url = plan.url.trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          uri.host.isEmpty) {
        return false;
      }
      final response = await fetchHead(url, plan.headers, itemTimeout);
      return feedProbePlayable(uri, response);
    } catch (_) {
      return false;
    }
  }
}
