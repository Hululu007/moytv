import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:moyi/content_http.dart';
import 'package:moyi/live_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/socks5_proxy.dart';

/// 真实网络测试：必须与 flutter_test 的 widget 测试分文件。
/// TestWidgetsFlutterBinding 会把全部 HttpClient 请求 mock 成 400，
/// 本文件只用 test()/group()，绝不用 testWidgets：声明 testWidgets
/// 时 TestWidgetsFlutterBinding 就会创建并把 HttpClient mock 成 400。

/// 测试用 SOCKS5 假服务器：做问候/认证/CONNECT 握手，握手成功后
/// 不论 CONNECT 的目标是什么，都回一段固定 HTTP 200（只证明握手与
/// 透传链路，不做真实转发）。
class _FakeSocks5Server {
  _FakeSocks5Server._(this._server, {this.expectUser, this.expectPass, this.connectRep = 0});

  final ServerSocket _server;
  final String? expectUser;
  final String? expectPass;
  final int connectRep;

  bool sawAuth = false;
  String authUser = '';
  String authPass = '';
  String connectHost = '';
  int connectPort = 0;
  int connections = 0;

  int get port => _server.port;

  static Future<_FakeSocks5Server> bind({
    String? expectUser,
    String? expectPass,
    int connectRep = 0,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeSocks5Server._(
      server,
      expectUser: expectUser,
      expectPass: expectPass,
      connectRep: connectRep,
    );
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket socket) async {
    connections++;
    final reader = _TestReader(socket);
    try {
      await _serve(socket, reader);
    } catch (_) {
      try {
        socket.destroy();
      } catch (_) {}
    } finally {
      await reader.close();
    }
  }

  Future<void> _serve(Socket socket, _TestReader reader) async {
    final head = await reader.readExactly(2);
      final methods = await reader.readExactly(head[1]);
      final wantAuth = expectUser != null;
      if (wantAuth && !methods.contains(0x02)) {
        socket.add(const [0x05, 0xFF]);
        await socket.flush();
        socket.destroy();
        return;
      }
      socket.add([0x05, wantAuth ? 0x02 : 0x00]);
      await socket.flush();
      if (wantAuth) {
        final authHead = await reader.readExactly(2);
        final user = await reader.readExactly(authHead[1]);
        final plen = await reader.readExactly(1);
        final pass = await reader.readExactly(plen[0]);
        sawAuth = true;
        authUser = utf8.decode(user);
        authPass = utf8.decode(pass);
        final ok = authUser == expectUser && authPass == expectPass;
        socket.add([0x01, ok ? 0x00 : 0x01]);
        await socket.flush();
        if (!ok) {
          socket.destroy();
          return;
        }
      }
      final reqHead = await reader.readExactly(4);
      final atyp = reqHead[3];
      if (atyp == 0x01) {
        final bytes = await reader.readExactly(4);
        connectHost = bytes.join('.');
      } else if (atyp == 0x03) {
        final length = await reader.readExactly(1);
        connectHost = utf8.decode(await reader.readExactly(length[0]));
      } else if (atyp == 0x04) {
        final bytes = await reader.readExactly(16);
        connectHost = InternetAddress.fromRawAddress(bytes).address;
      } else {
        socket.destroy();
        return;
      }
      final portBytes = await reader.readExactly(2);
      connectPort = (portBytes[0] << 8) | portBytes[1];
      socket.add([0x05, connectRep, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await socket.flush();
      if (connectRep != 0) {
        socket.destroy();
        return;
      }
      await reader.readUntilDoubleCrlf();
      const body = 'hello-via-socks5';
      socket.add(
        utf8.encode(
          'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n'
          'Content-Type: text/plain\r\nConnection: close\r\n\r\n$body',
        ),
      );
      await socket.flush();
      await socket.close();
  }
}

class _TestReader {
  _TestReader(Socket socket) {
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

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  void _onError(Object error) {
    _error = error;
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  void _onDone() {
    _done = true;
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  Future<void> close() => _subscription.cancel();

  Future<void> _fill(int count) async {
    while (_buffer.length < count) {
      final error = _error;
      if (error != null) throw error;
      if (_done) throw const SocketException('closed early');
      _waiter = Completer<void>();
      await _waiter!.future.timeout(const Duration(seconds: 5));
    }
  }

  Future<Uint8List> readExactly(int count) async {
    await _fill(count);
    final out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return out;
  }

  Future<void> readUntilDoubleCrlf() async {    const marker = [13, 10, 13, 10];
    while (true) {
      for (var i = 0; i + 3 < _buffer.length; i++) {
        if (_buffer[i] == marker[0] &&
            _buffer[i + 1] == marker[1] &&
            _buffer[i + 2] == marker[2] &&
            _buffer[i + 3] == marker[3]) {
          return;
        }
      }
      final error = _error;
      if (error != null) throw error;
      if (_done) throw const SocketException('closed early');
      _waiter = Completer<void>();
      await _waiter!.future.timeout(const Duration(seconds: 5));
    }
  }
}

void main() {
  // 绑定若被意外创建过，恢复真实 HttpClient。
  setUpAll(() {
    HttpOverrides.global = null;
  });

  group('SOCKS5 tunnel + forwarder against a fake server', () {
    test('tunnel handshake carries the domain; forwarder returns the body',
        () async {
      final server = await _FakeSocks5Server.bind();
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final entry = Socks5ProxyEntry(
        id: 'p',
        name: 'fake',
        host: '127.0.0.1',
        port: server.port,
      );
      final port = await pool.ensurePort(entry);
      final client = buildForwardedHttpClient(port);
      addTearDown(() => client.close(force: true));
      final request =
          await client.getUrl(Uri.parse('http://proxy-test.invalid/x'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 200);
      expect(body, 'hello-via-socks5');
      expect(server.connectHost, 'proxy-test.invalid');
      expect(server.connectPort, 80);
      expect(server.sawAuth, false);
    });

    test('https CONNECT reaches the proxy with host and port', () async {
      final server = await _FakeSocks5Server.bind();
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final entry = Socks5ProxyEntry(
        id: 'p',
        name: 'fake',
        host: '127.0.0.1',
        port: server.port,
      );
      final port = await pool.ensurePort(entry);
      final client = buildForwardedHttpClient(port);
      addTearDown(() => client.close(force: true));
      // 假服务器不做 TLS：握手注定失败，这里只证明 CONNECT 带着正确
      // 的目标主机与端口到了 SOCKS 代理；TLS 本身由 SDK 在隧道上做。
      await expectLater(
        client
            .getUrl(Uri.parse('https://proxy-test.invalid/'))
            .timeout(const Duration(seconds: 15)),
        throwsA(anyOf(isA<HandshakeException>(), isA<HttpException>())),
      );
      expect(server.connectHost, 'proxy-test.invalid');
      expect(server.connectPort, 443);
    });

    test('username/password auth is presented and accepted', () async {
      final server = await _FakeSocks5Server.bind(
        expectUser: 'alice',
        expectPass: 's3cret',
      );
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final entry = Socks5ProxyEntry(
        id: 'p',
        name: 'fake',
        host: '127.0.0.1',
        port: server.port,
        username: 'alice',
        password: 's3cret',
      );
      final port = await pool.ensurePort(entry);
      final client = buildForwardedHttpClient(port);
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse('http://proxy-test.invalid/'));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      expect(server.sawAuth, true);
      expect(server.authUser, 'alice');
      expect(server.authPass, 's3cret');
    });

    test('wrong password fails with a credential-safe message', () async {
      final server = await _FakeSocks5Server.bind(
        expectUser: 'alice',
        expectPass: 's3cret',
      );
      addTearDown(server.close);
      const entry = Socks5ProxyEntry(
        id: 'p',
        name: 'fake',
        host: '127.0.0.1',
        port: 0,
        username: 'alice',
        password: 'wrong-password-value',
      );
      await expectLater(
        socks5OpenTunnel(
          'proxy-test.invalid',
          80,
          entry.copyWith(port: server.port),
        ),
        throwsA(
          isA<Socks5Failure>().having(
            (e) => e.message.contains('wrong-password-value'),
            'message leaks password',
            false,
          ),
        ),
      );
    });

    test('non-zero CONNECT reply fails at the tunnel', () async {
      final server = await _FakeSocks5Server.bind(connectRep: 5);
      addTearDown(server.close);
      final entry = Socks5ProxyEntry(
        id: 'p',
        name: 'fake',
        host: '127.0.0.1',
        port: server.port,
      );
      await expectLater(
        socks5OpenTunnel('proxy-test.invalid', 80, entry),
        throwsA(isA<Socks5Failure>()),
      );
    });

    test('tunnel failure surfaces as 502 through the forwarder', () async {
      final server = await _FakeSocks5Server.bind(connectRep: 5);
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final entry = Socks5ProxyEntry(
        id: 'p',
        name: 'fake',
        host: '127.0.0.1',
        port: server.port,
      );
      final port = await pool.ensurePort(entry);
      final client = buildForwardedHttpClient(port);
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse('http://proxy-test.invalid/'));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 502);
    });

    test('loopback targets bypass the forwarder entirely', () async {
      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(httpServer.close);
      httpServer.listen((request) {
        request.response
          ..write('local-ok')
          ..close();
      });
      final client = buildForwardedHttpClient(1);
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${httpServer.port}/'),
      );
      final response = await request.close();
      expect(await response.transform(utf8.decoder).join(), 'local-ok');
    });
  });

  group('per-resource routing through LiveHttp and ContentHttp', () {
    test('LiveHttp request for an assigned live source goes via its proxy',
        () async {
      final server = await _FakeSocks5Server.bind();
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final router = Socks5ProxyRouter()
        ..update(
          [
            Socks5ProxyEntry(
              id: 'p1',
              name: 'fake',
              host: '127.0.0.1',
              port: server.port,
            ),
          ],
          {'live:xiuguo': 'p1'},
        );
      final http = LiveHttp(proxyRouter: router, forwarderPool: pool);
      addTearDown(http.close);
      final body = await http.get(
        'http://proxy-test.invalid/channels',
        proxyResourceKey: socks5LiveResourceKey('xiuguo'),
      );
      expect(body, 'hello-via-socks5');
      expect(server.connections, 1);
    });

    test('LiveHttp request for a direct-assigned source bypasses the proxy',
        () async {
      final server = await _FakeSocks5Server.bind();
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final router = Socks5ProxyRouter()
        ..update(
          [
            Socks5ProxyEntry(
              id: 'p1',
              name: 'fake',
              host: '127.0.0.1',
              port: server.port,
            ),
          ],
          {'live:xiuguo': socks5DirectAssignment},
        );
      final http = LiveHttp(proxyRouter: router, forwarderPool: pool);
      addTearDown(http.close);
      // 直连下请求注定失败（.invalid 域名），但异常类型取决于环境：
      // DNS 失败经 SocketException 包成 AppFailure，出口拦截则抛原生
      // HttpException（LiveHttp 既有口径，不包这层）。路由的证明是
      // 假服务器零连接。
      await expectLater(
        http.get(
          'http://proxy-test.invalid/channels',
          proxyResourceKey: socks5LiveResourceKey('xiuguo'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(server.connections, 0);
    });

    test('ContentHttp with a constructor resource key routes via its proxy',
        () async {
      final server = await _FakeSocks5Server.bind();
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final router = Socks5ProxyRouter()
        ..update(
          [
            Socks5ProxyEntry(
              id: 'p1',
              name: 'fake',
              host: '127.0.0.1',
              port: server.port,
            ),
          ],
          {socks5ScrapeResourceKey: 'p1'},
        );
      final http = ContentHttp(
        proxyResourceKey: socks5ScrapeResourceKey,
        proxyRouter: router,
        forwarderPool: pool,
      );
      addTearDown(http.close);
      final response = await http.getRaw('http://proxy-test.invalid/page');
      expect(response.statusCode, 200);
      expect(utf8.decode(response.bodyBytes), 'hello-via-socks5');
      expect(server.connections, 1);
    });

    test('router generation change drops cached per-proxy clients', () async {
      final server = await _FakeSocks5Server.bind();
      addTearDown(server.close);
      final pool = Socks5ForwarderPool();
      addTearDown(pool.closeAll);
      final router = Socks5ProxyRouter()
        ..update(
          [
            Socks5ProxyEntry(
              id: 'p1',
              name: 'fake',
              host: '127.0.0.1',
              port: server.port,
            ),
          ],
          {'live:xiuguo': 'p1'},
        );
      final http = LiveHttp(proxyRouter: router, forwarderPool: pool);
      addTearDown(http.close);
      await http.get(
        'http://proxy-test.invalid/a',
        proxyResourceKey: socks5LiveResourceKey('xiuguo'),
      );
      router.update(const [], const {});
      // 路由清空后旧的按代理客户端必须丢弃：第二次请求不再走代理，
      // 否则会经假服务器成功返回。失败的异常类型取决于环境（见上），
      // 关键证明是假服务器的连接数仍为第一次的 1 次。
      await expectLater(
        http.get(
          'http://proxy-test.invalid/a',
          proxyResourceKey: socks5LiveResourceKey('xiuguo'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(server.connections, 1);
    });
  });
}
