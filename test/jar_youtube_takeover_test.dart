import 'package:moyi/jar_bridge.dart';
import 'package:moyi/jar_youtube_takeover.dart';
import 'package:moyi/models.dart';
import 'package:flutter_test/flutter_test.dart';

JarSiteSpec _spec(String className) => JarSiteSpec(
      siteId: JarSiteSpec.siteIdFor('zakatv', 'ZakaYouTube'),
      configId: 'zakatv',
      name: 'YouTube',
      className: className,
      jarUrl: 'assets/jars/zakatv.jar',
      jarMd5: '',
      ext: '{"gl":"US","hl":"zh-CN"}',
    );

void main() {
  group('jar YouTube takeover site match', () {
    test('builtin ZakaYouTube class matches', () {
      expect(
        JarYoutubeTakeover.isJarYoutubeSite(
          _spec('com.github.catvod.spider.ZakaYouTubeAmns'),
        ),
        isTrue,
      );
    });

    test('other jar classes do not match', () {
      expect(
        JarYoutubeTakeover.isJarYoutubeSite(
          _spec('com.github.catvod.spider.ZakaMjv011Amns'),
        ),
        isFalse,
      );
      expect(
        JarYoutubeTakeover.isJarYoutubeSite(
          _spec('com.github.catvod.spider.YouTube'),
        ),
        isFalse,
      );
    });
  });

  group('jar YouTube takeover plan gate', () {
    test('direct url with parse disabled is usable', () {
      const plan = PlaybackPlan(
        url: 'https://example.com/stream.m3u8',
        headers: {'User-Agent': 'test'},
        needsParse: false,
      );
      expect(JarYoutubeTakeover.isUsablePlan(plan), isTrue);
    });

    test('empty url, parse request, and proxy url fall back', () {
      expect(
        JarYoutubeTakeover.isUsablePlan(
          const PlaybackPlan(url: '', needsParse: false),
        ),
        isFalse,
      );
      expect(
        JarYoutubeTakeover.isUsablePlan(
          const PlaybackPlan(
            url: 'https://example.com/stream.m3u8',
            needsParse: true,
          ),
        ),
        isFalse,
      );
      expect(
        JarYoutubeTakeover.isUsablePlan(
          const PlaybackPlan(url: 'proxy://x', needsParse: false),
        ),
        isFalse,
      );
    });
  });
}
