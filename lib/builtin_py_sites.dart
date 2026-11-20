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

  static const chaoliuSiteId = 'chaoliu';
  static const chaoliuAssetPath = 'assets/py_spiders/chaoliu.py';
  static const chaoliuFileId = 'builtin_chaoliu';

  static const chaoliuSite = SourceSite(
    chaoliuSiteId,
    '🔞潮流AV',
    '内置 py · chaoliu',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aijavSiteId = 'aijav';
  static const aijavAssetPath = 'assets/py_spiders/aijav.py';
  static const aijavFileId = 'builtin_aijav';

  static const aijavSite = SourceSite(
    aijavSiteId,
    '🔞AiJav',
    '内置 py · aijav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const insavSiteId = 'insav';
  static const insavAssetPath = 'assets/py_spiders/insav.py';
  static const insavFileId = 'builtin_insav';

  static const insavSite = SourceSite(
    insavSiteId,
    '🔞INSAV',
    '内置 py · insav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const sp91SiteId = 'sp91';
  static const sp91AssetPath = 'assets/py_spiders/sp91.py';
  static const sp91FileId = 'builtin_sp91';

  static const sp91Site = SourceSite(
    sp91SiteId,
    '🔞91视频',
    '内置 py · sp91',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const mmsqSiteId = 'mmsq';
  static const mmsqAssetPath = 'assets/py_spiders/mmsq.py';
  static const mmsqFileId = 'builtin_mmsq';

  static const mmsqSite = SourceSite(
    mmsqSiteId,
    '🔞猫咪社区',
    '内置 py · mmsq',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const ysw6789SiteId = '6789ysw';
  static const ysw6789AssetPath = 'assets/py_spiders/6789ysw.py';
  static const ysw6789FileId = 'builtin_6789ysw';

  static const ysw6789Site = SourceSite(
    ysw6789SiteId,
    '6789影视',
    '内置 py · 6789ysw',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const zz6789SiteId = '6789zz';
  static const zz6789AssetPath = 'assets/py_spiders/6789zz.py';
  static const zz6789FileId = 'builtin_6789zz';

  static const zz6789Site = SourceSite(
    zz6789SiteId,
    '6789影视',
    '内置 py · 6789zz',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const anet88SiteId = 'anet88';
  static const anet88AssetPath = 'assets/py_spiders/anet88.py';
  static const anet88FileId = 'builtin_anet88';

  static const anet88Site = SourceSite(
    anet88SiteId,
    '咕咚影院',
    '内置 py · anet88',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const ffv1SiteId = 'ffv1';
  static const ffv1AssetPath = 'assets/py_spiders/ffv1.py';
  static const ffv1FileId = 'builtin_ffv1';

  static const ffv1Site = SourceSite(
    ffv1SiteId,
    '星空影院',
    '内置 py · ffv1',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const qqys01SiteId = 'qqys01';
  static const qqys01AssetPath = 'assets/py_spiders/qqys01.py';
  static const qqys01FileId = 'builtin_qqys01';

  static const qqys01Site = SourceSite(
    qqys01SiteId,
    '千千影视',
    '内置 py · qqys01',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const rr520SiteId = 'rr520';
  static const rr520AssetPath = 'assets/py_spiders/rr520.py';
  static const rr520FileId = 'builtin_rr520';

  static const rr520Site = SourceSite(
    rr520SiteId,
    '人人影视',
    '内置 py · rr520',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const sc123jfSiteId = 'sc123jf';
  static const sc123jfAssetPath = 'assets/py_spiders/sc123jf.py';
  static const sc123jfFileId = 'builtin_sc123jf';

  static const sc123jfSite = SourceSite(
    sc123jfSiteId,
    '老牛影视',
    '内置 py · sc123jf',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const zmwSiteId = 'zmw';
  static const zmwAssetPath = 'assets/py_spiders/zmw.py';
  static const zmwFileId = 'builtin_zmw';

  static const zmwSite = SourceSite(
    zmwSiteId,
    '新新影视',
    '内置 py · zmw',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const mtavSiteId = 'mtav';
  static const mtavAssetPath = 'assets/py_spiders/mtav.py';
  static const mtavFileId = 'builtin_mtav';

  static const mtavSite = SourceSite(
    mtavSiteId,
    '🔞蜜桃视频',
    '内置 py · mtav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const qinavSiteId = 'qinav';
  static const qinavAssetPath = 'assets/py_spiders/qinav.py';
  static const qinavFileId = 'builtin_qinav';

  static const qinavSite = SourceSite(
    qinavSiteId,
    '🔞Qinav',
    '内置 py · qinav',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const tasexySiteId = 'tasexy';
  static const tasexyAssetPath = 'assets/py_spiders/tasexy.py';
  static const tasexyFileId = 'builtin_tasexy';

  static const tasexySite = SourceSite(
    tasexySiteId,
    '🔞Tasexy',
    '内置 py · tasexy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const aosikazySiteId = 'aosikazy';
  static const aosikazyAssetPath = 'assets/py_spiders/aosikazy.py';
  static const aosikazyFileId = 'builtin_aosikazy';

  static const aosikazySite = SourceSite(
    aosikazySiteId,
    '🔞奥斯卡资源',
    '内置 py · aosikazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const ckzySiteId = 'ckzy';
  static const ckzyAssetPath = 'assets/py_spiders/ckzy.py';
  static const ckzyFileId = 'builtin_ckzy';

  static const ckzySite = SourceSite(
    ckzySiteId,
    '🔞CK伦理资源',
    '内置 py · ckzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const dadizySiteId = 'dadizy';
  static const dadizyAssetPath = 'assets/py_spiders/dadizy.py';
  static const dadizyFileId = 'builtin_dadizy';

  static const dadizySite = SourceSite(
    dadizySiteId,
    '🔞大地资源',
    '内置 py · dadizy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const danaizizySiteId = 'danaizizy';
  static const danaizizyAssetPath = 'assets/py_spiders/danaizizy.py';
  static const danaizizyFileId = 'builtin_danaizizy';

  static const danaizizySite = SourceSite(
    danaizizySiteId,
    '🔞大奶子资源',
    '内置 py · danaizizy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const fanhaozySiteId = 'fanhaozy';
  static const fanhaozyAssetPath = 'assets/py_spiders/fanhaozy.py';
  static const fanhaozyFileId = 'builtin_fanhaozy';

  static const fanhaozySite = SourceSite(
    fanhaozySiteId,
    '🔞番号资源',
    '内置 py · fanhaozy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const honglouzySiteId = 'honglouzy';
  static const honglouzyAssetPath = 'assets/py_spiders/honglouzy.py';
  static const honglouzyFileId = 'builtin_honglouzy';

  static const honglouzySite = SourceSite(
    honglouzySiteId,
    '🔞红楼资源',
    '内置 py · honglouzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const ikunzySiteId = 'ikunzy';
  static const ikunzyAssetPath = 'assets/py_spiders/ikunzy.py';
  static const ikunzyFileId = 'builtin_ikunzy';

  static const ikunzySite = SourceSite(
    ikunzySiteId,
    '🔞iKun资源',
    '内置 py · ikunzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const jipinzySiteId = 'jipinzy';
  static const jipinzyAssetPath = 'assets/py_spiders/jipinzy.py';
  static const jipinzyFileId = 'builtin_jipinzy';

  static const jipinzySite = SourceSite(
    jipinzySiteId,
    '🔞极品资源',
    '内置 py · jipinzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const jp98zySiteId = 'jp98zy';
  static const jp98zyAssetPath = 'assets/py_spiders/jp98zy.py';
  static const jp98zyFileId = 'builtin_jp98zy';

  static const jp98zySite = SourceSite(
    jp98zySiteId,
    '🔞精品98',
    '内置 py · jp98zy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const laosepzySiteId = 'laosepzy';
  static const laosepzyAssetPath = 'assets/py_spiders/laosepzy.py';
  static const laosepzyFileId = 'builtin_laosepzy';

  static const laosepzySite = SourceSite(
    laosepzySiteId,
    '🔞老色P资源',
    '内置 py · laosepzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const lebozySiteId = 'lebozy';
  static const lebozyAssetPath = 'assets/py_spiders/lebozy.py';
  static const lebozyFileId = 'builtin_lebozy';

  static const lebozySite = SourceSite(
    lebozySiteId,
    '🔞乐播资源',
    '内置 py · lebozy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const mangguozySiteId = 'mangguozy';
  static const mangguozyAssetPath = 'assets/py_spiders/mangguozy.py';
  static const mangguozyFileId = 'builtin_mangguozy';

  static const mangguozySite = SourceSite(
    mangguozySiteId,
    '🔞芒果资源',
    '内置 py · mangguozy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const moduzySiteId = 'moduzy';
  static const moduzyAssetPath = 'assets/py_spiders/moduzy.py';
  static const moduzyFileId = 'builtin_moduzy';

  static const moduzySite = SourceSite(
    moduzySiteId,
    '🔞魔都资源',
    '内置 py · moduzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const naixxzySiteId = 'naixxzy';
  static const naixxzyAssetPath = 'assets/py_spiders/naixxzy.py';
  static const naixxzyFileId = 'builtin_naixxzy';

  static const naixxzySite = SourceSite(
    naixxzySiteId,
    '🔞奶香香资源',
    '内置 py · naixxzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const taohuazySiteId = 'taohuazy';
  static const taohuazyAssetPath = 'assets/py_spiders/taohuazy.py';
  static const taohuazyFileId = 'builtin_taohuazy';

  static const taohuazySite = SourceSite(
    taohuazySiteId,
    '🔞桃花资源',
    '内置 py · taohuazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const wsyzySiteId = 'wsyzy';
  static const wsyzyAssetPath = 'assets/py_spiders/wsyzy.py';
  static const wsyzyFileId = 'builtin_wsyzy';

  static const wsyzySite = SourceSite(
    wsyzySiteId,
    '🔞无水印资源',
    '内置 py · wsyzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const xingbazySiteId = 'xingbazy';
  static const xingbazyAssetPath = 'assets/py_spiders/xingbazy.py';
  static const xingbazyFileId = 'builtin_xingbazy';

  static const xingbazySite = SourceSite(
    xingbazySiteId,
    '🔞杏吧资源',
    '内置 py · xingbazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const xingyezySiteId = 'xingyezy';
  static const xingyezyAssetPath = 'assets/py_spiders/xingyezy.py';
  static const xingyezyFileId = 'builtin_xingyezy';

  static const xingyezySite = SourceSite(
    xingyezySiteId,
    '🔞星夜资源站',
    '内置 py · xingyezy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const yinghuazySiteId = 'yinghuazy';
  static const yinghuazyAssetPath = 'assets/py_spiders/yinghuazy.py';
  static const yinghuazyFileId = 'builtin_yinghuazy';

  static const yinghuazySite = SourceSite(
    yinghuazySiteId,
    '🔞樱花资源',
    '内置 py · yinghuazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const yutuzySiteId = 'yutuzy';
  static const yutuzyAssetPath = 'assets/py_spiders/yutuzy.py';
  static const yutuzyFileId = 'builtin_yutuzy';

  static const yutuzySite = SourceSite(
    yutuzySiteId,
    '🔞玉兔资源',
    '内置 py · yutuzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const zy360SiteId = 'zy360';
  static const zy360AssetPath = 'assets/py_spiders/zy360.py';
  static const zy360FileId = 'builtin_zy360';

  static const zy360Site = SourceSite(
    zy360SiteId,
    '🔞360资源',
    '内置 py · zy360',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const bufoleSiteId = 'bufole';
  static const bufoleAssetPath = 'assets/py_spiders/bufole.py';
  static const bufoleFileId = 'builtin_bufole';

  static const bufoleSite = SourceSite(
    bufoleSiteId,
    '奇奇影院',
    '内置 py · bufole',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const feikuaiSiteId = 'feikuai';
  static const feikuaiAssetPath = 'assets/py_spiders/feikuai.py';
  static const feikuaiFileId = 'builtin_feikuai';

  static const feikuaiSite = SourceSite(
    feikuaiSiteId,
    '飞快TV',
    '内置 py · feikuai',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const hanjudsSiteId = 'hanjuds';
  static const hanjudsAssetPath = 'assets/py_spiders/hanjuds.py';
  static const hanjudsFileId = 'builtin_hanjuds';

  static const hanjudsSite = SourceSite(
    hanjudsSiteId,
    '🔞80s成全影视网',
    '内置 py · hanjuds',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const nbsjyySiteId = 'nbsjyy';
  static const nbsjyyAssetPath = 'assets/py_spiders/nbsjyy.py';
  static const nbsjyyFileId = 'builtin_nbsjyy';

  static const nbsjyySite = SourceSite(
    nbsjyySiteId,
    '奶茶影院',
    '内置 py · nbsjyy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const odseliftSiteId = 'odselift';
  static const odseliftAssetPath = 'assets/py_spiders/odselift.py';
  static const odseliftFileId = 'builtin_odselift';

  static const odseliftSite = SourceSite(
    odseliftSiteId,
    'VS影院',
    '内置 py · odselift',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const qikantoukanSiteId = 'qikantoukan';
  static const qikantoukanAssetPath = 'assets/py_spiders/qikantoukan.py';
  static const qikantoukanFileId = 'builtin_qikantoukan';

  static const qikantoukanSite = SourceSite(
    qikantoukanSiteId,
    '90影视',
    '内置 py · qikantoukan',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const qilinyingshiSiteId = 'qilinyingshi';
  static const qilinyingshiAssetPath = 'assets/py_spiders/qilinyingshi.py';
  static const qilinyingshiFileId = 'builtin_qilinyingshi';

  static const qilinyingshiSite = SourceSite(
    qilinyingshiSiteId,
    '麒麟影视',
    '内置 py · qilinyingshi',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const t8090kaifucomSiteId = 't8090kaifucom';
  static const t8090kaifucomAssetPath = 'assets/py_spiders/t8090kaifucom.py';
  static const t8090kaifucomFileId = 'builtin_t8090kaifucom';

  static const t8090kaifucomSite = SourceSite(
    t8090kaifucomSiteId,
    '8090影院',
    '内置 py · t8090kaifucom',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const zjldSiteId = 'zjld';
  static const zjldAssetPath = 'assets/py_spiders/zjld.py';
  static const zjldFileId = 'builtin_zjld';

  static const zjldSite = SourceSite(
    zjldSiteId,
    '六六影视',
    '内置 py · zjld',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const baofengzySiteId = 'baofengzy';
  static const baofengzyAssetPath = 'assets/py_spiders/baofengzy.py';
  static const baofengzyFileId = 'builtin_baofengzy';

  static const baofengzySite = SourceSite(
    baofengzySiteId,
    '🔞暴风资源',
    '内置 py · baofengzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const changzhangzySiteId = 'changzhangzy';
  static const changzhangzyAssetPath = 'assets/py_spiders/changzhangzy.py';
  static const changzhangzyFileId = 'builtin_changzhangzy';

  static const changzhangzySite = SourceSite(
    changzhangzySiteId,
    '🔞厂长资源',
    '内置 py · changzhangzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const doudouzySiteId = 'doudouzy';
  static const doudouzyAssetPath = 'assets/py_spiders/doudouzy.py';
  static const doudouzyFileId = 'builtin_doudouzy';

  static const doudouzySite = SourceSite(
    doudouzySiteId,
    '🔞豆豆资源',
    '内置 py · doudouzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const dyttzySiteId = 'dyttzy';
  static const dyttzyAssetPath = 'assets/py_spiders/dyttzy.py';
  static const dyttzyFileId = 'builtin_dyttzy';

  static const dyttzySite = SourceSite(
    dyttzySiteId,
    '🔞电影天堂资源',
    '内置 py · dyttzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const feifanzySiteId = 'feifanzy';
  static const feifanzyAssetPath = 'assets/py_spiders/feifanzy.py';
  static const feifanzyFileId = 'builtin_feifanzy';

  static const feifanzySite = SourceSite(
    feifanzySiteId,
    '🔞非凡资源',
    '内置 py · feifanzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const guangsuzySiteId = 'guangsuzy';
  static const guangsuzyAssetPath = 'assets/py_spiders/guangsuzy.py';
  static const guangsuzyFileId = 'builtin_guangsuzy';

  static const guangsuzySite = SourceSite(
    guangsuzySiteId,
    '🔞光速资源',
    '内置 py · guangsuzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const haohuazySiteId = 'haohuazy';
  static const haohuazyAssetPath = 'assets/py_spiders/haohuazy.py';
  static const haohuazyFileId = 'builtin_haohuazy';

  static const haohuazySite = SourceSite(
    haohuazySiteId,
    '🔞豪华资源',
    '内置 py · haohuazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const heiheizySiteId = 'heiheizy';
  static const heiheizyAssetPath = 'assets/py_spiders/heiheizy.py';
  static const heiheizyFileId = 'builtin_heiheizy';

  static const heiheizySite = SourceSite(
    heiheizySiteId,
    '🔞嘿嘿资源',
    '内置 py · heiheizy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const heiliaozySiteId = 'heiliaozy';
  static const heiliaozyAssetPath = 'assets/py_spiders/heiliaozy.py';
  static const heiliaozyFileId = 'builtin_heiliaozy';

  static const heiliaozySite = SourceSite(
    heiliaozySiteId,
    '🔞黑料资源',
    '内置 py · heiliaozy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const heiyanSiteId = 'heiyan';
  static const heiyanAssetPath = 'assets/py_spiders/heiyan.py';
  static const heiyanFileId = 'builtin_heiyan';

  static const heiyanSite = SourceSite(
    heiyanSiteId,
    '🔞黑颜禁播',
    '内置 py · heiyan',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const hongniuzySiteId = 'hongniuzy';
  static const hongniuzyAssetPath = 'assets/py_spiders/hongniuzy.py';
  static const hongniuzyFileId = 'builtin_hongniuzy';

  static const hongniuzySite = SourceSite(
    hongniuzySiteId,
    '🔞红牛资源',
    '内置 py · hongniuzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const hsckzySiteId = 'hsckzy';
  static const hsckzyAssetPath = 'assets/py_spiders/hsckzy.py';
  static const hsckzyFileId = 'builtin_hsckzy';

  static const hsckzySite = SourceSite(
    hsckzySiteId,
    '🔞黄色仓库',
    '内置 py · hsckzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const huosuzySiteId = 'huosuzy';
  static const huosuzyAssetPath = 'assets/py_spiders/huosuzy.py';
  static const huosuzyFileId = 'builtin_huosuzy';

  static const huosuzySite = SourceSite(
    huosuzySiteId,
    '🔞火速资源',
    '内置 py · huosuzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const huyazySiteId = 'huyazy';
  static const huyazyAssetPath = 'assets/py_spiders/huyazy.py';
  static const huyazyFileId = 'builtin_huyazy';

  static const huyazySite = SourceSite(
    huyazySiteId,
    '🔞虎牙资源',
    '内置 py · huyazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const iqiyizySiteId = 'iqiyizy';
  static const iqiyizyAssetPath = 'assets/py_spiders/iqiyizy.py';
  static const iqiyizyFileId = 'builtin_iqiyizy';

  static const iqiyizySite = SourceSite(
    iqiyizySiteId,
    '🔞爱奇艺影视',
    '内置 py · iqiyizy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const jisuzySiteId = 'jisuzy';
  static const jisuzyAssetPath = 'assets/py_spiders/jisuzy.py';
  static const jisuzyFileId = 'builtin_jisuzy';

  static const jisuzySite = SourceSite(
    jisuzySiteId,
    '🔞极速资源',
    '内置 py · jisuzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const jjzySiteId = 'jjzy';
  static const jjzyAssetPath = 'assets/py_spiders/jjzy.py';
  static const jjzyFileId = 'builtin_jjzy';

  static const jjzySite = SourceSite(
    jjzySiteId,
    '🔞吉吉资源',
    '内置 py · jjzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const jkunzySiteId = 'jkunzy';
  static const jkunzyAssetPath = 'assets/py_spiders/jkunzy.py';
  static const jkunzyFileId = 'builtin_jkunzy';

  static const jkunzySite = SourceSite(
    jkunzySiteId,
    '🔞jkun资源',
    '内置 py · jkunzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const juliangzySiteId = 'juliangzy';
  static const juliangzyAssetPath = 'assets/py_spiders/juliangzy.py';
  static const juliangzyFileId = 'builtin_juliangzy';

  static const juliangzySite = SourceSite(
    juliangzySiteId,
    '🔞巨量资源',
    '内置 py · juliangzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const kuaichezySiteId = 'kuaichezy';
  static const kuaichezyAssetPath = 'assets/py_spiders/kuaichezy.py';
  static const kuaichezyFileId = 'builtin_kuaichezy';

  static const kuaichezySite = SourceSite(
    kuaichezySiteId,
    '🔞快车资源',
    '内置 py · kuaichezy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const maoyanzySiteId = 'maoyanzy';
  static const maoyanzyAssetPath = 'assets/py_spiders/maoyanzy.py';
  static const maoyanzyFileId = 'builtin_maoyanzy';

  static const maoyanzySite = SourceSite(
    maoyanzySiteId,
    '🔞猫眼资源',
    '内置 py · maoyanzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const niuniuzySiteId = 'niuniuzy';
  static const niuniuzyAssetPath = 'assets/py_spiders/niuniuzy.py';
  static const niuniuzyFileId = 'builtin_niuniuzy';

  static const niuniuzySite = SourceSite(
    niuniuzySiteId,
    '🔞牛牛资源',
    '内置 py · niuniuzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const okzySiteId = 'okzy';
  static const okzyAssetPath = 'assets/py_spiders/okzy.py';
  static const okzyFileId = 'builtin_okzy';

  static const okzySite = SourceSite(
    okzySiteId,
    '🔞ok资源站',
    '内置 py · okzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const souavzySiteId = 'souavzy';
  static const souavzyAssetPath = 'assets/py_spiders/souavzy.py';
  static const souavzyFileId = 'builtin_souavzy';

  static const souavzySite = SourceSite(
    souavzySiteId,
    '🔞搜av资源',
    '内置 py · souavzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const subozySiteId = 'subozy';
  static const subozyAssetPath = 'assets/py_spiders/subozy.py';
  static const subozyFileId = 'builtin_subozy';

  static const subozySite = SourceSite(
    subozySiteId,
    '🔞速播资源',
    '内置 py · subozy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const suonizySiteId = 'suonizy';
  static const suonizyAssetPath = 'assets/py_spiders/suonizy.py';
  static const suonizyFileId = 'builtin_suonizy';

  static const suonizySite = SourceSite(
    suonizySiteId,
    '🔞索尼资源',
    '内置 py · suonizy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const tianyazySiteId = 'tianyazy';
  static const tianyazyAssetPath = 'assets/py_spiders/tianyazy.py';
  static const tianyazyFileId = 'builtin_tianyazy';

  static const tianyazySite = SourceSite(
    tianyazySiteId,
    '🔞天涯资源',
    '内置 py · tianyazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const wujinzySiteId = 'wujinzy';
  static const wujinzyAssetPath = 'assets/py_spiders/wujinzy.py';
  static const wujinzyFileId = 'builtin_wujinzy';

  static const wujinzySite = SourceSite(
    wujinzySiteId,
    '🔞无尽资源',
    '内置 py · wujinzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const xiguazySiteId = 'xiguazy';
  static const xiguazyAssetPath = 'assets/py_spiders/xiguazy.py';
  static const xiguazyFileId = 'builtin_xiguazy';

  static const xiguazySite = SourceSite(
    xiguazySiteId,
    '🔞西瓜资源',
    '内置 py · xiguazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const yayazySiteId = 'yayazy';
  static const yayazyAssetPath = 'assets/py_spiders/yayazy.py';
  static const yayazyFileId = 'builtin_yayazy';

  static const yayazySite = SourceSite(
    yayazySiteId,
    '🔞鸭鸭资源',
    '内置 py · yayazy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const yuanlibzySiteId = 'yuanlibzy';
  static const yuanlibzyAssetPath = 'assets/py_spiders/yuanlibzy.py';
  static const yuanlibzyFileId = 'builtin_yuanlibzy';

  static const yuanlibzySite = SourceSite(
    yuanlibzySiteId,
    '🔞免费资源站',
    '内置 py · yuanlibzy',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originBuiltin,
    importType: 'py',
  );

  static const zuidazySiteId = 'zuidazy';
  static const zuidazyAssetPath = 'assets/py_spiders/zuidazy.py';
  static const zuidazyFileId = 'builtin_zuidazy';

  static const zuidazySite = SourceSite(
    zuidazySiteId,
    '🔞最大资源',
    '内置 py · zuidazy',
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
    BuiltinPyEntry(siteId: chaoliuSiteId, site: chaoliuSite, assetPath: chaoliuAssetPath, fileId: chaoliuFileId),
    BuiltinPyEntry(siteId: aijavSiteId, site: aijavSite, assetPath: aijavAssetPath, fileId: aijavFileId),
    BuiltinPyEntry(siteId: insavSiteId, site: insavSite, assetPath: insavAssetPath, fileId: insavFileId),
    BuiltinPyEntry(siteId: sp91SiteId, site: sp91Site, assetPath: sp91AssetPath, fileId: sp91FileId),
    BuiltinPyEntry(siteId: mmsqSiteId, site: mmsqSite, assetPath: mmsqAssetPath, fileId: mmsqFileId),
    BuiltinPyEntry(siteId: ysw6789SiteId, site: ysw6789Site, assetPath: ysw6789AssetPath, fileId: ysw6789FileId),
    BuiltinPyEntry(siteId: zz6789SiteId, site: zz6789Site, assetPath: zz6789AssetPath, fileId: zz6789FileId),
    BuiltinPyEntry(siteId: anet88SiteId, site: anet88Site, assetPath: anet88AssetPath, fileId: anet88FileId),
    BuiltinPyEntry(siteId: ffv1SiteId, site: ffv1Site, assetPath: ffv1AssetPath, fileId: ffv1FileId),
    BuiltinPyEntry(siteId: qqys01SiteId, site: qqys01Site, assetPath: qqys01AssetPath, fileId: qqys01FileId),
    BuiltinPyEntry(siteId: rr520SiteId, site: rr520Site, assetPath: rr520AssetPath, fileId: rr520FileId),
    BuiltinPyEntry(siteId: sc123jfSiteId, site: sc123jfSite, assetPath: sc123jfAssetPath, fileId: sc123jfFileId),
    BuiltinPyEntry(siteId: zmwSiteId, site: zmwSite, assetPath: zmwAssetPath, fileId: zmwFileId),
    BuiltinPyEntry(siteId: mtavSiteId, site: mtavSite, assetPath: mtavAssetPath, fileId: mtavFileId),
    BuiltinPyEntry(siteId: qinavSiteId, site: qinavSite, assetPath: qinavAssetPath, fileId: qinavFileId),
    BuiltinPyEntry(siteId: tasexySiteId, site: tasexySite, assetPath: tasexyAssetPath, fileId: tasexyFileId),
    BuiltinPyEntry(siteId: aosikazySiteId, site: aosikazySite, assetPath: aosikazyAssetPath, fileId: aosikazyFileId),
    BuiltinPyEntry(siteId: ckzySiteId, site: ckzySite, assetPath: ckzyAssetPath, fileId: ckzyFileId),
    BuiltinPyEntry(siteId: dadizySiteId, site: dadizySite, assetPath: dadizyAssetPath, fileId: dadizyFileId),
    BuiltinPyEntry(siteId: danaizizySiteId, site: danaizizySite, assetPath: danaizizyAssetPath, fileId: danaizizyFileId),
    BuiltinPyEntry(siteId: fanhaozySiteId, site: fanhaozySite, assetPath: fanhaozyAssetPath, fileId: fanhaozyFileId),
    BuiltinPyEntry(siteId: honglouzySiteId, site: honglouzySite, assetPath: honglouzyAssetPath, fileId: honglouzyFileId),
    BuiltinPyEntry(siteId: ikunzySiteId, site: ikunzySite, assetPath: ikunzyAssetPath, fileId: ikunzyFileId),
    BuiltinPyEntry(siteId: jipinzySiteId, site: jipinzySite, assetPath: jipinzyAssetPath, fileId: jipinzyFileId),
    BuiltinPyEntry(siteId: jp98zySiteId, site: jp98zySite, assetPath: jp98zyAssetPath, fileId: jp98zyFileId),
    BuiltinPyEntry(siteId: laosepzySiteId, site: laosepzySite, assetPath: laosepzyAssetPath, fileId: laosepzyFileId),
    BuiltinPyEntry(siteId: lebozySiteId, site: lebozySite, assetPath: lebozyAssetPath, fileId: lebozyFileId),
    BuiltinPyEntry(siteId: mangguozySiteId, site: mangguozySite, assetPath: mangguozyAssetPath, fileId: mangguozyFileId),
    BuiltinPyEntry(siteId: moduzySiteId, site: moduzySite, assetPath: moduzyAssetPath, fileId: moduzyFileId),
    BuiltinPyEntry(siteId: naixxzySiteId, site: naixxzySite, assetPath: naixxzyAssetPath, fileId: naixxzyFileId),
    BuiltinPyEntry(siteId: taohuazySiteId, site: taohuazySite, assetPath: taohuazyAssetPath, fileId: taohuazyFileId),
    BuiltinPyEntry(siteId: wsyzySiteId, site: wsyzySite, assetPath: wsyzyAssetPath, fileId: wsyzyFileId),
    BuiltinPyEntry(siteId: xingbazySiteId, site: xingbazySite, assetPath: xingbazyAssetPath, fileId: xingbazyFileId),
    BuiltinPyEntry(siteId: xingyezySiteId, site: xingyezySite, assetPath: xingyezyAssetPath, fileId: xingyezyFileId),
    BuiltinPyEntry(siteId: yinghuazySiteId, site: yinghuazySite, assetPath: yinghuazyAssetPath, fileId: yinghuazyFileId),
    BuiltinPyEntry(siteId: yutuzySiteId, site: yutuzySite, assetPath: yutuzyAssetPath, fileId: yutuzyFileId),
    BuiltinPyEntry(siteId: zy360SiteId, site: zy360Site, assetPath: zy360AssetPath, fileId: zy360FileId),
    BuiltinPyEntry(siteId: bufoleSiteId, site: bufoleSite, assetPath: bufoleAssetPath, fileId: bufoleFileId),
    BuiltinPyEntry(siteId: feikuaiSiteId, site: feikuaiSite, assetPath: feikuaiAssetPath, fileId: feikuaiFileId),
    BuiltinPyEntry(siteId: hanjudsSiteId, site: hanjudsSite, assetPath: hanjudsAssetPath, fileId: hanjudsFileId),
    BuiltinPyEntry(siteId: nbsjyySiteId, site: nbsjyySite, assetPath: nbsjyyAssetPath, fileId: nbsjyyFileId),
    BuiltinPyEntry(siteId: odseliftSiteId, site: odseliftSite, assetPath: odseliftAssetPath, fileId: odseliftFileId),
    BuiltinPyEntry(siteId: qikantoukanSiteId, site: qikantoukanSite, assetPath: qikantoukanAssetPath, fileId: qikantoukanFileId),
    BuiltinPyEntry(siteId: qilinyingshiSiteId, site: qilinyingshiSite, assetPath: qilinyingshiAssetPath, fileId: qilinyingshiFileId),
    BuiltinPyEntry(siteId: t8090kaifucomSiteId, site: t8090kaifucomSite, assetPath: t8090kaifucomAssetPath, fileId: t8090kaifucomFileId),
    BuiltinPyEntry(siteId: zjldSiteId, site: zjldSite, assetPath: zjldAssetPath, fileId: zjldFileId),
    BuiltinPyEntry(siteId: baofengzySiteId, site: baofengzySite, assetPath: baofengzyAssetPath, fileId: baofengzyFileId),
    BuiltinPyEntry(siteId: changzhangzySiteId, site: changzhangzySite, assetPath: changzhangzyAssetPath, fileId: changzhangzyFileId),
    BuiltinPyEntry(siteId: doudouzySiteId, site: doudouzySite, assetPath: doudouzyAssetPath, fileId: doudouzyFileId),
    BuiltinPyEntry(siteId: dyttzySiteId, site: dyttzySite, assetPath: dyttzyAssetPath, fileId: dyttzyFileId),
    BuiltinPyEntry(siteId: feifanzySiteId, site: feifanzySite, assetPath: feifanzyAssetPath, fileId: feifanzyFileId),
    BuiltinPyEntry(siteId: guangsuzySiteId, site: guangsuzySite, assetPath: guangsuzyAssetPath, fileId: guangsuzyFileId),
    BuiltinPyEntry(siteId: haohuazySiteId, site: haohuazySite, assetPath: haohuazyAssetPath, fileId: haohuazyFileId),
    BuiltinPyEntry(siteId: heiheizySiteId, site: heiheizySite, assetPath: heiheizyAssetPath, fileId: heiheizyFileId),
    BuiltinPyEntry(siteId: heiliaozySiteId, site: heiliaozySite, assetPath: heiliaozyAssetPath, fileId: heiliaozyFileId),
    BuiltinPyEntry(siteId: heiyanSiteId, site: heiyanSite, assetPath: heiyanAssetPath, fileId: heiyanFileId),
    BuiltinPyEntry(siteId: hongniuzySiteId, site: hongniuzySite, assetPath: hongniuzyAssetPath, fileId: hongniuzyFileId),
    BuiltinPyEntry(siteId: hsckzySiteId, site: hsckzySite, assetPath: hsckzyAssetPath, fileId: hsckzyFileId),
    BuiltinPyEntry(siteId: huosuzySiteId, site: huosuzySite, assetPath: huosuzyAssetPath, fileId: huosuzyFileId),
    BuiltinPyEntry(siteId: huyazySiteId, site: huyazySite, assetPath: huyazyAssetPath, fileId: huyazyFileId),
    BuiltinPyEntry(siteId: iqiyizySiteId, site: iqiyizySite, assetPath: iqiyizyAssetPath, fileId: iqiyizyFileId),
    BuiltinPyEntry(siteId: jisuzySiteId, site: jisuzySite, assetPath: jisuzyAssetPath, fileId: jisuzyFileId),
    BuiltinPyEntry(siteId: jjzySiteId, site: jjzySite, assetPath: jjzyAssetPath, fileId: jjzyFileId),
    BuiltinPyEntry(siteId: jkunzySiteId, site: jkunzySite, assetPath: jkunzyAssetPath, fileId: jkunzyFileId),
    BuiltinPyEntry(siteId: juliangzySiteId, site: juliangzySite, assetPath: juliangzyAssetPath, fileId: juliangzyFileId),
    BuiltinPyEntry(siteId: kuaichezySiteId, site: kuaichezySite, assetPath: kuaichezyAssetPath, fileId: kuaichezyFileId),
    BuiltinPyEntry(siteId: maoyanzySiteId, site: maoyanzySite, assetPath: maoyanzyAssetPath, fileId: maoyanzyFileId),
    BuiltinPyEntry(siteId: niuniuzySiteId, site: niuniuzySite, assetPath: niuniuzyAssetPath, fileId: niuniuzyFileId),
    BuiltinPyEntry(siteId: okzySiteId, site: okzySite, assetPath: okzyAssetPath, fileId: okzyFileId),
    BuiltinPyEntry(siteId: souavzySiteId, site: souavzySite, assetPath: souavzyAssetPath, fileId: souavzyFileId),
    BuiltinPyEntry(siteId: subozySiteId, site: subozySite, assetPath: subozyAssetPath, fileId: subozyFileId),
    BuiltinPyEntry(siteId: suonizySiteId, site: suonizySite, assetPath: suonizyAssetPath, fileId: suonizyFileId),
    BuiltinPyEntry(siteId: tianyazySiteId, site: tianyazySite, assetPath: tianyazyAssetPath, fileId: tianyazyFileId),
    BuiltinPyEntry(siteId: wujinzySiteId, site: wujinzySite, assetPath: wujinzyAssetPath, fileId: wujinzyFileId),
    BuiltinPyEntry(siteId: xiguazySiteId, site: xiguazySite, assetPath: xiguazyAssetPath, fileId: xiguazyFileId),
    BuiltinPyEntry(siteId: yayazySiteId, site: yayazySite, assetPath: yayazyAssetPath, fileId: yayazyFileId),
    BuiltinPyEntry(siteId: yuanlibzySiteId, site: yuanlibzySite, assetPath: yuanlibzyAssetPath, fileId: yuanlibzyFileId),
    BuiltinPyEntry(siteId: zuidazySiteId, site: zuidazySite, assetPath: zuidazyAssetPath, fileId: zuidazyFileId),
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
