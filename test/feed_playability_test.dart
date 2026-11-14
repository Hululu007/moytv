import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/models.dart';

final _episode = Episode(
  {'id': '1', 'title': '第1集', 'currentEpisode': 1},
  1,
);

Drama _drama(String id) => Drama(
  id: id,
  source: 'adult1',
  title: '条目$id',
  cover: 'https://x.test/$id.jpg',
);

DramaDetail _detail(Drama drama) => DramaDetail(drama, [_episode]);

FeedProbeResponse _manifestResponse() => const FeedProbeResponse(
  statusCode: 200,
  headers: {'content-type': 'application/vnd.apple.mpegurl'},
  headBytes: [35, 69, 88, 84, 77, 51, 85, 10],
);

FeedPlayabilityVerifier _verifier({
  Future<FeedProbeResponse> Function(String, Map<String, String>, Duration)?
  fetchHead,
  Future<DramaDetail?> Function(Drama)? detailOf,
  Future<PlaybackPlan> Function(Drama, Episode)? resolveOf,
  int concurrency = 4,
  Duration itemTimeout = const Duration(seconds: 6),
  Duration batchBudget = const Duration(seconds: 45),
}) => FeedPlayabilityVerifier(
  detailOf: detailOf ?? ((drama) async => _detail(drama)),
  resolveOf:
      resolveOf ??
      ((drama, episode) async =>
          const PlaybackPlan(url: 'https://x.test/play.m3u8')),
  fetchHead: fetchHead ?? ((_, _, _) async => _manifestResponse()),
  concurrency: concurrency,
  itemTimeout: itemTimeout,
  batchBudget: batchBudget,
);

