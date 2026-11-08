import 'dart:async';
import 'dart:convert';

import 'package:moyi/relay/relay_channel.dart';
import 'package:moyi/relay/relay_message.dart';
import 'package:moyi/relay/relay_settings.dart';
import 'package:moyi/relay_cf/cf_relay_client.dart';
import 'package:moyi/relay_cf/cf_relay_constants.dart';
import 'package:moyi/watchroom/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeRelaySocket implements RelaySocket {
  FakeRelaySocket();

  final StreamController<String> _incoming =
      StreamController<String>.broadcast();
  final List<String> sent = [];
  final Completer<void> _done = Completer<void>();
  bool closed = false;

  void deliver(RelayMessage message) => _incoming.add(message.encode());

  void deliverRaw(String raw) => _incoming.add(raw);

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(String text) {
    sent.add(text);
  }

  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      if (!_done.isCompleted) _done.complete();
      await _incoming.close();
    }
  }
}

void main() {
  test('relay message validates envelope fields', () {
    final message = RelayMessage(
      type: RelayMessage.chatType,
      channel: '123456',
      sender: 'device-a',
      payload: {'text': 'hi'},
    );
    final decoded = RelayMessage.decode(message.encode());
    expect(decoded.type, RelayMessage.chatType);
    expect(decoded.payload['text'], 'hi');
    expect(() => RelayMessage.decode('{"type":"chat"}'), throwsFormatException);
    expect(() => RelayMessage.decode('[]'), throwsFormatException);
  });

  test('relay settings fall back to the built-in relay', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = RelaySettings(await SharedPreferences.getInstance());
    expect(settings.storedUrl, '');
    expect(settings.url, cfRelayWsUrl);
    await settings.setUrl('wss://relay.example.com');
    expect(settings.storedUrl, 'wss://relay.example.com');
    expect(settings.url, 'wss://relay.example.com');
  });

  test('cf relay client builds the room url from the base address', () async {
    final socket = FakeRelaySocket();
    Uri? requested;
    final client = CfRelayClient(
      connector: (uri) async {
        requested = uri;
        return socket;
      },
    );
    await client.connect(
      url: cfRelayWsUrl,
      channelId: cfPublicRoomId,
      senderId: 'device-a',
    );
    expect(client.connected, isTrue);
    expect(
      requested.toString(),
      '$cfRelayWsUrl/room/$cfPublicRoomId?sender=device-a',
    );
    await client.disconnect();
    client.dispose();
  });

  test('watchroom controller creates a room over the built-in relay', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final socket = FakeRelaySocket();
    Uri? requested;
    final channel = CfRelayClient(
      connector: (uri) async {
        requested = uri;
        return socket;
      },
    );
    final room = WatchRoomController.instance;
    await room.createRoom(preferences: prefs, channel: channel);
    expect(room.inRoom, isTrue);
    expect(room.roomId, isNotEmpty);
    expect(requested.toString(), contains('/room/${room.roomId}?sender='));
    await room.leaveRoom();
    expect(room.inRoom, isFalse);
  });

  test('file assembler reassembles chunks in any order', () {
    final bytes = List.generate(100000, (i) => i % 251);
    final chunks = relayFileChunks(id: 'f1', bytes: bytes);
    expect(chunks.length, 3);
    final assembler = RelayFileAssembler(
      id: 'f1',
      name: 'a.py',
      size: bytes.length,
    );
    assembler.addChunk(2, chunks[2]['data'] as String);
    assembler.addChunk(0, chunks[0]['data'] as String);
    expect(assembler.complete, isFalse);
    assembler.addChunk(1, chunks[1]['data'] as String);
    expect(assembler.complete, isTrue);
    expect(assembler.assemble(), bytes);
  });

  test('file assembler rejects oversized chunks and bad indexes', () {
    final assembler = RelayFileAssembler(id: 'f1', name: 'a.py', size: 10);
    expect(
      () => assembler.addChunk(1, base64Encode([1])),
      throwsFormatException,
    );
    expect(
      () => assembler.addChunk(0, base64Encode(List.filled(50000, 0))),
      throwsFormatException,
    );
  });

  test('channel joins and routes only same-channel messages', () async {
    final socket = FakeRelaySocket();
    final channel = RelayChannel(connector: (_) async => socket);
    final received = <RelayMessage>[];
    channel.messages.listen(received.add);
    await channel.connect(
      url: 'wss://relay.example.com',
      channelId: '123456',
      senderId: 'device-a',
    );
    expect(channel.connected, isTrue);
    final join = RelayMessage.decode(socket.sent.first);
    expect(join.type, RelayMessage.joinType);
    expect(join.channel, '123456');
    socket.deliver(
      const RelayMessage(
        type: RelayMessage.chatType,
        channel: '123456',
        sender: 'device-b',
        payload: {'text': 'hello'},
      ),
    );
    socket.deliver(
      const RelayMessage(
        type: RelayMessage.chatType,
        channel: 'other',
        sender: 'device-c',
        payload: {'text': 'ignored'},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(received.length, 1);
    expect(received.first.payload['text'], 'hello');
    await channel.disconnect();
    expect(socket.closed, isTrue);
  });

  test('channel rejects non-ws urls', () async {
    final channel = RelayChannel(connector: (_) async => FakeRelaySocket());
    await channel.connect(
      url: 'https://relay.example.com',
      channelId: '123456',
      senderId: 'device-a',
    );
    expect(channel.state, RelayConnectionState.failed);
    expect(channel.error, isNotEmpty);
  });
}
