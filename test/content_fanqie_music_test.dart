import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_fanqie_music.dart';
import 'package:moyi/content_http.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/core_bridge.dart';

// 样本形状来自 2026-11-26 本机实拉的 m.novelfm.com 首页/详情页
// _ROUTER_DATA（条目为真数据，仅榜单截到 3 条）。

String _ssrPage(Map<String, dynamic> routerData) {
  return '<!doctype html><html><head><title>x</title></head><body>'
      '<script>window._ROUTER_DATA = ${jsonEncode(routerData)};</script>'
      '</body></html>';
}

Map<String, dynamic> _homeData() => {
  'loaderData': {
    'layout': null,
    'page': {
      'isSuccess': true,
      'homeData': {
        'data': {
          'hot_list_groups': [
            {
              'id': '1',
              'genre': 10,
              'tab_name': '热门歌曲',
              'hot_list': [
                {
                  'book_id': '7707714893352291353',
                  'play_num': '92943',
                  'collect_num': 301135,
                  'book_name': '外公',
                  'author': '江皓南',
                  'play_num_text': '9.3万人在听',
                  'genre': '10',
                  'abstract': '江皓南',
                  'audio_thumb_uri': 'http://p3-novel-sign.byteimg.com/novel-pic/aaa~tplv.image?x-expires=1&x-signature=s',
                  'album_title': '外公·我推的歌',
                  'singing_version_name': '',
                  'genre_type': '200',
                },
                {
                  'book_id': '7701384444749286424',
                  'play_num': '102326',
                  'collect_num': 334607,
                  'book_name': '人间',
                  'author': '许飞',
                  'play_num_text': '10.2万人在听',
                  'genre': '10',
                  'abstract': '许飞',
                  'audio_thumb_uri': 'http://p3-novel-sign.byteimg.com/novel-pic/bbb~tplv.image?x-expires=1&x-signature=s',
                  'album_title': '人间',
                  'singing_version_name': '原唱',
                  'genre_type': '200',
                },
                {'book_id': '', 'book_name': '无 id 坏条目', 'author': 'x'},
              ],
            },
          ],
        },
        'BaseResp': {'StatusCode': 0, 'StatusMessage': 'success'},
      },
    },
  },
  'errors': null,
};

Map<String, dynamic> _detailData() => {
  'loaderData': {
    'music_(id)/layout': null,
    'music_(id)/page': {
      'pageData': {
        'isSuccess': true,
        'api_book_info': {
          'book_id': '7291876781143886858',
          'play_num': '559',
          'collect_num': 82,
          'book_name': '兄弟的情',
          'author': '宋晓峰',
          'thumb_url': 'https://p3-novel.byteimg.com/origin/novel-pic/bb375849843540995a741e75ea7e62a3',
          'play_num_text': '0.1万人在听',
          'genre': '10',
          'abstract': '兄弟的情',
          'album_title': '兄弟的情',
          'singing_version_name': '原唱',
          'genre_type': '200',
        },
        'video_info': {
          'main_url': 'https://v26-novelfm.novelfmvod.com/aa/6b/video/tos/cn/tos-cn-ve/oA/?a=8661&mime_type=audio_mp4',
          'back_url': 'https://v3-novelfm.novelfmvod.com/aa/6b/video/tos/cn/tos-cn-ve/oA/?a=8661&mime_type=audio_mp4',
        },
        'lyric_info': '[15630,2290]<0,330,0>和<400,330,0>你\n[18750,2290]歌词',
        'lyric_type': 2,
        'recommend_books': <dynamic>[],
      },
    },
  },
  'errors': null,
};

