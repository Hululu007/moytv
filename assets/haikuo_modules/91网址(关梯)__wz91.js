// 91网址引擎 wz91（91wz4.life，自研模板站，非 MacCMS）
// 协议见 ~/workspace/wz91/协议清单.md
var X = X || {};
X.MV = 'wz91_';
X.HOST = 'https://91wz4.life';
X.UA = 'Mozilla/5.0 (Linux; Android 13; SM-S9080) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

// 7 主分类：机房从 /vod 导航抓的真实 tid（1-based UI 契约，CATS[catIdx-1]）
X.CATS = [
  {id:'9', name:'成人AI'}, {id:'1', name:'国产'}, {id:'2', name:'日韩'},
  {id:'3', name:'欧美'}, {id:'4', name:'伦理'}, {id:'5', name:'动漫'},
  {id:'6', name:'同性恋'}, {id:'short', name:'短视频'}
];

// 二级分类：机房从各主分类页 filtering 链接抓的真实清单（id:'' = 全部，走主分类页）
X.SUBS = {
  '9': [{id:'', name:'全部'}, {id:'36', name:'AI短剧'}, {id:'37', name:'明星脸'}, {id:'50', name:'AI换脸'}],
  '1': [{id:'', name:'全部'}, {id:'11', name:'国产自拍'}, {id:'12', name:'吃瓜黑料'}, {id:'13', name:'探花现场'}, {id:'14', name:'乱伦系列'}, {id:'15', name:'国产av'}, {id:'16', name:'福利姬'}, {id:'18', name:'成人主播'}],
  '2': [{id:'', name:'全部'}, {id:'19', name:'无码中字'}, {id:'20', name:'JAV自拍'}, {id:'21', name:'中文字幕'}, {id:'22', name:'jav无码'}, {id:'23', name:'AV解说'}],
  '3': [{id:'', name:'全部'}, {id:'24', name:'欧美大片'}, {id:'25', name:'黑人专区'}, {id:'26', name:'留学生'}],
  '4': [{id:'', name:'全部'}, {id:'27', name:'港台三级'}, {id:'28', name:'日韩三级'}, {id:'29', name:'欧美三级'}, {id:'51', name:'东南亚三级'}],
  '5': [{id:'', name:'全部'}, {id:'30', name:'3D动漫'}, {id:'31', name:'次元动漫'}],
  '6': [{id:'', name:'全部'}, {id:'32', name:'男同GAY'}, {id:'33', name:'女同百合'}, {id:'34', name:'伪娘'}],
  'short': [{id:'', name:'全部'}, {id:'44', name:'原创自拍'}, {id:'43', name:'反差系列'}, {id:'42', name:'明星大瓜'}, {id:'41', name:'素人自拍'}, {id:'40', name:'网红达人'}, {id:'39', name:'高燃混剪'}]
};

// HTML 实体解码：命名实体 + 十进制/十六进制数字引用（含代理对）+ &nbsp;
X.unesc = function (s) {
  if (!s) return '';
  s = String(s);
  var map = {amp:'&', lt:'<', gt:'>', quot:'"', apos:"'", nbsp:' '};
  s = s.replace(/&([a-zA-Z]+);/g, function (m, n) { return (n in map) ? map[n] : m; });
  s = s.replace(/&#(\d+);/g, function (m, n) {
    n = parseInt(n, 10);
    if (n > 0xFFFF) { n -= 0x10000; return String.fromCharCode(0xD800 + (n >> 10), 0xDC00 + (n & 0x3FF)); }
    return String.fromCharCode(n);
  });
  s = s.replace(/&#x([0-9a-fA-F]+);/g, function (m, n) {
    n = parseInt(n, 16);
    if (n > 0xFFFF) { n -= 0x10000; return String.fromCharCode(0xD800 + (n >> 10), 0xDC00 + (n & 0x3FF)); }
    return String.fromCharCode(n);
  });
  return s;
};

X._get = function (url) {
  var html = '';
  try {
    html = fetch(url, {headers: {'User-Agent': X.UA, 'Referer': X.HOST + '/'}});
  } catch (e) { html = ''; }
  if (html === 'error') html = '';
  X._diag = html ? ('ok:' + String(html).length) : 'empty';
  return html || '';
};

X._u = function (u) {
  if (!u) return '';
  u = String(u).trim();
  if (u.indexOf('//') === 0) return 'https:' + u;
  if (/^https?:/i.test(u)) return u;
  if (u.charAt(0) === '/') return X.HOST + u;
  return X.HOST + '/' + u;
};

