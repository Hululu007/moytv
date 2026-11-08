import 'dart:async';
import 'dart:math';

import '../relay/relay_channel.dart';
import '../relay/relay_message.dart';
import '../watchroom/models.dart';
import 'cf_relay_constants.dart';

class CfRelayClient extends RelayChannel {
  CfRelayClient({String? defaultBaseUrl, super.connector})
    : _defaultBaseUrl = defaultBaseUrl ?? '' {
    _pongSubscription = messages.listen((message) {
      if (message.type == cfPongType) {
        _lastPongAt = DateTime.now().millisecondsSinceEpoch;
      }
    });
    addListener(_onStateChanged);
  }

  final String _defaultBaseUrl;
  StreamSubscription<RelayMessage>? _pongSubscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _closed = false;
  int _attempt = 0;
  int _lastPongAt = 0;
  String _base = '';
  String _roomId = '';
  String _senderId = '';

  void _onStateChanged() {
    if (state == RelayConnectionState.failed &&
        !_closed &&
        _roomId.isNotEmpty &&
        _reconnectTimer == null) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer != null || _roomId.isEmpty) {
      return;
    }
    final index = _attempt < cfReconnectBackoffSeconds.length
        ? _attempt
        : cfReconnectBackoffSeconds.length - 1;
    final delaySeconds = cfReconnectBackoffSeconds[index];
    _attempt += 1;
    final jitterMs = Random().nextInt(1000);
    _reconnectTimer = Timer(
      Duration(seconds: delaySeconds, milliseconds: jitterMs),
      () async {
        _reconnectTimer = null;
        if (_closed) {
          return;
        }
        await connect(url: _base, channelId: _roomId, senderId: _senderId);
      },
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPongAt = DateTime.now().millisecondsSinceEpoch;
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: cfHeartbeatSeconds),
      (_) {
        if (!connected) {
          return;
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastPongAt > cfPongGraceSeconds * 1000) {
          unawaited(_forceReconnect());
          return;
        }
        try {
          sendMessage(cfPingType, {});
        } catch (_) {}
      },
    );
  }

  Future<void> _forceReconnect() async {
    await disconnect();
    if (_closed) {
      return;
    }
    await connect(url: _base, channelId: _roomId, senderId: _senderId);
  }

  @override
  Future<void> connect({
    required String url,
    required String channelId,
    required String senderId,
  }) async {
    final base = url.isNotEmpty ? url : _defaultBaseUrl;
    final trimmedBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final uri = Uri.tryParse(trimmedBase);
    if (trimmedBase.isEmpty ||
        uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'ws' && uri.scheme != 'wss') ||
        channelId.isEmpty ||
        senderId.isEmpty) {
      state = RelayConnectionState.failed;
      error = '中转地址须为 ws:// 或 wss:// 地址';
      notifyListeners();
      return;
    }
    _base = trimmedBase;
    _roomId = channelId;
    _senderId = senderId;
    final target =
        '$trimmedBase/room/$channelId?sender=${Uri.encodeComponent(senderId)}';
    await super.connect(url: target, channelId: channelId, senderId: senderId);
    if (connected) {
      _attempt = 0;
      _startHeartbeat();
    }
  }

  @override
  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await super.disconnect();
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await disconnect();
  }

  void sendChat(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final capped = trimmed.length > cfMaxChatChars
        ? trimmed.substring(0, cfMaxChatChars)
        : trimmed;
    sendMessage(RelayMessage.chatType, {'text': capped});
  }

  void sendVideo(RoomVideo video) {
    sendMessage(RelayMessage.videoSetType, video.toJson());
  }

  void sendPlayState(RoomPlayState playState) {
    sendMessage(RelayMessage.playStateType, playState.toJson());
  }

  void sendFileOffer({
    required String ticket,
    required String name,
    required int size,
  }) {
    sendMessage(RelayMessage.fileOfferType, {
      'ticket': ticket,
      'name': name,
      'size': size,
    });
  }

  @override
  void dispose() {
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    unawaited(_pongSubscription?.cancel());
    super.dispose();
  }
}
