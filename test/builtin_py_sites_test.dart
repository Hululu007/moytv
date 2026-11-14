import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('内置 py 视频站', () {
    test('河马站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.hmavSite;
      expect(site.id, 'hmav');
      expect(site.name, '🔞河马AV');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.hmavAssetPath, 'assets/py_spiders/hmav.py');
    });
    test('河马站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.hmavSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('ABJAV 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.abjavSite;
      expect(site.id, 'abjav');
      expect(site.name, '🔞ABJAV');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.abjavAssetPath, 'assets/py_spiders/abjav.py');
    });
    test('ABJAV 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.abjavSite), isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('2026短剧AI 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.ai2026Site;
      expect(site.id, 'ai2026');
      expect(site.name, '🔞2026短剧AI');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.ai2026AssetPath, 'assets/py_spiders/ai2026.py');
    });
    test('2026短剧AI 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.ai2026Site.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.ai2026Site), isFalse);
      expect(BuiltinPySites.ai2026Site.onlineSearch, isTrue);
      expect(BuiltinPySites.ai2026Site.pagedSearch, isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('4K.AI短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.ai4kSite;
      expect(site.id, 'ai4k');
      expect(site.name, '🔞4K.AI短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.ai4kAssetPath, 'assets/py_spiders/ai4k.py');
    });
    test('4K.AI短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.ai4kSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.ai4kSite), isFalse);
      expect(BuiltinPySites.ai4kSite.onlineSearch, isTrue);
      expect(BuiltinPySites.ai4kSite.pagedSearch, isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('AI短剧AV 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.aidjSite;
      expect(site.id, 'aidj');
      expect(site.name, '🔞AI短剧AV');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.aidjAssetPath, 'assets/py_spiders/aidj.py');
    });
    test('AI短剧AV 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.aidjSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.aidjSite), isFalse);
      expect(BuiltinPySites.aidjSite.onlineSearch, isTrue);
      expect(BuiltinPySites.aidjSite.pagedSearch, isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('AI短剧网 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.aiduanjuSite;
      expect(site.id, 'aiduanju');
      expect(site.name, '🔞AI短剧网');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.aiduanjuAssetPath, 'assets/py_spiders/aiduanju.py');
    });
    test('AI短剧网 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.aiduanjuSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.aiduanjuSite), isFalse);
      expect(BuiltinPySites.aiduanjuSite.onlineSearch, isTrue);
      expect(BuiltinPySites.aiduanjuSite.pagedSearch, isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('新黄果短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.aimoveSite;
      expect(site.id, 'aimove');
      expect(site.name, '🔞新黄果短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.aimoveAssetPath, 'assets/py_spiders/aimove.py');
    });
    test('新黄果短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.aimoveSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.aimoveSite), isFalse);
      expect(BuiltinPySites.aimoveSite.onlineSearch, isTrue);
      expect(BuiltinPySites.aimoveSite.pagedSearch, isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('Ai小视频 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.aisxpcSite;
      expect(site.id, 'aisxpc');
      expect(site.name, '🔞Ai小视频');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.aisxpcAssetPath, 'assets/py_spiders/aisxpc.py');
    });
    test('Ai小视频 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.aisxpcSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.aisxpcSite), isFalse);
      expect(BuiltinPySites.aisxpcSite.onlineSearch, isTrue);
      expect(BuiltinPySites.aisxpcSite.pagedSearch, isTrue);
    });
    test('大奶Ai短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.danaiSite;
      expect(site.id, 'danai');
      expect(site.name, '🔞大奶Ai短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.danaiAssetPath, 'assets/py_spiders/danai.py');
    });
    test('大奶Ai短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.danaiSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.danaiSite), isFalse);
      expect(BuiltinPySites.danaiSite.onlineSearch, isTrue);
      expect(BuiltinPySites.danaiSite.pagedSearch, isTrue);
    });
    test('69短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.dj69Site;
      expect(site.id, 'dj69');
      expect(site.name, '🔞69短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.dj69AssetPath, 'assets/py_spiders/dj69.py');
    });
    test('69短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.dj69Site.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.dj69Site), isFalse);
      expect(BuiltinPySites.dj69Site.onlineSearch, isTrue);
      expect(BuiltinPySites.dj69Site.pagedSearch, isTrue);
    });
    test('91短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.dj91Site;
      expect(site.id, 'dj91');
      expect(site.name, '🔞91短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.dj91AssetPath, 'assets/py_spiders/dj91.py');
    });
    test('91短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.dj91Site.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.dj91Site), isFalse);
      expect(BuiltinPySites.dj91Site.onlineSearch, isTrue);
      expect(BuiltinPySites.dj91Site.pagedSearch, isTrue);
    });
    test('短剧窝 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.djwoSite;
      expect(site.id, 'djwo');
      expect(site.name, '🔞短剧窝');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.djwoAssetPath, 'assets/py_spiders/djwo.py');
    });
    test('短剧窝 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.djwoSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.djwoSite), isFalse);
      expect(BuiltinPySites.djwoSite.onlineSearch, isTrue);
      expect(BuiltinPySites.djwoSite.pagedSearch, isTrue);
    });
    test('短剧one 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.duanjuoneSite;
      expect(site.id, 'duanjuone');
      expect(site.name, '🔞短剧one');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(
        BuiltinPySites.duanjuoneAssetPath,
        'assets/py_spiders/duanjuone.py',
      );
    });
    test('短剧one 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.duanjuoneSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.duanjuoneSite), isFalse);
      expect(BuiltinPySites.duanjuoneSite.onlineSearch, isTrue);
      expect(BuiltinPySites.duanjuoneSite.pagedSearch, isTrue);
    });
    test('柚子短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.youzidjSite;
      expect(site.id, 'youzidj');
      expect(site.name, '🔞柚子短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.youzidjAssetPath, 'assets/py_spiders/youzidj.py');
    });
    test('柚子短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.youzidjSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.youzidjSite), isFalse);
      expect(BuiltinPySites.youzidjSite.onlineSearch, isTrue);
      expect(BuiltinPySites.youzidjSite.pagedSearch, isTrue);
    });
    test('AIHI 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.aihiSite;
      expect(site.id, 'aihi');
      expect(site.name, '🔞AIHI');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.aihiAssetPath, 'assets/py_spiders/aihi.py');
    });
    test('AIHI 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.aihiSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.aihiSite), isFalse);
      expect(BuiltinPySites.aihiSite.onlineSearch, isTrue);
      expect(BuiltinPySites.aihiSite.pagedSearch, isTrue);
    });
    test('AI小视频·ficeforand 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.ficeforandSite;
      expect(site.id, 'ficeforand');
      expect(site.name, '🔞AI小视频·ficeforand');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(
        BuiltinPySites.ficeforandAssetPath,
        'assets/py_spiders/ficeforand.py',
      );
    });
    test('AI小视频·ficeforand 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.ficeforandSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.ficeforandSite), isFalse);
      expect(BuiltinPySites.ficeforandSite.onlineSearch, isTrue);
      expect(BuiltinPySites.ficeforandSite.pagedSearch, isTrue);
    });
    test('AiPorn 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.aipornxSite;
      expect(site.id, 'aipornx');
      expect(site.name, '🔞AiPorn');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.aipornxAssetPath, 'assets/py_spiders/aipornx.py');
    });
    test('AiPorn 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.aipornxSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.aipornxSite), isFalse);
      expect(BuiltinPySites.aipornxSite.onlineSearch, isTrue);
      expect(BuiltinPySites.aipornxSite.pagedSearch, isTrue);
    });
    test('AI淫航 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.aiyinhangSite;
      expect(site.id, 'aiyinhang');
      expect(site.name, '🔞AI淫航');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(
        BuiltinPySites.aiyinhangAssetPath,
        'assets/py_spiders/aiyinhang.py',
      );
    });
    test('AI淫航 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.aiyinhangSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.aiyinhangSite), isFalse);
      expect(BuiltinPySites.aiyinhangSite.onlineSearch, isTrue);
      expect(BuiltinPySites.aiyinhangSite.pagedSearch, isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('A色TV 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.asextvSite;
      expect(site.id, 'asextv');
      expect(site.name, '🔞A色TV');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.asextvAssetPath, 'assets/py_spiders/asextv.py');
    });
    test('A色TV 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.asextvSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('AVHWA 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.avhwaSite;
      expect(site.id, 'avhwa');
      expect(site.name, '🔞AVHWA');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.avhwaAssetPath, 'assets/py_spiders/avhwa.py');
    });
    test('AVHWA 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.avhwaSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('AV Today 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.avtodaySite;
      expect(site.id, 'avtoday');
      expect(site.name, '🔞AV Today');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.avtodayAssetPath, 'assets/py_spiders/avtoday.py');
    });
    test('AV Today 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.avtodaySite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('AV研究院 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.avyanjiuyuanSite;
      expect(site.id, 'avyanjiuyuan');
      expect(site.name, '🔞AV研究院');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(
        BuiltinPySites.avyanjiuyuanAssetPath,
        'assets/py_spiders/avyanjiuyuan.py',
      );
    });
    test('AV研究院 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.avyanjiuyuanSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('八度影院 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.badyiSite;
      expect(site.id, 'badyi');
      expect(site.name, '🔞八度影院');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.badyiAssetPath, 'assets/py_spiders/badyi.py');
    });
    test('八度影院 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.badyiSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('草榴视频 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.caoliuSite;
      expect(site.id, 'caoliu');
      expect(site.name, '🔞草榴视频');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.caoliuAssetPath, 'assets/py_spiders/caoliu.py');
    });
    test('草榴视频 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.caoliuSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('中国X站 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.chinaxSite;
      expect(site.id, 'chinax');
      expect(site.name, '🔞中国X站');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.chinaxAssetPath, 'assets/py_spiders/chinax.py');
    });
    test('中国X站 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.chinaxSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('中国X站精选 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.chinaxselecla08Site;
      expect(site.id, 'chinaxselecla08');
      expect(site.name, '🔞中国X站精选');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(
        BuiltinPySites.chinaxselecla08AssetPath,
        'assets/py_spiders/chinaxselecla08.py',
      );
    });
    test('中国X站精选 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.chinaxselecla08Site), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('探花AV 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.tanhuavip14Site;
      expect(site.id, 'tanhuavip14');
      expect(site.name, '🔞探花AV');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(
        BuiltinPySites.tanhuavip14AssetPath,
        'assets/py_spiders/tanhuavip14.py',
      );
    });
    test('探花AV 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.tanhuavip14Site), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('妇愁者联盟 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.fuchouSite;
      expect(site.id, 'fuchou');
      expect(site.name, '🔞妇愁者联盟');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.fuchouAssetPath, 'assets/py_spiders/fuchou.py');
    });
    test('妇愁者联盟 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.fuchouSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('黑桃短剧 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.heitaoSite;
      expect(site.id, 'heitao');
      expect(site.name, '🔞黑桃短剧');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.heitaoAssetPath, 'assets/py_spiders/heitao.py');
    });
    test('黑桃短剧 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.heitaoSite), isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('金果短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.jinguoSite;
      expect(site.id, 'jinguo');
      expect(site.name, '🔞金果短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.jinguoAssetPath, 'assets/py_spiders/jinguo.py');
    });
    test('金果短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.jinguoSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.jinguoSite), isFalse);
      expect(BuiltinPySites.jinguoSite.onlineSearch, isTrue);
      expect(BuiltinPySites.jinguoSite.pagedSearch, isTrue);
    });
    test('禁果短剧 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.jinguoJgSite;
      expect(site.id, 'jinguo_jg');
      expect(site.name, '🔞禁果短剧');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.jinguoAssetPath, 'assets/py_spiders/jinguo.py');
    });
    test('禁果短剧 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.jinguoJgSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.jinguoJgSite), isFalse);
      expect(BuiltinPySites.jinguoJgSite.onlineSearch, isTrue);
      expect(BuiltinPySites.jinguoJgSite.pagedSearch, isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('顶级AI色库 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.dingjiasekuSite;
      expect(site.id, 'dingjiaseku');
      expect(site.name, '🔞顶级AI色库');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(
        BuiltinPySites.dingjiasekuAssetPath,
        'assets/py_spiders/dingjiaseku.py',
      );
    });
    test('顶级AI色库 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.dingjiasekuSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('XOJAV 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.xojavSite;
      expect(site.id, 'xojav');
      expect(site.name, '🔞XOJAV');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.xojavAssetPath, 'assets/py_spiders/xojav.py');
    });
    test('XOJAV 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.xojavSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('Porn吃瓜网 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.porncgwSite;
      expect(site.id, 'porncgw');
      expect(site.name, '🔞Porn吃瓜网');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.porncgwAssetPath, 'assets/py_spiders/porncgw.py');
    });
    test('Porn吃瓜网 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.porncgwSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('看裤X 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.kankuxSite;
      expect(site.id, 'kankux');
      expect(site.name, '🔞看裤X');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.kankuxAssetPath, 'assets/py_spiders/kankux.py');
    });
    test('看裤X 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.kankuxSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('51X 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.xz51Site;
      expect(site.id, '51xz');
      expect(site.name, '🔞51X');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.xz51AssetPath, 'assets/py_spiders/51xz.py');
    });
    test('51X 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.xz51Site), isTrue);
    });
  });

  group('内置 py 短剧站', () {
    test('幻影AI 站注册值：短剧分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.sexaixSite;
      expect(site.id, 'sexaix');
      expect(site.name, '🔞幻影AI');
      expect(site.section, SourceSite.sectionDrama);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.sexaixAssetPath, 'assets/py_spiders/sexaix.py');
    });
    test('幻影AI 站进短剧区、不进点播区', () {
      expect(BuiltinPySites.sexaixSite.isDramaSection, isTrue);
      expect(isVodZoneSource(BuiltinPySites.sexaixSite), isFalse);
      expect(BuiltinPySites.sexaixSite.onlineSearch, isTrue);
      expect(BuiltinPySites.sexaixSite.pagedSearch, isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('气泡视频站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.qipaospSite;
      expect(site.id, 'qipaosp');
      expect(site.name, '🔞气泡视频');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.qipaospAssetPath, 'assets/py_spiders/qipaosp.py');
    });
    test('气泡视频站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.qipaospSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('X红颜 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.xhongyanSite;
      expect(site.id, 'xhongyan');
      expect(site.name, '🔞X红颜');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.xhongyanAssetPath, 'assets/py_spiders/xhongyan.py');
    });
    test('X红颜 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.xhongyanSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('多多影视 站注册值：视频分区、内置来源、py 类型', () {
      final site = BuiltinPySites.duoduoSite;
      expect(site.id, 'duoduo');
      expect(site.name, '多多影视');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.duoduoAssetPath, 'assets/py_spiders/duoduo.py');
    });
    test('多多影视 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.duoduoSite), isTrue);
    });
  });

  group('内置 py 视频站', () {
    test('JavMenu 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.javmenuSite;
      expect(site.id, 'javmenu');
      expect(site.name, '🔞JAV目錄大全');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.javmenuAssetPath, 'assets/py_spiders/javmenu.py');
    });
    test('JavMenu 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.javmenuSite), isTrue);
    });
    test('AVDB 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.avdbSite;
      expect(site.id, 'avdb');
      expect(site.name, '🔞AVDB');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.avdbAssetPath, 'assets/py_spiders/avdb.py');
    });
    test('AVDB 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.avdbSite), isTrue);
    });
    test('MemoJav 站注册值：视频分区、内置来源、py 类型、🔞 名', () {
      final site = BuiltinPySites.memojavSite;
      expect(site.id, 'memojav');
      expect(site.name, '🔞MemoJav');
      expect(site.section, SourceSite.sectionVideo);
      expect(site.origin, SourceSite.originBuiltin);
      expect(site.importType, 'py');
      expect(BuiltinPySites.memojavAssetPath, 'assets/py_spiders/memojav.py');
    });
    test('MemoJav 站进点播区（统一视频区）', () {
      expect(isVodZoneSource(BuiltinPySites.memojavSite), isTrue);
    });
  });
}