// 列表解析：href="/video/play/{vid}-1-1.html" 块，data-src 封面 + alt 标题 + dur 时长
X._items = function (html) {
  var out = [], seen = {};
  if (!html) return out;
  var re = /href="(\/(?:video\/play\/(\d+)-1-1|short\/video\/id\/(\d+))\.html)"/g, m;
  while ((m = re.exec(html)) !== null) {
    var vid = m[2] || m[3];
    var isShort = !!m[3];
    if (seen[vid]) continue;
    var seg = html.substring(m.index, m.index + 1200);
    var im = /data-src="([^"]+)"[^>]*alt="([^"]*)"/.exec(seg);
    if (!im) im = /<img[^>]+src="([^"]+)"[^>]*alt="([^"]*)"/.exec(seg);
    if (!im || /poster_loading/.test(im[1])) continue;
    var du = /<div class="dur[^"]*">([^<]+)<\/div>/.exec(seg);
    seen[vid] = 1;
    out.push({
      vod_id: vid,
      vod_name: X.unesc(im[2]).trim() || vid,
      vod_pic: X._u(im[1]),
      vod_remarks: du ? du[1].trim() : '',
      isShort: isShort
    });
  }
  return out;
};

// 卡片：vod_name/vod_pic/vod_remarks 契约；@rule 调 UI.detail；&pic= 供详情封面兜底
X._cards = function (items) {
  var cards = [];
  for (var i = 0; i < items.length; i++) {
    var c = items[i];
    var vid = String(c.vod_id || '');
    cards.push({
      vod_id: vid,
      vod_name: c.vod_name || '91网址',
      vod_pic: c.vod_pic || '',
      vod_remarks: c.vod_remarks || '',
      url: 'hiker://empty?vod_id=' + encodeURIComponent(vid) + '&pic=' + encodeURIComponent(c.vod_pic || '') + (c.isShort ? '&st=short' : '') + '#immersiveTheme#@rule=js:$.require("uiwz91").detail("' + vid + '")'
    });
  }
  return cards;
};

// 列表地址：catIdx=0 → /vod；短视频 → /short/index[/page/{pg}].html 或 /short/type/id/{sid}[/page/{pg}].html；主分类 → /video/Categories/{tid}[-{pg}].html；二级 → /video/filtering/{sid}[-{pg}].html
X._listUrl = function (catIdx, pg, sub) {
  if (catIdx === 0) return X.HOST + '/vod';
  var tid = X.CATS[catIdx - 1].id;
  if (tid === 'short') {
    if (sub) {
      return pg > 1 ? (X.HOST + '/short/type/id/' + sub + '/page/' + pg + '.html')
                    : (X.HOST + '/short/type/id/' + sub + '.html');
    }
    return pg > 1 ? (X.HOST + '/short/index/page/' + pg + '.html')
                  : (X.HOST + '/short/index.html');
  }
  if (sub) {
    return pg > 1 ? (X.HOST + '/video/filtering/' + sub + '-' + pg + '.html')
                  : (X.HOST + '/video/filtering/' + sub + '-.html');
  }
  return pg > 1 ? (X.HOST + '/video/Categories/' + tid + '-' + pg + '.html')
                : (X.HOST + '/video/Categories/' + tid + '.html');
};

X.home = function () {
  var catIdx = 0, pg = 1, sub = '';
  try { catIdx = parseInt(getMyVar(X.MV + 'cat', '0') || '0', 10) || 0; } catch (e) {}
  try { pg = parseInt(getMyVar(X.MV + 'pg', '1') || '1', 10) || 1; } catch (e) {}
  try { sub = getMyVar(X.MV + 'sub', '') || ''; } catch (e2) {}
  if (catIdx < 0 || catIdx > X.CATS.length) catIdx = 0;
  if (pg < 1) pg = 1;
  // 二级分类合法性：必须是当前主分类的子项，否则回退全部
  var tid = catIdx === 0 ? '' : X.CATS[catIdx - 1].id;
  if (sub && tid) {
    var ok = false, subs = X.SUBS[tid] || [];
    for (var i = 0; i < subs.length; i++) if (subs[i].id === sub) { ok = true; break; }
    if (!ok) sub = '';
  } else if (catIdx === 0) {
    sub = '';
  }
  var url = X._listUrl(catIdx, pg, sub);
  var html = X._get(url);
  var items = X._items(html);
  // pagecount：从同形态翻页链接取最大页码
  var pc = 1, pages = [], m, re;
  if (catIdx === 0) {
    re = /\/vod\/page\/(\d+)\.html/g;
  } else if (tid === 'short') {
    if (sub) {
      re = new RegExp('/short/type/id/' + sub + '/page/(\\d+)\\.html', 'g');
    } else {
      re = /\/short\/index\/page\/(\d+)\.html/g;
    }
  } else if (sub) {
    re = new RegExp('/video/filtering/' + sub + '-(\\d+)\\.html', 'g');
  } else {
    re = new RegExp('/video/Categories/' + tid + '-(\\d+)\\.html', 'g');
  }
  while ((m = re.exec(html)) !== null) pages.push(parseInt(m[1], 10));
  if (pages.length) pc = Math.max.apply(null, pages);
  var title = '91网址';
  if (catIdx > 0) {
    title = X.CATS[catIdx - 1].name;
    if (sub) {
      var subs2 = X.SUBS[tid] || [];
      for (var j = 0; j < subs2.length; j++) if (subs2[j].id === sub) { title = subs2[j].name; break; }
    }
  }
  var d = {
    title: title, cats: X.CATS, catIdx: catIdx, pg: pg, pc: pc, sub: sub, tid: tid,
    cards: X._cards(items), isHome: catIdx === 0
  };
  if (!items.length && X._diag) d.diag = X._diag;
  return d;
};

