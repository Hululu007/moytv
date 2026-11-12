import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/tmdb/tmdb_metadata.dart';

void main() {
  group('episodeNumberFromTitle', () {
    test('认中文“第 N 集”', () {
      expect(episodeNumberFromTitle('第12集'), 12);
      expect(episodeNumberFromTitle('第 8 集'), 8);
      expect(episodeNumberFromTitle('第01集'), 1);
      expect(episodeNumberFromTitle('第2季第3集'), 3);
    });

    test('认 EP/E 与季集写法', () {
      expect(episodeNumberFromTitle('EP12'), 12);
      expect(episodeNumberFromTitle('E03'), 3);
      expect(episodeNumberFromTitle('ep 5'), 5);
      expect(episodeNumberFromTitle('S01E05'), 5);
      expect(episodeNumberFromTitle('Keep12'), isNull);
    });

    test('认纯数字与开头数字', () {
      expect(episodeNumberFromTitle('12'), 12);
      expect(episodeNumberFromTitle('007'), 7);
      expect(episodeNumberFromTitle('12. 贵门恶女'), 12);
      expect(episodeNumberFromTitle('12、贵门恶女'), 12);
      expect(episodeNumberFromTitle('12 贵门恶女'), 12);
    });

    test('无集号与日期不误认', () {
      expect(episodeNumberFromTitle('花絮'), isNull);
      expect(episodeNumberFromTitle(''), isNull);
      expect(episodeNumberFromTitle('幕后特辑'), isNull);
      expect(episodeNumberFromTitle('2026-10-16'), isNull);
    });
  });

  TmdbEpisode episode(int number, {String name = '', int season = 1}) =>
      TmdbEpisode(
        seasonNumber: season,
        episodeNumber: number,
        name: name.isEmpty ? '剧名$number' : name,
        stillPath: '/still$number.jpg',
        airDate: '2026-01-0$number',
      );

  group('matchTmdbEpisodes', () {
    test('有 TMDB 匹配：按集号对号，顺序打乱也能对上', () {
      final matched = matchTmdbEpisodes(
        ['第1集', '第2集', '第3集'],
        [episode(3), episode(1), episode(2)],
      );
      expect(
        [for (final e in matched) e?.episodeNumber],
        [1, 2, 3],
      );
      expect(matched[0]?.stillPath, '/still1.jpg');
    });

    test('有 TMDB 无匹配：无集号标题按顺序配对，多余位置为 null', () {
      final matched = matchTmdbEpisodes(
        ['花絮A', '花絮B', '花絮C'],
        [episode(1), episode(2)],
      );
      expect(
        [for (final e in matched) e?.episodeNumber],
        [1, 2, null],
      );
    });

    test('无 TMDB：全部为 null，长度与顺序不变', () {
      final matched = matchTmdbEpisodes(['第1集', '第2集'], const []);
      expect(matched, [null, null]);
    });

    test('混合：先对号、剩余按顺序，绝不丢集', () {
      final matched = matchTmdbEpisodes(
        ['第2集', '幕后', '第5集'],
        [episode(1), episode(2), episode(3)],
      );
      expect(
        [for (final e in matched) e?.episodeNumber],
        [2, 1, null],
      );
    });

    test('同号重复标题不抢同一条记录，未配上者留空用兜底图', () {
      final matched = matchTmdbEpisodes(
        ['第1集', '第1集(重播)'],
        [episode(1), episode(2)],
      );
      expect(
        [for (final e in matched) e?.episodeNumber],
        [1, null],
      );
    });

    test('跨季同号取先出现的记录', () {
      final matched = matchTmdbEpisodes(
        ['第1集'],
        [episode(1, season: 1), episode(1, season: 2)],
      );
      expect(matched.single?.seasonNumber, 1);
    });

    test('空输入返回空列表', () {
      expect(matchTmdbEpisodes(const [], [episode(1)]), isEmpty);
    });
  });
}
