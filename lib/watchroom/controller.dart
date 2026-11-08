import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../relay/relay_channel.dart';
import '../relay/relay_message.dart';
import '../relay/relay_settings.dart';
import '../relay_cf/cf_relay_client.dart';
import '../relay_cf/cf_relay_constants.dart';
import 'models.dart';

class WatchRoomController extends ChangeNotifier {
  WatchRoomController._();

  static final WatchRoomController instance = WatchRoomController._();

  RelayChannel? _channel;
  StreamSubscription<RelayMessage>? _subscription;
  String _deviceId = '';

  String roomId = '';
  String hostId = '';
  List<RoomMember> members = [];
  RoomVideo? video;
  RoomPlayState playState = RoomPlayState(
    playing: false,
    position: 0,
    updatedAt: 0,
  );
  List<RoomChatMessage> chat = [];

  bool get inRoom => roomId.isNotEmpty;

  bool get isHost => hostId.isNotEmpty && hostId == _deviceId;

  String get deviceId => _deviceId;

  String get channelError => _channel?.error ?? '';

  RelayConnectionState get connectionState =>
      _channel?.state ?? RelayConnectionState.disconnected;

  void _electHost() {
    if (members.isEmpty) {
      hostId = '';
      return;
    }
    final creators = members.where((member) => member.isCreator).toList();
    if (creators.isNotEmpty) {
      hostId = creators.first.id;
      return;
    }
    final ordered = List.of(members)
      ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    hostId = ordered.first.id;
  }

  void _addMember(RoomMember member) {
    final index = members.indexWhere((item) => item.id == member.id);
    if (index >= 0) {
      members[index] = member;
    } else {
      members.add(member);
    }
    _electHost();
  }

  Future<void> _bindChannel({
    required RelaySettings settings,
    required String room,
    required bool creator,
    RelayChannel? channel,
  }) async {
    await leaveRoom();
    final deviceId = await settings.ensureDeviceId();
    final relayChannel = channel ?? CfRelayClient();
    _channel = relayChannel;
    _deviceId = deviceId;
    roomId = room;
    members = [
      RoomMember(
        id: deviceId,
        joinedAt: DateTime.now().millisecondsSinceEpoch,
        isCreator: creator,
      ),
    ];
    _electHost();
    relayChannel.addListener(notifyListeners);
    _subscription = relayChannel.messages.listen(_onMessage);
    await relayChannel.connect(
      url: settings.url,
      channelId: room,
      senderId: deviceId,
    );
    if (relayChannel.connected) {
      relayChannel.sendMessage(RelayMessage.joinType, {
        'sender': deviceId,
        'joinedAt': members.first.joinedAt,
        'isCreator': creator,
      });
    }
    notifyListeners();
  }

  Future<void> createRoom({
    required SharedPreferences preferences,
    RelayChannel? channel,
  }) async {
    final settings = RelaySettings(preferences);
    await _bindChannel(
      settings: settings,
      room: settings.randomPairId(),
      creator: true,
      channel: channel,
    );
  }

  Future<void> joinRoom({
    required SharedPreferences preferences,
    required String room,
    RelayChannel? channel,
  }) async {
    final settings = RelaySettings(preferences);
    if (room.isEmpty) {
      throw StateError('房间号不能为空');
    }
    await _bindChannel(
      settings: settings,
      room: room,
      creator: false,
      channel: channel,
    );
  }

  Future<void> joinPublicRoom({
    required SharedPreferences preferences,
    RelayChannel? channel,
  }) async {
    final settings = RelaySettings(preferences);
    await _bindChannel(
      settings: settings,
      room: cfPublicRoomId,
      creator: false,
      channel: channel,
    );
  }

  Future<void> leaveRoom() async {
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      channel.removeListener(notifyListeners);
      await channel.disconnect();
      channel.dispose();
    }
    roomId = '';
    hostId = '';
    members = [];
    video = null;
    playState = RoomPlayState(playing: false, position: 0, updatedAt: 0);
    chat = [];
    notifyListeners();
  }

  void setVideo(RoomVideo next) {
    if (!isHost) {
      throw StateError('只有房主可以更换房间视频');
    }
    video = next;
    playState = RoomPlayState(
      playing: true,
      position: 0,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _channel?.sendMessage(RelayMessage.videoSetType, next.toJson());
    _channel?.sendMessage(RelayMessage.playStateType, playState.toJson());
    notifyListeners();
  }

  void broadcastPlayState({required bool playing, required double position}) {
    if (!isHost) {
      throw StateError('只有房主可以同步播放状态');
    }
    playState = RoomPlayState(
      playing: playing,
      position: position,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _channel?.sendMessage(RelayMessage.playStateType, playState.toJson());
    notifyListeners();
  }

  void sendChat(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !inRoom) return;
    chat.add(
      RoomChatMessage(
        sender: _deviceId,
        text: trimmed,
        sentAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _channel?.sendMessage(RelayMessage.chatType, {'text': trimmed});
    notifyListeners();
  }

  void _onMessage(RelayMessage message) {
    if (message.sender == _deviceId) return;
    switch (message.type) {
      case RelayMessage.joinType:
        final sender = message.payload['sender'];
        final joinedAt = message.payload['joinedAt'];
        final isCreator = message.payload['isCreator'];
        if (sender is String && sender.isNotEmpty) {
          _addMember(
            RoomMember(
              id: sender,
              joinedAt: joinedAt is int
                  ? joinedAt
                  : DateTime.now().millisecondsSinceEpoch,
              isCreator: isCreator is bool ? isCreator : false,
            ),
          );
          _channel?.sendMessage(RelayMessage.listType, {
            'members': members.map((member) => member.toJson()).toList(),
          });
          notifyListeners();
        }
      case RelayMessage.leaveType:
        final sender = message.payload['sender'];
        if (sender is String) {
          members.removeWhere((member) => member.id == sender);
          _electHost();
          notifyListeners();
        }
      case RelayMessage.listType:
        final rows = message.payload['members'];
        if (rows is List) {
          for (final row in rows) {
            if (row is Map<String, dynamic>) {
              try {
                _addMember(RoomMember.fromJson(row));
              } catch (_) {}
            }
          }
          notifyListeners();
        }
      case RelayMessage.videoSetType:
        try {
          video = RoomVideo.fromJson(message.payload);
          playState = RoomPlayState(
            playing: true,
            position: 0,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          );
          notifyListeners();
        } catch (_) {}
      case RelayMessage.playStateType:
        try {
          playState = RoomPlayState.fromJson(message.payload);
          notifyListeners();
        } catch (_) {}
      case RelayMessage.chatType:
        final text = message.payload['text'];
        if (text is String && text.isNotEmpty) {
          chat.add(
            RoomChatMessage(
              sender: message.sender,
              text: text,
              sentAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          notifyListeners();
        }
    }
  }
}