// 搜索：GET /search/keyword/wd/{kw}.html
X.search = function (kw, pg) {
  kw = String(kw || '');
  pg = parseInt(pg, 10) || 1;
  if (!kw) return {title: '搜索', cats: X.CATS, catIdx: 0, pg: 1, pc: 1, cards: [], isSearch: true};
  var url = X.HOST + '/search/keyword/wd/' + encodeURIComponent(kw) + '.html';
  var html = X._get(url);
  var items = X._items(html);
  var d = {title: '搜索:' + kw, cats: X.CATS, catIdx: 0, pg: pg, pc: 1, cards: X._cards(items), isSearch: true};
  if (!items.length && X._diag) d.diag = X._diag;
  return d;
};

// vod_id 多路取参：字面量参数 → MY_URL query → path → getParam → MY_PARAMS → myVar
X._vid = function (vidArg) {
  if (vidArg) return String(vidArg);
  var u = '';
  try { u = MY_URL || ''; } catch (e) {}
  var m = /[?&]vod_id=([^&#]+)/.exec(u || '');
  if (m) { try { return decodeURIComponent(m[1]); } catch (e2) { return m[1]; } }
  m = /\/video\/play\/(\d+)-1-1/.exec(u || '');
  if (m) return m[1];
  try { var gp = getParam('vod_id'); if (gp) return gp; } catch (e) {}
  try { var mp = MY_PARAMS; if (mp) { var m2 = /vod_id=([^&]+)/.exec(mp); if (m2) return decodeURIComponent(m2[1]); } } catch (e) {}
  try { var mv = getMyVar(X.MV + 'vid', ''); if (mv) return mv; } catch (e) {}
  return '';
};

// 详情：/video/play/{vid}-1-1.html，h1 标题，og:image 封面（cardPic 兜底），m3u8 直链
X.detail = function (vidArg) {
  var vid = X._vid(vidArg).split('/')[0].split('?')[0].split('#')[0];
  if (!vid) return {vod_name: '91网址', lines: []};
  var cardPic = '';
  try {
    var _uu = MY_URL || '';
    var _pm = /[?&]pic=([^&#]+)/.exec(_uu);
    if (_pm) cardPic = decodeURIComponent(_pm[1]);
  } catch (_e) {}
  var isShort = /[?&]st=short/.test(_uu);
  var html = X._get(isShort ? (X.HOST + '/short/video/id/' + vid + '.html') : (X.HOST + '/video/play/' + vid + '-1-1.html'));
  var title = '';
  var tm = /<h1[^>]*>([^<]+)<\/h1>/.exec(html);
  if (tm) title = X.unesc(tm[1]).trim();
  var pic = cardPic || '';
  var pm = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/.exec(html);
  if (pm) pic = X._u(pm[1]);
  if (!pic) {
    var pm2 = /data-src="([^"]+poster[^"]*)"/.exec(html);
    if (pm2) pic = X._u(pm2[1]);
  }
  if (!pic) pic = cardPic || '';
  var m3u8 = '';
  var mm = /(https?:\/\/[^\s"'<>]+\.m3u8[^\s"'<>]*)/.exec(html);
  if (mm) m3u8 = mm[1];
  var eps = [];
  if (m3u8) eps.push({name: '正片', url: m3u8 + '#isVideo=true#'});  // 裸 m3u8，绝不拼 @Referer=
  return {
    vod_id: vid, vod_name: title || '91网址', vod_pic: pic, vod_remarks: '', vod_content: '',
    lines: [{name: '91网址', eps: eps}]
  };
};

$.exports = X;