void main() {
  group('茄果音乐源', () {
    test('身份与分区', () {
      final source = FanqieMusicSource(ContentHttp());
      expect(source.id, 'fanqie_music');
      expect(source.name, '茄果音乐');
      expect(source.section, ContentSection.music);
      expect(source.note, contains('暂不支持搜索'));
    });

    test('注册表：音乐区有茄果音乐，听书区没有', () {
      final music = ContentRegistry.sourcesFor(ContentSection.music);
      expect(music.map((s) => s.id), contains('fanqie_music'));
      final audio = ContentRegistry.sourcesFor(ContentSection.audio);
      expect(audio.map((s) => s.id), isNot(contains('fanqie_music')));
      expect(ContentRegistry.isKnownId('fanqie_music'), isTrue);
    });

    test('ROUTER_DATA 抽取：字符串里的括号不干扰配平', () {
      final data = parseFanqieRouterData(_ssrPage(_detailData()));
      expect(data, isNotNull);
      expect(data!['loaderData'], isA<Map>());
      expect(parseFanqieRouterData('<html>no data</html>'), isNull);
    });

    test('分类与目录：热门歌曲一组，坏条目剔除，封面转 https', () {
      final data = parseFanqieRouterData(_ssrPage(_homeData()))!;
      final categories = parseFanqieMusicCategories(data);
      expect(categories, hasLength(1));
      expect(categories.single.id, '1');
      expect(categories.single.name, '热门歌曲');
      final page = parseFanqieMusicCatalog(data, '1');
      expect(page.items, hasLength(2));
      expect(page.hasMore, isFalse);
      final first = page.items.first;
      expect(first.id, '7707714893352291353');
      expect(first.title, '外公');
      expect(first.author, '江皓南');
      expect(first.cover, startsWith('https://'));
      expect(first.remarks, '9.3万人在听');
      expect(first.intro, contains('我推的歌'));
      expect(page.items[1].intro, contains('原唱'));
    });

    test('详情：书信息 + 单曲章节', () {
      final data = parseFanqieRouterData(_ssrPage(_detailData()))!;
      final detail = parseFanqieMusicDetail(data, '7291876781143886858');
      expect(detail.book.title, '兄弟的情');
      expect(detail.book.author, '宋晓峰');
      expect(detail.book.cover, contains('p3-novel.byteimg.com'));
      expect(detail.book.remarks, contains('原唱'));
      expect(detail.chapters, hasLength(1));
      expect(detail.chapters.single.id, '7291876781143886858');
      expect(detail.chapters.single.meta, '宋晓峰');
    });

    test('播放地址：main 优先，空了回落 back', () {
      final data = parseFanqieRouterData(_ssrPage(_detailData()))!;
      expect(
        parseFanqieMusicPlayUrl(data),
        startsWith('https://v26-novelfm.novelfmvod.com/'),
      );
      final noMain = _detailData();
      (((noMain['loaderData'] as Map)['music_(id)/page'] as Map)['pageData']
          as Map)['video_info'] = {
        'main_url': '',
        'back_url': 'https://v3-novelfm.novelfmvod.com/x',
      };
      expect(
        parseFanqieMusicPlayUrl(parseFanqieRouterData(_ssrPage(noMain))!),
        'https://v3-novelfm.novelfmvod.com/x',
      );
    });

    test('搜索明确不可用（不假装）', () {
      final source = FanqieMusicSource(ContentHttp());
      expect(() => source.search('周杰伦', 1), throwsA(isA<AppFailure>()));
    });
  });

  group('茄果音乐活测', () {
    test('全链：分类/目录/详情/播放地址/Range 真播', () async {
      if (Platform.environment['FANQIE_MUSIC_LIVE'] != '1') {
        return;
      }
      HttpOverrides.global = _ProxyOverrides();
      final source = FanqieMusicSource(ContentHttp());
      final categories = await source.categories();
      expect(categories.map((c) => c.name), contains('热门歌曲'));
      final page = await source.catalog(categories.first.id, 1);
      expect(page.items.length, greaterThan(50));
      final first = page.items.first;
      expect(first.title, isNotEmpty);
      expect(first.author, isNotEmpty);
      expect(first.cover, startsWith('http'));
      final detail = await source.detail(first.id);
      expect(detail.chapters, hasLength(1));
      final track = await source.audioTrack(first.id, detail.chapters.single);
      expect(track.url, contains('novelfmvod.com'));
      // Range 拉首段验真：206 + ftyp 魔数。
      final client = HttpClient()
        ..findProxy = (_) => 'PROXY hatch-egress-proxy:3128';
      try {
        final request = await client.getUrl(Uri.parse(track.url));
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        request.headers.set(HttpHeaders.userAgentHeader, fanqieMusicUserAgent);
        final response = await request.close();
        expect(response.statusCode, 206);
        final bytes = await response.expand((c) => c).toList();
        expect(bytes.length, greaterThan(16));
        expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');
      } finally {
        client.close(force: true);
      }
    }, timeout: const Timeout(Duration(minutes: 6)));
  });
}

class _ProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..findProxy = (_) => 'PROXY hatch-egress-proxy:3128';
  }
}
