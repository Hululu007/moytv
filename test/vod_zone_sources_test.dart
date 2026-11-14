import 'package:moyi/models.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('点播区谓词（第二阶段站合并后：唯一的视频区分流）', () {
    test('内置视频站进点播区（不论是否带 🔞）', () {
      const plain = SourceSite(
        'go_hua',
        'Hua',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originBuiltin,
      );
      const adult = SourceSite(
        'mjv011',
        '🔞mjv011',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originBuiltin,
      );
      expect(isVodZoneSource(plain), isTrue);
      expect(isVodZoneSource(adult), isTrue);
    });
    test('配置与导入站行为不变（视频分区都进点播区）', () {
      const config = SourceSite(
        'cfg',
        '配置站',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originConfig,
      );
      const py = SourceSite(
        'py1',
        '导入py',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originImport,
        importType: 'py',
      );
      const jar = SourceSite(
        'jar1',
        '导入jar',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originImport,
        importType: 'jar',
      );
      const other = SourceSite(
        'o1',
        '其他导入',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originImport,
        importType: 'zip',
      );
      expect(isVodZoneSource(config), isTrue);
      expect(isVodZoneSource(py), isTrue);
      expect(isVodZoneSource(jar), isTrue);
      // importType 不再参与分流：视频分区即进点播区。
      expect(isVodZoneSource(other), isTrue);
    });
    test('短剧分区内置站不进点播区', () {
      const site = SourceSite(
        'hgtv',
        'HGTV',
        '',
        section: SourceSite.sectionDrama,
        origin: SourceSite.originBuiltin,
      );
      expect(isVodZoneSource(site), isFalse);
    });
    test('黄果/黄豆 jar 站登记在短剧区', () {
      final byKey = {for (final site in zakatvBuiltinSites) site.key: site};
      expect(byKey['ZakaHgdj']?.section, SourceSite.sectionDrama);
      expect(byKey['ZakaHddj']?.section, SourceSite.sectionDrama);
      expect(
        byKey['ZakaHgdj']?.className,
        'com.github.catvod.spider.ZakaHgdjAmns',
      );
      expect(
        byKey['ZakaHddj']?.className,
        'com.github.catvod.spider.ZakaHddjAmns',
      );
    });
    test('jar 三件套对齐火蚁TV现行版：Roshy/Javtiful 在，lnkl/JAV Verse 不在', () {
      final byKey = {for (final site in zakatvBuiltinSites) site.key: site};
      expect(byKey['ZakaRoshy']?.name, '🔞Roshy┃日系无码');
      expect(byKey['javtiful']?.name, '🔞Javtiful┃JAV视频');
      expect(byKey.containsKey('ZakaLnkl'), isFalse);
      expect(byKey.containsKey('zakajavverse'), isFalse);
      expect(zakatvBuiltinSites.length, 146);
      expect(zakatvJarMd5, '37a0efc39919de84f12cc65642c56dee');
    });
  });
}
