import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/playback_sniff_verify.dart';

SniffProbeFetch fakeFetch({
  required int status,
  String contentType = '',
  String body = '',
}) {
  return (url, headers, timeout) async => SniffProbeResponse(
    statusCode: status,
    headers: {if (contentType.isNotEmpty) 'content-type': contentType},
    headBytes: utf8.encode(body),
  );
}

void main() {
  test('m3u8 with manifest head verifies alive', () async {
    final ok = await verifySniffedCandidate(
      'https://cdn.example.test/a.m3u8',
      fetchHead: fakeFetch(
        status: 200,
        contentType: 'application/vnd.apple.mpegurl',
        body: '#EXTM3U\n#EXT-X-VERSION:3',
      ),
    );
    expect(ok, isTrue);
  });

  test('m3u8 without manifest head is dead', () async {
    final ok = await verifySniffedCandidate(
      'https://cdn.example.test/a.m3u8',
      fetchHead: fakeFetch(status: 200, body: '<html>nope</html>'),
    );
    expect(ok, isFalse);
  });

  test('direct file with 206 verifies alive', () async {
    final ok = await verifySniffedCandidate(
      'https://cdn.example.test/a.mp4',
      fetchHead: fakeFetch(status: 206, body: 'x'),
    );
    expect(ok, isTrue);
  });

  test('direct file with 200 html error page is dead', () async {
    final ok = await verifySniffedCandidate(
      'https://cdn.example.test/a.mp4',
      fetchHead: fakeFetch(
        status: 200,
        contentType: 'text/html; charset=utf-8',
        body: '<html>404</html>',
      ),
    );
    expect(ok, isFalse);
  });

  test('http error and fetch failure are dead, never throw', () async {
    expect(
      await verifySniffedCandidate(
        'https://cdn.example.test/a.mp4',
        fetchHead: fakeFetch(status: 403),
      ),
      isFalse,
    );
    expect(
      await verifySniffedCandidate(
        'https://cdn.example.test/a.mp4',
        fetchHead: (url, headers, timeout) async =>
            throw StateError('network down'),
      ),
      isFalse,
    );
    expect(
      await verifySniffedCandidate('not a url', fetchHead: fakeFetch(status: 200)),
      isFalse,
    );
  });
}
