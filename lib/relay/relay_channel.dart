import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'relay_message.dart';

abstract class RelaySocket {
  Stream<String> get messages;
  Future<void> get done;
  void send(String text);
  Future<void> close();
}

class IoRelaySocket implements RelaySocket {
  IoRelaySocket._(this._socket);

  static Future<IoRelaySocket> connect(Uri uri) async {
    final socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 20));
    return IoRelaySocket._(socket);
  }

  final WebSocket _socket;

  @override
  Stream<String> get messages => _socket.map(
    (event) => event is List<int>
        ? utf8.decode(event, allowMalformed: true)
        : event.toString(),
  );

  @override
  Future<void> get done => _socket.done;

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close() => _socket.close();
}

enum RelayConnectionState { disconnected, connecting, connected, failed }

class RelayChannel extends ChangeNotifier {
  RelayChannel({Future<RelaySocket> Function(Uri uri)? connector})
    : _connector = connector ?? IoRelaySocket.connect;

  final Future<RelaySocket> Function(Uri uri) _connector;
  RelaySocket? _socket;
  StreamSubscription<String>? _subscription;
  final StreamController<RelayMessage> _incoming =
      StreamController<RelayMessage>.broadcast();

  RelayConnectionState state = RelayConnectionState.disconnected;
  String error = '';
  String url = '';
  String channelId = '';
  String senderId = '';

  Stream<RelayMessage> get messages => _incoming.stream;

  bool get connected => state == RelayConnectionState.connected;

  Future<void> connect({
    required String url,
    required String channelId,
    required String senderId,
  }) async {
    await disconnect();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      state = RelayConnectionState.failed;
      error = '中转地址须为 ws:// 或 wss:// 地址';
      notifyListeners();
      return;
    }
    if (channelId.isEmpty || senderId.isEmpty) {
      state = RelayConnectionState.failed;
      error = '频道与发送方不能为空';
      notifyListeners();
      return;
    }
    state = RelayConnectionState.connecting;
    error = '';
    notifyListeners();
    try {
      final socket = await _connector(uri);
      _socket = socket;
      this.url = url;
      this.channelId = channelId;
      this.senderId = senderId;
      state = RelayConnectionState.connected;
      notifyListeners();
      _subscription = socket.messages.listen(
        (text) {
          try {
            final message = RelayMessage.decode(text);
            if (message.channel == channelId) _incoming.add(message);
          } catch (_) {}
        },
        onError: (_) => _fail('中转连接中断'),
        onDone: () {
          if (state == RelayConnectionState.connected) {
            _fail('中转连接已断开');
          }
        },
      );
      socket.done.then((_) {
        if (state == RelayConnectionState.connected) {
          _fail('中转连接已断开');
        }
      });
      sendMessage(RelayMessage.joinType, {'sender': senderId});
    } catch (error) {
      _fail(error.toString());
    }
  }

  void _fail(String message) {
    if (state == RelayConnectionState.failed) return;
    state = RelayConnectionState.failed;
    error = message;
    notifyListeners();
  }

  void sendMessage(
    String type,
    Map<String, dynamic> payload, {
    String id = '',
    String to = '',
  }) {
    final socket = _socket;
    if (state != RelayConnectionState.connected || socket == null) {
      throw StateError('中转未连接');
    }
    socket.send(
      RelayMessage(
        type: type,
        channel: channelId,
        sender: senderId,
        payload: payload,
        id: id,
        to: to,
      ).encode(),
    );
  }

  Future<void> disconnect() async {
    if (state == RelayConnectionState.connected) {
      try {
        sendMessage(RelayMessage.leaveType, {'sender': senderId});
      } catch (_) {}
    }
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    if (state != RelayConnectionState.disconnected) {
      state = RelayConnectionState.disconnected;
      error = '';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(disconnect());
    unawaited(_incoming.close());
    super.dispose();
  }
}