void main() {
  group('feedProbePlayable', () {
    test('m3u8 清单 200 且含 EXT-M3U 判可播', () {
      expect(
        feedProbePlayable(
          Uri.parse('https://x.test/a.m3u8?token=1'),
          _manifestResponse(),
        ),
        isTrue,
      );
    });

    test('m3u8 返回非清单判不可播', () {
      expect(
        feedProbePlayable(
          Uri.parse('https://x.test/a.m3u8'),
          const FeedProbeResponse(
            statusCode: 200,
            headers: {'content-type': 'text/html'},
            headBytes: [60, 104, 116, 109, 108, 62],
          ),
        ),
        isFalse,
      );
    });

    test('直链 Range 206 判可播', () {
      expect(
        feedProbePlayable(
          Uri.parse('https://x.test/a.mp4'),
          const FeedProbeResponse(
            statusCode: 206,
            headers: {'content-type': 'video/mp4'},
            headBytes: [0, 0, 0, 1],
          ),
        ),
        isTrue,
      );
    });

    test('直链 200 非 HTML 且有数据判可播', () {
      expect(
        feedProbePlayable(
          Uri.parse('https://x.test/a.mp4'),
          const FeedProbeResponse(
            statusCode: 200,
            headers: {'content-type': 'video/mp4'},
            headBytes: [0, 0, 0, 1],
          ),
        ),
        isTrue,
      );
    });

    test('直链 200 但 HTML 错误页判不可播', () {
      expect(
        feedProbePlayable(
          Uri.parse('https://x.test/a.mp4'),
          const FeedProbeResponse(
            statusCode: 200,
            headers: {'content-type': 'text/html'},
            headBytes: [60, 104, 116, 109, 108, 62],
          ),
        ),
        isFalse,
      );
    });

    test('404/403 判不可播', () {
      for (final status in [404, 410, 403, 500]) {
        expect(
          feedProbePlayable(
            Uri.parse('https://x.test/a.mp4'),
            FeedProbeResponse(
              statusCode: status,
              headers: const {},
              headBytes: const [],
            ),
          ),
          isFalse,
        );
      }
    });
  });

  group('FeedPlayabilityVerifier.verifyOne', () {
    test('验播通过返回真', () async {
      final verifier = _verifier();
      expect(await verifier.verifyOne(_drama('a1')), isTrue);
    });

    test('取流 404 返回假', () async {
      final verifier = _verifier(
        fetchHead: (_, _, _) async => const FeedProbeResponse(
          statusCode: 404,
          headers: {},
          headBytes: [],
        ),
      );
      expect(await verifier.verifyOne(_drama('a1')), isFalse);
    });

    test('详情抛错/无详情/无选集返回假', () async {
      final throwing = _verifier(
        detailOf: (_) async => throw AppFailure('测试不播'),
      );
      expect(await throwing.verifyOne(_drama('a1')), isFalse);
      final nullDetail = _verifier(detailOf: (_) async => null);
      expect(await nullDetail.verifyOne(_drama('a1')), isFalse);
      final noEpisodes = _verifier(
        detailOf: (drama) async => DramaDetail(drama, []),
      );
      expect(await noEpisodes.verifyOne(_drama('a1')), isFalse);
    });

    test('取流抛错返回假', () async {
      final verifier = _verifier(
        resolveOf: (_, _) async => throw AppFailure('取流失败'),
      );
      expect(await verifier.verifyOne(_drama('a1')), isFalse);
    });

    test('需解析计划返回假', () async {
      final verifier = _verifier(
        resolveOf: (_, _) async =>
            const PlaybackPlan(url: 'https://x.test/page', needsParse: true),
      );
      expect(await verifier.verifyOne(_drama('a1')), isFalse);
    });

    test('非 http 协议返回假', () async {
      final verifier = _verifier(
        resolveOf: (_, _) async => const PlaybackPlan(
          url: 'magnet:?xt=urn:btih:abc',
        ),
      );
      expect(await verifier.verifyOne(_drama('a1')), isFalse);
    });

    test('超时返回假且不卡住', () async {
      final verifier = _verifier(
        itemTimeout: const Duration(milliseconds: 100),
        fetchHead: (_, _, _) => Completer<FeedProbeResponse>().future,
      );
      final stopwatch = Stopwatch()..start();
      expect(await verifier.verifyOne(_drama('a1')), isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('FeedPlayabilityVerifier.verifyAll', () {
    test('只返回验真的条目且保留原顺序', () async {
      final verifier = _verifier(
        fetchHead: (url, _, _) async => url.contains('good')
            ? _manifestResponse()
            : const FeedProbeResponse(
                statusCode: 404,
                headers: {},
                headBytes: [],
              ),
        resolveOf: (drama, _) async => PlaybackPlan(
          url: 'https://x.test/${drama.id}.m3u8',
        ),
      );
      final result = await verifier.verifyAll([
        _drama('bad1'),
        _drama('good1'),
        _drama('bad2'),
        _drama('good2'),
      ]);
      expect(result.map((d) => d.id), ['good1', 'good2']);
    });

    test('空输入返回空', () async {
      expect(await _verifier().verifyAll([]), isEmpty);
    });

    test('会话内缓存：重复验不再发请求', () async {
      var fetches = 0;
      var resolves = 0;
      final verifier = _verifier(
        resolveOf: (drama, _) async {
          resolves++;
          return const PlaybackPlan(url: 'https://x.test/play.m3u8');
        },
        fetchHead: (_, _, _) async {
          fetches++;
          return _manifestResponse();
        },
      );
      final candidates = [_drama('a1'), _drama('a2')];
      expect((await verifier.verifyAll(candidates)).length, 2);
      expect((await verifier.verifyAll(candidates)).length, 2);
      expect(fetches, 2);
      expect(resolves, 2);
    });

    test('失败结果也缓存', () async {
      var fetches = 0;
      final verifier = _verifier(
        fetchHead: (_, _, _) async {
          fetches++;
          return const FeedProbeResponse(
            statusCode: 404,
            headers: {},
            headBytes: [],
          );
        },
      );
      final candidates = [_drama('a1')];
      expect(await verifier.verifyAll(candidates), isEmpty);
      expect(await verifier.verifyAll(candidates), isEmpty);
      expect(fetches, 1);
    });

    test('并发不超过上限', () async {
      var active = 0;
      var maxActive = 0;
      final verifier = _verifier(
        concurrency: 3,
        fetchHead: (_, _, _) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          active--;
          return _manifestResponse();
        },
      );
      final candidates = List.generate(9, (i) => _drama('c$i'));
      expect((await verifier.verifyAll(candidates)).length, 9);
      expect(maxActive, lessThanOrEqualTo(3));
      expect(maxActive, greaterThan(1));
    });

    test('整批预算耗尽时不再起探、不拖住调用方', () async {
      final verifier = _verifier(
        concurrency: 1,
        itemTimeout: const Duration(seconds: 5),
        batchBudget: const Duration(milliseconds: 100),
        fetchHead: (_, _, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return _manifestResponse();
        },
      );
      final candidates = List.generate(6, (i) => _drama('s$i'));
      final stopwatch = Stopwatch()..start();
      final result = await verifier.verifyAll(candidates);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(result.length, lessThanOrEqualTo(1));
    });
  });
}
