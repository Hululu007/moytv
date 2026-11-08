import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/jar_haijiao_takeover.dart';
import 'package:moyi/models.dart';

void main() {
  JarSiteSpec spec(String key, String className) => JarSiteSpec(
        siteId: 'jar:zakatv:$key',
        configId: 'zakatv',
        name: key,
        className: className,
        jarUrl: '',
        jarMd5: '',
        ext: '',
      );

  test('jar 海角四个站映射到已验通的站源', () {
    JarBridge.register(spec(
        'ZakaHaijiao', 'com.github.catvod.spider.ZakaHaijiaoAmns'));
    JarBridge.register(
        spec('ZakaHj1', 'com.github.catvod.spider.ZakaHj1Amns'));
    JarBridge.register(
        spec('ZakaHjw', 'com.github.catvod.spider.ZakaHjwAmns'));
    JarBridge.register(
        spec('ZakaHjApp', 'com.github.catvod.spider.ZakaHjAppAmns'));
    JarBridge.register(
        spec('ZakaMissav', 'com.github.catvod.spider.ZakaMissavAmns'));
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHaijiao'),
        'v_haijiao');
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHj1'),
        'v_haijiao_fanguo');
    expect(
        JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHjw'), 'v_hjw');
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHjApp'),
        'v_haijiao_fanguo');
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaMissav'),
        isNull);
  });

  test('详情用的剧集编号改成站源加编号的形式', () {
    const drama = Drama(id: '2347171', source: 'jar:zakatv:ZakaHaijiao', title: 't');
    final remapped = JarHaijiaoTakeover.remapDrama(drama, 'v_haijiao');
    expect(remapped.id, 'v_haijiao:2347171');
    expect(remapped.source, 'v_haijiao');
    expect(remapped.sourceId, '2347171');
    const post =
        Drama(id: 'post:1:0:u', source: 'jar:zakatv:ZakaHaijiao', title: 't');
    expect(JarHaijiaoTakeover.remapDrama(post, 'v_haijiao').id,
        'v_haijiao:post:1:0:u');
  });
}
