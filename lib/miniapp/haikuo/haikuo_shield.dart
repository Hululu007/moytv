/// 通用过盾（Cloudflare 人机验证）——不按站点写死，全站共用一套。
///
/// 为什么放在请求层而不是规则里：
/// 每个站的规则、选择器、加密各不一样，但「被盾挡住」这件事是同一件事。
/// 规则层只负责解析，取不到页面时不该由规则作者一站一份地写绕过逻辑。
/// 所以：请求层识别挑战 → 隐藏浏览器解一次 → 把通行证（cf_clearance 等）
/// 连同 UA 一起存进共用票池 → 之后所有同主机请求自动带上，秒回。
///
/// 这一层不认域名、不认站点名，只认 Cloudflare 的通用特征。
library;

/// 挑战判定结果。
class HaikuoShieldVerdict {
  const HaikuoShieldVerdict._(this.blocked, this.reason);

  /// 被盾挡住（需要解一次）。
  final bool blocked;

  /// 判定依据，只用于日志/调试，不影响业务。
  final String reason;

  static const pass = HaikuoShieldVerdict._(false, '');
  static const challenge = HaikuoShieldVerdict._(true, 'cf-mitigated');
  static const challengeBody = HaikuoShieldVerdict._(true, 'challenge-body');
}

/// 判定一次响应是不是「被盾挡住」，而不是站点真返回 403/503。
///
/// 只认通用特征，避免把正常的鉴权失败、下架、限流误判成挑战（误判会让
/// 每个 403 都去起一次浏览器，既慢又容易被站方判为异常）。
HaikuoShieldVerdict haikuoShieldCheck({
  required int status,
  required Map<String, List<String>> headers,
  required String body,
}) {
  // 1) CF 直接标注了本次响应是挑战（最可靠，不看正文）。
  for (final key in const ['cf-mitigated', 'cf-mitigated-type']) {
    final raw = headers[key];
    if (raw == null) continue;
    final value = raw.join(',').toLowerCase();
    if (value.contains('challenge') || value.contains('managed')) {
      return HaikuoShieldVerdict.challenge;
    }
  }
  // 2) 正文特征。只在 4xx/5xx 上看，2xx 的正文里出现这些词多半是
  //    站方自己的说明文字，不能动。
  if (status < 400) return HaikuoShieldVerdict.pass;
  final head = body.length > 32768 ? body.substring(0, 32768) : body;
  if (head.isEmpty) return HaikuoShieldVerdict.pass;
  final lower = head.toLowerCase();
  const markers = <String>[
    'just a moment',
    '/cdn-cgi/challenge-platform',
    'challenge-platform/h/',
    'cf-chl',
    '_cf_chl_opt',
    'verifying you are human',
    'checking your browser',
    'enable javascript and cookies to continue',
    'cf-browser-verification',
    // CDN 层的硬化拦截（不是挑战页，同样需要真实会话来过）：
    'cloudflare protection detected',
    'cf-error-details',
    'error 1020',
  ];
  for (final marker in markers) {
    if (lower.contains(marker)) return HaikuoShieldVerdict.challengeBody;
  }
  // 3) CF 的 JSON 错误体（如 1020 防火墙规则）也会给 challenge 提示。
  final server = headers['server']?.join(',').toLowerCase() ?? '';
  if (status == 503 && server.contains('cloudflare')) {
    return HaikuoShieldVerdict.challengeBody;
  }
  return HaikuoShieldVerdict.pass;
}

/// 直接从代理响应的统一结构里判定挑战，省得每个调用点各写一遍。
HaikuoShieldVerdict haikuoShieldVerdictOf(Map<String, dynamic> result) {
  final code = (result['code'] as num?)?.toInt() ?? 0;
  final body = '${result['body'] ?? ''}';
  final map = <String, List<String>>{};
  final raw = result['headers'];
  if (raw is Map) {
    raw.forEach((key, value) {
      map['$key'.toLowerCase()] =
          value is List ? [for (final e in value) '$e'] : ['$value'];
    });
  }
  return haikuoShieldCheck(status: code, headers: map, body: body);
}

/// 判断一个已拿到的页面正文是不是「真内容」（解盾成功），而不是
/// 还在挑战页上。同样只认通用特征。
bool haikuoShieldLooksSolved(String html) {
  if (html.isEmpty) return false;
  final lower = html.toLowerCase();
  const markers = <String>[
    '/cdn-cgi/challenge-platform',
    'just a moment',
    'verifying you are human',
    'checking your browser',
    'cf-browser-verification',
    '_cf_chl_opt',
  ];
  for (final marker in markers) {
    if (lower.contains(marker)) return false;
  }
  return html.length > 800;
}

/// 给隐藏浏览器用的「挑战已过」判定脚本（规则层不参与，通用）。
///
/// 判定口径：页面有真实内容、且不再出现任何挑战页特征。
/// 不用站点专属选择器——那样等于一站一份。
const String haikuoShieldPassJs = r'''(function(){
  try {
    var body = document.body;
    if (!body) { return false; }
    var text = (body.innerText || '') + '';
    if (text.length < 80) { return false; }
    if (/Just a moment|Verifying you are human|Checking your browser|Enable JavaScript and cookies|请稍候|正在验证|人机验证/i.test(text)) { return false; }
    if (document.querySelector('#challenge-form, .challenge-form, #challenge-error-text')) { return false; }
    return true;
  } catch (e) { return false; }
})()''';

/// 通行证票：一个主机解盾成功后拿到的 Cookie 串 + 解盾时的 UA。
///
/// UA 必须一起存：cf_clearance 是绑 UA 的，换了 UA 票据就作废。
class HaikuoShieldTicket {
  HaikuoShieldTicket({
    required this.cookie,
    required this.userAgent,
    required this.issuedAt,
  });

  final String cookie;
  final String userAgent;
  final DateTime issuedAt;

  /// 票据有效期：CF 默认 30 分钟，留点余量按 20 分钟用，过期重解。
  static const Duration ttl = Duration(minutes: 20);

  bool get fresh => DateTime.now().difference(issuedAt) < ttl;
}

/// 共用票池：host → 通行证。进程内共享，所有规则、所有站点同一份。
///
/// 之所以不是每个规则各存一份：同一个站的挑战一次就够了，不同规则
/// 命中同一个站（比如鉴黄师同时有海阔规则和原生源）时也该直接复用。
class HaikuoShieldVault {
  HaikuoShieldVault._();

  static final Map<String, HaikuoShieldTicket> _tickets =
      <String, HaikuoShieldTicket>{};

  /// 取一张还有效的票；没有/过期回 null。
  static HaikuoShieldTicket? get(String host) {
    final ticket = _tickets[host];
    if (ticket == null) return null;
    if (!ticket.fresh) {
      _tickets.remove(host);
      return null;
    }
    return ticket;
  }

  static void put(
    String host, {
    required String cookie,
    required String userAgent,
  }) {
    if (host.isEmpty || cookie.trim().isEmpty) return;
    _tickets[host] = HaikuoShieldTicket(
      cookie: cookie.trim(),
      userAgent: userAgent.trim(),
      issuedAt: DateTime.now(),
    );
  }

  static void drop(String host) => _tickets.remove(host);

  static void clear() => _tickets.clear();
}
