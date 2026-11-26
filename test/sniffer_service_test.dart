import 'package:moyi/playback_sniffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extract finds direct and assigned media urls without duplicates', () {
    final found = MediaSniffer.extractFromText(
      'var hlsUrl = "https://cdn.example.test/a.m3u8"; '
      '<video src="https://cdn.example.test/b.mp4"></video> '
      'https://cdn.example.test/a.m3u8 '
      'https://example.test/page.html',
    );
    expect(found, contains('https://cdn.example.test/a.m3u8'));
    expect(found, contains('https://cdn.example.test/b.mp4'));
    expect(
      found.where((url) => url == 'https://cdn.example.test/a.m3u8').length,
      1,
    );
    expect(found, isNot(contains('https://example.test/page.html')));
  });

  test('service rejects non-media urls and dedupes', () {
    final service = SnifferService(
      initialCandidates: ['https://cdn.example.test/a.m3u8'],
    );
    expect(service.add('https://cdn.example.test/a.m3u8'), isFalse);
    expect(service.add('https://example.test/page.html'), isFalse);
    expect(service.add('https://cdn.example.test/b.mp4'), isTrue);
    expect(service.candidates.length, 2);
  });

  test('preferred ranks m3u8 above mpd above mp4', () {
    final service = SnifferService();
    service.add('https://cdn.example.test/b.mp4');
    service.add('https://cdn.example.test/c.m4s');
    service.add('https://cdn.example.test/d.mpd');
    expect(service.preferred, 'https://cdn.example.test/d.mpd');
    service.add('https://cdn.example.test/a.m3u8?token=x');
    expect(service.preferred, 'https://cdn.example.test/a.m3u8?token=x');
    expect(SnifferService().preferred, isNull);
  });

  test('extract finds audio urls and preferred ranks audio below video', () {
    final found = MediaSniffer.extractFromText(
      'https://cdn.example.test/a.m4a https://cdn.example.test/b.mp3',
    );
    expect(found, contains('https://cdn.example.test/a.m4a'));
    expect(found, contains('https://cdn.example.test/b.mp3'));
    final service = SnifferService();
    service.add('https://cdn.example.test/a.m4a');
    service.add('https://cdn.example.test/b.mp4');
    expect(service.preferred, 'https://cdn.example.test/b.mp4');
  });

  test('auxiliary captures subtitle urls separately from media', () {
    expect(
      MediaSniffer.extractAuxFromText(
        'https://cdn.example.test/sub.vtt https://cdn.example.test/a.mp4',
      ),
      ['https://cdn.example.test/sub.vtt'],
    );
    final service = SnifferService();
    expect(service.addAux('https://cdn.example.test/sub.vtt'), isTrue);
    expect(service.addAux('https://cdn.example.test/sub.vtt'), isFalse);
    expect(service.addAux('https://cdn.example.test/a.mp4'), isFalse);
    expect(service.auxiliary, ['https://cdn.example.test/sub.vtt']);
    expect(service.preferred, isNull);
  });

  test('ad and preview candidates are filtered at intake', () {
    final service = SnifferService();
    // 广告网络主机与路径 token 命中：一律不收。
    expect(
      service.add('https://ads.example.test/banner.m3u8'),
      isFalse,
    );
    expect(
      service.add('https://cdn.example.test/preview/movie.m3u8'),
      isFalse,
    );
    expect(
      service.add('https://cdn.example.test/movie-trailer.mp4'),
      isFalse,
    );
    expect(
      service.add('https://cdn.example.test/trial/index.m3u8'),
      isFalse,
    );
    expect(
      service.add('https://doubleclick.example.test/ad.m3u8'),
      isFalse,
    );
    // 含 "ad" 子串但不是 token 的正常地址不能误伤。
    expect(
      service.add('https://cdn.example.test/adaptive/movie.m3u8'),
      isTrue,
    );
    expect(
      service.add('https://cdn.example.test/download/movie.mp4'),
      isTrue,
    );
    expect(service.candidates.length, 2);
  });

  test('rejected candidate is removed and never re-added', () {
    final service = SnifferService();
    service.add('https://cdn.example.test/a.m3u8');
    service.add('https://cdn.example.test/b.m3u8');
    expect(service.preferred, 'https://cdn.example.test/a.m3u8');
    service.reject('https://cdn.example.test/a.m3u8');
    expect(service.candidates, ['https://cdn.example.test/b.m3u8']);
    expect(service.preferred, 'https://cdn.example.test/b.m3u8');
    // 探针会反复上报同一地址：剔除后不能再被收回。
    expect(service.add('https://cdn.example.test/a.m3u8'), isFalse);
    expect(service.candidates, ['https://cdn.example.test/b.m3u8']);
  });

  test('sniffed result parses list and json string forms', () {
    expect(
      SnifferService.parseSniffedResult([
        'https://cdn.example.test/a.m3u8',
        42,
      ]),
      ['https://cdn.example.test/a.m3u8'],
    );
    expect(
      SnifferService.parseSniffedResult('["https://cdn.example.test/a.m3u8"]'),
      ['https://cdn.example.test/a.m3u8'],
    );
    expect(SnifferService.parseSniffedResult('not json'), isEmpty);
    expect(SnifferService.parseSniffedResult(null), isEmpty);
  });
}
