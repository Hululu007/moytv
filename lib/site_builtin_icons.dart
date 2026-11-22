/// 内置站标：怪兽聚合逆向解包里提取的站点图标，只配给已在魔蚁
/// 注册表里的站，绝不凭图标造出幽灵站点。
///
/// 映射规则（逐个实证，见工作目录映射清单）：同一显示名 +（同一
/// 主页主机名 或 同一模块 key 且名一致）。只凭拼音像、名带后缀
/// 变体、名未确认的，一律不认。图标文件取自
/// `~/workspace/guaishou_re/extract_guaishou/.../assets/images/`，
/// 大图已缩到 192 像素以内；完整来源文件名 + md5 + 证据见
/// `~/workspace/hk_fix_20261116/guaishou_icon_manifest.json`。
///
/// 查表键是站 id 的最后一段：py/Go/阅读站直接用 id，jar 站用
/// `jar:<config>:<key>` 里的 key。未映射的站回落 favicon 管线。
const Map<String, String> builtinSiteIcons = {
  // py 站：模块 key + 显示名一致。
  'aijav': 'assets/site_icons/ic_app_aijav.png',
  'insav': 'assets/site_icons/ic_app_insav.png',
  'missav': 'assets/site_icons/ic_app_missav.png',
  'sp91': 'assets/site_icons/ic_app_91sp.png',
  'mmsq': 'assets/site_icons/ic_app_mmsq.png',
  // 阅读站：模块 key + 显示名一致。
  'akmh': 'assets/site_icons/ic_app_akmh.png',
  'hhlz': 'assets/site_icons/ic_app_hhlz.png',
  // 阅读 JSON 源：显示名 + 源地址主机含站名/key。
  'legado_7621_0': 'assets/site_icons/ic_app_mw.png',
  'legado_8039_0': 'assets/site_icons/ic_app_jmtt.png',
  // Go 核站：模块 key + 显示名一致，或显示名 + 主页主机一致。
  'v_hsck': 'assets/site_icons/ic_app_hsck.png',
  'v_javdb': 'assets/site_icons/ic_app_javdb.png',
  'v_sihu': 'assets/site_icons/ic_app_4hu.png',
  'v_km': 'assets/site_icons/ic_app_km.png',
  'v_lxs': 'assets/site_icons/ic_app_lxs.png',
  'v_pron91': 'assets/site_icons/ic_app_91pron.png',
  'v_av91': 'assets/site_icons/ic_app_91av.png',
  'v_haijiao_fanguo': 'assets/site_icons/ic_app_hjsq.png',
  // jar 站：key + 显示名一致，或显示名 + ext 主机一致。
  'ZakaAv91': 'assets/site_icons/ic_app_91av.png',
  'ZakaLxs': 'assets/site_icons/ic_app_lxs.png',
  'ZakaQysq': 'assets/site_icons/ic_app_qysq.png',
  'zakasihu': 'assets/site_icons/ic_app_4hu.png',
  'zakasihucdn': 'assets/site_icons/ic_app_4hu.png',
};

/// 按站 id 取内置站标资源路径；id 带 `jar:` 这类前缀时取最后一段。
String? builtinSiteIconAsset(String siteId) {
  final key = siteId.contains(':') ? siteId.split(':').last : siteId;
  if (key.isEmpty) return null;
  return builtinSiteIcons[key];
}
