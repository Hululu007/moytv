(function () {
var X = {};
X.MV = 'aveyp_';
X.BASE = 'https://avesns5.sbs';
X.UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
X.CATS = [
  {id:'1', name:'新传媒'}, {id:'2', name:'有字幕'}, {id:'3', name:'美主播'},
  {id:'4', name:'日语系'}, {id:'5', name:'动漫疯'}, {id:'6', name:'游世界'},
  {id:'7', name:'短片区'}, {id:'8', name:'最猎奇'}, {id:'9', name:'投稿箱'},
  {id:'10', name:'吃瓜瓜'}
];

X._headers = function () {
  return {
    'User-Agent': X.UA,
    'Referer': X.BASE + '/',
    'Accept': 'text/html,application/xhtml+xml,*/*'
  };
};

X._get = function (url) {
  try {
    var r = fetch(url, { headers: X._headers(), timeout: 60000 });
    if (!r || r === 'error') return '';
    return r.content || r;
  } catch (e) { return ''; }
};

X._fix = function (u) {
  return String(u || '').replace(/&amp;/g, '&').trim();
};

// 整数参数：优先 URL 参数（翻页/分类导航），读不到回落 myVar
X._intParam = function (name, def) {
  var v = '';
  try { v = getParam(name) || ''; } catch (e) {}
  if (v === '' || v == null) { try { v = getMyVar(X.MV + name, ''); } catch (e2) {} }
  v = parseInt(String(v), 10);
  if (isNaN(v)) v = def;
  return v;
};

X._cards = function (html) {
  var out = [], seen = {};
  html = String(html || '');
  var re = /<a\s[^<>]*class="vodcard"[^<>]*href="(\/play-(\d+)-1-1\.html)"[^<>]*title="([^"]+)"/gi, m;
  while ((m = re.exec(html))) {
    var href = m[1], vid = m[2], name = String(m[3] || '').trim();
    if (!name || seen[href]) continue;
    seen[href] = 1;
    var seg = html.substr(m.index, 2500);
    var pic = '';
    var pm = /data-(?:src|original)="([^"]+)"/i.exec(seg);
    if (pm) {
      pic = X._fix(pm[1]);
      if (pic.indexOf('//') === 0) pic = 'https:' + pic;
      else if (pic.charAt(0) === '/') pic = X.BASE + pic;
    }
    out.push({ vod_id: vid, vod_name: name, vod_pic: pic, vod_remarks: '' });
  }
  return out;
};

X._m3u8 = function (html) {
  html = String(html || '');
  var m = /player_aaaa=(\{.*?\})<\/script>/s.exec(html);
  if (!m) return '';
  try {
    var j = JSON.parse(m[1].split('\\/').join('/'));
    if (j && j.url) return String(j.url);
  } catch (e) {}
  var m2 = /"url"\s*:\s*"(https?:[^"]+?\.m3u8[^"]*)"/.exec(html);
  if (m2) return m2[1].split('\\/').join('/');
  return '';
};

X._detailHtml = function (vid) {
  return X._get(X.BASE + '/play-' + vid + '-1-1.html');
};

// ---------------- 入口 ----------------
X.home = function () {
  try { if (/[?&]vod_id=/.test(String(MY_URL || ''))) { X.detail(); return; } } catch (e0) {}
  var catIdx = X._intParam('cat', 0);
  var pg = X._intParam('pg', 1);
  if (catIdx < 0 || catIdx > X.CATS.length) catIdx = 0;
  if (pg < 1) pg = 1;
  var data;
  if (catIdx === 0) {
    var html = X._get(X.BASE + '/');
    var cards = X._cards(html).slice(0, 36);
    data = { title: 'AVE影片', cats: X.CATS, catIdx: catIdx, pg: 1, pc: 1, cards: cards, isHome: true };
  } else {
    var tid = X.CATS[catIdx - 1].id;
    var url = X.BASE + '/type-' + tid + '.html';
    if (pg > 1) url = X.BASE + '/type-' + tid + '-' + pg + '.html';
    var html2 = X._get(url);
    var cards2 = X._cards(html2);
    var nxt = new RegExp('/type-' + tid + '-' + (pg + 1) + '\\.html').test(html2);
    var pc = (nxt || cards2.length >= 20) ? pg + 1 : pg;
    data = { title: 'AVE影片', cats: X.CATS, catIdx: catIdx, pg: pg, pc: pc, cards: cards2, isHome: false };
  }
  try { $.require('uiaveyp').render(data); } catch (e2) { setResult([]); }
};

// ---------------- 搜索（fypage 子页，奇优 v4 规范） ----------------
X._kw = function () {
  var kw = '';
  try { kw = getParam('kw') || ''; } catch (e) {}
  if (!kw) { try { kw = getMyVar(X.MV + 'keyword', ''); } catch (e2) {} }
  if (!kw) { try { kw = MY_KEYWORD || ''; } catch (e3) {} }
  kw = String(kw || '');
  var prev = '';
  while (/%[0-9A-Fa-f]{2}/.test(kw) && kw !== prev) {
    prev = kw;
    try { kw = decodeURIComponent(kw); } catch (e4) { break; }
  }
  return kw.trim();
};

X.search = function () {
  var kw = X._kw();
  var pg = 1;
  try { pg = parseInt(getParam('page') || '1', 10) || 1; } catch (e) {}
  var cards = [];
  if (kw) {
    var html = X._get(X.BASE + '/search/wd/' + encodeURIComponent(kw) + '.html');
    cards = X._cards(html);
    if (!cards.length) {
      // 两级兜底：先访首页建会话重试
      X._get(X.BASE + '/');
      html = X._get(X.BASE + '/search/wd/' + encodeURIComponent(kw) + '.html');
      cards = X._cards(html);
    }
  }
  try { $.require('uiaveyp').renderSearch({ keyword: kw, pg: pg, pc: 1, cards: cards }); }
  catch (e2) { setResult([]); }
};

// ---------------- 详情 ----------------
X.detail = function (vidArg) {
  var vid = '';
  try {
    if (vidArg) vid = String(vidArg);
    var m1 = /[?&]vod_id=([^&#]+)/.exec(String(MY_URL || ''));
    if (!vid && m1) vid = m1[1];
    var m2 = /(\d+)/.exec(vid);
    if (m2) vid = m2[1];
  } catch (e) {}
  var data = { vod_id: vid, vod_name: '', vod_pic: '', vod_content: '', lines: [] };
  if (vid) {
    var html = X._detailHtml(vid);
    if (html) {
      var tm = /<title[^>]*>([^<]+)<\/title>/i.exec(html);
      if (tm) data.vod_name = tm[1].split('-')[0].split('&')[0].replace(/&nbsp;/g, ' ').trim();
      var pm = /data-original="([^"]+)"/i.exec(html);
      if (pm) {
        var pic = X._fix(pm[1]);
        if (pic.indexOf('//') === 0) pic = 'https:' + pic;
        data.vod_pic = pic;
      }
      var playUrl = X._m3u8(html);
      if (playUrl) {
        data.lines = [{ name: '默认线路', eps: [{ name: '正片', url: playUrl + '#isVideo=true#' }] }];
      }
    }
  }
  try { $.require('uiaveyp').renderDetail(data); } catch (e2) { setResult([]); }
};

$.exports = X;
})();
