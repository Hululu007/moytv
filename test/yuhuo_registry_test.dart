import 'package:moyi/live_parser.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/models.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

// 欲火移植注册表锁定（fix3）：senlin 进点播、huangdou 进短剧，
// 直播区 2026-11-08 用户令改：修仙版四源（秀果、欲火聚合、百年直播、
// 成人点播）之外，新接绿果鉴直播数据——B站、虎牙、PandaLive、
// SakuraLive 四个 JSON 接口源，加 445569.xyz 七个 m3u 聚合源；
// 哔哩哔哩、虎牙已于本次恢复为内置源（2026-11-07 删站令作废），
// 欲火直播仍删。注册漏挂/归属写错即红。
// 成人点播频道表为修仙版原样复制版（9,966 条 EXTINF / 17 分组，
// 解析器按（分组,台名）合并多线路后为 9,958 个频道）。
void main() {
  group('点播区：森林资源', () {
    test('videoValues 含 v_senlin 且槽位映射正确，删站后共 78 项', () {
      expect(SourceSite.videoValues, hasLength(78));
      final senlin = SourceSite.byId('v_senlin');
      expect(senlin.name, '🔞森林资源');
      expect(senlin.section, SourceSite.sectionVideo);
      expect(senlin.slotId, 'yh_senlin');
      expect(senlin.coreSlotId, 'yh_senlin');
      expect(SourceSite.byId('v_senlin').slotId, 'yh_senlin');
      expect(
        SourceSite.knownValues.map((s) => s.id),
        containsAll(['v_ikun', 'v_senlin']),
      );
    });

    test('videoValues 尾项为黄果 v_huangguo（v_hg 已删）', () {
      final hg = SourceSite.videoValues.last;
      expect(hg.id, 'v_huangguo');
      expect(hg.slotId, 'yh_huangguo');
      expect(hg.section, SourceSite.sectionVideo);
      expect(
        SourceSite.videoValues.map((s) => s.slotId),
        containsAll(['yh_km', 'yh_lxs', 'yh_km2', 'yh_cucumber', 'yh_avbobo']),
      );
    });
  });

  group('短剧区：黄豆短剧', () {
    test('duanjuValues 尾项为 huangdou_yh 且能力位齐', () {
      expect(SourceSite.duanjuValues, hasLength(12));
      final huangdou = SourceSite.duanjuValues.last;
      expect(huangdou.id, 'huangdou_yh');
      expect(huangdou.name, '黄豆短剧');
      expect(huangdou.isDramaSection, isTrue);
      expect(huangdou.onlineSearch, isTrue);
      expect(huangdou.pagedSearch, isTrue);
      expect(SourceSite.byId('huangdou_yh').name, '黄豆短剧');
      expect(SourceSite.defaultHiddenSiteIds, isNot(contains('huangdou_yh')));
    });
  });

  group('直播区：修仙版四源 + 绿果鉴十一源', () {
    test('内置直播源清单与协议/端点锁定', () {
      expect(LiveSource.values.map((s) => s.id), [
        'xiuguo',
        'maiyoux',
        'bnzb',
        'user_m3u',
        'bilibili',
        'huya',
        'pandalive',
        'sakuralive',
        'm3u_douyin',
        'm3u_douyu',
        'm3u_huya',
        'm3u_kugou',
        'm3u_tiktok',
        'm3u_twitch',
        'm3u_yy',
      ]);
      expect(LiveSource.values.map((s) => s.name), [
        '🔞秀果',
        '🔞欲火聚合',
        '🔞百年直播',
        '🔞成人点播',
        '哔哩哔哩',
        '虎牙',
        'PandaLive',
        'SakuraLive',
        '抖音直播',
        '斗鱼直播',
        '虎牙直播',
        '酷狗直播',
        'TikTok直播',
        'Twitch直播',
        'YY直播',
      ]);
      final maiyoux = LiveSource.byId('maiyoux')!;
      expect(maiyoux.protocol, LiveProtocol.pingtai);
      expect(maiyoux.endpoints, [
        'http://api.maiyoux.com:81/mf',
        'http://api.vipmisss.com:81/xcdsw',
      ]);
      expect(maiyoux.adult, isTrue);

      final bnzb = LiveSource.byId('bnzb')!;
      expect(bnzb.protocol, LiveProtocol.pingtai);
      expect(bnzb.endpoints, ['http://api.vipmisss.com:81/xcdsw']);
      expect(bnzb.adult, isTrue);

      final userM3u = LiveSource.byId('user_m3u')!;
      expect(userM3u.protocol, LiveProtocol.list);
      expect(userM3u.endpoint, 'asset://assets/live/user_m3u.m3u');
      expect(userM3u.adult, isTrue);

      final bilibili = LiveSource.byId('bilibili')!;
      expect(bilibili.protocol, LiveProtocol.api);
      expect(bilibili.adult, isFalse);
      expect(bilibili.paginated, isTrue);
      expect(bilibili.greenCategoryFilter, isFalse);

      final huya = LiveSource.byId('huya')!;
      expect(huya.protocol, LiveProtocol.api);
      expect(huya.adult, isFalse);
      expect(huya.paginated, isTrue);

      final m3uDouyu = LiveSource.byId('m3u_douyu')!;
      expect(m3uDouyu.protocol, LiveProtocol.list);
      expect(m3uDouyu.endpoint, 'https://douyu.445569.xyz/live.m3u');
      expect(m3uDouyu.adult, isFalse);
      expect(m3uDouyu.greenCategoryFilter, isFalse);

      expect(LiveSource.byId('yuhuo_live'), isNull);
      expect(LiveSource.byId('uu'), isNull);
      expect(LiveSource.byId('douyu'), isNull);
    });

    test('绿色模式下四个成人源全部隐藏，主流源全部可见', () {
      expect(
        LiveSource.visible(true).map((s) => s.id),
        [
          'bilibili',
          'huya',
          'pandalive',
          'sakuralive',
          'm3u_douyin',
          'm3u_douyu',
          'm3u_huya',
          'm3u_kugou',
          'm3u_tiktok',
          'm3u_twitch',
          'm3u_yy',
        ],
      );
      expect(LiveSource.visible(false), hasLength(15));
    });
  });

  group('成人点播频道表资产', () {
    test('打包 m3u 可加载并解析出全量分组与频道', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final text = await rootBundle.loadString('assets/live/user_m3u.m3u');
      expect(text, startsWith('#EXTM3U'));
      final parsed = LiveParser.parse(
        text,
        source: 'user_m3u',
        defaultGroup: '成人点播',
      );
      expect(parsed.format, LiveFormat.m3u);
      expect(parsed.groups, hasLength(17));
      // 原始 9,966 条 EXTINF；解析器按（分组,台名）合并多线路后为 9,958 个频道。
      expect(parsed.channelCount, 9958);
      final coded = parsed.groups.firstWhere((g) => g.name == '中文有码');
      expect(coded.channels, hasLength(1778));
      expect(coded.channels.first.urls, isNotEmpty);
      final single = parsed.groups.firstWhere((g) => g.name == '香蕉台');
      expect(single.channels.single.name, '未命名频道');
    });

    test('m3u 小样解析：分组与多线路合并', () {
      const sample = '''
#EXTM3U
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://example.com/hunan.m3u8
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://example.com/hunan2.m3u8
#EXTINF:-1 group-title="电影频道",CCTV-6
http://example.com/cctv6.m3u8
''';
      final parsed = LiveParser.parse(sample, source: 'user_m3u');
      expect(parsed.groups, hasLength(2));
      expect(parsed.channelCount, 2);
      expect(parsed.groups.first.channels.single.urls, hasLength(2));
    });
  });
}
