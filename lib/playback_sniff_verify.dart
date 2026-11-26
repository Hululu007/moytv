import 'dart:async';
import 'dart:io';

/// 嗅探兜底的统一时限：主播放器、西瓜播放器、小程序宿主三处
/// 共用。超时仍没拿到验活的地址，按「无法获取播放链接」收口，
/// 不让嗅探无限挂着。
const sniffFallbackTimeout = Duration(seconds: 45);

/// 与 content_http.contentUserAgent 同值的默认 UA（此处自带一份，
/// 避免为一句常量引入整条内容层导入链）。
const _sniffProbeUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

/// 轻验探针响应：状态码 + 响应头（键已转小写）+ 首段字节。
class SniffProbeResponse {
  const SniffProbeResponse({
    required this.statusCode,
    required this.headers,
    required this.headBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> headBytes;
}

/// 轻验探针取数：供测试注入假实现。
typedef SniffProbeFetch =
    Future<SniffProbeResponse> Function(
      String url,
      Map<String, String> headers,
      Duration timeout,
    );

/// 默认探针：HttpClient GET + Range bytes=0-2047，只读首个数据块
/// 就取消（大文件不整段下载）。判定口径与 feed_playability 的
/// 验播探针一致，两处独立实现、规则同步修改。
Future<SniffProbeResponse> probeSniffHead(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const FormatException('验活地址无效');
  }
  final client = HttpClient()..connectionTimeout = timeout;
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
      request.headers.set(HttpHeaders.userAgentHeader, _sniffProbeUserAgent);
    }
    final response = await request.close().timeout(timeout);
    final head = await _firstChunk(response, timeout);
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      }
    });
    return SniffProbeResponse(
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

/// 轻验判定：m3u8 须 2xx 且首段含 #EXTM3U；直链须 206，或 200
/// 且非 HTML 错误页。其它一律验死。
bool sniffProbePlayable(Uri uri, SniffProbeResponse response) {
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
    return response.headBytes.isNotEmpty && !contentType.contains('text/html');
  }
  return false;
}

/// 验一个嗅探候选：任何异常/超时都记验死，绝不抛错。
Future<bool> verifySniffedCandidate(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 6),
  SniffProbeFetch fetchHead = probeSniffHead,
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return false;
  }
  try {
    final response = await fetchHead(url, headers, timeout);
    return sniffProbePlayable(uri, response);
  } catch (_) {
    return false;
  }
}

/// 给 SniffWebViewPage.validateCandidate 用的闭包工厂：带上页面
/// 请求头（Referer/UA 等）去验，验法与递给播放器时一致。
Future<bool> Function(String) sniffCandidateValidator({
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 6),
}) {
  return (url) =>
      verifySniffedCandidate(url, headers: headers, timeout: timeout);
}
