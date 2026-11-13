import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/playback_parse.dart';

void main() {
  group('ParseInterface.apply', () {
    test('{url} 占位符替换并编码', () {
      const api = ParseInterface(
        id: 'a',
        name: '测试接口',
        url: 'https://parse.example.com/?url={url}',
      );
      expect(
        api.apply('https://video.example.com/play?id=1&x=2'),
        'https://parse.example.com/?url=https%3A%2F%2Fvideo.example.com%2Fplay%3Fid%3D1%26x%3D2',
      );
    });

    test('无占位符时直接拼在模板后（TVBox 惯例）', () {
      const api = ParseInterface(
        id: 'a',
        name: '测试接口',
        url: 'https://parse.example.com/?url=',
      );
      expect(
        api.apply('https://video.example.com/play'),
        'https://parse.example.com/?url=https://video.example.com/play',
      );
    });
  });

  group('looksLikeDirectMedia / looksLikeWebPage', () {
    test('直链扩展名认作直链', () {
      expect(looksLikeDirectMedia('https://cdn.example.com/a.m3u8'), isTrue);
      expect(looksLikeDirectMedia('https://cdn.example.com/a.mp4?token=1'), isTrue);
      expect(looksLikeDirectMedia('https://cdn.example.com/a.mkv#frag'), isTrue);
    });

    test('本地回环地址一律认作直链，不套解析', () {
      expect(looksLikeDirectMedia('http://127.0.0.1:8090/stream?link=x'), isTrue);
      expect(looksLikeDirectMedia('http://localhost:9978/proxy'), isTrue);
      expect(looksLikeDirectMedia('http://[::1]:8090/stream'), isTrue);
      expect(looksLikeWebPage('http://127.0.0.1:8090/stream?link=x'), isFalse);
    });

    test('普通 http 页面认作网页', () {
      expect(looksLikeWebPage('https://video.example.com/play/123'), isTrue);
      expect(looksLikeDirectMedia('https://video.example.com/play/123'), isFalse);
    });

    test('非 http(s) 不认作网页', () {
      expect(looksLikeWebPage('magnet:?xt=urn:btih:ABCDEF'), isFalse);
      expect(looksLikeWebPage('not a url'), isFalse);
    });
  });

  group('applySelectedParse', () {
    const api = ParseInterface(
      id: 'a',
      name: '测试接口',
      url: 'https://parse.example.com/?url=',
    );

    test('无选中接口或空地址返回 null', () {
      expect(
        applySelectedParse(url: 'https://x.example.com/p', needsParse: true, selected: null),
        isNull,
      );
      expect(
        applySelectedParse(url: '', needsParse: true, selected: api),
        isNull,
      );
    });

    test('needsParse 时直链也套解析', () {
      expect(
        applySelectedParse(
          url: 'https://cdn.example.com/a.mp4',
          needsParse: true,
          selected: api,
        ),
        'https://parse.example.com/?url=https://cdn.example.com/a.mp4',
      );
    });

    test('不需解析时直链不套、网页套', () {
      expect(
        applySelectedParse(
          url: 'https://cdn.example.com/a.mp4',
          needsParse: false,
          selected: api,
        ),
        isNull,
      );
      expect(
        applySelectedParse(
          url: 'https://video.example.com/play/123',
          needsParse: false,
          selected: api,
        ),
        'https://parse.example.com/?url=https://video.example.com/play/123',
      );
    });

    test('本地回环流地址不套解析', () {
      expect(
        applySelectedParse(
          url: 'http://127.0.0.1:8090/stream?link=x&play=1',
          needsParse: false,
          selected: api,
        ),
        isNull,
      );
    });
  });
}
