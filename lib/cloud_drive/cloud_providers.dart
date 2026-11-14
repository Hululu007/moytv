/// 四家网盘的扫码登录 + 文件列表 + 直链客户端。
///
/// 协议来源：115/夸克/百度三家的 QR 流程与接口地址是从 TVBox_Web
/// 的 index.js 混淆包里抽出的协议事实（本文件按协议自己实现，不抄
/// 它的代码）；阿里云盘在 TVBox_Web 里没有扫码登录，按公开的阿里云盘
/// OpenAPI 协议实现。2026-11-14 已实测四家的二维码参数接口均可匿名
/// 调通（见 ~/workspace/moyi_tvboxweb_port/DESIGN.md）；轮询、登录、
/// 列表、直链四步需真账号，均未实测，列为手机待验。
///
/// 所有请求都走注入的 [http.Client]，便于单测用假客户端替换。
/// 凭证只存在 [CloudCredentialStore] 里，不进日志、不进局域网接口。
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'cloud_credential_store.dart';
import 'cloud_drive_types.dart';

/// 网盘侧的错误（面向用户的中文消息，由引擎转成 AppFailure）。
class CloudDriveException implements Exception {
  CloudDriveException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 二维码登录会话（一次扫码流程的状态）。
class QrLoginSession {
  const QrLoginSession({
    required this.qrContent,
    required this.qrImageUrl,
    required this.message,
    required this.state,
    required this.expiresAt,
  });

  /// 二维码内容（URL 字符串，应用内用二维码编码器画成图）。
  /// 走图片地址的网盘（百度）这里为空。
  final String qrContent;

  /// 二维码图片地址（百度直接给图）；不用图片的网盘这里为空。
  final String qrImageUrl;

  /// 提示文案（“请用 XX App 扫码确认”）。
  final String message;

  /// 轮询用的不透明状态（各家自己解释，引擎不解析）。
  final Map<String, String> state;

  /// 会话过期时间（界面据此停轮询、显示“二维码已过期”）。
  final DateTime expiresAt;
}

enum QrPollStatus {
  /// 等待扫码。
  waiting,

  /// 已扫码、等待在 App 内确认。
  scanned,

  /// 登录成功（带凭证）。
  success,

  /// 二维码已过期。
  expired,

  /// 流程失败（带原因）。
  failed,
}

class QrPollResult {
  const QrPollResult({
    required this.status,
    this.credentials,
    this.message = '',
  });

  final QrPollStatus status;
  final CloudCredentials? credentials;
  final String message;
}

/// 文件夹一页的列表结果。
class CloudFolderPage {
  const CloudFolderPage({
    required this.files,
    required this.hasMore,
    this.total = -1,
  });

  final List<CloudDriveFile> files;
  final bool hasMore;

  /// 总数；网盘没给时为 -1（未知）。
  final int total;
}

/// 直链结果：播放器直接用的地址 + 请求头。
class CloudDirectLink {
  const CloudDirectLink({
    required this.url,
    this.headers = const {},
    this.isTranscoded = false,
  });

  final String url;
  final Map<String, String> headers;

  /// 是否转码流（夸克 v2/play 兜底）；仍是直链数据，不嵌网页播放器。
  final bool isTranscoded;
}

/// 网盘客户端的统一接口。
abstract class CloudDriveProvider {
  /// 网盘 id：pan115 / quark / aliyun / baidu。
  String get id;

  /// 显示名：115网盘 / 夸克网盘 / 阿里云盘 / 百度网盘。
  String get displayName;

  /// 扫码用的 App 名（提示文案用）。
  String get appName;

  /// 根文件夹 id（115/夸克=0，阿里=root，百度=/）。
  String get rootFolderId;

  /// 开始扫码登录：取二维码参数。
  Future<QrLoginSession> startQrLogin(http.Client client);

  /// 轮询一次扫码状态。
  Future<QrPollResult> pollQrLogin(http.Client client, QrLoginSession session);

  /// 列文件夹一页（page 从 1 起）。
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  );

  /// 在指定文件夹内搜索。没有站方搜索接口的网盘抛
  /// [UnsupportedError]，引擎改用“取列表后按名过滤”兜底。
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  );

  /// 取文件的直链（视频/音频/图片都走直链，不嵌网页播放器）。
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  );

  /// 凭证被刷新时的回调（阿里 access_token 续期用，引擎负责落盘）。
  void Function(String providerId, CloudCredentials credentials)?
  get onCredentialsRefreshed;
  set onCredentialsRefreshed(
    void Function(String providerId, CloudCredentials credentials)? value,
  );
}

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

const _requestTimeout = Duration(seconds: 20);

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Map<String, dynamic> _jsonObject(String body, String what) {
  final decoded = jsonDecode(body);
  if (decoded is Map<String, dynamic>) return decoded;
  throw CloudDriveException('$what：返回的不是 JSON 对象');
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  return value.toString();
}

