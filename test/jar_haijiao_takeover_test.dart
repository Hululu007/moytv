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
      JarSiteSpec(
        siteId: 'jar:missav30:ZakaMissav',
        configId: 'missav30',
        name: 'ZakaMissav',
        className: 'com.github.catvod.spider.ZakaMissavAmns',
        jarUrl: '',
        jarMd5: '',
        ext: '',
      ),
    );
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHaijiao'),
        'v_haijiao');
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHj1'),
        'v_haijiao_fanguo');
    expect(
        JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHjw'), 'v_hjw');
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaHjApp'),
        'v_haijiao_fanguo');
    // 2026-11-22：missav30 jar 的三个蜘蛛改由 Go 核 MissAV 接管
    // （jar 内写死 missav.ws，被 CF 挡后整站空；Go 核带镜像降级）。
    expect(JarHaijiaoTakeover.goSourceForJarSite('jar:missav30:ZakaMissav'),
        'v_missav');
  });

  test('MissAV镜像|免代理 也交给 Go 核', () {
    JarBridge.register(JarSiteSpec(
      siteId: 'jar:zakatv:ZakaMirror',
      configId: 'zakatv',
      name: 'MissAV镜像|免代理',
      className: 'com.github.catvod.spider.ZakaMirrorAmns',
      jarUrl: '',
      jarMd5: '',
      ext: '{"host":"https://www.thisav.my"}',
    ));
    expect(
        JarHaijiaoTakeover.goSourceForJarSite('jar:zakatv:ZakaMirror'),
        'v_missav');
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
