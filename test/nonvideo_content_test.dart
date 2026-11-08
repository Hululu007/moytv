import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/nonvideo_content.dart';
import 'package:moyi/models.dart';

Episode _episode(Map<String, dynamic> raw) => Episode(raw, 1);

void main() {
  test('novel payload parses title and text', () {
    final content = parseNonVideoUrl(
      'novel://{"title":"T","content":"hello world"}',
    );
    expect(content, isNotNull);
    expect(content!.isNovel, isTrue);
    expect(content.title, 'T');
    expect(content.text, 'hello world');
  });

  test('pics payload splits on double ampersand only', () {
    final content = parseNonVideoUrl(
      'pics://https://a.example/1.jpg?x=1&y=2&&https://a.example/2.jpg',
    );
    expect(content, isNotNull);
    expect(content!.isPics, isTrue);
    expect(content.urls, [
      'https://a.example/1.jpg?x=1&y=2',
      'https://a.example/2.jpg',
    ]);
  });

  test('hgitem token is not final novel text', () {
    expect(
      parseNonVideoUrl(
        'novel://hgitem:7598518950523063321?t=%E7%AC%AC1%E7%AB%A0',
      ),
      isNull,
    );
    final episode = _episode({
      'id': 'hongguo:novel:1:7598518950523063321',
      'videoUrl': 'novel://hgitem:7598518950523063321?t=%E7%AC%AC1%E7%AB%A0',
      'title': '第1章',
    });
    expect(nonVideoFromEpisode(episode), isNull);
    expect(nonVideoKindOfEpisode(episode), NonVideoKind.novel);
  });

  test('plain video urls are not non-video', () {
    expect(parseNonVideoUrl('https://cdn.example/a.m3u8'), isNull);
    expect(parseNonVideoUrl('num|slug|pid|1080'), isNull);
  });

  test('episode scanning finds payload in videoUrl and in id', () {
    final fromVideoUrl = _episode({
      'id': 'mjv011:novel#1#x:1',
      'videoUrl': 'novel://{"title":"N","content":"c"}',
      'title': '阅读',
    });
    expect(nonVideoFromEpisode(fromVideoUrl)?.isNovel, isTrue);
    final fromId = _episode({
      'id': 'pics://https://a.example/1.jpg&&https://a.example/2.jpg',
      'title': '查看',
    });
    expect(nonVideoFromEpisode(fromId)?.urls.length, 2);
    final video = _episode({
      'id': '123|slug|pid|1080',
      'title': '1080P',
    });
    expect(nonVideoFromEpisode(video), isNull);
    expect(isNonVideoEpisode(video), isFalse);
  });
}