/// 从 set-cookie 头里抽 name=value（跳过 Expires 里的逗号干扰）。
Map<String, String> parseSetCookies(String? setCookieHeader) {
  final result = <String, String>{};
  if (setCookieHeader == null || setCookieHeader.isEmpty) return result;
  // 按“逗号 + 名字=”切分（Expires=Wed, 21 Oct ... 里的逗号后跟的不是 名字=）。
  final parts = setCookieHeader.split(
    RegExp(r",\s*(?=[A-Za-z0-9_!#\$%&'*+\-.^`|~]+=[^;,]*)"),
  );
  for (final part in parts) {
    final first = part.split(';').first.trim();
    final eq = first.indexOf('=');
    if (eq <= 0) continue;
    final name = first.substring(0, eq).trim();
    final value = first.substring(eq + 1).trim();
    if (name.isEmpty || name.toLowerCase() == 'expires') continue;
    result[name] = value;
  }
  return result;
}

/// 把 set-cookie 合并进已有的 Cookie 头（同名覆盖）。
String mergeCookieHeader(String existing, String? setCookieHeader) {
  final jar = <String, String>{};
  for (final part in existing.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq > 0) jar[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
  }
  jar.addAll(parseSetCookies(setCookieHeader));
  return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// 手动跟随重定向（不下载正文），返回最终地址与沿途 set-cookie。
/// [maxHops] 跳后仍是重定向则返回最后一次的 Location（调用方决定）。
Future<({String url, String setCookie})> resolveRedirects(
  http.Client client,
  http.Request request, {
  int maxHops = 5,
}) async {
  var current = request;
  var cookies = '';
  for (var hop = 0; hop <= maxHops; hop++) {
    current.followRedirects = false;
    final response = await client.send(current).timeout(_requestTimeout);
    final location = response.headers['location'];
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      cookies = mergeCookieHeader(cookies, setCookie);
    }
    final status = response.statusCode;
    if (status >= 300 && status < 400 && location != null && location.isNotEmpty) {
      // 302 正文极小，直接取消流，不下载。
      await response.stream.listen(null).cancel().catchError((_) {});
      final next = current.url.resolve(location);
      final follow = http.Request('GET', next);
      follow.headers.addAll(current.headers);
      current = follow;
      continue;
    }
    await response.stream.listen(null).cancel().catchError((_) {});
    return (url: current.url.toString(), setCookie: cookies);
  }
  return (url: current.url.toString(), setCookie: cookies);
}

Future<http.Response> _get(
  http.Client client,
  Uri uri, {
  Map<String, String> headers = const {},
}) async {
  final response = await client.get(uri, headers: headers).timeout(_requestTimeout);
  return response;
}

Future<http.Response> _postJson(
  http.Client client,
  Uri uri,
  Map<String, dynamic> body, {
  Map<String, String> headers = const {},
}) async {
  return client
      .post(
        uri,
        headers: {'Content-Type': 'application/json', ...headers},
        body: jsonEncode(body),
      )
      .timeout(_requestTimeout);
}

Future<http.Response> _postForm(
  http.Client client,
  Uri uri,
  Map<String, String> fields, {
  Map<String, String> headers = const {},
}) async {
  return client
      .post(
        uri,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          ...headers,
        },
        body: fields.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&'),
      )
      .timeout(_requestTimeout);
}

// ---------------------------------------------------------------------------
// 115 网盘
// ---------------------------------------------------------------------------

