class RoomVideo {
  const RoomVideo({
    required this.source,
    required this.dramaId,
    required this.title,
    this.cover = '',
    this.sourceId = '',
    required this.episodeIndex,
    this.episodeTitle = '',
  });

  final String source;
  final String dramaId;
  final String title;
  final String cover;
  final String sourceId;
  final int episodeIndex;
  final String episodeTitle;

  String get key => '$source|$dramaId|$episodeIndex';

  Map<String, dynamic> toJson() => {
    'source': source,
    'dramaId': dramaId,
    'title': title,
    'cover': cover,
    'sourceId': sourceId,
    'episodeIndex': episodeIndex,
    'episodeTitle': episodeTitle,
  };

  factory RoomVideo.fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    final dramaId = json['dramaId'];
    final title = json['title'];
    final episodeIndex = json['episodeIndex'];
    if (source is! String ||
        source.isEmpty ||
        dramaId is! String ||
        dramaId.isEmpty ||
        title is! String ||
        title.isEmpty ||
        episodeIndex is! int ||
        episodeIndex < 0) {
      throw const FormatException('room video is invalid');
    }
    return RoomVideo(
      source: source,
      dramaId: dramaId,
      title: title,
      cover: json['cover'] is String ? json['cover'] as String : '',
      sourceId: json['sourceId'] is String ? json['sourceId'] as String : '',
      episodeIndex: episodeIndex,
      episodeTitle: json['episodeTitle'] is String
          ? json['episodeTitle'] as String
          : '',
    );
  }
}

class RoomPlayState {
  const RoomPlayState({
    required this.playing,
    required this.position,
    required this.updatedAt,
  });

  final bool playing;
  final double position;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'playing': playing,
    'position': position,
    'updatedAt': updatedAt,
  };

  factory RoomPlayState.fromJson(Map<String, dynamic> json) {
    final playing = json['playing'];
    final position = json['position'];
    final updatedAt = json['updatedAt'];
    if (playing is! bool ||
        position is! num ||
        !position.isFinite ||
        position < 0 ||
        updatedAt is! int) {
      throw const FormatException('room play state is invalid');
    }
    return RoomPlayState(
      playing: playing,
      position: position.toDouble(),
      updatedAt: updatedAt,
    );
  }
}

class RoomChatMessage {
  const RoomChatMessage({
    required this.sender,
    required this.text,
    required this.sentAt,
  });

  final String sender;
  final String text;
  final int sentAt;
}

class RoomMember {
  const RoomMember({
    required this.id,
    required this.joinedAt,
    required this.isCreator,
  });

  final String id;
  final int joinedAt;
  final bool isCreator;

  Map<String, dynamic> toJson() => {
    'id': id,
    'joinedAt': joinedAt,
    'isCreator': isCreator,
  };

  factory RoomMember.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final joinedAt = json['joinedAt'];
    final isCreator = json['isCreator'];
    if (id is! String || id.isEmpty || joinedAt is! int || isCreator is! bool) {
      throw const FormatException('room member is invalid');
    }
    return RoomMember(id: id, joinedAt: joinedAt, isCreator: isCreator);
  }
}
