import 'dart:convert';

class RelayMessage {
  const RelayMessage({
    required this.type,
    required this.channel,
    required this.sender,
    required this.payload,
    this.id = '',
    this.to = '',
  });

  final String type;
  final String channel;
  final String sender;
  final Map<String, dynamic> payload;
  final String id;
  final String to;

  static const joinType = 'presence.join';
  static const leaveType = 'presence.leave';
  static const listType = 'presence.list';
  static const chatType = 'chat';
  static const videoSetType = 'video.set';
  static const playStateType = 'play.state';
  static const fileOfferType = 'file.offer';
  static const fileChunkType = 'file.chunk';
  static const fileEndType = 'file.end';

  Map<String, dynamic> toJson() => {
    'type': type,
    'channel': channel,
    'sender': sender,
    'payload': payload,
    if (id.isNotEmpty) 'id': id,
    if (to.isNotEmpty) 'to': to,
  };

  String encode() => jsonEncode(toJson());

  factory RelayMessage.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final channel = json['channel'];
    final sender = json['sender'];
    final payload = json['payload'];
    if (type is! String ||
        type.isEmpty ||
        type.length > 32 ||
        channel is! String ||
        channel.isEmpty ||
        channel.length > 64 ||
        sender is! String ||
        sender.isEmpty ||
        sender.length > 128 ||
        payload is! Map<String, dynamic>) {
      throw const FormatException('relay message is invalid');
    }
    final id = json['id'];
    final to = json['to'];
    return RelayMessage(
      type: type,
      channel: channel,
      sender: sender,
      payload: payload,
      id: id is String ? id : '',
      to: to is String ? to : '',
    );
  }

  static RelayMessage decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('relay message must be a json object');
    }
    return RelayMessage.fromJson(decoded);
  }
}

class RelayFileAssembler {
  RelayFileAssembler({
    required this.id,
    required this.name,
    required this.size,
  });

  static const chunkSize = 48 * 1024;
  static const maxSize = 32 * 1024 * 1024;

  final String id;
  final String name;
  final int size;
  final Map<int, List<int>> _chunks = {};

  int get expectedChunks => size <= 0 ? 0 : (size + chunkSize - 1) ~/ chunkSize;

  bool get complete => expectedChunks > 0 && _chunks.length == expectedChunks;

  double get progress =>
      expectedChunks == 0 ? 0 : _chunks.length / expectedChunks;

  void addChunk(int index, String base64Data) {
    if (index < 0 || index >= expectedChunks) {
      throw const FormatException('relay file chunk index out of range');
    }
    if (_chunks.containsKey(index)) return;
    final bytes = base64Decode(base64Data);
    if (bytes.length > chunkSize) {
      throw const FormatException('relay file chunk is too large');
    }
    _chunks[index] = bytes;
  }

  List<int> assemble() {
    if (!complete) {
      throw StateError('relay file is incomplete');
    }
    final out = <int>[];
    for (var i = 0; i < expectedChunks; i++) {
      out.addAll(_chunks[i]!);
    }
    return out;
  }
}

List<Map<String, dynamic>> relayFileChunks({
  required String id,
  required List<int> bytes,
}) {
  final chunks = <Map<String, dynamic>>[];
  var index = 0;
  for (
    var offset = 0;
    offset < bytes.length;
    offset += RelayFileAssembler.chunkSize
  ) {
    final end = (offset + RelayFileAssembler.chunkSize).clamp(0, bytes.length);
    chunks.add({
      'index': index,
      'data': base64Encode(bytes.sublist(offset, end)),
    });
    index++;
  }
  return chunks;
}
