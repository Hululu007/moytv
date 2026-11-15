import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/episode_preview_card.dart';
import 'package:moyi/models.dart';

const _urlTitle =
    'https://tm.helloye.com/6VKLIFs2ZnYnTSEJzbCXug==,1794667511/6ada0940a5d0e70c60c61f0e/index.m3u8';

void main() {
  group('episodeTitleLooksLikeUrl', () {
    test('m3u8 link title is url-like', () {
      expect(episodeTitleLooksLikeUrl(_urlTitle), isTrue);
    });
    test('plain http link is url-like', () {
      expect(episodeTitleLooksLikeUrl('http://example.test/a.mp4'), isTrue);
    });
    test('bare stream suffix is url-like', () {
      expect(episodeTitleLooksLikeUrl('cdn.example.test/x/index.m3u8'), isTrue);
    });
    test('clean episode name is not url-like', () {
      expect(episodeTitleLooksLikeUrl('第1集'), isFalse);
      expect(episodeTitleLooksLikeUrl('正片'), isFalse);
      expect(episodeTitleLooksLikeUrl('第一章 重逢'), isFalse);
    });
  });

  group('displayEpisodeTitle', () {
    test('url title falls back to the episode label', () {
      expect(displayEpisodeTitle(_urlTitle, 1), '第1集');
    });
    test('clean title passes through', () {
      expect(displayEpisodeTitle('正片', 3), '正片');
    });
  });

  group('displayEpisodeLine', () {
    test('url title shows only the episode label, no link', () {
      expect(displayEpisodeLine(_urlTitle, 1), '第1集');
    });
    test('clean title keeps the label plus title shape', () {
      expect(displayEpisodeLine('正片', 1), '第1集 | 正片');
    });
    test('empty or label-equal title shows only the label', () {
      expect(displayEpisodeLine('', 2), '第2集');
      expect(displayEpisodeLine(null, 2), '第2集');
      expect(displayEpisodeLine('第2集', 2), '第2集');
    });
  });

  testWidgets('preview card with a link title shows no http text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpisodePreviewCard(
            episode: Episode({'id': '1', 'title': _urlTitle}, 1),
            tmdb: null,
            stillUrl: '',
            posterUrl: '',
            current: false,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('http'), findsNothing);
    expect(find.textContaining('m3u8'), findsNothing);
    expect(find.text('第1集'), findsOneWidget);
  });

  testWidgets('preview card keeps a clean episode title', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpisodePreviewCard(
            episode: Episode({'id': '1', 'title': '正片'}, 1),
            tmdb: null,
            stillUrl: '',
            posterUrl: '',
            current: false,
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('正片'), findsOneWidget);
  });
}
