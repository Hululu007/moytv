import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// SOCKS5 代理管理：代理列表、延迟探测、按资源选代理的路由。
///
/// 关键事实（Dart 3.13 SDK 实测源码结论）：`HttpClient.findProxy` 只认
/// `PROXY host:port` 与 `DIRECT` 两种写法，SDK 里根本没有 SOCKS 分支，
/// 返回 `SOCKS host:port` 会在请求时抛 `HttpException("Invalid proxy
/// configuration")`。所以 SOCKS5 不能直接挂 findProxy。
///
/// 本文件的走法是本地转发器（与 mihomo 混合端口同一形态）：每个
/// SOCKS5 代理对应一个 127.0.0.1 临时端口的转发器
/// （[Socks5ForwarderPool]），HttpClient 用标准 `PROXY 127.0.0.1:端口`
/// 写法——https 由 SDK 自己发 CONNECT 建隧道、自己做 TLS，http 发
/// 绝对地址请求；转发器只做两件事：解析 CONNECT/绝对地址出目标，
/// 再经 SOCKS5 握手连目标并双向透传字节。不走自定义
/// `connectionFactory`：Socket 流是单订阅的，握手监听过的 socket
/// 无法再交给 HttpClient（实测抛 `Stream has already been listened
/// to`），而 SecureSocket.secure 接管已监听 socket 在实测里握手失败。
/// 握手走 RFC 1928/1929：问候、用户名密码子协商、CONNECT，域名/
/// IPv4/IPv6 三种地址形态都支持。回环目标由 findProxy 闭包直接
/// DIRECT，不进转发器（本地中继/127.0.0.1 服务必须直连）。
///
/// 密码口径：树里没有 flutter_secure_storage，代理密码与既有
/// NetworkConfigService 的做法同级，存 SharedPreferences（非加密），
/// 绝不记日志、界面遮掩显示。不要把密码拼进任何异常信息或 findProxy
/// 字符串里。

/// 延迟探测的目标：与 NetworkConfigService.testProxy 同一个 204 探针。
const String socks5ProbeUrl = 'https://www.gstatic.com/generate_204';

/// 资源分配里“直连”的取值：该资源强制 DIRECT，不走任何代理。
const String socks5DirectAssignment = 'direct';

/// 网页抓取/探站链路（ContentHttp）的资源键。
const String socks5ScrapeResourceKey = 'scrape';

/// 直播源的资源键。
String socks5LiveResourceKey(String sourceId) => 'live:$sourceId';

/// m3u 订阅的资源键。
String socks5M3uResourceKey(String subscriptionId) => 'm3u:$subscriptionId';

class Socks5Failure implements Exception {
  Socks5Failure(this.message);
  final String message;
  @override
  String toString() => message;
}

String _socks5NewId() {
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final salt = Random().nextInt(1 << 20).toRadixString(36);
  return 'socks5_${stamp}_$salt';
}

/// 一条 SOCKS5 代理。密码只随 JSON 落盘，[displayAddress] 与异常信息
/// 里永远不出现密码与用户名。
class Socks5ProxyEntry {
  const Socks5ProxyEntry({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
    this.enabled = true,
    this.lastLatencyMs,
    this.lastAvailable,
    this.lastCheckedAtMs = 0,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String password;
  final bool enabled;

  /// 最近一次延迟测试的结果：null 表示从未测通或最近一次未测通。
  final int? lastLatencyMs;

  /// 最近一次延迟测试是否测通：null 表示从未测试。
  final bool? lastAvailable;

  /// 最近一次延迟测试的时间戳（毫秒）。
  final int lastCheckedAtMs;

  /// 安全展示地址：只有 host:port，绝不带凭证。
  String get displayAddress => '$host:$port';

  Socks5ProxyEntry copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    bool? enabled,
    int? lastLatencyMs,
    bool? lastAvailable,
    int? lastCheckedAtMs,
    bool clearLatency = false,
  }) => Socks5ProxyEntry(
    id: id ?? this.id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    password: password ?? this.password,
    enabled: enabled ?? this.enabled,
    lastLatencyMs: clearLatency ? null : (lastLatencyMs ?? this.lastLatencyMs),
    lastAvailable: lastAvailable ?? this.lastAvailable,
    lastCheckedAtMs: lastCheckedAtMs ?? this.lastCheckedAtMs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'enabled': enabled,
    if (lastLatencyMs != null) 'lastLatencyMs': lastLatencyMs,
    if (lastAvailable != null) 'lastAvailable': lastAvailable,
    'lastCheckedAtMs': lastCheckedAtMs,
  };

