import 'package:moyi/fullscreen_feed_screen.dart';
import 'package:moyi/models.dart';
import 'package:moyi/playback_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feed resume key joins source and id', () {
    const drama = Drama(id: 'd1', source: 'hongguo', title: '剧名');
    expect(feedResumeKey(drama), 'hongguo|d1');
  });

  test('feed only keeps video dramas', () {
    const items = [
      Drama(id: 'v1', source: 's', title: '视频'),
      Drama(id: 'f1', source: 's', title: '文件夹', kind: 'folder'),
      Drama(id: 'v2', source: 's', title: '视频二'),
    ];
    final playable = feedPlayableDramas(items);
    expect(playable.map((drama) => drama.id), ['v1', 'v2']);
    expect(feedPlayableDramas([]), isEmpty);
  });

  test('feed episode index clamps to range', () {
    expect(clampFeedEpisodeIndex(2, 10), 2);
    expect(clampFeedEpisodeIndex(-1, 10), 0);
    expect(clampFeedEpisodeIndex(10, 10), 9);
    expect(clampFeedEpisodeIndex(0, 0), 0);
    expect(clampFeedEpisodeIndex(5, 1), 0);
  });

  test('feed episode bar label shows status only when known', () {
    expect(feedEpisodeBarLabel('finished', 1000), '选集 · 已完结 · 全1000集');
    expect(feedEpisodeBarLabel('completed', 1000), '选集 · 已完结 · 全1000集');
    expect(feedEpisodeBarLabel('ongoing', 24), '选集 · 连载中 · 全24集');
    expect(feedEpisodeBarLabel('', 24), '选集 · 全24集');
    expect(feedEpisodeBarLabel('unknown', 24), '选集 · 全24集');
  });

  test('feed episode segments split long series by 100', () {
    final segments = feedEpisodeSegments(1000);
    expect(segments.length, 10);
    expect(segments.first.start, 1);
    expect(segments.first.end, 100);
    expect(segments.last.start, 901);
    expect(segments.last.end, 1000);
    expect(feedEpisodeSegments(24), [(start: 1, end: 24)]);
    expect(feedEpisodeSegments(100), [(start: 1, end: 100)]);
    expect(feedEpisodeSegments(0), isEmpty);
  });

  test('feed more speeds match the official sheet subset', () {
    expect(feedMoreSpeeds, [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]);
    for (final speed in feedMoreSpeeds) {
      expect(playbackSpeeds, contains(speed));
    }
  });

  test('feed landscape actions are data driven with enabled flags', () {
    final actions = feedLandscapeActions(hasPrevious: false, hasNext: true);
    expect(actions.map((action) => action.key), [
      'previous',
      'playPause',
      'episodes',
      'next',
      'more',
      'exitFullscreen',
    ]);
    expect(actions.first.enabled, isFalse);
    expect(actions[3].enabled, isTrue);
    expect(
      feedLandscapeActions(hasPrevious: true, hasNext: false)[3].enabled,
      isFalse,
    );
  });

  test('feed completion advances episode first, then video, then stops', () {
    expect(
      feedCompletionAction(
        episode: 0,
        episodeCount: 10,
        videoIndex: 0,
        videoCount: 3,
      ),
      FeedCompletionAction.nextEpisode,
    );
    expect(
      feedCompletionAction(
        episode: 9,
        episodeCount: 10,
        videoIndex: 0,
        videoCount: 3,
      ),
      FeedCompletionAction.nextVideo,
    );
    expect(
      feedCompletionAction(
        episode: 9,
        episodeCount: 10,
        videoIndex: 2,
        videoCount: 3,
      ),
      FeedCompletionAction.stop,
    );
    expect(
      feedCompletionAction(
        episode: 0,
        episodeCount: 10,
        videoIndex: 2,
        videoCount: 3,
      ),
      FeedCompletionAction.nextEpisode,
    );
    expect(
      feedCompletionAction(
        episode: 0,
        episodeCount: null,
        videoIndex: 0,
        videoCount: 3,
      ),
      FeedCompletionAction.nextVideo,
    );
    expect(
      feedCompletionAction(
        episode: 0,
        episodeCount: null,
        videoIndex: 2,
        videoCount: 3,
      ),
      FeedCompletionAction.stop,
    );
    expect(
      feedCompletionAction(
        episode: 0,
        episodeCount: 0,
        videoIndex: 0,
        videoCount: 3,
      ),
      FeedCompletionAction.nextVideo,
    );
    expect(
      feedCompletionAction(
        episode: 10,
        episodeCount: 10,
        videoIndex: 0,
        videoCount: 3,
      ),
      FeedCompletionAction.nextVideo,
    );
  });
}
