// JavDB 接口演员库（2026-11-26 接入）：签名向量（与独立
// MD5 实现对照）、图片 XOR 解密、JSON 解析与视图状态。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/javdb_api.dart';
import 'package:moyi/actress/javdb_view.dart';

void main() {
  test('签名：格式与 MD5 向量对得上', () {
    // 向量由独立实现（python hashlib）对同一时间戳+盐算出。
    expect(
      javdbSignature(1700000000),
      '1700000000.lpw6vgqzsp.dacaffcd8b4e1b35c2752f065e906f3a',
    );
  });

  test('图片解密：魔数图原样、加密图首字节异或还原', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x10, 0x20]);
    expect(javdbDecryptImageBytes(jpeg), jpeg);
    const key = 0x5A;
    final plain = [0xFF, 0xD8, 0xFF, 0x00, 0x42];
    final encrypted = Uint8List.fromList([
      key,
      for (final b in plain) b ^ key,
    ]);
    expect(javdbDecryptImageBytes(encrypted), plain);
  });

  test('解析：信封 + 作品/演员字段（snake_case）', () async {
    final seenUrls = <String>[];
    Future<String> fakeFetch(String url) async {
      seenUrls.add(url);
      if (url.contains('/actors')) {
        return jsonEncode({
          'success': true,
          'data': {
            'actors': [
              {
                'id': 'a1',
                'name': '演员甲',
                'avatar_url': 'https://c0.jdbstatic.com/avatars/a1.jpg',
                'gender': 0,
              },
            ],
          },
        });
      }
      return jsonEncode({
        'success': true,
        'data': {
          'current_page': 1,
          'movies': [
            {
              'id': 'm1',
              'number': 'SSIS-001',
              'title': '标题一',
              'thumb_url': 'https://c0.jdbstatic.com/thumbs/m1.jpg',
              'cover_url': 'https://c0.jdbstatic.com/covers/m1.jpg',
              'duration': 7260,
              'release_date': '2024-06-15',
              'has_cnsub': true,
              'magnets_count': 3,
              'score': '4.5',
            },
          ],
        },
      });
    }

    final client = JavdbApiClient(fetch: fakeFetch);
    final movies = await client.latestMovies();
    expect(movies.single.number, 'SSIS-001');
    expect(movies.single.poster, 'https://c0.jdbstatic.com/covers/m1.jpg');
    expect(movies.single.hasCnsub, isTrue);
    expect(movies.single.magnetsCount, 3);
    final actors = await client.actors();
    expect(actors.single.name, '演员甲');
    expect(actors.single.avatarUrl, contains('avatars/a1.jpg'));
    // 请求形状照 jar 版 ZakaJavdbAmns 原文实证：演员列表必
    // 带 type=0（漏带服务端回「参数不能为空: type」）。
    expect(
      seenUrls.any((u) => u.contains('api/v1/actors?type=0&page=1')),
      isTrue,
    );
  });

  test('演员列表：名字空时落 name_zht（jar 版取值顺序实证）', () async {
    final client = JavdbApiClient(
      fetch: (_) async => jsonEncode({
        'success': true,
        'data': {
          'actors': [
            {'id': 'a9', 'name': '', 'name_zht': '繁中名', 'avatar_url': ''},
          ],
        },
      }),
    );
    final actors = await client.actors();
    expect(actors.single.name, '繁中名');
  });

  test('搜索：参数名是 q 不是 keyword（jar 版 searchMovies 实证）', () async {
    String? seenUrl;
    final client = JavdbApiClient(
      fetch: (url) async {
        seenUrl = url;
        return jsonEncode({
          'success': true,
          'data': {'movies': []},
        });
      },
    );
    await client.searchMovies('SSIS-001');
    expect(seenUrl, contains('api/v2/search?q=SSIS-001&page=1'));
    expect(seenUrl, isNot(contains('keyword=')));
  });

  test('解析：success 为假时抛带消息的失败', () async {
    final client = JavdbApiClient(
      fetch: (_) async =>
          jsonEncode({'success': false, 'message': 'invalid signature'}),
    );
    expect(client.latestMovies(), throwsA(anything));
  });

  testWidgets('视图：演员网格渲染 + 未验标常挂', (tester) async {
    final client = JavdbApiClient(
      fetch: (url) async {
        if (url.contains('/actors')) {
          return jsonEncode({
            'success': true,
            'data': {
              'actors': [
                {'id': 'a1', 'name': '演员甲', 'avatar_url': '', 'gender': 0},
                {'id': 'a2', 'name': '演员乙', 'avatar_url': '', 'gender': 0},
              ],
            },
          });
        }
        return jsonEncode({'success': true, 'data': {'movies': []}});
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: JavdbSourceView(client: client))),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('演员甲').evaluate().isNotEmpty) break;
    }
    expect(find.text('演员甲'), findsOneWidget);
    expect(find.text('演员乙'), findsOneWidget);
    expect(find.text('未验'), findsOneWidget);
  });

  testWidgets('视图：接口失败给人话提示 + 重试，不露假数据', (tester) async {
    final client = JavdbApiClient(
      fetch: (_) async => throw Exception('timeout'),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: JavdbSourceView(client: client))),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('重试').evaluate().isNotEmpty) break;
    }
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('连不上'), findsOneWidget);
  });
}