class Pan115Provider implements CloudDriveProvider {
  @override
  String get id => 'pan115';
  @override
  String get displayName => '115网盘';
  @override
  String get appName => '115 App';
  @override
  String get rootFolderId => '0';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36 115Browser/26.0.7.2';
  static const _referer = 'https://cdnassets.115.com/';
  static const _qrTokenUrl =
      'https://qrcodeapi.115.com/api/1.0/alipaymini/1.0/token/';
  static const _qrStatusUrl = 'https://qrcodeapi.115.com/get/status/';
  static const _qrLoginUrl =
      'https://passportapi.115.com/app/1.0/alipaymini/1.0/login/qrcode/';
  static const _filesUrl = 'https://webapi.115.com/files';
  static const _categoryUrl = 'https://webapi.115.com/category/get';
  static const _downloadUrl = 'https://webapi.115.com/files/download';
  static const _pageSize = 40;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final response = await _get(
      client,
      Uri.parse(_qrTokenUrl),
      headers: {'User-Agent': _ua, 'Referer': _referer},
    );
    if (response.statusCode != 200) {
      throw CloudDriveException('115 二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    final data = _jsonObject(response.body, '115 二维码参数')['data'];
    if (data is! Map<String, dynamic>) {
      throw CloudDriveException('115 二维码参数获取失败：返回格式不对');
    }
    final uid = _asString(data['uid']);
    final qrcode = _asString(data['qrcode']);
    if (uid.isEmpty || qrcode.isEmpty) {
      throw CloudDriveException('115 二维码参数获取失败：缺少 uid 或二维码地址');
    }
    return QrLoginSession(
      qrContent: qrcode,
      qrImageUrl: '',
      message: '请用 115 App 扫码确认',
      state: {
        'uid': uid,
        'time': _asString(data['time']),
        'sign': _asString(data['sign']),
      },
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final uid = session.state['uid'] ?? '';
    final time = session.state['time'] ?? '';
    final sign = session.state['sign'] ?? '';
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(_qrStatusUrl).replace(
      queryParameters: {
        'uid': uid,
        'time': time,
        'sign': sign,
        '_': '$seconds.112',
      },
    );
    final response = await _get(
      client,
      uri,
      headers: {'User-Agent': _ua, 'Referer': _referer},
    );
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待 115 App 扫码确认',
      );
    }
    final root = _jsonObject(response.body, '115 扫码状态');
    final data = root['data'];
    if (data is! Map<String, dynamic>) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待 115 App 扫码确认',
      );
    }
    // 已扫码确认的信号：data 里有 version 且没有 msg。
    final hasVersion = data['version'] != null;
    final msg = _asString(data['msg']);
    if (hasVersion && msg.isEmpty) {
      return _finishLogin(client, uid);
    }
    final status = _asInt(data['status'], 0);
    if (status == -1 || _asInt(root['code'], 0) != 0) {
      return const QrPollResult(
        status: QrPollStatus.expired,
        message: '二维码已过期，请重新获取',
      );
    }
    return QrPollResult(
      status: status == 1 ? QrPollStatus.scanned : QrPollStatus.waiting,
      message: msg.isEmpty ? '等待 115 App 扫码确认' : msg,
    );
  }

  Future<QrPollResult> _finishLogin(http.Client client, String uid) async {
    final response = await _postForm(
      client,
      Uri.parse(_qrLoginUrl),
      {'account': uid, 'app': 'web'},
      headers: {
        'User-Agent': _ua,
        'Referer': _referer,
        'Origin': _referer,
      },
    );
    final cookie = mergeCookieHeader('', response.headers['set-cookie']);
    if (cookie.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '115 登录失败：没有拿到登录凭证',
      );
    }
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: CloudCredentials(
        fields: {'cookie': cookie},
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      message: '115网盘登录成功',
    );
  }

  Map<String, String> _authHeaders(CloudCredentials credentials) => {
    'User-Agent': _ua,
    'Referer': _referer,
    'Cookie': credentials.fields['cookie'] ?? '',
  };

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final offset = (page - 1) * _pageSize;
    final uri = Uri.parse(_filesUrl).replace(
      queryParameters: {
        'aid': '1',
        'cid': folderId,
        'o': 'file_name',
        'asc': '1',
        'offset': '$offset',
        'show_dir': '1',
        'limit': '$_pageSize',
        'format': 'json',
        'natsort': '1',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('115 文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '115 文件列表');
    final data = root['data'];
    if (data is! List) {
      throw CloudDriveException('115 文件列表获取失败：返回格式不对');
    }
    final files = <CloudDriveFile>[];
    for (final item in data) {
      if (item is! Map<String, dynamic>) continue;
      files.add(_parseItem(item));
    }
    final total = _asInt(root['count'], -1);
    final hasMore = total >= 0
        ? offset + files.length < total
        : files.length >= _pageSize;
    return CloudFolderPage(files: files, hasMore: hasMore, total: total);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final fid = _asString(item['fid']);
    final cid = _asString(item['cid']);
    final isFolder = fid.isEmpty;
    final name = _asString(item['n']).replaceAll('|', ' ');
    final size = _asInt(item['s']);
    final pickcode = _asString(item['pc']);
    final duration = item['play_long'] is num
        ? (item['play_long'] as num).toInt()
        : (item['duration'] is num ? (item['duration'] as num).toInt() : null);
    final thumb = _asString(item['thumb']);
    final kind = classifyCloudFile(name: name, isFolder: isFolder);
    return CloudDriveFile(
      id: isFolder ? cid : fid,
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: size,
      modifiedMs: _asInt(item['t']) * 1000,
      durationSeconds: duration,
      thumbnailUrl: thumb,
      extra: {if (pickcode.isNotEmpty) 'pickcode': pickcode},
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    final uri = Uri.parse('https://webapi.115.com/files/search').replace(
      queryParameters: {
        'search_value': keyword,
        'aid': '1',
        'cid': folderId,
        'o': 'file_name',
        'asc': '1',
        'offset': '0',
        'limit': '$_pageSize',
        'format': 'json',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('115 搜索失败（HTTP ${response.statusCode}）');
    }
    final data = _jsonObject(response.body, '115 搜索')['data'];
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map<String, dynamic>) _parseItem(item),
    ];
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    var pickcode = file.extra['pickcode'] ?? '';
    if (pickcode.isEmpty) {
      pickcode = await _fetchPickcode(client, credentials, file.id);
    }
    if (pickcode.isEmpty) {
      throw CloudDriveException('115 取直链失败：没有拿到文件提取码');
    }
    // 不走 proapi downurl 加密接口（混淆加密未抽出），走 files/download
    // 的 302 跳转拿 CDN 直链；该路径未经真账号实测，列为手机待验。
    final uri = Uri.parse(_downloadUrl).replace(
      queryParameters: {'pickcode': pickcode},
    );
    final request = http.Request('GET', uri)..headers.addAll(_authHeaders(credentials));
    final resolved = await resolveRedirects(client, request);
    final cookie = mergeCookieHeader(
      credentials.fields['cookie'] ?? '',
      resolved.setCookie.isEmpty ? null : resolved.setCookie,
    );
    return CloudDirectLink(
      url: resolved.url,
      headers: {'User-Agent': _ua, 'Cookie': cookie},
    );
  }

  Future<String> _fetchPickcode(
    http.Client client,
    CloudCredentials credentials,
    String fid,
  ) async {
    final uri = Uri.parse(_categoryUrl).replace(
      queryParameters: {'cid': fid},
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) return '';
    final root = _jsonObject(response.body, '115 文件信息');
    final pickcode = _asString(root['pick_code']);
    if (pickcode.isNotEmpty) return pickcode;
    // 文件夹 id 误传时返回的是夹内列表，取第一条的文件 id 再取一次。
    final data = root['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map<String, dynamic>) {
        final innerFid = _asString(first['fid']);
        if (innerFid.isNotEmpty && innerFid != fid) {
          return _fetchPickcode(client, credentials, innerFid);
        }
      }
    }
    return '';
  }
}

