import 'package:moyi/core_bridge.dart';
import 'package:moyi/live_api.dart';
import 'package:moyi/live_http.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_sources.dart';
import 'package:flutter_test/flutter_test.dart';

// 绿果鉴直播数据内置（2026-11-08）：JSON 接口源的解析与仓库分支。
// 2026-11-15 用户令删站后只剩哔哩哔哩一个接口源，虎牙/PandaLive/
// SakuraLive 的解析与仓库用例随接口表一并删除。
// 全部用仿真数据，不联网；出口断网时也能跑。
void main() {
  group('B站分区与房间解析', () {
    const areas = '''
{"code":0,"data":[
{"id":1,"parent_id":0,"name":"娱乐","list":[
{"id":2,"parent_id":1,"name":"视频唱见","list":[]},
{"id":3,"parent_id":1,"name":"才艺主播","list":[]}]},
{"id":9,"parent_id":0,"name":"游戏","list":[
{"id":10,"parent_id":9,"name":"英雄联盟","list":[]}]}]}
''';
    const rooms = '''
{"code":0,"data":{"count":2,"list":[
{"roomid":111,"uid":1,"title":"唱歌","uname":"主播A","cover":"https://example.com/a.jpg","online":100},
{"roomid":222,"uid":2,"title":"聊天","uname":"主播B","cover":"https://example.com/b.jpg","online":50}]}}
''';
    const play = '''
{"code": 0, "data": {"room_id": 111, "playurl_info": {"playurl": {"stream": [{"protocol_name": "http_stream", "format": [{"format_name": "flv", "codec": [{"codec_name": "avc", "base_url": "/live.flv", "url_info": [{"host": "https://flv.example.com", "extra": "?x=1"}]}]}]}, {"protocol_name": "http_hls", "format": [{"format_name": "ts", "codec": [{"codec_name": "avc", "base_url": "/live.m3u8", "url_info": [{"host": "https://hls.example.com", "extra": "?y=2"}]}]}]}]}}}}
''';

    test('分区表展平为子分区，父分区 id 进 endpoint', () {
      final spec = liveApiSpecs['bilibili']!;
      final platforms = parseApiPlatforms(spec, areas);
      expect(platforms.map((p) => p.id), ['2', '3', '10']);
      expect(platforms.map((p) => p.name), ['视频唱见', '才艺主播', '英雄联盟']);
      expect(platforms.map((p) => p.endpoint), ['1', '1', '9']);
    });

    test('房间列表转频道，房间号进 token，播放地址待取流', () {
      final spec = liveApiSpecs['bilibili']!;
      const platform = LivePlatform(id: '2', name: '视频唱见', endpoint: '1');
      final channels = parseApiChannels(spec, platform, rooms, 'bilibili');
      expect(channels, hasLength(2));
      expect(channels.first.name, '唱歌');
      expect(channels.first.subtitle, '主播A');
      expect(channels.first.logo, 'https://example.com/a.jpg');
      expect(channels.first.token, '111');
      expect(channels.first.urls, isEmpty);
      expect(channels.last.token, '222');
    });

    test('取流优先选 http_hls/ts/avc，拼 host + base + extra', () {
      final spec = liveApiSpecs['bilibili']!;
      expect(
        parseApiPlayUrl(spec, play),
        'https://hls.example.com/live.m3u8?y=2',
      );
    });
  });

  group('仓库 api 分支（假 HTTP）', () {
    late Map<String, String> responses;
    late LiveRepository repository;

    setUp(() {
      responses = {
        'https://api.live.bilibili.com/room/v1/Area/getList':
            '{"code":0,"data":[{"id":1,"parent_id":0,"name":"娱乐","list":[{"id":2,"parent_id":1,"name":"视频唱见","list":[]}]}]}',
        'https://api.live.bilibili.com/room/v3/area/getRoomList?area_id=2&parent_area_id=1&page=1&page_size=30':
            '{"code":0,"data":{"count":1,"list":[{"roomid":111,"uid":1,"title":"唱歌","uname":"主播A","cover":"https://example.com/a.jpg"}]}}',
        'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id=111&protocol=0,1&format=0,1,2&codec=0,1&qn=10000&platform=web&ptype=8':
            '{"code":0,"data":{"playurl_info":{"playurl":{"stream":[{"protocol_name":"http_hls","format":[{"format_name":"ts","codec":[{"codec_name":"avc","base_url":"/live.m3u8","url_info":[{"host":"https://hls.example.com","extra":""}]}]}]}]}}}}',
      };
      repository = LiveRepository(http: _FakeLiveHttp(responses));
    });

    test('B站：分区、房间、取流全链路走通', () async {
      final source = LiveSource.byId('bilibili')!;
      final platforms = await repository.platforms(source);
      expect(platforms.map((p) => p.name), ['视频唱见']);
      final channels = await repository.channels(source, platforms.first);
      expect(channels, hasLength(1));
      expect(channels.first.token, '111');
      final playback = await repository.playback(source, channels.first);
      expect(playback.url, 'https://hls.example.com/live.m3u8');
    });

    test('未登记的接口源报暂未接入', () async {
      // 待接入的斗鱼 + 2026-11-15 已删的三个接口源：接口表里
      // 查不到，一律报暂未接入。
      for (final id in ['douyu', 'huya', 'pandalive', 'sakuralive']) {
        final pending = LiveSource(
          id: id,
          name: id,
          description: '',
          protocol: LiveProtocol.api,
        );
        await expectLater(
          repository.platforms(pending),
          throwsA(isA<AppFailure>()),
        );
      }
    });
  });

  group('接入红线', () {
    test('接口表只用提取出的公开地址，不含原 App 中继与令牌接口', () {
      for (final spec in liveApiSpecs.values) {
        for (final url in [
          spec.listUrl,
          spec.playUrl,
          spec.platformsUrl,
        ]) {
          expect(url, isNot(contains('51777')));
          expect(url, isNot(contains('bg6zkb5')));
          expect(url, isNot(contains('39ogrmw')));
          expect(url, isNot(contains('app_token')));
          expect(url, isNot(contains('sgt.')));
          expect(url, isNot(contains('bdt.')));
        }
      }
    });

    test('待接入 14 个平台登记在案，且都不在内置源里', () {
      expect(pendingLiveApiSources.keys, hasLength(14));
      for (final id in pendingLiveApiSources.keys) {
        expect(LiveSource.byId(id), isNull);
      }
      expect(LiveSource.values, hasLength(27)); // 5 个原有（4 修仙 + 哔哩哔哩）+ 22 个内置 m3u 清单。
      expect(LiveSource.visible(true), hasLength(1));
    });
  });
}

class _FakeLiveHttp extends LiveHttp {
  _FakeLiveHttp(this._responses);

  final Map<String, String> _responses;

  @override
  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration? timeout,
    String? proxyResourceKey,
  }) async {
    final text = _responses[url];
    if (text == null) throw StateError('unexpected url: $url');
    return text;
  }
}
