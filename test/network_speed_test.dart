import 'package:moyi/network_speed.dart';
import 'package:flutter_test/flutter_test.dart';

const _cacheStateJson =
    '{"seekable-ranges":[{"start":0.0101,"end":4.433322}],"cache-end":271.066667,'
    '"reader-pts":45.966656,"cache-duration":224.755967,"eof":false,'
    '"underrun":false,"idle":false,"total-bytes":201765408,"fw-bytes":157287072,'
    '"raw-input-rate":644208,"bof-cached":true,"eof-cached":false}';

MpvNetworkSample _sample(
  String uri, {
  double? rawInputRate,
  double? totalBytes,
  double? cacheEnd,
  double? bitrate,
}) {
  return MpvNetworkSample(
    uri: uri,
    rawInputRate: rawInputRate,
    totalBytes: totalBytes,
    cacheEndSeconds: cacheEnd,
    bitrateBps: bitrate,
  );
}

TimedMpvSample _timed(
  int seconds, {
  String uri = 'https://example.com/video.m3u8',
  double? rawInputRate,
  double? totalBytes,
  double? cacheEnd,
  double? bitrate,
}) {
  return TimedMpvSample(
    time: DateTime.utc(2026, 1, 1).add(Duration(seconds: seconds)),
    sample: _sample(
      uri,
      rawInputRate: rawInputRate,
      totalBytes: totalBytes,
      cacheEnd: cacheEnd,
      bitrate: bitrate,
    ),
  );
}

