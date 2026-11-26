// 详情页在线线路区（2026-11-26）：按番号自动搜 123AV / PH，
// 命中口径（123AV 比番号、PH 只认标题含番号）、状态文案与
// 点行取流递播放器回调。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_online_lines.dart';
import 'package:moyi/models.dart';

const _av123SearchHtml = '''
<div class="card">
  <a class="card__cover" href="/cn/v/ssis-001"><img class="card__img" data-src="https://icdn.123av.com/p1.jpg" alt=""></a>
  <div class="card__title">SSIS-001 命中标题</div>
  <span class="card__dur">120分钟</span>
</div>
<div class="card">
  <a class="card__cover" href="/cn/v/other-999"><img class="card__img" data-src="https://icdn.123av.com/p2.jpg" alt=""></a>
  <div class="card__title">别的片</div>
  <span class="card__dur">90分钟</span>
</div>
''';

const _av123DetailHtml = r'''
<html><body>
<h1>SSIS-001 命中标题</h1>
<script>embed("https:\/\/javplayer.me\/e\/AbC123?token=xyz")</script>
</body></html>
''';

const _phSearchHtml = '''
<div class="wrap">
  <a href="/view_video.php?viewkey=abc123"><img src="https://ci.phncdn.com/t1.jpg" alt="无关标题"></a>
  <span class="duration">12:34</span>
</div>
''';

Future<String> _fakeFetch(String url, Map<String, String> headers) async {
  if (url.contains('javplayer.me/stream')) {
    return '{"stream":"https://cdn.example.com/x.m3u8"}';
  }
  if (url.contains('123av.com/cn/v/')) return _av123DetailHtml;
  if (url.contains('123av.com')) return _av123SearchHtml;
  if (url.contains('pornhub.com')) return _phSearchHtml;
  return '<html></html>';
}

Future<String> _failFetch(String url, Map<String, String> headers) async {
  throw Exception('network down');
}

void main() {
  testWidgets('123AV 命中番号成线路、PH 标题不含番号算未找到、点行取流', (
    tester,
  ) async {
    DramaDetail? played;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActressOnlineLinesSection(
            code: 'SSIS-001',
            fetch: _fakeFetch,
            onPlay: (detail) => played = detail,
          ),
        ),
      ),
    );
    // 搜索是真异步：轮询等两行状态都落定。
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('已找到').evaluate().isNotEmpty &&
          find.text('未找到').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.textContaining('已找到 · 点播'), findsOneWidget);
    expect(find.text('未找到'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('actress-online-line-av123')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('actress-online-line-ph')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('actress-online-line-av123')),
    );
    for (var i = 0; i < 30 && played == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(played, isNotNull);
    expect(played!.episodes.single.id, 'https://cdn.example.com/x.m3u8');
    expect(played!.drama.source, 'av123');
  });

  testWidgets('搜索全失败时两行都标搜索失败、不编线路', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActressOnlineLinesSection(
            code: 'SSIS-001',
            fetch: _failFetch,
            onPlay: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('搜索失败 · 点按重试').evaluate().length >= 2) break;
    }
    expect(find.text('搜索失败 · 点按重试'), findsNWidgets(2));
    expect(find.textContaining('已找到'), findsNothing);
  });
}
