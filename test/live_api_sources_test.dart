import 'package:moyi/core_bridge.dart';
import 'package:moyi/live_api.dart';
import 'package:moyi/live_http.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_sources.dart';
import 'package:flutter_test/flutter_test.dart';

// 绿果鉴直播数据内置（2026-11-08）：JSON 接口源的解析与仓库分支。
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

  group('虎牙列表与取流解析', () {
    const list = '''
{"status":200,"data":{"totalCount":2,"pageSize":120,"datas":[
{"uid":"u1","gameId":"1","nick":"虎牙A","roomName":"上分","screenshot":"https://example.com/h1.jpg","gameFullName":"英雄联盟","roomId":"r1"},
{"uid":"u2","gameId":"1","nick":"虎牙B","roomName":"娱乐","screenshot":"https://example.com/h2.jpg","gameFullName":"英雄联盟","roomId":"r2"}]}}
''';
    const play = '''
{"status":200,"data":{"profileRoom":"x","stream":{
"flv":{"url":"http://flv.example.com/r1.flv"},
"hls":{"url":"https://hls.example.com/r1.m3u8"}}}}
''';

    test('分类名从首条房间的 gameFullName 取，计数从 totalCount 取', () {
      final spec = liveApiSpecs['huya']!;
      expect(deriveApiPlatformName(spec, list), '英雄联盟');
      expect(deriveApiPlatformCount(spec, list), 2);
    });

    test('房间列表转频道，房间号进 token', () {
      final spec = liveApiSpecs['huya']!;
      const platform = LivePlatform(id: '1', name: '英雄联盟');
      final channels = parseApiChannels(spec, platform, list, 'huya');
      expect(channels, hasLength(2));
      expect(channels.first.name, '上分');
      expect(channels.first.subtitle, '虎牙A');
      expect(channels.first.token, 'r1');
    });

    test('取流优先选 hls 再选 flv', () {
      final spec = liveApiSpecs['huya']!;
      expect(parseApiPlayUrl(spec, play), 'https://hls.example.com/r1.m3u8');
    });
  });

  group('PandaLive 与 SakuraLive 列表解析', () {
    test('PandaLive：列表项自带播放地址的直接用上，没有的留空', () {
      const text = '''
{"list":[
{"userId":"p1","title":"판다방","thumbnail":"https://example.com/p1.jpg"},
{"userId":"p2","title":"노래방","thumbnail":"https://example.com/p2.jpg","playUrl":"https://example.com/p2.m3u8"}]}
''';
      final spec = liveApiSpecs['pandalive']!;
      const platform = LivePlatform(id: 'all', name: '全部');
      final channels = parseApiChannels(spec, platform, text, 'pandalive');
      expect(channels, hasLength(2));
      expect(channels.first.urls, isEmpty);
      expect(channels.first.token, 'p1');
      expect(channels.last.urls, ['https://example.com/p2.m3u8']);
    });

    test('SakuraLive：online_performers 转频道', () {
      const text = '''
{"online_performers":[
{"name":"sakura1","username":"s1","image":"https://example.com/s1.jpg"},
{"name":"sakura2","username":"s2","image":"https://example.com/s2.jpg"}]}
''';
      final spec = liveApiSpecs['sakuralive']!;
      const platform = LivePlatform(id: 'all', name: '全部');
      final channels = parseApiChannels(spec, platform, text, 'sakuralive');
      expect(channels, hasLength(2));
      expect(channels.first.token, 's1');
      expect(channels.first.logo, 'https://example.com/s1.jpg');
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
        'https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage&gameId=1&page=1':
            '{"status":200,"data":{"totalCount":1,"datas":[{"uid":"u1","gameId":"1","nick":"虎牙A","roomName":"上分","screenshot":"https://example.com/h1.jpg","gameFullName":"英雄联盟","roomId":"r1"}]}}',
        'https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=r1':
            '{"status":200,"data":{"stream":{"hls":{"url":"https://hls.example.com/r1.m3u8"}}}}',
        'https://api.pandalive.co.kr/v1/live':
            '{"list":[{"userId":"p1","title":"판다방","thumbnail":"https://example.com/p1.jpg","playUrl":"https://example.com/p1.m3u8"}]}',
        'https://chat.sakuralive.com/jsonSL/listing/freechat?guest=slen':
            '{"online_performers":[{"name":"sakura1","username":"s1","image":"https://example.com/s1.jpg"}]}',
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

    test('虎牙：分类名从数据取，房间取流走 profileRoom', () async {
      final source = LiveSource.byId('huya')!;
      final platforms = await repository.platforms(source);
      expect(platforms.single.name, '英雄联盟');
      expect(platforms.single.count, 1);
      final channels = await repository.channels(source, platforms.single);
      expect(channels.single.name, '上分');
      final playback = await repository.playback(source, channels.single);
      expect(playback.url, 'https://hls.example.com/r1.m3u8');
    });

    test('PandaLive 与 SakuraLive：单分类，列表项自带地址可播', () async {
      final panda = LiveSource.byId('pandalive')!;
      final pandaPlatforms = await repository.platforms(panda);
      expect(pandaPlatforms.single.name, '全部');
      final pandaChannels =
          await repository.channels(panda, pandaPlatforms.single);
      expect(pandaChannels.single.urls, ['https://example.com/p1.m3u8']);
      final playback = await repository.playback(panda, pandaChannels.single);
      expect(playback.url, 'https://example.com/p1.m3u8');

      final sakura = LiveSource.byId('sakuralive')!;
      final sakuraChannels = await repository.channels(
        sakura,
        (await repository.platforms(sakura)).single,
      );
      expect(sakuraChannels.single.name, 'sakura1');
      expect(sakuraChannels.single.urls, isEmpty);
      await expectLater(
        repository.playback(sakura, sakuraChannels.single),
        throwsA(isA<AppFailure>()),
      );
    });

    test('未登记的接口源报暂未接入', () async {
      const pending = LiveSource(
        id: 'douyu',
        name: '斗鱼',
        description: '',
        protocol: LiveProtocol.api,
      );
      await expectLater(
        repository.platforms(pending),
        throwsA(isA<AppFailure>()),
      );
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
      expect(LiveSource.values, hasLength(37)); // 15 个原有 + 22 个内置 m3u 清单。
      expect(LiveSource.visible(true), hasLength(11));
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
  }) async {
    final text = _responses[url];
    if (text == null) throw StateError('unexpected url: $url');
    return text;
  }
}
