import 'dart:async';

import 'package:flutter/services.dart';

import 'import_file_store.dart';
import 'models.dart';
import 'py_bridge.dart';

/// 内置 py 插件的一条站点记录：一个 py 文件对应一条，jinguo.py 对应两条。
class BuiltinPyEntry {
  const BuiltinPyEntry({
    required this.siteId,
    required this.site,
    required this.assetPath,
    required this.fileId,
  });

  final String siteId;
  final SourceSite site;
  final String assetPath;
  final String fileId;
}

class BuiltinPySites {
  BuiltinPySites._();

  static const hmavSiteId = 'hmav';
  static const hmavAssetPath = 'assets/py_spiders/hmav.py';
  static const hmavFileId = 'builtin_hmav';

  static const hmavSite = SourceSite(
    hmavSiteId,
    '🔞河马AV',
    '内置 py · hmav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const abjavSiteId = 'abjav';
  static const abjavAssetPath = 'assets/py_spiders/abjav.py';
  static const abjavFileId = 'builtin_abjav';

  static const abjavSite = SourceSite(
    abjavSiteId,
    '🔞ABJAV',
    '内置 py · abjav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const ai2026SiteId = 'ai2026';
  static const ai2026AssetPath = 'assets/py_spiders/ai2026.py';
  static const ai2026FileId = 'builtin_ai2026';

  static const ai2026Site = SourceSite(
    ai2026SiteId,
    '🔞2026短剧AI',
    '内置 py · ai2026',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const ai4kSiteId = 'ai4k';
  static const ai4kAssetPath = 'assets/py_spiders/ai4k.py';
  static const ai4kFileId = 'builtin_ai4k';

  static const ai4kSite = SourceSite(
    ai4kSiteId,
    '🔞4K.AI短剧',
    '内置 py · ai4k',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aidjSiteId = 'aidj';
  static const aidjAssetPath = 'assets/py_spiders/aidj.py';
  static const aidjFileId = 'builtin_aidj';

  static const aidjSite = SourceSite(
    aidjSiteId,
    '🔞AI短剧AV',
    '内置 py · aidj',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aiduanjuSiteId = 'aiduanju';
  static const aiduanjuAssetPath = 'assets/py_spiders/aiduanju.py';
  static const aiduanjuFileId = 'builtin_aiduanju';

  static const aiduanjuSite = SourceSite(
    aiduanjuSiteId,
    '🔞AI短剧网',
    '内置 py · aiduanju',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aimoveSiteId = 'aimove';
  static const aimoveAssetPath = 'assets/py_spiders/aimove.py';
  static const aimoveFileId = 'builtin_aimove';

  static const aimoveSite = SourceSite(
    aimoveSiteId,
    '🔞新黄果短剧',
    '内置 py · aimove',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aisxpcSiteId = 'aisxpc';
  static const aisxpcAssetPath = 'assets/py_spiders/aisxpc.py';
  static const aisxpcFileId = 'builtin_aisxpc';

  static const aisxpcSite = SourceSite(
    aisxpcSiteId,
    '🔞Ai小视频',
    '内置 py · aisxpc',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const asextvSiteId = 'asextv';
  static const asextvAssetPath = 'assets/py_spiders/asextv.py';
  static const asextvFileId = 'builtin_asextv';

  static const asextvSite = SourceSite(
    asextvSiteId,
    '🔞A色TV',
    '内置 py · asextv',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const avhwaSiteId = 'avhwa';
  static const avhwaAssetPath = 'assets/py_spiders/avhwa.py';
  static const avhwaFileId = 'builtin_avhwa';

  static const avhwaSite = SourceSite(
    avhwaSiteId,
    '🔞AVHWA',
    '内置 py · avhwa',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const avtodaySiteId = 'avtoday';
  static const avtodayAssetPath = 'assets/py_spiders/avtoday.py';
  static const avtodayFileId = 'builtin_avtoday';

  static const avtodaySite = SourceSite(
    avtodaySiteId,
    '🔞AV Today',
    '内置 py · avtoday',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const avyanjiuyuanSiteId = 'avyanjiuyuan';
  static const avyanjiuyuanAssetPath = 'assets/py_spiders/avyanjiuyuan.py';
  static const avyanjiuyuanFileId = 'builtin_avyanjiuyuan';

  static const avyanjiuyuanSite = SourceSite(
    avyanjiuyuanSiteId,
    '🔞AV研究院',
    '内置 py · avyanjiuyuan',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const badyiSiteId = 'badyi';
  static const badyiAssetPath = 'assets/py_spiders/badyi.py';
  static const badyiFileId = 'builtin_badyi';

  static const badyiSite = SourceSite(
    badyiSiteId,
    '🔞八度影院',
    '内置 py · badyi',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const caoliuSiteId = 'caoliu';
  static const caoliuAssetPath = 'assets/py_spiders/caoliu.py';
  static const caoliuFileId = 'builtin_caoliu';

  static const caoliuSite = SourceSite(
    caoliuSiteId,
    '🔞草榴视频',
    '内置 py · caoliu',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const chinaxSiteId = 'chinax';
  static const chinaxAssetPath = 'assets/py_spiders/chinax.py';
  static const chinaxFileId = 'builtin_chinax';

  static const chinaxSite = SourceSite(
    chinaxSiteId,
    '🔞中国X站',
    '内置 py · chinax',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const chinaxselecla08SiteId = 'chinaxselecla08';
  static const chinaxselecla08AssetPath =
      'assets/py_spiders/chinaxselecla08.py';
  static const chinaxselecla08FileId = 'builtin_chinaxselecla08';

  static const chinaxselecla08Site = SourceSite(
    chinaxselecla08SiteId,
    '🔞中国X站精选',
    '内置 py · chinaxselecla08',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const danaiSiteId = 'danai';
  static const danaiAssetPath = 'assets/py_spiders/danai.py';
  static const danaiFileId = 'builtin_danai';

  static const danaiSite = SourceSite(
    danaiSiteId,
    '🔞大奶Ai短剧',
    '内置 py · danai',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const dingjiasekuSiteId = 'dingjiaseku';
  static const dingjiasekuAssetPath = 'assets/py_spiders/dingjiaseku.py';
  static const dingjiasekuFileId = 'builtin_dingjiaseku';

  static const dingjiasekuSite = SourceSite(
    dingjiasekuSiteId,
    '🔞顶级AI色库',
    '内置 py · dingjiaseku',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const dj69SiteId = 'dj69';
  static const dj69AssetPath = 'assets/py_spiders/dj69.py';
  static const dj69FileId = 'builtin_dj69';

  static const dj69Site = SourceSite(
    dj69SiteId,
    '🔞69短剧',
    '内置 py · dj69',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const dj91SiteId = 'dj91';
  static const dj91AssetPath = 'assets/py_spiders/dj91.py';
  static const dj91FileId = 'builtin_dj91';

  static const dj91Site = SourceSite(
    dj91SiteId,
    '🔞91短剧',
    '内置 py · dj91',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const djwoSiteId = 'djwo';
  static const djwoAssetPath = 'assets/py_spiders/djwo.py';
  static const djwoFileId = 'builtin_djwo';

  static const djwoSite = SourceSite(
    djwoSiteId,
    '🔞短剧窝',
    '内置 py · djwo',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const duanjuoneSiteId = 'duanjuone';
  static const duanjuoneAssetPath = 'assets/py_spiders/duanjuone.py';
  static const duanjuoneFileId = 'builtin_duanjuone';

  static const duanjuoneSite = SourceSite(
    duanjuoneSiteId,
    '🔞短剧one',
    '内置 py · duanjuone',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aihiSiteId = 'aihi';
  static const aihiAssetPath = 'assets/py_spiders/aihi.py';
  static const aihiFileId = 'builtin_aihi';

  static const aihiSite = SourceSite(
    aihiSiteId,
    '🔞AIHI',
    '内置 py · aihi',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const ficeforandSiteId = 'ficeforand';
  static const ficeforandAssetPath = 'assets/py_spiders/ficeforand.py';
  static const ficeforandFileId = 'builtin_ficeforand';

  static const ficeforandSite = SourceSite(
    ficeforandSiteId,
    '🔞AI小视频·ficeforand',
    '内置 py · ficeforand',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aipornxSiteId = 'aipornx';
  static const aipornxAssetPath = 'assets/py_spiders/aipornx.py';
  static const aipornxFileId = 'builtin_aipornx';

  static const aipornxSite = SourceSite(
    aipornxSiteId,
    '🔞AiPorn',
    '内置 py · aipornx',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aiyinhangSiteId = 'aiyinhang';
  static const aiyinhangAssetPath = 'assets/py_spiders/aiyinhang.py';
  static const aiyinhangFileId = 'builtin_aiyinhang';

  static const aiyinhangSite = SourceSite(
    aiyinhangSiteId,
    '🔞AI淫航',
    '内置 py · aiyinhang',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aiwuSiteId = 'aiwu';
  static const aiwuAssetPath = 'assets/py_spiders/aiwu.py';
  static const aiwuFileId = 'builtin_aiwu';

  static const aiwuSite = SourceSite(
    aiwuSiteId,
    '🔞AI污短剧',
    '内置 py · aiwu',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const xojavSiteId = 'xojav';
  static const xojavAssetPath = 'assets/py_spiders/xojav.py';
  static const xojavFileId = 'builtin_xojav';

  static const xojavSite = SourceSite(
    xojavSiteId,
    '🔞XOJAV',
    '内置 py · xojav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const porncgwSiteId = 'porncgw';
  static const porncgwAssetPath = 'assets/py_spiders/porncgw.py';
  static const porncgwFileId = 'builtin_porncgw';

  static const porncgwSite = SourceSite(
    porncgwSiteId,
    '🔞Porn吃瓜网',
    '内置 py · porncgw',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const xhongyanSiteId = 'xhongyan';
  static const xhongyanAssetPath = 'assets/py_spiders/xhongyan.py';
  static const xhongyanFileId = 'builtin_xhongyan';

  static const xhongyanSite = SourceSite(
    xhongyanSiteId,
    '🔞X红颜',
    '内置 py · xhongyan',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const kankuxSiteId = 'kankux';
  static const kankuxAssetPath = 'assets/py_spiders/kankux.py';
  static const kankuxFileId = 'builtin_kankux';

  static const kankuxSite = SourceSite(
    kankuxSiteId,
    '🔞看裤X',
    '内置 py · kankux',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const guohnsqjSiteId = 'guohnsqj';
  static const guohnsqjAssetPath = 'assets/py_spiders/guohnsqj.py';
  static const guohnsqjFileId = 'builtin_guohnsqj';

  static const guohnsqjSite = SourceSite(
    guohnsqjSiteId,
    '🔞欲望乐园',
    '内置 py · guohnsqj',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const xz51SiteId = '51xz';
  static const xz51AssetPath = 'assets/py_spiders/51xz.py';
  static const xz51FileId = 'builtin_51xz';

  static const xz51Site = SourceSite(
    xz51SiteId,
    '🔞51X',
    '内置 py · 51xz',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const sexaixSiteId = 'sexaix';
  static const sexaixAssetPath = 'assets/py_spiders/sexaix.py';
  static const sexaixFileId = 'builtin_sexaix';

  static const sexaixSite = SourceSite(
    sexaixSiteId,
    '🔞幻影AI',
    '内置 py · sexaix',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const qipaospSiteId = 'qipaosp';
  static const qipaospAssetPath = 'assets/py_spiders/qipaosp.py';
  static const qipaospFileId = 'builtin_qipaosp';

  static const qipaospSite = SourceSite(
    qipaospSiteId,
    '🔞气泡视频',
    '内置 py · qipaosp',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const youzidjSiteId = 'youzidj';
  static const youzidjAssetPath = 'assets/py_spiders/youzidj.py';
  static const youzidjFileId = 'builtin_youzidj';

  static const youzidjSite = SourceSite(
    youzidjSiteId,
    '🔞柚子短剧',
    '内置 py · youzidj',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const tanhuavip14SiteId = 'tanhuavip14';
  static const tanhuavip14AssetPath = 'assets/py_spiders/tanhuavip14.py';
  static const tanhuavip14FileId = 'builtin_tanhuavip14';

  static const tanhuavip14Site = SourceSite(
    tanhuavip14SiteId,
    '🔞探花AV',
    '内置 py · tanhuavip14',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const fuchouSiteId = 'fuchou';
  static const fuchouAssetPath = 'assets/py_spiders/fuchou.py';
  static const fuchouFileId = 'builtin_fuchou';

  static const fuchouSite = SourceSite(
    fuchouSiteId,
    '🔞妇愁者联盟',
    '内置 py · fuchou',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const heitaoSiteId = 'heitao';
  static const heitaoAssetPath = 'assets/py_spiders/heitao.py';
  static const heitaoFileId = 'builtin_heitao';

  static const heitaoSite = SourceSite(
    heitaoSiteId,
    '🔞黑桃短剧',
    '内置 py · heitao',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const jinguoSiteId = 'jinguo';
  static const jinguoAssetPath = 'assets/py_spiders/jinguo.py';
  static const jinguoFileId = 'builtin_jinguo';

  static const jinguoSite = SourceSite(
    jinguoSiteId,
    '🔞金果短剧',
    '内置 py · jinguo',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const jinguoJgSiteId = 'jinguo_jg';
  static const jinguoJgFileId = 'builtin_jinguo_jg';

  static const jinguoJgSite = SourceSite(
    jinguoJgSiteId,
    '🔞禁果短剧',
    '内置 py · jinguo',
    section: SourceSite.sectionDrama,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const duoduoSiteId = 'duoduo';
  static const duoduoAssetPath = 'assets/py_spiders/duoduo.py';
  static const duoduoFileId = 'builtin_duoduo';

  static const duoduoSite = SourceSite(
    duoduoSiteId,
    '多多影视',
    '内置 py · duoduo',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const javmenuSiteId = 'javmenu';
  static const javmenuAssetPath = 'assets/py_spiders/javmenu.py';
  static const javmenuFileId = 'builtin_javmenu';

  static const javmenuSite = SourceSite(
    javmenuSiteId,
    '🔞JAV目錄大全',
    '内置 py · javmenu',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const avdbSiteId = 'avdb';
  static const avdbAssetPath = 'assets/py_spiders/avdb.py';
  static const avdbFileId = 'builtin_avdb';

  static const avdbSite = SourceSite(
    avdbSiteId,
    '🔞AVDB',
    '内置 py · avdb',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const memojavSiteId = 'memojav';
  static const memojavAssetPath = 'assets/py_spiders/memojav.py';
  static const memojavFileId = 'builtin_memojav';

  static const memojavSite = SourceSite(
    memojavSiteId,
    '🔞MemoJav',
    '内置 py · memojav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  /// 全部内置 py 插件条目，顺序与今天 register() 的注册顺序一致。
  static const List<BuiltinPyEntry> entries = [
    BuiltinPyEntry(siteId: hmavSiteId, site: hmavSite, assetPath: hmavAssetPath, fileId: hmavFileId),
    BuiltinPyEntry(siteId: abjavSiteId, site: abjavSite, assetPath: abjavAssetPath, fileId: abjavFileId),
    BuiltinPyEntry(siteId: ai2026SiteId, site: ai2026Site, assetPath: ai2026AssetPath, fileId: ai2026FileId),
    BuiltinPyEntry(siteId: ai4kSiteId, site: ai4kSite, assetPath: ai4kAssetPath, fileId: ai4kFileId),
    BuiltinPyEntry(siteId: aidjSiteId, site: aidjSite, assetPath: aidjAssetPath, fileId: aidjFileId),
    BuiltinPyEntry(siteId: aiduanjuSiteId, site: aiduanjuSite, assetPath: aiduanjuAssetPath, fileId: aiduanjuFileId),
    BuiltinPyEntry(siteId: aimoveSiteId, site: aimoveSite, assetPath: aimoveAssetPath, fileId: aimoveFileId),
    BuiltinPyEntry(siteId: aisxpcSiteId, site: aisxpcSite, assetPath: aisxpcAssetPath, fileId: aisxpcFileId),
    BuiltinPyEntry(siteId: asextvSiteId, site: asextvSite, assetPath: asextvAssetPath, fileId: asextvFileId),
    BuiltinPyEntry(siteId: avhwaSiteId, site: avhwaSite, assetPath: avhwaAssetPath, fileId: avhwaFileId),
    BuiltinPyEntry(siteId: avtodaySiteId, site: avtodaySite, assetPath: avtodayAssetPath, fileId: avtodayFileId),
    BuiltinPyEntry(siteId: avyanjiuyuanSiteId, site: avyanjiuyuanSite, assetPath: avyanjiuyuanAssetPath, fileId: avyanjiuyuanFileId),
    BuiltinPyEntry(siteId: badyiSiteId, site: badyiSite, assetPath: badyiAssetPath, fileId: badyiFileId),
    BuiltinPyEntry(siteId: caoliuSiteId, site: caoliuSite, assetPath: caoliuAssetPath, fileId: caoliuFileId),
    BuiltinPyEntry(siteId: chinaxSiteId, site: chinaxSite, assetPath: chinaxAssetPath, fileId: chinaxFileId),
    BuiltinPyEntry(siteId: chinaxselecla08SiteId, site: chinaxselecla08Site, assetPath: chinaxselecla08AssetPath, fileId: chinaxselecla08FileId),
    BuiltinPyEntry(siteId: danaiSiteId, site: danaiSite, assetPath: danaiAssetPath, fileId: danaiFileId),
    BuiltinPyEntry(siteId: dingjiasekuSiteId, site: dingjiasekuSite, assetPath: dingjiasekuAssetPath, fileId: dingjiasekuFileId),
    BuiltinPyEntry(siteId: dj69SiteId, site: dj69Site, assetPath: dj69AssetPath, fileId: dj69FileId),
    BuiltinPyEntry(siteId: dj91SiteId, site: dj91Site, assetPath: dj91AssetPath, fileId: dj91FileId),
    BuiltinPyEntry(siteId: djwoSiteId, site: djwoSite, assetPath: djwoAssetPath, fileId: djwoFileId),
    BuiltinPyEntry(siteId: duanjuoneSiteId, site: duanjuoneSite, assetPath: duanjuoneAssetPath, fileId: duanjuoneFileId),
    BuiltinPyEntry(siteId: aihiSiteId, site: aihiSite, assetPath: aihiAssetPath, fileId: aihiFileId),
    BuiltinPyEntry(siteId: ficeforandSiteId, site: ficeforandSite, assetPath: ficeforandAssetPath, fileId: ficeforandFileId),
    BuiltinPyEntry(siteId: aipornxSiteId, site: aipornxSite, assetPath: aipornxAssetPath, fileId: aipornxFileId),
    BuiltinPyEntry(siteId: aiyinhangSiteId, site: aiyinhangSite, assetPath: aiyinhangAssetPath, fileId: aiyinhangFileId),
    BuiltinPyEntry(siteId: aiwuSiteId, site: aiwuSite, assetPath: aiwuAssetPath, fileId: aiwuFileId),
    BuiltinPyEntry(siteId: xojavSiteId, site: xojavSite, assetPath: xojavAssetPath, fileId: xojavFileId),
    BuiltinPyEntry(siteId: porncgwSiteId, site: porncgwSite, assetPath: porncgwAssetPath, fileId: porncgwFileId),
    BuiltinPyEntry(siteId: xhongyanSiteId, site: xhongyanSite, assetPath: xhongyanAssetPath, fileId: xhongyanFileId),
    BuiltinPyEntry(siteId: kankuxSiteId, site: kankuxSite, assetPath: kankuxAssetPath, fileId: kankuxFileId),
    BuiltinPyEntry(siteId: guohnsqjSiteId, site: guohnsqjSite, assetPath: guohnsqjAssetPath, fileId: guohnsqjFileId),
    BuiltinPyEntry(siteId: xz51SiteId, site: xz51Site, assetPath: xz51AssetPath, fileId: xz51FileId),
    BuiltinPyEntry(siteId: sexaixSiteId, site: sexaixSite, assetPath: sexaixAssetPath, fileId: sexaixFileId),
    BuiltinPyEntry(siteId: qipaospSiteId, site: qipaospSite, assetPath: qipaospAssetPath, fileId: qipaospFileId),
    BuiltinPyEntry(siteId: youzidjSiteId, site: youzidjSite, assetPath: youzidjAssetPath, fileId: youzidjFileId),
    BuiltinPyEntry(siteId: tanhuavip14SiteId, site: tanhuavip14Site, assetPath: tanhuavip14AssetPath, fileId: tanhuavip14FileId),
    BuiltinPyEntry(siteId: fuchouSiteId, site: fuchouSite, assetPath: fuchouAssetPath, fileId: fuchouFileId),
    BuiltinPyEntry(siteId: heitaoSiteId, site: heitaoSite, assetPath: heitaoAssetPath, fileId: heitaoFileId),
    BuiltinPyEntry(siteId: jinguoSiteId, site: jinguoSite, assetPath: jinguoAssetPath, fileId: jinguoFileId),
    BuiltinPyEntry(siteId: jinguoJgSiteId, site: jinguoJgSite, assetPath: jinguoAssetPath, fileId: jinguoJgFileId),
    BuiltinPyEntry(siteId: duoduoSiteId, site: duoduoSite, assetPath: duoduoAssetPath, fileId: duoduoFileId),
    BuiltinPyEntry(siteId: javmenuSiteId, site: javmenuSite, assetPath: javmenuAssetPath, fileId: javmenuFileId),
    BuiltinPyEntry(siteId: avdbSiteId, site: avdbSite, assetPath: avdbAssetPath, fileId: avdbFileId),
    BuiltinPyEntry(siteId: memojavSiteId, site: memojavSite, assetPath: memojavAssetPath, fileId: memojavFileId),
  ];

  static BuiltinPyEntry? entryFor(String siteId) {
    for (final entry in entries) {
      if (entry.siteId == siteId) return entry;
    }
    return null;
  }

  static Future<void> _install(BuiltinPyEntry entry) async {
    final bytes = await rootBundle.load(entry.assetPath);
    final fileName = await ImportFileStore.save(
      entry.fileId,
      'py',
      bytes.buffer.asUint8List(),
    );
    SourceSite.importedSites[entry.siteId] = entry.site;
    SourceSite.importedPyFiles[entry.siteId] = fileName;
  }

  static Future<bool> register() => registerSkipping(const {});

  /// 注册全部内置 py 插件，跳过 [skipSiteIds]（用户已卸载的插件的站点）。
  static Future<bool> registerSkipping(Set<String> skipSiteIds) async {
    try {
      for (final entry in entries) {
        if (skipSiteIds.contains(entry.siteId)) continue;
        try {
          await _install(entry);
        } catch (_) {}
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 安装单个内置 py 站点（插件重装时用）。失败返回 false。
  static Future<bool> installEntry(String siteId) async {
    final entry = entryFor(siteId);
    if (entry == null) return false;
    try {
      await _install(entry);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 卸载单个内置 py 站点：撤登记 + 释放该文件的解释器会话 +
  /// 删落盘文件副本，不留残影。
  static Future<void> uninstallEntry(String siteId) async {
    final entry = entryFor(siteId);
    SourceSite.importedSites.remove(siteId);
    final fileName = SourceSite.importedPyFiles.remove(siteId);
    final target = fileName ?? (entry == null ? '' : '${entry.fileId}.py');
    if (target.isNotEmpty) {
      final path = await ImportFileStore.pathOf(target);
      unawaited(PyBridge.dispose(path));
    }
    await ImportFileStore.delete(target);
  }












































}
