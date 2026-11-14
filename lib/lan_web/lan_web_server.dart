/// 局域网网页服务：App 内嵌 HTTP 服务，同一局域网的手机/电脑用
/// 浏览器打开地址就能看。内容走魔蚁已有的蜘蛛引擎（py/jar/Go 核），
/// 不另起第二套引擎；海阔规则跑在应用内 WebView 里、树里没有无头
/// 求值入口，局域网页只能列出规则名并提示在 App 内打开（已在回报
/// 里列为全局缺口）。
///
/// 服务默认关闭，设置里有开关与端口设置；绑定 0.0.0.0，端口被占时
/// 顺延 8 个端口。无鉴权（局域网信任模型，与 TVBox_Web 一致），
/// 不暴露凭证接口。
library;

import 'dart:convert';
import 'dart:io';

import '../cloud_drive/cloud_credential_store.dart';
import '../cloud_drive/cloud_providers.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../miniapp/haikuo/haikuo_store.dart';
import '../models.dart';
import 'stream_gateway.dart';

/// 局域网服务的数据源（仓库 + 商店的薄适配，便于单测用假数据源）。
abstract class LanWebDataSource {
  Future<List<SourceSite>> visibleSites();
  Future<CatalogPage> catalog(
    String source, {
    int page,
    String query,
    String category,
  });
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode);
  Future<CatalogPage> searchAcross(String query);
  Future<List<HaikuoProgramSummary>> haikuoPrograms();
  List<CloudDriveStatus> cloudDriveStatuses();
}

class HaikuoProgramSummary {
  const HaikuoProgramSummary({required this.id, required this.name});
  final String id;
  final String name;
}

class CloudDriveStatus {
  const CloudDriveStatus({
    required this.id,
    required this.name,
    required this.loggedIn,
  });
  final String id;
  final String name;
  final bool loggedIn;
}

/// 仓库桥接：局域网服务 → AppRepository / LocalStore。
class LanWebRepositoryBridge implements LanWebDataSource {
  LanWebRepositoryBridge({
    required AppRepository repository,
    required LocalStore store,
    required CloudCredentialStore credentialStore,
    HaikuoStore? haikuoStore,
  }) : _repository = repository,
       _store = store,
       _credentialStore = credentialStore,
       _haikuoStore = haikuoStore ?? HaikuoStore();

  final AppRepository _repository;
  final LocalStore _store;
  final CloudCredentialStore _credentialStore;
  final HaikuoStore _haikuoStore;