// ---------------------------------------------------------------------------
// 夸克网盘
// ---------------------------------------------------------------------------

class QuarkProvider implements CloudDriveProvider {
  @override
  String get id => 'quark';
  @override
  String get displayName => '夸克网盘';
  @override
  String get appName => '夸克 App';
  @override
  String get rootFolderId => '0';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36';
  static const _tokenUrl =
      'https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin';
  static const _ticketUrl =
      'https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken';
  static const _loginUrl = 'https://pan.quark.cn/desktop/account/login';
  static const _fileListUrl =
      'https://drive-pc.quark.cn/1/clouddrive/file/sort';
  static const _downloadUrl =
      'https://drive-pc.quark.cn/1/clouddrive/file/download';
  static const _playUrl =
      'https://drive-pc.quark.cn/1/clouddrive/file/v2/play';
  static const _pageSize = 50;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final requestId = _uuidV4();
    final uri = Uri.parse(_tokenUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        'client_id': '386',
        'v': '1.2',
        'request_id': requestId,
      },
    );
    final response = await _get(client, uri, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      throw CloudDriveException('夸克二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '夸克二维码参数');
    final token = _asString(
      ((root['data'] as Map?)?['members'] as Map?)?['token'],
    );
    if (token.isEmpty) {
      throw CloudDriveException('夸克二维码参数获取失败：缺少 token');
    }
    final qrUrl =
        'https://su.quark.cn/4_eMHBJ?token=$token&client_id=386'
        '&sch=pckk@other_ch&sve=3.1.8&ssb=weblogin&uc_param_str='
        '&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0';
    return QrLoginSession(
      qrContent: qrUrl,
      qrImageUrl: '',
      message: '请用夸克 App 扫码确认',
      state: {'requestId': requestId, 'token': token},
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final uri = Uri.parse(_ticketUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        'client_id': '386',
        'v': '1.2',
        'request_id': session.state['requestId'] ?? '',
        'token': session.state['token'] ?? '',
      },
    );
    final response = await _get(client, uri, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待夸克 App 扫码确认',
      );
    }
    final root = _jsonObject(response.body, '夸克扫码状态');
    final message = _asString(root['message']);
    final ticket = _asString(
      ((root['data'] as Map?)?['members'] as Map?)?['service_ticket'],
    );
    if (!message.contains('ok') || ticket.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待夸克 App 扫码确认',
      );
    }
    final loginUri = Uri.parse(_loginUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        'st': ticket,
      },
    );
    final loginResponse = await _get(
      client,
      loginUri,
      headers: {'User-Agent': _ua},
    );
    final cookie = mergeCookieHeader('', loginResponse.headers['set-cookie']);
    if (cookie.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '夸克登录失败：没有拿到登录凭证',
      );
    }
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: CloudCredentials(
        fields: {'cookie': cookie},
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      message: '夸克网盘登录成功',
    );
  }

  Map<String, String> _authHeaders(CloudCredentials credentials) => {
    'User-Agent': _ua,
    'Cookie': credentials.fields['cookie'] ?? '',
  };

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final uri = Uri.parse(_fileListUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'uc_param_str': '',
        'pdir_fid': folderId,
        '_page': '$page',
        '_size': '$_pageSize',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,updated_at:desc',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('夸克文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '夸克文件列表');
    final data = root['data'];
    if (data is! Map<String, dynamic>) {
      throw CloudDriveException('夸克文件列表获取失败：返回格式不对');
    }
    final list = data['list'];
    final files = <CloudDriveFile>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) files.add(_parseItem(item));
      }
    }
    final total = _asInt(data['total'], -1);
    final hasMore = total >= 0
        ? (page - 1) * _pageSize + files.length < total
        : files.length >= _pageSize;
    return CloudFolderPage(files: files, hasMore: hasMore, total: total);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final isFolder = item['file'] == false;
    final name = _asString(item['file_name']);
    final duration = item['duration'] is num
        ? (item['duration'] as num).toInt()
        : null;
    final kind = classifyCloudFile(name: name, isFolder: isFolder);
    return CloudDriveFile(
      id: _asString(item['fid']),
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: _asInt(item['size']),
      modifiedMs: _asInt(item['updated_at']) * 1000,
      durationSeconds: duration,
      thumbnailUrl: _asString(item['thumbnail']),
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    // 夸克没有公开的站内搜索接口，走引擎的“取列表后按名过滤”兜底。
    throw UnsupportedError('夸克网盘没有站方搜索接口');
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final headers = _authHeaders(credentials);
    // 先取原文件直链。
    final downloadUri = Uri.parse(_downloadUrl).replace(
      queryParameters: {'pr': 'ucpro', 'fr': 'pc'},
    );
    try {
      final response = await _postJson(
        client,
        downloadUri,
        {
          'fids': [file.id],
        },
        headers: headers,
      );
      if (response.statusCode == 200) {
        final root = _jsonObject(response.body, '夸克直链');
        final data = root['data'];
        if (data is List && data.isNotEmpty) {
          final first = data.first;
          if (first is Map<String, dynamic>) {
            final url = _asString(first['download_url']);
            if (url.isNotEmpty) {
              return CloudDirectLink(url: url, headers: headers);
            }
          }
        }
      }
    } catch (_) {
      // 直链接口失败时落到转码流兜底。
    }
    // 兜底：转码播放接口（仍是直链数据，不嵌网页播放器）。
    final playUri = Uri.parse(_playUrl).replace(
      queryParameters: {'pr': 'ucpro', 'fr': 'pc'},
    );
    final playResponse = await _postJson(
      client,
      playUri,
      {
        'fid': file.id,
      },
      headers: headers,
    );
    if (playResponse.statusCode != 200) {
      throw CloudDriveException('夸克取直链失败（HTTP ${playResponse.statusCode}）');
    }
    final root = _jsonObject(playResponse.body, '夸克转码播放');
    final videoList = (root['data'] as Map?)?['video_list'];
    if (videoList is List) {
      for (final entry in videoList) {
        if (entry is Map<String, dynamic>) {
          final info = entry['video_info'];
          if (info is Map<String, dynamic>) {
            final url = _asString(info['url']);
            if (url.isNotEmpty) {
              return CloudDirectLink(
                url: url,
                headers: headers,
                isTranscoded: true,
              );
            }
          }
        }
      }
    }
    throw CloudDriveException('夸克取直链失败：没有返回可播地址');
  }
}