void main() {
  test('parses mpv demuxer cache state fields', () {
    final parsed = parseDemuxerCacheState(
      'https://example.com/video.m3u8',
      _cacheStateJson,
    );
    expect(parsed, isNotNull);
    expect(parsed!.cacheEndSeconds, closeTo(271.066667, 0.000001));
    expect(parsed.rawInputRate, 644208);
    expect(parsed.totalBytes, 201765408);
  });

  test('cache state parse rejects garbage and empty objects', () {
    expect(parseDemuxerCacheState('u', 'not json'), isNull);
    expect(parseDemuxerCacheState('u', '{}'), isNull);
    expect(parseDemuxerCacheState('u', '{"eof":false}'), isNull);
  });

  test('bitrate parse accepts positive numbers only', () {
    expect(parseMpvBitrate('510278'), 510278);
    expect(parseMpvBitrate(' 144326 '), 144326);
    expect(parseMpvBitrate(''), isNull);
    expect(parseMpvBitrate('0'), isNull);
    expect(parseMpvBitrate('-5'), isNull);
    expect(parseMpvBitrate('abc'), isNull);
    expect(parseMpvBitrate(null), isNull);
  });

  test('raw input rate wins when present', () {
    final speed = computeNetworkSpeed([
      _timed(0, totalBytes: 1000, cacheEnd: 10, bitrate: 8000000),
      _timed(3, rawInputRate: 644208, totalBytes: 5000, cacheEnd: 13),
    ]);
    expect(speed, 644208);
  });

  test('total bytes window rate', () {
    final speed = computeNetworkSpeed([
      _timed(0, totalBytes: 1000),
      _timed(3, totalBytes: 4000),
    ]);
    expect(speed, closeTo(1000, 0.001));
  });

  test('total bytes backward jump yields null', () {
    final speed = computeNetworkSpeed([
      _timed(0, totalBytes: 4000),
      _timed(3, totalBytes: 100),
    ]);
    expect(speed, isNull);
  });

  test('cache end fallback converts media seconds with bitrate', () {
    final speed = computeNetworkSpeed([
      _timed(0, cacheEnd: 0, bitrate: 8000000),
      _timed(3, cacheEnd: 10, bitrate: 8000000),
      _timed(6, cacheEnd: 20, bitrate: 8000000),
    ]);
    expect(speed, closeTo(3333333.33, 0.01));
  });

  test('cache end fallback needs a five second span', () {
    final speed = computeNetworkSpeed([
      _timed(0, cacheEnd: 0, bitrate: 8000000),
      _timed(3, cacheEnd: 10, bitrate: 8000000),
    ]);
    expect(speed, isNull);
  });

  test('empty samples yield null', () {
    expect(computeNetworkSpeed([]), isNull);
  });

  test('speed formatting uses binary units with one decimal', () {
    expect(formatNetworkSpeed(0), '0 B/s');
    expect(formatNetworkSpeed(512), '512 B/s');
    expect(formatNetworkSpeed(1536), '1.5 KB/s');
    expect(formatNetworkSpeed(2500000), '2.4 MB/s');
    expect(formatNetworkSpeed(1610612736), '1.5 GB/s');
  });

  test('tracker shows raw input rate after one tick', () async {
    var calls = 0;
    final tracker = NetworkSpeedTracker(
      sample: () async {
        calls++;
        return _sample('https://example.com/video.m3u8', rawInputRate: 1000000);
      },
    );
    await tracker.tick();
    expect(tracker.speedText.value, '976.6 KB/s');
    expect(calls, 1);
    tracker.dispose();
  });

  test('tracker throttles rapid ticks', () async {
    var calls = 0;
    var now = DateTime.utc(2026, 1, 1);
    final tracker = NetworkSpeedTracker(
      now: () => now,
      sample: () async {
        calls++;
        return _sample('https://example.com/video.m3u8', rawInputRate: 1000000);
      },
    );
    await tracker.tick();
    now = now.add(const Duration(milliseconds: 100));
    await tracker.tick();
    expect(calls, 1);
    tracker.dispose();
  });

  test('tracker hides speed when sample disappears', () async {
    var current = _sample(
      'https://example.com/video.m3u8',
      rawInputRate: 500000,
    );
    var now = DateTime.utc(2026, 1, 1);
    final tracker = NetworkSpeedTracker(
      now: () => now,
      sample: () async => current,
    );
    await tracker.tick();
    expect(tracker.speedText.value, isNotNull);
    now = now.add(const Duration(seconds: 1));
    current = _sample('https://example.com/video.m3u8');
    await tracker.tick();
    expect(tracker.speedText.value, isNull);
    tracker.dispose();
  });

  test('tracker restarts history on uri change', () async {
    final script = [
      _sample('https://a.example.com/1.m3u8', totalBytes: 1000),
      _sample('https://a.example.com/1.m3u8', totalBytes: 4000),
      _sample('https://b.example.com/2.m3u8', totalBytes: 100),
      _sample('https://b.example.com/2.m3u8', totalBytes: 3100),
    ];
    var step = 0;
    var now = DateTime.utc(2026, 1, 1);
    final tracker = NetworkSpeedTracker(
      now: () => now,
      sample: () async => script[step],
    );
    await tracker.tick();
    now = now.add(const Duration(seconds: 3));
    step = 1;
    await tracker.tick();
    expect(tracker.speedText.value, '1000 B/s');
    now = now.add(const Duration(seconds: 3));
    step = 2;
    await tracker.tick();
    expect(tracker.speedText.value, isNull);
    now = now.add(const Duration(seconds: 3));
    step = 3;
    await tracker.tick();
    expect(tracker.speedText.value, '1000 B/s');
    tracker.dispose();
  });

  test('tracker recovers after a seek jump', () async {
    final script = [
      _sample('https://example.com/v.m3u8', cacheEnd: 100, bitrate: 8000000),
      _sample('https://example.com/v.m3u8', cacheEnd: 103, bitrate: 8000000),
      _sample('https://example.com/v.m3u8', cacheEnd: 50, bitrate: 8000000),
      _sample('https://example.com/v.m3u8', cacheEnd: 53, bitrate: 8000000),
      _sample('https://example.com/v.m3u8', cacheEnd: 56, bitrate: 8000000),
    ];
    var step = 0;
    var now = DateTime.utc(2026, 1, 1);
    final tracker = NetworkSpeedTracker(
      now: () => now,
      sample: () async => script[step],
    );
    await tracker.tick();
    now = now.add(const Duration(seconds: 3));
    step = 1;
    await tracker.tick();
    now = now.add(const Duration(seconds: 3));
    step = 2;
    await tracker.tick();
    expect(tracker.speedText.value, isNull);
    now = now.add(const Duration(seconds: 3));
    step = 3;
    await tracker.tick();
    now = now.add(const Duration(seconds: 3));
    step = 4;
    await tracker.tick();
    expect(tracker.speedText.value, '976.6 KB/s');
    tracker.dispose();
  });
}
