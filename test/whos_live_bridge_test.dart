import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/whos_live_bridge.dart';
import 'package:moyi/whos_local_library.dart';

void main() {
  List<Map<String, Object?>> rows() => [
    for (var i = 0; i < 5; i++)
      {
        'vod_name': 'SDAM 作品 $i',
        'vod_code': 'sdam-18$i',
        'vod_pic': 'https://v.hersav.me/images/av/s$i.jpg',
        'vod_play_url': r'正片$https://v.hersav.me/s' '$i.m3u8',
        'vod_id': 'sdam-18$i',
      },
    for (var i = 0; i < 3; i++)
      {
        'vod_name': 'FC2 作品 $i',
        'vod_code': 'fc2ppv-49133$i',
        'vod_pic': 'https://v.hersav.me/images/av/f$i.jpg',
        'vod_play_url': r'正片$https://v.hersav.me/f' '$i.m3u8',
        'vod_id': 'fc2ppv-49133$i',
      },
    // 没有直链的行不该变成频道
    {
      'vod_name': '无地址作品',
      'vod_code': 'sdam-999',
      'vod_play_url': '',
      'vod_id': 'sdam-999',
    },
  ];

  WhosLocalLibrary library() =>
      WhosLocalLibrary.fromWorks(WhosLocalLibrary.parseWorks(jsonEncode(rows())));

  test('内置片库作为一个内置直播源注册，走本地库清单', () {
    final source = LiveSource.byId(whosLibSourceId);
    expect(source, isNotNull);
    expect(source!.protocol, LiveProtocol.list);
    expect(source.endpoints.single, startsWith(whosLibScheme));
    expect(source.adult, isTrue);
    expect(source.builtin, isTrue);
    expect(source.paginated, isTrue);
  });

  test('分类：最新/排行榜 + 厂牌，名字后面带条数', () {
    final platforms = whosLibPlatforms(library(), brandLimit: 10);
    final ids = [for (final row in platforms) row.id];
    expect(ids, contains(whosLocalNewCategory));
    expect(ids, contains('${whosLocalBrandPrefix}sdam'));
    expect(ids, contains('${whosLocalBrandPrefix}fc2ppv'));
    final sdam = platforms.firstWhere(
      (row) => row.id == '${whosLocalBrandPrefix}sdam',
    );
    expect(sdam.name, 'SDAM · 5');
  });

  test('频道：一条作品一个频道，直链、封面、厂牌都对上', () {
    final library1 = library();
    final channels = whosLibChannels(
      library1,
      category: '${whosLocalBrandPrefix}sdam',
      page: 1,
    );
    expect(channels.length, 5);
    final first = channels.first;
    expect(first.name, 'sdam-180 SDAM 作品 0');
    expect(first.urls.single, 'https://v.hersav.me/s0.m3u8');
    expect(first.logo, 'https://v.hersav.me/images/av/s0.jpg');
    expect(first.group, 'SDAM');
    expect(first.source, whosLibSourceId);
    expect(first.playable, isTrue);
    expect(first.headers['Referer'], isNotEmpty);
  });

  test('分页按库的页长滚动，翻过尾页返回空', () {
    final library1 = library();
    final total = library1.countFor(category: '');
    expect(total, 8); // 5 SDAM + 3 FC2，无地址的行不入库
    final firstPage = whosLibChannels(library1, category: '', page: 1);
    expect(firstPage.length, total <= whosLibPageSize ? total : whosLibPageSize);
    final beyond = whosLibChannels(
      library1,
      category: '',
      page: 1 + (total ~/ whosLibPageSize) + 5,
    );
    expect(beyond, isEmpty);
  });

  test('没有直链的作品不出频道', () {
    final channels = whosLibChannels(library(), category: '');
    expect(channels.every((row) => row.urls.single.startsWith('http')), isTrue);
    expect(
      channels.where((row) => row.name.contains('无地址作品')),
      isEmpty,
    );
  });

  test('频道名过长截断，不撑爆一行', () {
    final long = WhosLocalWork(
      id: 'x1',
      title: 'x' * 120,
      code: 'sdam-1',
      playUrl: 'https://v.hersav.me/x.m3u8',
    );
    final name = whosLibChannelName(long);
    expect(name.length, lessThanOrEqualTo(64));
    expect(name.endsWith('…'), isTrue);
  });
}
