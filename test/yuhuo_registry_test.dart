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
// 2026-11-15 用户令：哔哩哔哩以下的直播站全删（虎牙、PandaLive、
// SakuraLive 与 7 个 445569 m3u 聚合源），只留哔哩哔哩。
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

  group('直播区：内置片库 + 修仙版四源 + 接口源/聚合表 + 内置 m3u 二十二源', () {
    test('内置直播源清单与协议/端点锁定', () {
      expect(LiveSource.values.map((s) => s.id), [
        'whos_lib',
        'xiuguo',
        'maiyoux',
        'bnzb',
        'user_m3u',
        // 2026-11-14 内置的 22 个清洗版 m3u 清单（TG 私发）。
        'm3u_zhubo',
        'm3u_luanlun',
        'm3u_huayu',
        'm3u_guochan',
        'm3u_xuesheng',
        'm3u_tanhua',
        'm3u_riben',
        'm3u_oumei',
        'm3u_heilian',
        'm3u_community10',
        'm3u_community11',
        'm3u_wuma',
        'm3u_wanghong',
        'm3u_xingba',
        'm3u_chengtou',
        'm3u_zhifu',
        'm3u_qunjiao',
        'm3u_mingxing',
        'm3u_zipai',
        'm3u_avxiongdi',
        'm3u_guochanse',
        'm3u_riben2',
        'bilibili',
        // 2026-11-26 真果鉴直播批：虎牙接口源 + 6 个平台聚合表
        // + Stripchat/Cam4（逐个验活验播后登记）。
        'huya',
        'douyu_m3u',
        'douyin_m3u',
        'kugou_live_m3u',
        'kuaishou_m3u',
        'twitch_m3u',
        'tiktok_m3u',
        'stripchat',
        'cam4',
      ]);
      expect(LiveSource.values.map((s) => s.name), [
        '🔞内置片库',
        '🔞秀果',
        '🔞欲火聚合',
        '🔞百年直播',
        '🔞成人点播',
        '🔞主播网红',
        '🔞乱伦精品',
        '🔞华语精品',
        '🔞国产精品',
        '🔞学生合集',
        '🔞探花约炮',
        '🔞日本有码',
        '🔞欧美大屌',
        '🔞黑料吃瓜',
        '🔞社区合集 10',
        '🔞社区合集 11',
        '🔞無碼專區',
        '🔞網紅頭條',
        '🔞杏吧原創',
        '🔞成人頭條',
        '🔞制服絲襪',
        '🔞群交淫亂',
        '🔞明星換臉',
        '🔞自拍偷拍',
        '🔞AV兄弟无码',
        '🔞国产色情',
        '🔞日本有码 2',
        '哔哩哔哩',
        '虎果',
        '斗果',
        '音果',
        '狗果',
        '手果',
        '弦果',
        '跃果',
        '🔞彩果',
        '🔞卡果',
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

      // 2026-11-26 真果鉴直播批新增 9 源的协议/口径锁定。
      final huya = LiveSource.byId('huya')!;
      expect(huya.protocol, LiveProtocol.api);
      expect(huya.adult, isFalse);
      expect(huya.paginated, isTrue);
      expect(huya.greenCategoryFilter, isFalse);

      final douyuM3u = LiveSource.byId('douyu_m3u')!;
      expect(douyuM3u.protocol, LiveProtocol.list);
      expect(douyuM3u.endpoint, 'https://douyu.445569.xyz/live.m3u');
      expect(douyuM3u.adult, isFalse);
      for (final id in [
        'douyin_m3u',
        'kugou_live_m3u',
        'kuaishou_m3u',
        'twitch_m3u',
        'tiktok_m3u',
      ]) {
        final source = LiveSource.byId(id)!;
        expect(source.protocol, LiveProtocol.list);
        expect(source.adult, isFalse);
        expect(source.greenCategoryFilter, isFalse);
      }

      for (final id in ['stripchat', 'cam4']) {
        final source = LiveSource.byId(id)!;
        expect(source.protocol, LiveProtocol.api);
        expect(source.adult, isTrue);
      }

      // 2026-11-15 删站的旧登记仍查无此源。（虎牙已于 2026-11-26
      // 经真果鉴批重验后以新接口重新登记，不在此列；旧 m3u_* 命名
      // 的聚合表登记也不复活，本批用 *_m3u 的源 id 重新登记。）
      for (final id in [
        'pandalive',
        'sakuralive',
        'm3u_douyin',
        'm3u_douyu',
        'm3u_huya',
        'm3u_kugou',
        'm3u_tiktok',
        'm3u_twitch',
        'm3u_yy',
      ]) {
        expect(LiveSource.byId(id), isNull);
      }

      expect(LiveSource.byId('yuhuo_live'), isNull);
      expect(LiveSource.byId('uu'), isNull);
      expect(LiveSource.byId('douyu'), isNull);
    });

    test('绿色模式下成人源全部隐藏，主流源全部可见', () {
      expect(
        LiveSource.visible(true).map((s) => s.id),
        [
          'bilibili',
          'huya',
          'douyu_m3u',
          'douyin_m3u',
          'kugou_live_m3u',
          'kuaishou_m3u',
          'twitch_m3u',
          'tiktok_m3u',
        ],
      );
      // 8 个主流源（哔哩哔哩 + 虎牙 + 6 个平台聚合表）+ 29 个成人源
      // （内置片库 + 4 个原有 + 22 个内置 m3u 清单 + Stripchat/Cam4）。
      expect(LiveSource.visible(false), hasLength(37));
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
