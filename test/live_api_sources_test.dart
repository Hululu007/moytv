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
// 2026-11-26 真果鉴直播批：虎牙（www 主机列表 + 房间页内嵌数据取流）、
// Stripchat（公开列表 + 地址直拼）、Cam4（目录 JSON 自带 HLS）重新验活
// 验播后登记，用例随接口表一并补回。
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
      // 待接入的斗鱼 + 2026-11-15 已删的两个接口源：接口表里
      // 查不到，一律报暂未接入。（虎牙已于 2026-11-26 重新登记。）
      for (final id in ['douyu', 'pandalive', 'sakuralive']) {
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
        for (final url in [spec.listUrl, spec.playUrl, spec.platformsUrl]) {
          expect(url, isNot(contains('51777')));
          expect(url, isNot(contains('bg6zkb5')));
          expect(url, isNot(contains('39ogrmw')));
          expect(url, isNot(contains('app_token')));
          expect(url, isNot(contains('sgt.')));
          expect(url, isNot(contains('bdt.')));
        }
      }
    });

    test('待接入 12 个平台登记在案，且都不在内置源里', () {
      expect(pendingLiveApiSources.keys, hasLength(12));
      for (final id in pendingLiveApiSources.keys) {
        expect(LiveSource.byId(id), isNull);
      }
      expect(
        LiveSource.values,
        hasLength(37),
      ); // 来源：lib/live_sources.dart 的 LiveSource.values 清单逐项数——
      // 原 28（内置片库 whos_lib + 秀果/欲火聚合/百年直播/成人点播 4 个
      // + 哔哩哔哩 + 22 个内置 m3u 清单）+ 2026-11-26 真果鉴直播批 9 个
      // （虎牙 + 6 个平台聚合表 + Stripchat/Cam4）= 37。
      expect(
        LiveSource.visible(true),
        hasLength(8),
      ); // 绿色模式可见的主流源：哔哩哔哩 + 虎牙 + 6 个平台聚合表。
    });
  });

  group('虎牙解析（2026-11-26 真果鉴直播批）', () {
    const rooms = '''
{"status":200,"data":{"page":1,"pageSize":120,"totalPage":53,"datas":[
{"profileRoom":13579,"introduction":"标题甲","roomName":"","nick":"主播甲","screenshot":"https://example.com/a.jpg","gameFullName":"主机游戏"},
{"profileRoom":99798,"introduction":"","roomName":"标题乙","nick":"主播乙","screenshot":"","gameFullName":"网游"}]}}
''';
    const roomPage = '''
<html><script>
var hyPlayerConfig = { html5: 1, vappid: 10057, stream: {"data":[{"gameLiveInfo":{"uid":500066171},"gameStreamInfoList":[
{"sCdnType":"AL","iIsMaster":0,"sStreamName":"stream_al","sFlvUrl":"http://al.flv.huya.com/src","sFlvUrlSuffix":"flv","sFlvAntiCode":"wsSecret=aaa&wsTime=bbb&fm=ccc&ctype=huya_live&fs=bgct"},
{"sCdnType":"HS","iIsMaster":1,"sStreamName":"stream_hs","sFlvUrl":"https://hs.flv.huya.com/src","sFlvUrlSuffix":"flv","sFlvAntiCode":"wsSecret=ddd&wsTime=eee&fm=fff&ctype=huya_live&fs=bgct"}]}]} };
</script></html>
''';

    test('房间列表转频道，房号进 token，标题空时回退 roomName', () {
      final spec = liveApiSpecs['huya']!;
      const platform = LivePlatform(id: 'all', name: '全部');
      final channels = parseApiChannels(spec, platform, rooms, 'huya');
      expect(channels, hasLength(2));
      expect(channels.first.name, '标题甲');
      expect(channels.first.subtitle, '主播甲');
      expect(channels.first.logo, 'https://example.com/a.jpg');
      expect(channels.first.token, '13579');
      expect(channels.first.urls, isEmpty);
      expect(channels.last.name, '标题乙');
      expect(channels.last.token, '99798');
    });

    test('房间页取流：选主线（iIsMaster）拼 FLV + 页面 anticode', () {
      final spec = liveApiSpecs['huya']!;
      expect(
        parseApiPlayUrl(spec, roomPage),
        'https://hs.flv.huya.com/src/stream_hs.flv?wsSecret=ddd&wsTime=eee&fm=fff&ctype=huya_live&fs=bgct',
      );
    });

    test('房间页没有内嵌数据时取流返回 null', () {
      final spec = liveApiSpecs['huya']!;
      expect(parseApiPlayUrl(spec, '<html>no config</html>'), isNull);
    });
  });

  group('Stripchat 与 Cam4 解析（2026-11-26 真果鉴直播批）', () {
    const stripchatRooms = '''
{"blocks":[{"id":"countryGenderModels","models":[
{"id":34946535,"username":"model_a","status":"public","isLive":true},
{"id":51314223,"username":"model_b","status":"public","isLive":true}]}]}
''';
    const cam4Rooms = '''
{"totalCount":2,"users":[
{"username":"UserA","profileImageLink":"https://example.com/a.jpg","hlsPreviewUrl":"https://cam4-hls.example.com/a/playlist.m3u8"},
{"username":"UserB","profileImageLink":"","hlsPreviewUrl":""}]}
''';

    test('Stripchat：blocks 首块 models 转频道，主播 id 进 token', () {
      final spec = liveApiSpecs['stripchat']!;
      const platform = LivePlatform(id: 'all', name: '全部');
      final channels = parseApiChannels(spec, platform, stripchatRooms, 'stripchat');
      expect(channels, hasLength(2));
      expect(channels.first.name, 'model_a');
      expect(channels.first.token, '34946535');
      expect(channels.first.urls, isEmpty);
      expect(spec.playUrlFor(channels.first.token),
          'https://edge-hls.doppiocdn.com/hls/34946535/master/34946535.m3u8');
    });

    test('Cam4：users 转频道，hlsPreviewUrl 直接进 urls', () {
      final spec = liveApiSpecs['cam4']!;
      const platform = LivePlatform(id: 'all', name: '全部');
      final channels = parseApiChannels(spec, platform, cam4Rooms, 'cam4');
      expect(channels, hasLength(2));
      expect(channels.first.name, 'UserA');
      expect(channels.first.logo, 'https://example.com/a.jpg');
      expect(channels.first.urls,
          ['https://cam4-hls.example.com/a/playlist.m3u8']);
      expect(channels.last.urls, isEmpty);
    });
  });

  group('仓库 api 分支：虎牙全链路与 Stripchat 直拼（假 HTTP）', () {
    test('虎牙：列表、房间页取流全链路走通', () async {
      final repository = LiveRepository(
        http: _FakeLiveHttp({
          'https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage&gameId=0&page=1':
              '{"status":200,"data":{"datas":[{"profileRoom":13579,"introduction":"标题甲","nick":"主播甲","screenshot":""}]}}',
          'https://www.huya.com/13579':
              'var hyPlayerConfig = { stream: {"data":[{"gameStreamInfoList":[{"sCdnType":"AL","iIsMaster":1,"sStreamName":"s1","sFlvUrl":"http://al.flv.huya.com/src","sFlvUrlSuffix":"flv","sFlvAntiCode":"wsSecret=aaa&wsTime=bbb"}]}]} };',
        }),
      );
      final source = LiveSource.byId('huya')!;
      final platforms = await repository.platforms(source);
      expect(platforms.single.name, '全部');
      final channels = await repository.channels(source, platforms.single);
      expect(channels.single.token, '13579');
      final playback = await repository.playback(source, channels.single);
      expect(playback.url, 'http://al.flv.huya.com/src/s1.flv?wsSecret=aaa&wsTime=bbb');
    });

    test('Stripchat：播放地址直拼，不发取流请求', () async {
      final repository = LiveRepository(
        http: _FakeLiveHttp({
          'https://stripchat.com/api/front/v2/models?limit=60&primaryTag=girls':
              '{"blocks":[{"models":[{"id":34946535,"username":"model_a"}]}]}',
        }),
      );
      final source = LiveSource.byId('stripchat')!;
      final platforms = await repository.platforms(source);
      final channels = await repository.channels(source, platforms.single);
      expect(channels.single.token, '34946535');
      // 假 HTTP 里没有播放页地址：一旦真去取流就会抛错，
      // 能拿到地址即证明走了直拼分支。
      final playback = await repository.playback(source, channels.single);
      expect(playback.url,
          'https://edge-hls.doppiocdn.com/hls/34946535/master/34946535.m3u8');
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
  }) async {
    final text = _responses[url];
    if (text == null) throw StateError('unexpected url: $url');
    return text;
  }
}