// ---------------------------------------------------------------------------
// 百度网盘
// ---------------------------------------------------------------------------

class BaiduProvider implements CloudDriveProvider {
  @override
  String get id => 'baidu';
  @override
  String get displayName => '百度网盘';
  @override
  String get appName => '百度网盘 App';
  @override
  String get rootFolderId => '/';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36';
  static const _qrCodeUrl = 'https://passport.baidu.com/v2/api/getqrcode';
  static const _channelUrl = 'https://passport.baidu.com/channel/unicast';
  static const _qrLoginUrl =
      'https://passport.baidu.com/v3/login/main/qrbdusslogin';
  static const _xpanUrl = 'https://pan.baidu.com/rest/2.0/xpan/file';
  static const _pcsUrl = 'https://pcs.baidu.com/rest/2.0/pcs/file';
  static const _pageSize = 100;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final gid = _uuidV4().toUpperCase();
    final tangramGuid = DateTime.now().millisecondsSinceEpoch.toString();
    final tt = DateTime.now().millisecondsSinceEpoch.toString();
    final uri = Uri.parse(_qrCodeUrl).replace(
      queryParameters: {
        'lp': 'pc',
        'qrloginfrom': 'pc',
        'gid': gid,
        'callback': 'tangram_guid_$tangramGuid',
        'apiver': 'v3',
        'tt': tt,
        'tpl': 'netdisk',
        'logPage': '',
      },
    );
    final response = await _get(client, uri, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      throw CloudDriveException('百度二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    // 返回是 JSONP：tangram_guid_xxx({...})，取括号里的 JSON。
    final body = response.body;
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw CloudDriveException('百度二维码参数获取失败：返回格式不对');
    }
    final root = _jsonObject(body.substring(start, end + 1), '百度二维码参数');
    final sign = _asString(root['sign']);
    final imgurl = _asString(root['imgurl']);
    if (sign.isEmpty || imgurl.isEmpty) {
      throw CloudDriveException('百度二维码参数获取失败：缺少 sign 或二维码图');
    }
    final cookie = mergeCookieHeader('', response.headers['set-cookie']);
    return QrLoginSession(
      qrContent: '',
      qrImageUrl: imgurl.startsWith('http') ? imgurl : 'https://$imgurl',
      message: '请用百度网盘 App 扫码确认',
      state: {
        'gid': gid,
        'sign': sign,
        'tangramGuid': tangramGuid,
        'cookie': cookie,
      },
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final nonce = (DateTime.now().millisecondsSinceEpoch * 1000 + 3000).toString();
    final uri = Uri.parse(_channelUrl).replace(
      queryParameters: {
        'channel_id': session.state['sign'] ?? '',
        'gid': session.state['gid'] ?? '',
        'tpl': 'netdisk',
        '_sdkFrom': '1',
        'callback': 'tangram_guid_${session.state['tangramGuid'] ?? ''}',
        'apiver': 'v3',
        'tt': nonce,
        '_': nonce,
      },
    );
    final cookie = session.state['cookie'] ?? '';
    final response = await _get(
      client,
      uri,
      headers: {'User-Agent': _ua, if (cookie.isNotEmpty) 'Cookie': cookie},
    );
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待百度网盘 App 扫码确认',
      );
    }
    final match = RegExp(r'\\"v\\":\\"([a-f0-9]{32})\\"').firstMatch(response.body);
    final bdussValue = match?.group(1) ?? '';
    if (bdussValue.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待百度网盘 App 扫码确认',
      );
    }
    return _finishLogin(client, session, bdussValue, nonce);
  }

  Future<QrPollResult> _finishLogin(
    http.Client client,
    QrLoginSession session,
    String bdussValue,
    String nonce,
  ) async {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(_qrLoginUrl).replace(
      queryParameters: {
        'v': nonce,
        'bduss': bdussValue,
        'u':
            'https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fmain%23%2Findex%3Fcategory%3Dall',
        'loginVersion': 'v5',
        'qrcode': '1',
        'tpl': 'netdisk',
        'maskId': '',
        'fileId': '',
        'apiver': 'v3',
        'tt': nonce,
        'traceid': '',
        'time': '$seconds',
        'alg': 'v3',
        'elapsed': '1',
        'callback': 'bd__cbs__tro4ll',
      },
    );
    final cookie = session.state['cookie'] ?? '';
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'User-Agent': _ua,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      })
      ..followRedirects = false;
    final streamed = await client.send(request).timeout(_requestTimeout);
    var body = '';
    if (streamed.statusCode == 302) {
      final location = streamed.headers['location'];
      await streamed.stream.listen(null).cancel().catchError((_) {});
      if (location != null && location.isNotEmpty) {
        final follow = await _get(
          client,
          uri.resolve(location),
          headers: {'User-Agent': _ua, if (cookie.isNotEmpty) 'Cookie': cookie},
        );
        body = follow.body;
      }
    } else {
      body = await streamed.stream.bytesToString().timeout(_requestTimeout);
    }
    final match = RegExp(r'bd__cbs__tro4ll\((.*?)\)').firstMatch(body);
    if (match == null) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '百度登录失败：没有拿到会话信息',
      );
    }
    final root = _jsonObject(match.group(1)!, '百度登录会话');
    final data = root['data'];
    final sessionMap = data is Map<String, dynamic> ? data['session'] : null;
    if (sessionMap is! Map<String, dynamic>) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '百度登录失败：会话格式不对',
      );
    }
    final ubi = _asString(sessionMap['ubi']);
    final stoken = _asString(sessionMap['stoken']);
    final bduss = _asString(sessionMap['bduss']);
    final ptoken = _asString(sessionMap['ptoken']);
    if (bduss.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '百度登录失败：缺少 BDUSS',
      );
    }
    final jar = <String, String>{};
    for (final part in cookie.split(';')) {
      final trimmed = part.trim();
      final eq = trimmed.indexOf('=');
      if (eq > 0) jar[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
    }
    jar.addAll({
      'newlogin': '1',
      'UBI': ubi,
      'STOKEN': stoken,
      'BDUSS': bduss,
      'PTOKEN': ptoken,
      'BDUSS_BFESS': bduss,
      'STOKEN_BFESS': stoken,
      'PTOKEN_BFESS': ptoken,
      'UBI_BFESS': ubi,
    });
    final fullCookie = jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: CloudCredentials(
        fields: {'cookie': fullCookie},
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      message: '百度网盘登录成功',
    );
  }

  Map<String, String> _authHeaders(CloudCredentials credentials) => {
    'User-Agent': _ua,
    'Cookie': credentials.fields['cookie'] ?? '',
  };

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final uri = Uri.parse(_xpanUrl).replace(
      queryParameters: {
        'method': 'list',
        'dir': folderId,
        'order': 'name',
        'desc': '0',
        'showempty': '0',
        'web': '1',
        'page': '$page',
        'num': '$_pageSize',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('百度文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '百度文件列表');
    if (_asInt(root['errno'], 0) != 0) {
      throw CloudDriveException('百度文件列表获取失败：${_asString(root['errmsg'], '接口报错')}');
    }
    final list = root['list'];
    final files = <CloudDriveFile>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) files.add(_parseItem(item));
      }
    }
    return CloudFolderPage(files: files, hasMore: files.length >= _pageSize);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final isFolder = _asInt(item['isdir']) == 1;
    final name = _asString(item['server_filename']);
    // 百度 category：1 视频 / 2 音频 / 3 图片（最佳推测，扩展名兜底）。
    CloudFileKind? hint;
    switch (_asInt(item['category'])) {
      case 1:
        hint = CloudFileKind.video;
      case 2:
        hint = CloudFileKind.audio;
      case 3:
        hint = CloudFileKind.image;
    }
    final kind = classifyCloudFile(name: name, isFolder: isFolder, providerHint: hint);
    var thumb = '';
    final thumbs = item['thumbs'];
    if (thumbs is Map<String, dynamic>) {
      thumb = _asString(thumbs['url3']);
      if (thumb.isEmpty) thumb = _asString(thumbs['url2']);
      if (thumb.isEmpty) thumb = _asString(thumbs['url1']);
    }
    return CloudDriveFile(
      id: _asString(item['fs_id']),
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: _asInt(item['size']),
      modifiedMs: _asInt(item['server_mtime']) * 1000,
      thumbnailUrl: thumb,
      extra: {'path': _asString(item['path'])},
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    final uri = Uri.parse(_xpanUrl).replace(
      queryParameters: {
        'method': 'search',
        'key': keyword,
        'dir': folderId,
        'recursion': '1',
        'web': '1',
        'page': '1',
        'num': '$_pageSize',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('百度搜索失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '百度搜索');
    final list = root['list'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) _parseItem(item),
    ];
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final path = file.extra['path'] ?? '';
    if (path.isEmpty) {
      throw CloudDriveException('百度取直链失败：缺少文件路径');
    }
    final uri = Uri.parse(_pcsUrl).replace(
      queryParameters: {
        'method': 'download',
        'app_id': '250528',
        'path': path,
      },
    );
    final request = http.Request('GET', uri)..headers.addAll(_authHeaders(credentials));
    final resolved = await resolveRedirects(client, request);
    return CloudDirectLink(url: resolved.url, headers: _authHeaders(credentials));
  }
}

// ---------------------------------------------------------------------------
// 阿里云盘（公开 OpenAPI 协议；TVBox_Web 里没有这家，全程标注未实测）
// ---------------------------------------------------------------------------

class AliyunProvider implements CloudDriveProvider {
  @override
  String get id => 'aliyun';
  @override
  String get displayName => '阿里云盘';
  @override
  String get appName => '阿里云盘 App';
  @override
  String get rootFolderId => 'root';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  static const _generateUrl =
      'https://passport.aliyundrive.com/newlogin/qrcode/generate.do';
  static const _queryUrl =
      'https://passport.aliyundrive.com/newlogin/qrcode/query.do';
  static const _tokenUrl = 'https://auth.aliyundrive.com/v2/account/token';
  static const _listUrl =
      'https://open.aliyundrive.com/adrive/v1.0/openFile/list';
  static const _downloadUrl =
      'https://open.aliyundrive.com/adrive/v1.0/openFile/getDownloadUrl';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36';

  /// 分页 marker 缓存：folderId -> 按页存的 marker（第 N 页用第 N-1 个）。
  final Map<String, List<String>> _markers = {};

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final uri = Uri.parse(_generateUrl).replace(
      queryParameters: {
        'appName': 'aliyun_drive',
        'fromSite': '52',
        'appEntrance': 'web',
      },
    );
    final response = await _postJson(client, uri, {
      'appName': 'aliyun_drive',
      'appEntrance': 'web',
    }, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      throw CloudDriveException('阿里二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '阿里二维码参数');
    final data = (root['content'] as Map?)?['data'];
    if (data is! Map<String, dynamic>) {
      throw CloudDriveException('阿里二维码参数获取失败：返回格式不对');
    }
    final codeContent = _asString(data['codeContent']);
    if (codeContent.isEmpty) {
      throw CloudDriveException('阿里二维码参数获取失败：缺少二维码内容');
    }
    return QrLoginSession(
      qrContent: codeContent,
      qrImageUrl: '',
      message: '请用阿里云盘 App 扫码确认',
      state: {
        't': _asString(data['t']),
        'ck': _asString(data['ck']),
      },
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final uri = Uri.parse(_queryUrl).replace(
      queryParameters: {
        'appName': 'aliyun_drive',
        'fromSite': '52',
      },
    );
    final response = await _postJson(client, uri, {
      't': session.state['t'] ?? '',
      'ck': session.state['ck'] ?? '',
      'appName': 'aliyun_drive',
      'appEntrance': 'web',
    }, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待阿里云盘 App 扫码确认',
      );
    }
    final root = _jsonObject(response.body, '阿里扫码状态');
    final data = (root['content'] as Map?)?['data'];
    if (data is! Map<String, dynamic>) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待阿里云盘 App 扫码确认',
      );
    }
    final status = _asString(data['status']);
    switch (status) {
      case 'LOGINED':
        return _finishLogin(client, data);
      case 'EXPIRED':
        return const QrPollResult(
          status: QrPollStatus.expired,
          message: '二维码已过期，请重新获取',
        );
      case 'SCANED':
        return const QrPollResult(
          status: QrPollStatus.scanned,
          message: '已扫码，请在阿里云盘 App 内确认登录',
        );
      default:
        return const QrPollResult(
          status: QrPollStatus.waiting,
          message: '等待阿里云盘 App 扫码确认',
        );
    }
  }

  Future<QrPollResult> _finishLogin(
    http.Client client,
    Map<String, dynamic> data,
  ) async {
    final bizExt = data['bizExt'];
    final loginResultRaw = bizExt is Map<String, dynamic>
        ? bizExt['pds_login_result']
        : null;
    Map<String, dynamic>? loginResult;
    if (loginResultRaw is String) {
      final decoded = jsonDecode(loginResultRaw);
      if (decoded is Map<String, dynamic>) loginResult = decoded;
    } else if (loginResultRaw is Map<String, dynamic>) {
      loginResult = loginResultRaw;
    }
    final refreshToken = _asString(loginResult?['refreshToken']);
    if (refreshToken.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '阿里登录失败：没有拿到刷新凭证',
      );
    }
    final credentials = await _exchangeToken(client, refreshToken);
    if (credentials == null) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '阿里登录失败：换取访问凭证失败',
      );
    }
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: credentials,
      message: '阿里云盘登录成功',
    );
  }

  /// 手动粘贴 refresh_token 登录（单手机用户扫不了自己屏幕时的兜底）：
  /// 用 refresh_token 换 access_token + drive_id，失败返回 null。
  Future<CloudCredentials?> credentialsFromRefreshToken(
    http.Client client,
    String refreshToken,
  ) =>
      _exchangeToken(client, refreshToken.trim());

  Future<CloudCredentials?> _exchangeToken(
    http.Client client,
    String refreshToken,
  ) async {
    final response = await _postJson(client, Uri.parse(_tokenUrl), {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    }, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) return null;
    final root = _jsonObject(response.body, '阿里换取凭证');
    final accessToken = _asString(root['access_token']);
    final newRefresh = _asString(root['refresh_token']);
    final driveId = _asString(root['default_drive_id']);
    if (accessToken.isEmpty || newRefresh.isEmpty || driveId.isEmpty) {
      return null;
    }
    return CloudCredentials(
      fields: {
        'refresh_token': newRefresh,
        'access_token': accessToken,
        'drive_id': driveId,
      },
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 带一次 401 续期重试的请求：续期成功后通知引擎落盘新凭证。
  Future<http.Response> _withAuth(
    http.Client client,
    CloudCredentials credentials,
    Future<http.Response> Function(String accessToken) run,
  ) async {
    var accessToken = credentials.fields['access_token'] ?? '';
    var response = await run(accessToken);
    if (response.statusCode == 401) {
      final refreshed = await _exchangeToken(
        client,
        credentials.fields['refresh_token'] ?? '',
      );
      if (refreshed != null) {
        onCredentialsRefreshed?.call(id, refreshed);
        accessToken = refreshed.fields['access_token'] ?? '';
        response = await run(accessToken);
      }
    }
    return response;
  }

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final driveId = credentials.fields['drive_id'] ?? '';
    final markers = _markers.putIfAbsent(folderId, () => []);
    final marker = page > 1 && markers.length >= page - 1
        ? markers[page - 2]
        : '';
    final body = <String, dynamic>{
      'drive_id': driveId,
      'parent_file_id': folderId,
      'limit': 100,
      'order_by': 'name',
      'order_direction': 'ASC',
      if (marker.isNotEmpty) 'marker': marker,
    };
    final response = await _withAuth(
      client,
      credentials,
      (token) => _postJson(
        client,
        Uri.parse(_listUrl),
        body,
        headers: {'Authorization': 'Bearer $token', 'User-Agent': _ua},
      ),
    );
    if (response.statusCode != 200) {
      throw CloudDriveException('阿里文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '阿里文件列表');
    final items = root['items'];
    final files = <CloudDriveFile>[];
    if (items is List) {
      for (final item in items) {
        if (item is Map<String, dynamic>) files.add(_parseItem(item));
      }
    }
    final nextMarker = _asString(root['next_marker']);
    if (nextMarker.isNotEmpty) {
      while (markers.length < page) {
        markers.add('');
      }
      markers[page - 1] = nextMarker;
    }
    return CloudFolderPage(files: files, hasMore: nextMarker.isNotEmpty);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final isFolder = _asString(item['type']) == 'folder';
    final name = _asString(item['name']);
    CloudFileKind? hint;
    switch (_asString(item['category'])) {
      case 'video':
        hint = CloudFileKind.video;
      case 'audio':
        hint = CloudFileKind.audio;
      case 'image':
        hint = CloudFileKind.image;
    }
    final kind = classifyCloudFile(name: name, isFolder: isFolder, providerHint: hint);
    int? duration;
    final meta = item['video_media_metadata'];
    if (meta is Map<String, dynamic> && meta['duration'] is num) {
      duration = (meta['duration'] as num).toInt();
    }
    var modifiedMs = 0;
    final updated = _asString(item['updated_at']);
    if (updated.isNotEmpty) {
      modifiedMs = DateTime.tryParse(updated)?.millisecondsSinceEpoch ?? 0;
    }
    return CloudDriveFile(
      id: _asString(item['file_id']),
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: _asInt(item['size']),
      modifiedMs: modifiedMs,
      durationSeconds: duration,
      thumbnailUrl: _asString(item['thumbnail']),
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    // 阿里 OpenAPI 没有搜索接口，走引擎的“取列表后按名过滤”兜底。
    throw UnsupportedError('阿里云盘没有站方搜索接口');
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final driveId = credentials.fields['drive_id'] ?? '';
    final response = await _withAuth(
      client,
      credentials,
      (token) => _postJson(
        client,
        Uri.parse(_downloadUrl),
        {'drive_id': driveId, 'file_id': file.id},
        headers: {'Authorization': 'Bearer $token', 'User-Agent': _ua},
      ),
    );
    if (response.statusCode != 200) {
      throw CloudDriveException('阿里取直链失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '阿里直链');
    final url = _asString(root['url']);
    if (url.isEmpty) {
      throw CloudDriveException('阿里取直链失败：没有返回下载地址');
    }
    return CloudDirectLink(url: url);
  }
}

// ---------------------------------------------------------------------------
// 注册表
// ---------------------------------------------------------------------------

/// 四家网盘客户端（每次调用新建实例；阿里实例带分页 marker 缓存，
/// 引擎内只建一次、复用到底）。
List<CloudDriveProvider> createCloudDriveProviders() => [
  Pan115Provider(),
  QuarkProvider(),
  AliyunProvider(),
  BaiduProvider(),
];

/// 网盘 id → 显示名（界面与站点注册共用）。
const cloudDriveDisplayNames = <String, String>{
  'pan115': '115网盘',
  'quark': '夸克网盘',
  'aliyun': '阿里云盘',
  'baidu': '百度网盘',
};
