import 'package:moyi/watchroom/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('room video round-trips through json', () {
    const video = RoomVideo(
      source: 'site-a',
      dramaId: 'drama-1',
      title: '测试剧',
      cover: 'https://example.com/cover.jpg',
      sourceId: 'source-1',
      episodeIndex: 3,
      episodeTitle: '第4集',
    );
    expect(video.key, 'site-a|drama-1|3');
    final restored = RoomVideo.fromJson(video.toJson());
    expect(restored.source, video.source);
    expect(restored.dramaId, video.dramaId);
    expect(restored.title, video.title);
    expect(restored.cover, video.cover);
    expect(restored.sourceId, video.sourceId);
    expect(restored.episodeIndex, video.episodeIndex);
    expect(restored.episodeTitle, video.episodeTitle);
  });

  test('room video rejects invalid json', () {
    expect(
      () => RoomVideo.fromJson({
        'source': '',
        'dramaId': 'd',
        'title': 't',
        'episodeIndex': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => RoomVideo.fromJson({
        'source': 's',
        'dramaId': 'd',
        'title': 't',
        'episodeIndex': -1,
      }),
      throwsFormatException,
    );
  });

  test('room play state round-trips and rejects invalid json', () {
    const state = RoomPlayState(playing: true, position: 12.5, updatedAt: 42);
    final restored = RoomPlayState.fromJson(state.toJson());
    expect(restored.playing, isTrue);
    expect(restored.position, 12.5);
    expect(restored.updatedAt, 42);
    expect(
      () => RoomPlayState.fromJson({
        'playing': true,
        'position': -1,
        'updatedAt': 1,
      }),
      throwsFormatException,
    );
  });

  test('room member round-trips and rejects invalid json', () {
    const member = RoomMember(id: 'device-1', joinedAt: 7, isCreator: true);
    final restored = RoomMember.fromJson(member.toJson());
    expect(restored.id, 'device-1');
    expect(restored.joinedAt, 7);
    expect(restored.isCreator, isTrue);
    expect(
      () => RoomMember.fromJson({'id': '', 'joinedAt': 1, 'isCreator': true}),
      throwsFormatException,
    );
  });
}
