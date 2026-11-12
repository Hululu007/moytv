import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/episode_preview_card.dart';
import 'package:moyi/tmdb/tmdb_config.dart';
import 'package:moyi/tmdb/tmdb_metadata.dart';

void main() {
  const config = TmdbConfig();

  TmdbEpisode episode(
    int number, {
    String stillPath = '',
    String name = '',
    String airDate = '',
  }) => TmdbEpisode(
    seasonNumber: 1,
    episodeNumber: number,
    name: name,
    stillPath: stillPath.isEmpty ? '/still$number.jpg' : stillPath,
    airDate: airDate,
  );

  group('episodePreviewData', () {
    test('匹配上的集：still 取 w500 剧照地址', () {
      final data = episodePreviewData(
        titles: ['第1集', '第2集'],
        tmdbEpisodes: [episode(1), episode(2)],
        config: config,
        tmdbPosterUrl: '',
        dramaCover: 'https://cover.example/poster.jpg',
      );
      expect(data[0].tmdb?.episodeNumber, 1);
      expect(data[0].stillUrl, 'https://image.tmdb.org/t/p/w500/still1.jpg');
      expect(data[1].stillUrl, contains('/w500/still2.jpg'));
    });

    test('没匹配上的集：still 为空，卡片走海报兜底', () {
      final data = episodePreviewData(
        titles: ['第9集'],
        tmdbEpisodes: [episode(1)],
        config: config,
        tmdbPosterUrl: '',
        dramaCover: 'https://cover.example/poster.jpg',
      );
      expect(data.single.tmdb, isNull);
      expect(data.single.stillUrl, isEmpty);
      expect(data.single.posterUrl, 'https://cover.example/poster.jpg');
    });

    test('TMDB 有记录但 stillPath 为空：still 为空，不拼坏地址', () {
      final bare = episodePreviewData(
        titles: ['第1集'],
        tmdbEpisodes: const [
          TmdbEpisode(seasonNumber: 1, episodeNumber: 1, stillPath: ''),
        ],
        config: config,
        tmdbPosterUrl: 'https://image.tmdb.org/t/p/w500/poster.jpg',
        dramaCover: 'https://cover.example/poster.jpg',
      );
      expect(bare.single.tmdb?.episodeNumber, 1);
      expect(bare.single.stillUrl, isEmpty);
      expect(
        bare.single.posterUrl,
        'https://image.tmdb.org/t/p/w500/poster.jpg',
      );
    });

    test('海报兜底：TMDB 海报优先，其次本剧封面，都没有为空', () {
      final withTmdbPoster = episodePreviewData(
        titles: ['第1集'],
        tmdbEpisodes: const [],
        config: config,
        tmdbPosterUrl: 'https://image.tmdb.org/t/p/w500/poster.jpg',
        dramaCover: 'https://cover.example/poster.jpg',
      );
      expect(
        withTmdbPoster.single.posterUrl,
        'https://image.tmdb.org/t/p/w500/poster.jpg',
      );
      final coverOnly = episodePreviewData(
        titles: ['第1集'],
        tmdbEpisodes: const [],
        config: config,
        tmdbPosterUrl: '',
        dramaCover: 'https://cover.example/poster.jpg',
      );
      expect(coverOnly.single.posterUrl, 'https://cover.example/poster.jpg');
      final none = episodePreviewData(
        titles: ['第1集'],
        tmdbEpisodes: const [],
        config: config,
        tmdbPosterUrl: '',
        dramaCover: '',
      );
      expect(none.single.posterUrl, isEmpty);
    });

    test('返回列表与标题等长同序；倒序显示按真实集号下标取不错位', () {
      final data = episodePreviewData(
        titles: ['第1集', '第2集', '第3集'],
        tmdbEpisodes: [episode(3), episode(1), episode(2)],
        config: config,
        tmdbPosterUrl: '',
        dramaCover: '',
      );
      expect(data.length, 3);
      expect([for (final d in data) d.tmdb?.episodeNumber], [1, 2, 3]);
      // 倒序显示：第 0 个展示位对应真实下标 2，取到的仍是第 3 集。
      final display = [
        for (var i = 0; i < data.length; i++) data[data.length - 1 - i],
      ];
      expect([for (final d in display) d.tmdb?.episodeNumber], [3, 2, 1]);
    });

    test('空输入返回空列表；无 TMDB 时全部无匹配但长度不变', () {
      expect(
        episodePreviewData(
          titles: const [],
          tmdbEpisodes: [episode(1)],
          config: config,
          tmdbPosterUrl: '',
          dramaCover: '',
        ),
        isEmpty,
      );
      final noTmdb = episodePreviewData(
        titles: ['第1集', '第2集'],
        tmdbEpisodes: const [],
        config: config,
        tmdbPosterUrl: '',
        dramaCover: 'https://cover.example/poster.jpg',
      );
      expect(noTmdb.length, 2);
      expect(noTmdb.every((d) => d.tmdb == null && d.stillUrl.isEmpty), isTrue);
      expect(
        noTmdb.every((d) => d.posterUrl == 'https://cover.example/poster.jpg'),
        isTrue,
      );
    });
  });
}