  factory Socks5ProxyEntry.fromJson(Map<String, dynamic> json) {
    final latency = (json['lastLatencyMs'] as num?)?.toInt();
    final available = json['lastAvailable'];
    return Socks5ProxyEntry(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      host: '${json['host'] ?? ''}',
      port: (json['port'] as num?)?.toInt() ?? 0,
      username: '${json['username'] ?? ''}',
      password: '${json['password'] ?? ''}',
      enabled: json['enabled'] != false,
      lastLatencyMs: latency,
      lastAvailable: available is bool ? available : null,
      lastCheckedAtMs: (json['lastCheckedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 校验一条代理的输入：返回 null 表示通过，否则返回中文错误原因。
/// 用户名/密码按 SOCKS5 协议各限 255 字节（单字节长度字段）。
String? validateSocks5ProxyEntry({
  required String host,
  required int port,
  required String username,
  required String password,
}) {
  final trimmedHost = host.trim();
  if (trimmedHost.isEmpty) return '请填写代理地址';
  if (trimmedHost.contains(RegExp(r'\s'))) return '代理地址不能包含空格';
  if (utf8.encode(trimmedHost).length > 255) return '代理地址过长';
  if (port < 1 || port > 65535) return '端口应为 1 至 65535';
  if (utf8.encode(username).length > 255) return '用户名过长（限 255 字节）';
  if (utf8.encode(password).length > 255) return '密码过长（限 255 字节）';
  if (username.isEmpty && password.isNotEmpty) return '没有用户名时密码不会生效，请先填用户名';
  return null;
}

abstract class Socks5ProxyStore {
  Future<String> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class SharedPreferencesSocks5ProxyStore implements Socks5ProxyStore {
  @override
  Future<String> read(String key) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(key) ?? '';
  }

  @override
  Future<void> write(String key, String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
  }
}

class MemorySocks5ProxyStore implements Socks5ProxyStore {
  final _values = <String, String>{};

  @override
  Future<String> read(String key) async => _values[key] ?? '';

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}

enum Socks5RouteKind { fallback, direct, via }

/// 一次按资源路由的决策。
class Socks5Route {
  const Socks5Route.fallback() : kind = Socks5RouteKind.fallback, entry = null;
  const Socks5Route.direct() : kind = Socks5RouteKind.direct, entry = null;
  const Socks5Route.via(this.entry) : kind = Socks5RouteKind.via;

  final Socks5RouteKind kind;
  final Socks5ProxyEntry? entry;

  /// 客户端缓存键：代理的地址/端口/用户名任一变化就换新客户端，
  /// 避免旧连接复用改过的配置。
  String get clientKey {
    final target = entry;
    if (kind != Socks5RouteKind.via || target == null) return kind.name;
    return 'via:${target.id}:${target.host}:${target.port}:${target.username}';
  }
}

/// 纯函数：按资源键算路由。
///
/// - 无资源键 / 无分配 / 分配指向不存在或已停用的代理 → fallback：
///   走调用方原有链路（代理内核全局 findProxy），绝不因配错断网。
/// - 分配为 `direct` → 强制直连。
/// - 分配指向已启用的代理 → 走该 SOCKS5 代理。
Socks5Route resolveSocks5Route(
  String? resourceKey,
  List<Socks5ProxyEntry> proxies,
  Map<String, String> assignments,
) {
  if (resourceKey == null || resourceKey.isEmpty) {
    return const Socks5Route.fallback();
  }
  final assignment = assignments[resourceKey];
  if (assignment == null || assignment.isEmpty) {
    return const Socks5Route.fallback();
  }
  if (assignment == socks5DirectAssignment) {
    return const Socks5Route.direct();
  }
  for (final proxy in proxies) {
    if (proxy.id == assignment) {
      return proxy.enabled
          ? Socks5Route.via(proxy)
          : const Socks5Route.fallback();
    }
  }
  return const Socks5Route.fallback();
}

/// 路由快照：路由决策取内存快照，不在每次请求时读异步存储；
/// 服务每次改动后同步快照并 bump [generation]，各 HTTP 层凭
/// generation 失效自己缓存的按代理客户端。
class Socks5ProxyRouter {
  Socks5ProxyRouter();

  static final Socks5ProxyRouter instance = Socks5ProxyRouter();

  List<Socks5ProxyEntry> _proxies = const [];
  Map<String, String> _assignments = const {};
  int _generation = 0;

  List<Socks5ProxyEntry> get proxies => List.unmodifiable(_proxies);
  Map<String, String> get assignments => Map.unmodifiable(_assignments);
  int get generation => _generation;

  void update(List<Socks5ProxyEntry> proxies, Map<String, String> assignments) {
    _proxies = List.unmodifiable(proxies);
    _assignments = Map.unmodifiable(assignments);
    _generation++;
  }

  Socks5Route resolve(String? resourceKey) =>
      resolveSocks5Route(resourceKey, _proxies, _assignments);
}

// ---------------------------------------------------------------------------
// SOCKS5 握手与本地转发器
// ---------------------------------------------------------------------------

bool _isLoopbackHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower == '::1' || lower == '[::1]') return true;
  final parsed = InternetAddress.tryParse(host);
  return parsed?.isLoopback ?? false;
}

/// 单订阅 socket 的缓冲读取器：握手阶段按需取精确字节数；握手完成后
/// [takeRemaining] 把订阅切换成转发模式——握手后多读到的字节与后续
/// 到达的字节都经同一个订阅转发出去，绝不取消订阅再重监听（Socket
/// 流只允许监听一次，重监听抛错）。
class _Socks5Reader {
  _Socks5Reader(Socket socket) {
    _subscription = socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = <int>[];
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;
  StreamController<Uint8List>? _forward;

  void _onData(Uint8List data) {
    final forward = _forward;
    if (forward != null) {
      if (!forward.isClosed) forward.add(data);
      return;
    }
    _buffer.addAll(data);
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  void _onError(Object error) {
    final forward = _forward;
    if (forward != null) {
      if (!forward.isClosed) forward.addError(error);
      return;
    }
    _error = error;
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  void _onDone() {
    final forward = _forward;
    if (forward != null) {
      if (!forward.isClosed) forward.close();
      return;
    }
    _done = true;
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  Future<Uint8List> readExactly(int count) async {
    while (_buffer.length < count) {
      final error = _error;
      if (error != null) throw error;
      if (_done) {
        throw const SocketException('SOCKS5 代理提前关闭了连接');
      }
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return out;
  }

  /// 读到 [marker]（含）为止，返回含 marker 的全部字节；剩余字节
  /// 留在缓冲里供 [takeRemaining] 转发。超过 [maxBytes] 仍未命中抛错。
  Future<Uint8List> readUntil(
    List<int> marker, {
    int maxBytes = 65536,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (var i = 0; i + marker.length <= _buffer.length; i++) {
        var hit = true;
        for (var j = 0; j < marker.length; j++) {
          if (_buffer[i + j] != marker[j]) {
            hit = false;
            break;
          }
        }
        if (hit) {
          final end = i + marker.length;
          final out = Uint8List.fromList(_buffer.sublist(0, end));
          _buffer.removeRange(0, end);
          return out;
        }
      }
      final error = _error;
      if (error != null) throw error;
      if (_done) throw const SocketException('连接提前关闭');
      if (_buffer.length > maxBytes) {
        throw Socks5Failure('请求头过大');
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) throw TimeoutException('读取请求头超时');
      _waiter = Completer<void>();
      await _waiter!.future.timeout(remaining);
    }
  }

  /// 切换到转发模式并返回后续字节流：调用前缓冲里剩下的字节先发出，
  /// 之后到达的字节直接转发。只能调用一次。
  Stream<Uint8List> takeRemaining() {
    if (_forward != null) {
      throw StateError('takeRemaining 只能调用一次');
    }
    final controller = StreamController<Uint8List>();
    _forward = controller;
    if (_buffer.isNotEmpty) {
      controller.add(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
    if (_done) controller.close();
    final error = _error;
    if (error != null) controller.addError(error);
    return controller.stream;
  }

  Future<void> close() async {
    await _subscription.cancel();
    final forward = _forward;
    if (forward != null && !forward.isClosed) await forward.close();
  }
}

String _socks5ReplyMessage(int rep) => switch (rep) {
  1 => 'SOCKS5 代理返回通用失败',
  2 => 'SOCKS5 代理拒绝了该连接（规则不允许）',
  3 => 'SOCKS5 代理无法到达目标网络',
  4 => 'SOCKS5 代理无法到达目标主机',
  5 => '目标主机拒绝了连接',
  6 => 'SOCKS5 代理返回 TTL 耗尽',
  7 => 'SOCKS5 代理不支持 CONNECT 命令',
  8 => 'SOCKS5 代理不支持该地址类型',
  _ => 'SOCKS5 代理连接失败（REP=$rep）',
};

/// 一条已握手完成的 SOCKS5 隧道：[socket] 供写，[incoming] 是
/// 握手后到达的字节流（由握手读取器转发而来，订阅从未取消）。
/// 用完调 [close]，同时关 socket 与读取订阅。
class Socks5Tunnel {
  Socks5Tunnel(this.socket, this.incoming, this._closeReader);

  final Socket socket;
  final Stream<Uint8List> incoming;
  final Future<void> Function() _closeReader;

  Future<void> close() async {
    try {
      await _closeReader();
    } catch (_) {}
    socket.destroy();
  }
}

/// 经 [entry] 指定的 SOCKS5 代理连通到 [targetHost]:[targetPort]，
/// 完成握手后返回隧道（只做 TCP 透传，不做 TLS——TLS 由调用方
/// 在隧道上自己完成，或由 HttpClient 经转发器的 CONNECT 完成）。
/// 任何失败都抛 [Socks5Failure]/[SocketException]，信息里不含凭证。
Future<Socks5Tunnel> socks5OpenTunnel(
  String targetHost,
  int targetPort,
  Socks5ProxyEntry entry, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (targetHost.isEmpty || targetPort < 1 || targetPort > 65535) {
    throw Socks5Failure('目标地址无效');
  }
  final socket = await Socket.connect(
    entry.host,
    entry.port,
    timeout: timeout,
  ).timeout(timeout);
  final reader = _Socks5Reader(socket);
  try {
    await _socks5Handshake(reader, socket, entry, targetHost, targetPort)
        .timeout(timeout);
    return Socks5Tunnel(socket, reader.takeRemaining(), reader.close);
  } catch (error) {
    try {
      await reader.close();
    } catch (_) {}
    socket.destroy();
    if (error is TimeoutException) {
      throw Socks5Failure('连接 SOCKS5 代理 ${entry.displayAddress} 超时');
    }
    if (error is Socks5Failure || error is SocketException) rethrow;
    throw Socks5Failure('连接 SOCKS5 代理 ${entry.displayAddress} 失败：$error');
  }
}

Future<void> _socks5Handshake(
  _Socks5Reader reader,
  Socket socket,
  Socks5ProxyEntry entry,
  String targetHost,
  int targetPort,
) async {
  final hasCredentials = entry.username.isNotEmpty;
  socket.add(
    hasCredentials
        ? const [0x05, 0x02, 0x00, 0x02]
        : const [0x05, 0x01, 0x00],
  );
  await socket.flush();
  final greeting = await reader.readExactly(2);
  if (greeting[0] != 0x05) {
    throw Socks5Failure(
      '代理 ${entry.displayAddress} 不是 SOCKS5（版本 ${greeting[0]}）',
    );
  }
  final method = greeting[1];
  if (method == 0xFF) {
    throw Socks5Failure('代理 ${entry.displayAddress} 拒绝了认证方式');
  }
  if (method == 0x02) {
    if (!hasCredentials) {
      throw Socks5Failure('代理 ${entry.displayAddress} 要求用户名密码认证');
    }
    final userBytes = utf8.encode(entry.username);
    final passBytes = utf8.encode(entry.password);
    socket.add([
      0x01,
      userBytes.length,
      ...userBytes,
      passBytes.length,
      ...passBytes,
    ]);
    await socket.flush();
    final auth = await reader.readExactly(2);
    if (auth[0] != 0x01 || auth[1] != 0x00) {
      throw Socks5Failure('代理 ${entry.displayAddress} 拒绝了用户名或密码');
    }
  } else if (method != 0x00) {
    throw Socks5Failure(
      '代理 ${entry.displayAddress} 要求不支持的认证方式（$method）',
    );
  }
  final request = <int>[0x05, 0x01, 0x00];
  final bareHost =
      targetHost.startsWith('[') && targetHost.endsWith(']')
      ? targetHost.substring(1, targetHost.length - 1)
      : targetHost;
  final parsed = InternetAddress.tryParse(bareHost);
  if (parsed != null && parsed.type == InternetAddressType.IPv4) {
    request.add(0x01);
    request.addAll(parsed.rawAddress);
  } else if (parsed != null && parsed.type == InternetAddressType.IPv6) {
    request.add(0x04);
    request.addAll(parsed.rawAddress);
  } else {
    final hostBytes = utf8.encode(bareHost);
    if (hostBytes.length > 255) {
      throw Socks5Failure('目标主机名过长，SOCKS5 无法表示');
    }
    request.add(0x03);
    request.add(hostBytes.length);
    request.addAll(hostBytes);
  }
  request.addAll([targetPort >> 8, targetPort & 0xFF]);
  socket.add(request);
  await socket.flush();
  final header = await reader.readExactly(4);
  if (header[0] != 0x05) {
    throw Socks5Failure('代理 ${entry.displayAddress} 返回了无效的 SOCKS5 应答');
  }
  if (header[1] != 0x00) {
    throw Socks5Failure(_socks5ReplyMessage(header[1]));
  }
  final addressType = header[3];
  final int addressLength;
  if (addressType == 0x01) {
    addressLength = 4;
  } else if (addressType == 0x04) {
    addressLength = 16;
  } else if (addressType == 0x03) {
    final lengthByte = await reader.readExactly(1);
    addressLength = lengthByte[0];
  } else {
    throw Socks5Failure(
      '代理 ${entry.displayAddress} 返回了不支持的地址类型（$addressType）',
    );
  }
  await reader.readExactly(addressLength + 2);
}

/// 把 [aIncoming] 的字节写给 [b]、把 [bIncoming] 的字节写给 [a]，
/// 任一一边结束/出错就两边一起销毁。[prefixToB] 先于 [aIncoming]
/// 的字节写给 [b]（绝对地址请求的完整请求头，需原样转发给目标）。
Future<void> _pipeSockets(
  Socket a,
  Stream<Uint8List> aIncoming,
  Socket b,
  Stream<Uint8List> bIncoming, {
  List<int> prefixToB = const [],
}) {
  final done = Completer<void>();
  var closed = false;
  late final StreamSubscription<Uint8List> subA;
  late final StreamSubscription<Uint8List> subB;

  Future<void> teardown() async {
    if (closed) return;
    closed = true;
    try {
      await subA.cancel();
    } catch (_) {}
    try {
      await subB.cancel();
    } catch (_) {}
    a.destroy();
    b.destroy();
    if (!done.isCompleted) done.complete();
  }

  if (prefixToB.isNotEmpty) {
    try {
      b.add(prefixToB);
    } catch (_) {
      a.destroy();
      b.destroy();
      done.complete();
      return done.future;
    }
  }
  subA = aIncoming.listen(
    (data) {
      try {
        b.add(data);
      } catch (_) {
        unawaited(teardown());
      }
    },
    onError: (_) => unawaited(teardown()),
    onDone: () => unawaited(teardown()),
    cancelOnError: true,
  );
  subB = bIncoming.listen(
    (data) {
      try {
        a.add(data);
      } catch (_) {
        unawaited(teardown());
      }
    },
    onError: (_) => unawaited(teardown()),
    onDone: () => unawaited(teardown()),
    cancelOnError: true,
  );
  return done.future;
}

/// 单个 SOCKS5 代理的本地转发器：监听 127.0.0.1 临时端口，接受标准
/// HTTP 代理请求（CONNECT 隧道与绝对地址请求），经 SOCKS5 握手后
/// 透传。只绑回环，不对外暴露。
class _Socks5Forwarder {
  _Socks5Forwarder._(this.entry, this._server);

  final Socks5ProxyEntry entry;
  final ServerSocket _server;

  int get port => _server.port;

  static Future<_Socks5Forwarder> start(Socks5ProxyEntry entry) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final forwarder = _Socks5Forwarder._(entry, server);
    server.listen(forwarder._handle, onError: (_) {});
    return forwarder;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket local) async {
    final reader = _Socks5Reader(local);
    try {
      final headBytes = await reader.readUntil(
        const [13, 10, 13, 10],
        timeout: const Duration(seconds: 10),
      );
      final head = latin1.decode(headBytes);
      final firstLineEnd = head.indexOf('\r\n');
      final firstLine = firstLineEnd < 0
          ? head.trim()
          : head.substring(0, firstLineEnd);
      final parts = firstLine.split(' ');
      if (parts.length < 2) {
        local.destroy();
        return;
      }
      final method = parts[0].toUpperCase();
      final target = parts[1];
      if (method == 'CONNECT') {
        await _handleConnect(local, reader, target);
      } else {
        await _handleAbsolute(local, reader, headBytes, target);
      }
    } catch (_) {
      local.destroy();
    } finally {
      try {
        await reader.close();
      } catch (_) {}
    }
  }

  Future<void> _handleConnect(
    Socket local,
    _Socks5Reader reader,
    String target,
  ) async {
    final colon = target.lastIndexOf(':');
    if (colon <= 0 || colon == target.length - 1) {
      local.destroy();
      return;
    }
    final host = target.substring(0, colon);
    final port = int.tryParse(target.substring(colon + 1)) ?? 0;
    if (host.isEmpty || port < 1 || port > 65535) {
      local.destroy();
      return;
    }
    Socks5Tunnel tunnel;
    try {
      tunnel = await socks5OpenTunnel(host, port, entry);
    } catch (_) {
      try {
        local.add(
          utf8.encode('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n'),
        );
        await local.flush();
      } catch (_) {}
      local.destroy();
      return;
    }
    try {
      local.add(utf8.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      await local.flush();
    } catch (_) {
      await tunnel.close();
      local.destroy();
      return;
    }
    try {
      await _pipeSockets(
        local,
        reader.takeRemaining(),
        tunnel.socket,
        tunnel.incoming,
      );
    } finally {
      await tunnel.close();
    }
  }

  Future<void> _handleAbsolute(
    Socket local,
    _Socks5Reader reader,
    Uint8List headBytes,
    String target,
  ) async {
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      local.destroy();
      return;
    }
    final port = uri.port != 0 ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    Socks5Tunnel tunnel;
    try {
      tunnel = await socks5OpenTunnel(uri.host, port, entry);
    } catch (_) {
      try {
        local.add(
          utf8.encode('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n'),
        );
        await local.flush();
      } catch (_) {}
      local.destroy();
      return;
    }
    try {
      await _pipeSockets(
        local,
        reader.takeRemaining(),
        tunnel.socket,
        tunnel.incoming,
        prefixToB: headBytes,
      );
    } finally {
      await tunnel.close();
    }
  }
}

/// 转发器池：每个代理配置一个转发器，配置变化（地址/端口/凭证）
/// 就换新转发器。转发器只在第一次被用到时才起，起好后一直留着，
/// 直到 [closeAll]（进程退出时由系统回收亦可，端口是回环临时的）。
class Socks5ForwarderPool {
  Socks5ForwarderPool();

  static final Socks5ForwarderPool instance = Socks5ForwarderPool();

  final Map<String, Future<_Socks5Forwarder>> _pending = {};
  final Map<String, _Socks5Forwarder> _running = {};

  String _key(Socks5ProxyEntry entry) =>
      '${entry.id}|${entry.host}|${entry.port}|${entry.username}|${entry.password}';

  /// 确保 [entry] 的转发器已起，返回其回环端口。
  Future<int> ensurePort(Socks5ProxyEntry entry) async {
    final key = _key(entry);
    final running = _running[key];
    if (running != null) return running.port;
    final pending = _pending.putIfAbsent(key, () async {
      final forwarder = await _Socks5Forwarder.start(entry);
      _running[key] = forwarder;
      _pending.remove(key);
      return forwarder;
    });
    return (await pending).port;
  }

  Future<void> closeAll() async {
    final forwarders = _running.values.toList();
    _running.clear();
    _pending.clear();
    for (final forwarder in forwarders) {
      try {
        await forwarder.close();
      } catch (_) {}
    }
  }
}

/// 建一个经转发器走 [forwarderPort] 的 HttpClient：标准 PROXY 写法，
/// 回环目标直连（不进转发器），其余目标走转发器。
HttpClient buildForwardedHttpClient(
  int forwarderPort, {
  Duration connectionTimeout = const Duration(seconds: 10),
}) {
  final client = HttpClient()..connectionTimeout = connectionTimeout;
  client.findProxy = (uri) => _isLoopbackHost(uri.host)
      ? 'DIRECT'
      : 'PROXY 127.0.0.1:$forwarderPort';
  return client;
}

// ---------------------------------------------------------------------------
// 延迟探测
// ---------------------------------------------------------------------------

class Socks5ProbeResult {
  const Socks5ProbeResult({required this.available, this.latencyMs});

  final bool available;

  /// 测通时的往返毫秒；未测通为 null（没有假数字）。
  final int? latencyMs;
}

/// 探测传输：经某代理取探测 URL，返回状态码，失败抛错。
/// 抽象出来供测试注入假实现；真实实现走 SOCKS5 握手发真请求。
abstract class Socks5ProbeTransport {
  Future<int> fetchStatus(Socks5ProxyEntry entry);
}

class HttpClientSocks5ProbeTransport implements Socks5ProbeTransport {
  HttpClientSocks5ProbeTransport({
    this.probeUrl = socks5ProbeUrl,
    this.timeout = const Duration(seconds: 10),
    Socks5ForwarderPool? forwarderPool,
  }) : _forwarderPool = forwarderPool ?? Socks5ForwarderPool.instance;

  final String probeUrl;
  final Duration timeout;
  final Socks5ForwarderPool _forwarderPool;

  @override
  Future<int> fetchStatus(Socks5ProxyEntry entry) async {
    final port = await _forwarderPool.ensurePort(entry);
    final client = buildForwardedHttpClient(
      port,
      connectionTimeout: timeout,
    );
    try {
      final request = await client
          .getUrl(Uri.parse(probeUrl))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}

/// 延迟测试器：时钟可注入（测试用假时钟），传输可注入（测试用假客户端）。
class Socks5LatencyTester {
  Socks5LatencyTester({
    required this.transport,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Socks5ProbeTransport transport;
  final DateTime Function() _clock;

  Future<Socks5ProbeResult> test(Socks5ProxyEntry entry) async {
    final start = _clock();
    try {
      final status = await transport.fetchStatus(entry);
      final elapsed = _clock().difference(start).inMilliseconds;
      if (status >= 200 && status < 400) {
        return Socks5ProbeResult(available: true, latencyMs: elapsed);
      }
      return const Socks5ProbeResult(available: false);
    } catch (_) {
      return const Socks5ProbeResult(available: false);
    }
  }
}

// ---------------------------------------------------------------------------
// 服务：增删改、分配、一键识别
// ---------------------------------------------------------------------------

class Socks5ProxyService {
  Socks5ProxyService({
    Socks5ProxyStore? store,
    Socks5ProxyRouter? router,
    Socks5LatencyTester? tester,
  }) : _store = store ?? SharedPreferencesSocks5ProxyStore(),
       _router = router ?? Socks5ProxyRouter.instance,
       _tester =
           tester ??
           Socks5LatencyTester(
             transport: HttpClientSocks5ProbeTransport(),
           );

  static const String proxiesKey = 'socks5_proxies_json';
  static const String assignmentsKey = 'socks5_resource_assignments_json';

  final Socks5ProxyStore _store;
  final Socks5ProxyRouter _router;
  final Socks5LatencyTester _tester;

  Socks5ProxyRouter get router => _router;

  Future<List<Socks5ProxyEntry>> loadProxies() async {
    final raw = await _store.read(proxiesKey);
    if (raw.isEmpty) return <Socks5ProxyEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Socks5ProxyEntry>[];
      final entries = <Socks5ProxyEntry>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final entry = Socks5ProxyEntry.fromJson(
          item.cast<String, dynamic>(),
        );
        if (entry.id.isEmpty || entry.host.isEmpty || entry.port <= 0) {
          continue;
        }
        if (!seen.add(entry.id)) continue;
        entries.add(entry);
      }
      return entries;
    } catch (_) {
      return <Socks5ProxyEntry>[];
    }
  }

  Future<void> _saveProxies(List<Socks5ProxyEntry> entries) async {
    await _store.write(
      proxiesKey,
      jsonEncode([for (final entry in entries) entry.toJson()]),
    );
    await _syncRouter(proxies: entries);
  }

  Future<Map<String, String>> loadAssignments() async {
    final raw = await _store.read(assignmentsKey);
    if (raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final assignments = <String, String>{};
      decoded.forEach((key, value) {
        if (key is String && value is String && key.isNotEmpty) {
          assignments[key] = value;
        }
      });
      return assignments;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _saveAssignments(Map<String, String> assignments) async {
    await _store.write(assignmentsKey, jsonEncode(assignments));
    await _syncRouter(assignments: assignments);
  }

  Future<void> _syncRouter({
    List<Socks5ProxyEntry>? proxies,
    Map<String, String>? assignments,
  }) async {
    _router.update(
      proxies ?? await loadProxies(),
      assignments ?? await loadAssignments(),
    );
  }

  /// 启动时把持久化数据恢复进路由快照，失败不抛（保持默认直连/内核链路）。
  Future<void> refreshRouter() => _syncRouter();

  static Future<void> maybeLoadRouter() async {
    try {
      await Socks5ProxyService().refreshRouter();
    } catch (_) {}
  }

  Future<Socks5ProxyEntry> addProxy({
    required String name,
    required String host,
    required int port,
    String username = '',
    String password = '',
    bool enabled = true,
  }) async {
    final trimmedHost = host.trim();
    final error = validateSocks5ProxyEntry(
      host: trimmedHost,
      port: port,
      username: username,
      password: password,
    );
    if (error != null) throw Socks5Failure(error);
    final entry = Socks5ProxyEntry(
      id: _socks5NewId(),
      name: name.trim().isEmpty ? '$trimmedHost:$port' : name.trim(),
      host: trimmedHost,
      port: port,
      username: username,
      password: password,
      enabled: enabled,
    );
    final entries = [...await loadProxies()];
    entries.add(entry);
    await _saveProxies(entries);
    return entry;
  }

  Future<void> updateProxy(Socks5ProxyEntry entry) async {
    final error = validateSocks5ProxyEntry(
      host: entry.host,
      port: entry.port,
      username: entry.username,
      password: entry.password,
    );
    if (error != null) throw Socks5Failure(error);
    final entries = [...await loadProxies()];
    final index = entries.indexWhere((item) => item.id == entry.id);
    if (index < 0) throw Socks5Failure('该代理已被删除');
    entries[index] = entry;
    await _saveProxies(entries);
  }

  Future<void> removeProxy(String id) async {
    final entries = [...await loadProxies()];
    entries.removeWhere((item) => item.id == id);
    await _saveProxies(entries);
    final assignments = Map<String, String>.from(await loadAssignments());
    var changed = false;
    assignments.removeWhere((_, value) {
      if (value == id) {
        changed = true;
        return true;
      }
      return false;
    });
    if (changed) await _saveAssignments(assignments);
  }

  Future<void> setProxyEnabled(String id, bool enabled) async {
    final entries = [...await loadProxies()];
    final index = entries.indexWhere((item) => item.id == id);
    if (index < 0) return;
    entries[index] = entries[index].copyWith(enabled: enabled);
    await _saveProxies(entries);
  }

  /// 设置某资源的代理：[assignment] 为代理 id、'direct'（直连），
  /// null/空表示删掉分配、跟随默认链路。
  Future<void> setAssignment(String resourceKey, String? assignment) async {
    if (resourceKey.isEmpty) return;
    final assignments = Map<String, String>.from(await loadAssignments());
    final value = (assignment ?? '').trim();
    if (value.isEmpty) {
      assignments.remove(resourceKey);
    } else {
      assignments[resourceKey] = value;
    }
    await _saveAssignments(assignments);
  }

  /// 测一个代理并把结果写回持久化，返回更新后的条目。
  Future<Socks5ProxyEntry> testOne(Socks5ProxyEntry entry) async {
    final result = await _tester.test(entry);
    final updated = entry.copyWith(
      lastLatencyMs: result.latencyMs,
      lastAvailable: result.available,
      lastCheckedAtMs: DateTime.now().millisecondsSinceEpoch,
      clearLatency: result.latencyMs == null,
    );
    final entries = [...await loadProxies()];
    final index = entries.indexWhere((item) => item.id == entry.id);
    if (index >= 0) {
      entries[index] = updated;
      await _saveProxies(entries);
    }
    return updated;
  }

  /// 一键识别：逐个（不并发，避免 burst）测全部已存代理，
  /// 测通标可用、测不通标不可用，结果全部写回持久化。
  /// [onProgress] 在每测完一个后回调。
  Future<List<Socks5ProxyEntry>> identifyAll({
    void Function(Socks5ProxyEntry entry, int index, int total)? onProgress,
  }) async {
    final entries = await loadProxies();
    final updated = <Socks5ProxyEntry>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final result = await _tester.test(entry);
      final next = entry.copyWith(
        lastLatencyMs: result.latencyMs,
        lastAvailable: result.available,
        lastCheckedAtMs: DateTime.now().millisecondsSinceEpoch,
        clearLatency: result.latencyMs == null,
      );
      updated.add(next);
      onProgress?.call(next, i, entries.length);
    }
    await _saveProxies(updated);
    return updated;
  }
}