  @override
  Future<List<SourceSite>> visibleSites() async => _store.visibleSources;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
  }) =>
      _repository.catalog(source, page: page, query: query, category: category);

  @override
  Future<DramaDetail> detail(Drama drama) => _repository.detail(drama);

  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) =>
      _repository.resolve(drama, episode);

  @override
  Future<CatalogPage> searchAcross(String query) =>
      _repository.searchAcross(_store.visibleSources.map((s) => s.id).toList(), query);

  @override
  Future<List<HaikuoProgramSummary>> haikuoPrograms() async {
    try {
      final programs = await _haikuoStore.list();
      return [
        for (final program in programs)
          HaikuoProgramSummary(id: program.id, name: program.name),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  List<CloudDriveStatus> cloudDriveStatuses() {
    final loggedIn = _credentialStore.loggedInProviderIds(
      cloudDriveDisplayNames.keys,
    );
    return [
      for (final entry in cloudDriveDisplayNames.entries)
        CloudDriveStatus(
          id: entry.key,
          name: entry.value,
          loggedIn: loggedIn.contains(entry.key),
        ),
    ];
  }
}

class LanWebServer {
  LanWebServer({required this.dataSource, LanStreamProxy? streamProxy})
    : _streamProxy = streamProxy ?? LanStreamProxy();

  final LanWebDataSource dataSource;
  final LanStreamProxy _streamProxy;
  HttpServer? _server;

  bool get running => _server != null;
  int get boundPort => _server?.port ?? 0;

  /// 绑定 [port] 起的 8 个端口，返回实际绑定的端口；全被占时抛错。
  Future<int> start({required int port}) async {
    await stop();
    Object? lastError;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port + attempt);
        _server!.listen(_route, onError: (_) {});
        return _server!.port;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('局域网服务启动失败：端口 $port 起 8 个都被占用（$lastError）');
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true).catchError((_) {});
    }
  }

  void dispose() {
    _streamProxy.close();
  }

  Future<void> _route(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/stream') {
        await _streamProxy.handle(request);
        return;
      }
      if (path == '/cover') {
        await _handleCover(request);
        return;
      }
      if (path == '/' || path == '/index.html') {
        await _home(request);
        return;
      }
      if (path == '/list') {
        await _listPage(request);
        return;
      }
      if (path == '/detail') {
        await _detailPage(request);
        return;
      }
      if (path == '/watch') {
        await _watchPage(request);
        return;
      }
      if (path == '/drives') {
        await _drivesPage(request);
        return;
      }
      if (path == '/api/sites') {
        await _apiSites(request);
        return;
      }
      if (path == '/api/catalog') {
        await _apiCatalog(request);
        return;
      }
      if (path == '/api/detail') {
        await _apiDetail(request);
        return;
      }
      if (path == '/api/resolve') {
        await _apiResolve(request);
        return;
      }
      if (path == '/api/search') {
        await _apiSearch(request);
        return;
      }
      _notFound(request);
    } catch (_) {
      try {
        final response = request.response;
        response.statusCode = HttpStatus.internalServerError;
        response.headers.contentType = ContentType.html;
        response.write('<h1>服务出错</h1><p><a href="/">回首页</a></p>');
        await response.close();
      } catch (_) {}
    }
  }

  // -- 封面代理 ---------------------------------------------------------------

  Future<void> _handleCover(HttpRequest request) async {
    final targetRaw = request.uri.queryParameters['url'] ?? '';
    final target = Uri.tryParse(targetRaw);
    if (target == null ||
        (target.scheme != 'http' && target.scheme != 'https') ||
        isLoopbackHost(target.host)) {
      final response = request.response;
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    await _streamProxy.proxyTarget(request, target, const {});
  }

  // -- HTML 页 -----------------------------------------------------------------

  static const _css = '''
body{margin:0;background:#120B20;color:#fff;font:15px/1.6 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;padding:0 14px 40px}
a{color:#C9A7FF;text-decoration:none}header{padding:16px 2px 10px;display:flex;align-items:center;gap:8px}
header h1{font-size:18px;margin:0}header .dot{width:9px;height:9px;border-radius:50%;background:#B14BFF;box-shadow:0 0 12px #B14BFF}
.search{display:flex;gap:8px;margin:8px 0 16px}.search input{flex:1;background:#1E1338;border:1px solid #B14BFF66;color:#fff;border-radius:10px;padding:10px 12px;font-size:15px}
.search button{background:linear-gradient(135deg,#B14BFF,#7C3AED);color:#fff;border:0;border-radius:10px;padding:0 18px;font-size:15px}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.card{background:#1E1338;border-radius:12px;overflow:hidden}
.card img{width:100%;aspect-ratio:3/4;object-fit:cover;display:block;background:#2A1B4A}
.card .t{padding:8px 10px;font-size:13px;line-height:1.4;min-height:38px}
.card .noimg{aspect-ratio:3/4;display:flex;align-items:center;justify-content:center;color:#8E7BA8;font-size:12px;background:#2A1B4A}
.sites{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:16px}.site{border:1px solid #B14BFF66;border-radius:999px;padding:6px 14px;font-size:13px;background:#1E1338}
.note{color:#B4A5CE;font-size:13px}.warn{background:#3A2A12;border:1px solid #B98A2F55;color:#F5D9A0;border-radius:10px;padding:10px 12px;font-size:13px;margin:10px 0}
.episodes{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}.ep{border:1px solid #B14BFF66;border-radius:10px;padding:8px 14px;background:#1E1338}
.detail{display:flex;gap:14px}.detail img{width:120px;border-radius:10px}.detail .info{flex:1}
video{width:100%;border-radius:12px;background:#000}.pager{display:flex;gap:10px;margin:16px 0}.pager a{border:1px solid #B14BFF66;border-radius:10px;padding:8px 18px}
footer{margin-top:28px;color:#8E7BA8;font-size:12px}
''';

  String _page(String title, String body) => '''
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_escape(title)} · 魔蚁</title><style>$_css</style></head>
<body><header><span class="dot"></span><h1>魔蚁 · 局域网</h1></header>$body
<footer>魔蚁局域网服务 · 内容来自本机站源 · 海阔规则请在 App 内打开</footer></body></html>''';

  String _searchForm(String query) => '''
<form class="search" action="/list" method="get">
<input type="hidden" name="source" value="">
<input name="q" value="${_escape(query)}" placeholder="搜片名">
<button type="submit">搜索</button></form>''';

  Future<void> _html(HttpRequest request, String title, String body) async {
    final response = request.response;
    response.headers.contentType = ContentType.html;
    response.write(_page(title, body));
    await response.close();
  }

  Future<void> _home(HttpRequest request) async {
    final sites = await dataSource.visibleSites();
    final programs = await dataSource.haikuoPrograms();
    final siteLinks = sites
        .map(
          (site) => '<a class="site" href="/list?source=${Uri.encodeQueryComponent(site.id)}">${_escape(site.name)}</a>',
        )
        .join();
    final haikuo = programs.isEmpty
        ? ''
        : '<h3>海阔规则（请在 App 内打开）</h3><div class="sites">${programs.map((p) => '<span class="site">${_escape(p.name)}</span>').join()}</div>';
    await _html(
      request,
      '首页',
      '''
${_searchForm('')}
<h3>站源</h3><div class="sites">$siteLinks</div>
$haikuo
<p class="note"><a href="/drives">网盘状态</a> · 网盘登录请在 App 设置里操作</p>
''',
    );
  }

  Future<void> _listPage(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final source = params['source'] ?? '';
    final query = params['q'] ?? '';
    final category = params['category'] ?? '';
    final page = int.tryParse(params['page'] ?? '1') ?? 1;
    final CatalogPage result;
    final String heading;
    if (query.isNotEmpty && source.isEmpty) {
      result = await dataSource.searchAcross(query);
      heading = '搜索：${_escape(query)}';
    } else {
      result = await dataSource.catalog(
        source,
        page: page,
        query: query,
        category: category,
      );
      heading = _escape(source);
    }
    final cards = result.items.map((drama) {
      final cover = drama.cover.isNotEmpty
          ? '<img loading="lazy" src="/cover?url=${Uri.encodeQueryComponent(drama.cover)}" alt="">'
          : '<div class="noimg">无封面</div>';
      final link = drama.kind == 'folder'
          ? '/list?source=${Uri.encodeQueryComponent(source)}&category=${Uri.encodeQueryComponent(drama.folderId)}'
          : '/detail?drama=${_encodeDrama(drama)}';
      return '<a class="card" href="$link">$cover<div class="t">${_escape(drama.title)}</div></a>';
    }).join();
    final pager = StringBuffer('<div class="pager">');
    if (page > 1) {
      pager.write(
        '<a href="/list?source=${Uri.encodeQueryComponent(source)}&category=${Uri.encodeQueryComponent(category)}&q=${Uri.encodeQueryComponent(query)}&page=${page - 1}">上一页</a>',
      );
    }
    if (result.hasMore) {
      pager.write(
        '<a href="/list?source=${Uri.encodeQueryComponent(source)}&category=${Uri.encodeQueryComponent(category)}&q=${Uri.encodeQueryComponent(query)}&page=${page + 1}">下一页</a>',
      );
    }
    pager.write('</div>');
    await _html(
      request,
      heading,
      '''
<p><a href="/">‹ 首页</a></p>${_searchForm(query)}
<h2>$heading</h2>
${result.warning.isNotEmpty ? '<div class="warn">${_escape(result.warning)}</div>' : ''}
<div class="grid">$cards</div>$pager
''',
    );
  }

  Future<void> _detailPage(HttpRequest request) async {
    final drama = _decodeDrama(request.uri.queryParameters['drama'] ?? '');
    if (drama == null) {
      _notFound(request);
      return;
    }
    final detail = await dataSource.detail(drama);
    final episodes = <String>[];
    for (var i = 0; i < detail.episodes.length; i++) {
      final episode = detail.episodes[i];
      episodes.add(
        '<a class="ep" href="/watch?drama=${_encodeDrama(drama)}&episode=${_encodeEpisode(episode, i + 1)}">${_escape(episode.title)}</a>',
      );
    }
    final cover = drama.cover.isNotEmpty
        ? '<img src="/cover?url=${Uri.encodeQueryComponent(drama.cover)}" alt="">'
        : '';
    await _html(
      request,
      drama.title,
      '''
<p><a href="/">‹ 首页</a></p>
<div class="detail">$cover<div class="info"><h2>${_escape(drama.title)}</h2>
<p class="note">${_escape(drama.description)}</p>
<p class="note">${detail.tags.map((t) => _escape(t.name)).join(' · ')}</p></div></div>
${detail.warning.isNotEmpty ? '<div class="warn">${_escape(detail.warning)}</div>' : ''}
<div class="episodes">${episodes.join()}</div>
''',
    );
  }

  Future<void> _watchPage(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final drama = _decodeDrama(params['drama'] ?? '');
    final episode = _decodeEpisode(params['episode'] ?? '');
    if (drama == null || episode == null) {
      _notFound(request);
      return;
    }
    final plan = await dataSource.resolve(drama, episode);
    final playable = _playableInBrowser(plan);
    final body = StringBuffer('<p><a href="/">‹ 首页</a></p><h2>${_escape(drama.title)} · ${_escape(episode.title)}</h2>');
    if (!playable.$1) {
      body.write('<div class="warn">${_escape(playable.$2)}</div>');
    } else {
      final gatewayBase =
          'http://${request.headers.host ?? '127.0.0.1:$boundPort'}';
      final src = shouldGatewayRewrite(plan)
          ? buildGatewayUrl(gatewayBase, plan.url, plan.headers)
          : plan.url;
      body.write(
        '<video controls autoplay playsinline src="${_escape(src)}"></video>'
        '<p class="note">浏览器不支持 HLS（m3u8）时请改用 Safari，或在 App 内播放。</p>',
      );
    }
    await _html(request, '${drama.title} · ${episode.title}', body.toString());
  }

  /// 浏览器里能不能直接播：带解密密钥、非视频协议的一律不行。
  (bool, String) _playableInBrowser(PlaybackPlan plan) {
    if (plan.decryptionKey.isNotEmpty) {
      return (false, '该片源需要 App 内解密播放，请在魔蚁 App 内打开。');
    }
    final uri = Uri.tryParse(plan.url);
    if (uri == null) return (false, '播放地址无效。');
    if (uri.scheme == 'novel' || uri.scheme == 'pics') {
      return (false, '该内容是小说/图片，请在魔蚁 App 内打开。');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return (false, '该播放地址浏览器打不开，请在魔蚁 App 内打开。');
    }
    return (true, '');
  }

  Future<void> _drivesPage(HttpRequest request) async {
    final statuses = dataSource.cloudDriveStatuses();
    final rows = statuses
        .map(
          (s) => '<p>${_escape(s.name)}：${s.loggedIn ? '已登录' : '未登录'}</p>',
        )
        .join();
    await _html(
      request,
      '网盘状态',
      '''
<p><a href="/">‹ 首页</a></p><h2>网盘状态</h2>$rows
<p class="note">网盘扫码登录与凭证清除请在 App 设置 → 网盘登录里操作；
登录后网盘会作为站源出现在站源列表里。</p>
''',
    );
  }

  // -- JSON API ---------------------------------------------------------------

  Future<void> _json(HttpRequest request, Map<String, dynamic> body) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Headers', '*');
    response.headers.set('Access-Control-Expose-Headers', 'Content-Length');
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _apiSites(HttpRequest request) async {
    final sites = await dataSource.visibleSites();
    await _json(request, {
      'sites': [
        for (final site in sites)
          {'id': site.id, 'name': site.name, 'section': site.section},
      ],
    });
  }

  Future<void> _apiCatalog(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final source = params['source'] ?? '';
    final result = await dataSource.catalog(
      source,
      page: int.tryParse(params['page'] ?? '1') ?? 1,
      query: params['q'] ?? '',
      category: params['category'] ?? '',
    );
    await _json(request, {
      'items': [for (final item in result.items) item.toJson()],
      'hasMore': result.hasMore,
      'warning': result.warning,
      'page': result.page,
    });
  }

  Future<void> _apiDetail(HttpRequest request) async {
    final drama = _decodeDrama(request.uri.queryParameters['drama'] ?? '');
    if (drama == null) {
      await _json(request, {'error': 'drama 参数无效'});
      return;
    }
    final detail = await dataSource.detail(drama);
    await _json(request, {
      'drama': detail.drama.toJson(),
      'episodes': [for (final e in detail.episodes) e.raw],
      'warning': detail.warning,
      'backdrop': detail.backdrop,
      'tags': [for (final t in detail.tags) {'id': t.id, 'name': t.name}],
    });
  }

  Future<void> _apiResolve(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final drama = _decodeDrama(params['drama'] ?? '');
    final episode = _decodeEpisode(params['episode'] ?? '');
    if (drama == null || episode == null) {
      await _json(request, {'error': 'drama 或 episode 参数无效'});
      return;
    }
    final plan = await dataSource.resolve(drama, episode);
    final playable = _playableInBrowser(plan);
    if (!playable.$1) {
      await _json(request, {'playable': false, 'reason': playable.$2});
      return;
    }
    final gatewayBase =
        'http://${request.headers.host ?? '127.0.0.1:$boundPort'}';
    final url = shouldGatewayRewrite(plan)
        ? buildGatewayUrl(gatewayBase, plan.url, plan.headers)
        : plan.url;
    await _json(request, {
      'playable': true,
      'url': url,
      'headers': plan.headers,
    });
  }

  Future<void> _apiSearch(HttpRequest request) async {
    final query = request.uri.queryParameters['q'] ?? '';
    final result = await dataSource.searchAcross(query);
    await _json(request, {
      'items': [for (final item in result.items) item.toJson()],
      'hasMore': result.hasMore,
      'warning': result.warning,
    });
  }

  void _notFound(HttpRequest request) {
    final response = request.response;
    response.statusCode = HttpStatus.notFound;
    response.headers.contentType = ContentType.html;
    response.write('<h1>找不到</h1><p><a href="/">回首页</a></p>');
    response.close();
  }

  // -- 编解码小工具 ------------------------------------------------------------

  String _encodeDrama(Drama drama) =>
      base64Url.encode(utf8.encode(jsonEncode(drama.toJson())));

  Drama? _decodeDrama(String encoded) {
    if (encoded.isEmpty) return null;
    try {
      final json = jsonDecode(utf8.decode(_b64decode(encoded)));
      if (json is Map<String, dynamic>) return Drama.fromJson(json);
    } catch (_) {}
    return null;
  }

  String _encodeEpisode(Episode episode, int fallback) =>
      base64Url.encode(
        utf8.encode(jsonEncode({'raw': episode.raw, 'fallback': fallback})),
      );

  Episode? _decodeEpisode(String encoded) {
    if (encoded.isEmpty) return null;
    try {
      final json = jsonDecode(utf8.decode(_b64decode(encoded)));
      if (json is Map<String, dynamic> && json['raw'] is Map) {
        return Episode(
          Map<String, dynamic>.from(json['raw'] as Map),
          json['fallback'] is int ? json['fallback'] as int : 1,
        );
      }
    } catch (_) {}
    return null;
  }

  List<int> _b64decode(String encoded) {
    var padded = encoded;
    while (padded.length % 4 != 0) {
      padded += '=';
    }
    return base64Url.decode(padded);
  }

  String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

/// 局域网服务控制器（生命周期 + 地址），供 main.dart 与设置页共用。
class LanWebController {
  LanWebController(this._dataSource);

  static LanWebController? current;

  final LanWebDataSource _dataSource;
  LanWebServer? _server;

  bool get running => _server?.running ?? false;
  int get port => _server?.boundPort ?? 0;

  /// 启动服务（端口被占时顺延），成功返回实际端口，失败返回 -1。
  Future<int> start(int port) async {
    await stop();
    try {
      final server = LanWebServer(dataSource: _dataSource);
      final bound = await server.start(port: port);
      _server = server;
      LanGatewayState.active = true;
      LanGatewayState.port = bound;
      return bound;
    } catch (_) {
      _server = null;
      return -1;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.stop();
      server.dispose();
    }
    LanGatewayState.active = false;
  }

  /// 局域网访问地址（http://<本机 IP>:<端口>），取不到 IP 时返回 ''。
  Future<String> lanAddress() async {
    if (!running) return '';
    final ip = await localLanIp();
    if (ip.isEmpty) return '';
    return 'http://$ip:$port';
  }
}

/// 本机局域网 IPv4（第一个非回环地址），取不到返回 ''。
Future<String> localLanIp() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) return address.address;
      }
    }
  } catch (_) {}
  return '';
}
