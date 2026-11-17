import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/html_host/html_play.dart';

void main() {
  group('parseHtmlVodPlayUrl', () {
    test('parses name\$url segments', () {
      final episodes = parseHtmlVodPlayUrl(
        '第1集\$https://cdn.example.com/1.m3u8#第2集\$https://cdn.example.com/2.m3u8',
      );
      expect(episodes, hasLength(2));
      expect(episodes[0].name, '第1集');
      expect(episodes[0].url, 'https://cdn.example.com/1.m3u8');
      expect(episodes[1].name, '第2集');
    });

    test('bare urls get numbered names and empty segments are skipped', () {
      final episodes = parseHtmlVodPlayUrl(
        'https://cdn.example.com/a.mp4##https://cdn.example.com/b.mp4',
      );
      expect(episodes, hasLength(2));
      expect(episodes[0].name, '第1集');
      expect(episodes[1].name, '第3集');
    });

    test('empty text yields no episodes', () {
      expect(parseHtmlVodPlayUrl(''), isEmpty);
      expect(parseHtmlVodPlayUrl('  #  '), isEmpty);
    });
  });

  group('parseHtmlPlayEpisodes', () {
    test('list of maps with per-episode headers', () {
      final episodes = parseHtmlPlayEpisodes([
        {
          'name': 'EP1',
          'url': 'https://cdn.example.com/1.mp4',
          'headers': {'Referer': 'https://site.example.com/'},
        },
        {'title': 'EP2', 'playUrl': 'https://cdn.example.com/2.mp4'},
      ], defaultHeaders: const {'User-Agent': 'moyi'});
      expect(episodes, hasLength(2));
      expect(episodes[0].headers['Referer'], 'https://site.example.com/');
      expect(episodes[0].headers['User-Agent'], 'moyi');
      expect(episodes[1].name, 'EP2');
      expect(episodes[1].headers, {'User-Agent': 'moyi'});
    });

    test('list of strings including embedded vod_play_url', () {
      final episodes = parseHtmlPlayEpisodes([
        'A\$https://cdn.example.com/a.mp4',
        'B\$https://cdn.example.com/b.mp4#C\$https://cdn.example.com/c.mp4',
        'https://cdn.example.com/d.mp4',
      ]);
      expect(
        episodes.map((episode) => episode.name).toList(),
        ['A', 'B', 'C', '第3集'],
      );
    });

    test('vod_play_url string input', () {
      final episodes = parseHtmlPlayEpisodes(
        '第1集\$https://cdn.example.com/1.m3u8#第2集\$https://cdn.example.com/2.m3u8',
      );
      expect(episodes, hasLength(2));
    });

    test('name to url map input', () {
      final episodes = parseHtmlPlayEpisodes({
        'EP1': 'https://cdn.example.com/1.mp4',
        'EP2': 'https://cdn.example.com/2.mp4',
      });
      expect(episodes.map((episode) => episode.name), ['EP1', 'EP2']);
    });

    test('object with episodes key', () {
      final episodes = parseHtmlPlayEpisodes({
        'episodes': [
          {'name': 'E1', 'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(episodes, hasLength(1));
    });

    test('resolver episodes throw honestly', () {
      expect(
        () => parseHtmlPlayEpisodes([
          {'name': 'E1', 'resolver': 'https://site.example.com/r.js'},
        ]),
        throwsA(isA<HtmlResolverUnsupported>()),
      );
    });

    test('empty resolver marker is ignored', () {
      final episodes = parseHtmlPlayEpisodes([
        {'name': 'E1', 'url': 'https://cdn.example.com/1.mp4', 'resolver': ''},
      ]);
      expect(episodes, hasLength(1));
    });

    test('no playable url throws FormatException', () {
      expect(
        () => parseHtmlPlayEpisodes([
          {'name': 'E1'},
        ]),
        throwsFormatException,
      );
      expect(() => parseHtmlPlayEpisodes(null), throwsFormatException);
      expect(() => parseHtmlPlayEpisodes([]), throwsFormatException);
      expect(() => parseHtmlPlayEpisodes(''), throwsFormatException);
    });

    test('metadata-only maps are not mistaken for episodes', () {
      expect(
        () => parseHtmlPlayEpisodes({'title': 'just a title'}),
        throwsFormatException,
      );
      expect(
        () => parseHtmlPlayEpisodes({'EP1': 'not-a-url'}),
        throwsFormatException,
      );
    });
  });

  group('parseHtmlPlayPayload', () {
    test('clamps the initial index into range', () {
      final low = parseHtmlPlayPayload({
        'index': -3,
        'episodes': [
          {'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(low.initialIndex, 0);
      final high = parseHtmlPlayPayload({
        'index': 99,
        'episodes': [
          {'url': 'https://cdn.example.com/1.mp4'},
          {'url': 'https://cdn.example.com/2.mp4'},
        ],
      });
      expect(high.initialIndex, 1);
    });

    test('title, subtitle and headers flow through', () {
      final request = parseHtmlPlayPayload({
        'title': '测试剧',
        'subtitleUrl': 'https://cdn.example.com/s.vtt',
        'headers': {'Referer': 'https://site.example.com/'},
        'episodes': [
          {'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(request.title, '测试剧');
      expect(request.subtitleUrl, 'https://cdn.example.com/s.vtt');
      expect(request.headers['Referer'], 'https://site.example.com/');
    });
  });

  group('parseHtmlVodPayload', () {
    test('TVBox vod fields with multi-line play urls', () {
      final detail = parseHtmlVodPayload({
        'vod_name': '测试剧',
        'vod_pic': 'https://cdn.example.com/pic.jpg',
        'vod_content': '简介',
        'vod_class': '剧情',
        'vod_play_from': '线路A\$\$\$线路B',
        'vod_play_url':
            '第1集\$https://a.example.com/1.m3u8\$\$\$第1集\$https://b.example.com/1.m3u8',
      });
      expect(detail.title, '测试剧');
      expect(detail.pic, 'https://cdn.example.com/pic.jpg');
      expect(detail.description, '简介');
      expect(detail.category, '剧情');
      expect(detail.lines, hasLength(2));
      expect(detail.lines[0].name, '线路A');
      expect(detail.lines[1].name, '线路B');
      expect(detail.allEpisodes, hasLength(2));
    });

    test('episodes list input uses the default line name', () {
      final detail = parseHtmlVodPayload({
        'title': '短剧',
        'episodes': [
          {'name': 'E1', 'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(detail.lines, hasLength(1));
      expect(detail.lines.single.name, '默认');
    });

    test('bare vodId without playable content fails honestly', () {
      expect(
        () => parseHtmlVodPayload({'vod_id': '12345'}),
        throwsFormatException,
      );
    });

    test('direct url becomes a single default episode', () {
      final detail = parseHtmlVodPayload({
        'title': '单片',
        'url': 'https://cdn.example.com/movie.mp4',
      });
      expect(detail.lines.single.episodes.single.name, '正片');
    });
  });
}
