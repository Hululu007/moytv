js:
(function () {
var X = {};
X.HOST = 'https://xqxq22.cc';
X.UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

X.CATS = [
  {name: '日本av', id: '44'},
  {name: '口交自慰', id: '62'},
  {name: '群交多P', id: '63'},
  {name: '强奸迷奸', id: '67'},
  {name: '丝袜制服', id: '68'},
  {name: '国产AV', id: '46'},
  {name: '乱伦系列', id: '45'},
  {name: '素人特摄', id: '65'},
  {name: '探花约炮', id: '47'},
  {name: '日韩精选', id: '61'},
  {name: 'VR专区', id: '64'},
  {name: '主播大秀', id: '48'},
  {name: '反差母狗', id: '70'},
  {name: '国产传媒', id: '50'},
  {name: '网曝吃瓜', id: '49'},
  {name: '异域风情', id: '71'},
  {name: '中文字幕', id: '53'},
  {name: '偷拍偷窥', id: '51'},
  {name: '色情动漫', id: '55'}
];

X._get = function (url) {
  try {
    var r = fetch(url, {headers: {'User-Agent': X.UA, 'Referer': X.HOST + '/'}});
    return String(r);
  } catch (e) { return ''; }
};

X._unesc = function (s) {
  return String(s || '').replace(/&#(\d+);/g, function (m, n) {
    return String.fromCharCode(parseInt(n, 10));
  }).replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
};

X._abs = function (u) {
  u = String(u || '').trim();
  if (!u) return '';
  if (u.indexOf('//') === 0) return 'https:' + u;
  if (u.indexOf('http') === 0) return u;
  if (u.charAt(0) === '/') return X.HOST + u;
  return X.HOST + '/' + u;
};

X._listUrl = function (catIdx, pg) {
  var tid = X.CATS[catIdx].id;
  if (pg > 1) return X.HOST + '/index.php/vod/type/id/' + tid + '/page/' + pg + '.html';
  return X.HOST + '/index.php/vod/type/id/' + tid + '.html';
};

X._items = function (html) {
  var out = [], seen = {};
  var re = /<a class="poster[^"]*" href="\/index\.php\/vod\/play\/id\/(\d+)\.html"[^>]*>/g;
  var m;
  while ((m = re.exec(html)) !== null) {
    var vid = m[1];
    if (seen[vid]) continue;
    var seg = html.substring(Math.max(0, m.index - 200), m.index + 1500);
    var im = seg.match(/data-src="([^"]+)"/);
    var at = seg.match(/alt="([^"]*)"/);
    var du = seg.match(/<span class="text-sm">([^<]+)<\/span>/);
    seen[vid] = 1;
    out.push({
      id: vid,
      title: X._unesc(at ? at[1] : vid).trim() || vid,
      pic: X._abs(im ? im[1] : ''),
      remarks: du ? du[1].trim() : ''
    });
  }
  return out;
};

X.home = function () {
  var cat = 0, pg = 1;
  try { cat = parseInt(getMyVar('avxq_cat', '0'), 10) || 0; } catch (e) {}
  try { pg = parseInt(getMyVar('avxq_page', '1'), 10) || 1; } catch (e) {}
  if (cat < 0 || cat >= X.CATS.length) cat = 0;
  var html = '';
  for (var t = 0; t < 3 && !html; t++) html = X._get(X._listUrl(cat, pg));
  var items = X._items(html);
  var hasMore = items.length >= 20;
  $.require('uiavxq').renderHome({cats: X.CATS, cat: cat, page: pg, items: items, hasMore: hasMore});
};

X.search = function () {
  var kw = '';
  try { kw = getParam('kw') || ''; } catch (e) {}
  if (kw.indexOf('%') >= 0) { try { kw = decodeURIComponent(kw); } catch (e) {} }
  if (!kw) { try { kw = getMyVar('keyword', ''); } catch (e) {} }
  if (!kw) { try { kw = MY_KEYWORD; } catch (e) {} }
  kw = String(kw || '').trim();
  var pg = 1;
  try { pg = parseInt(getMyVar('avxq_spage', '1'), 10) || 1; } catch (e) {}
  var items = [];
  if (kw) {
    var url = X.HOST + '/index.php/vod/search.html?wd=' + encodeURIComponent(kw) + '&page=' + pg;
    var html = '';
    for (var t = 0; t < 3 && !html; t++) html = X._get(url);
    items = X._items(html);
    if (!items.length && pg === 1) {
      html = X._get(X.HOST + '/index.php/vod/search.html?wd=' + encodeURIComponent(kw));
      items = X._items(html);
    }
  }
  $.require('uiavxq').renderSearch({kw: kw, page: pg, items: items, hasMore: items.length >= 20});
};

X.detail = function (vid) {
  if (!vid) {
    try {
      var u = MY_URL || '';
      var m = u.match(/vod_id=(\d+)/);
      if (m) vid = m[1];
    } catch (e) {}
  }
  vid = String(vid || '').split('/')[0].split('?')[0].split('#')[0];
  var html = X._get(X.HOST + '/index.php/vod/play/id/' + vid + '.html');
  var t = html.match(/<h1[^>]*>([^<]+)<\/h1>/);
  var title = t ? X._unesc(t[1]).trim() : vid;
  var pic = '';
  var pm = html.match(/<meta[^>]+property="og:image"[^>]+content="([^"]+)"/);
  if (!pm) pm = html.match(/let poster = '([^']+)'/);
  if (pm) pic = X._abs(pm[1]);
  var playUrl = '';
  var sm = html.match(/const source = '([^']+)'/);
  if (sm) playUrl = sm[1];
  if (!playUrl) {
    var dm = html.match(/data-url="([^"]+)"/);
    if (dm) {
      var du = dm[1];
      playUrl = du.indexOf('$') > 0 ? du.split('$')[1] : du;
    }
  }
  if (!playUrl) {
    var mm = html.match(/(https?:\/\/[^\s"']+\.m3u8[^\s"']*)/);
    if (mm) playUrl = mm[1];
  }
  if (playUrl && /\.m3u8(\?|#|$)/.test(playUrl)) {
    try { playUrl = clearM3u8AdLazy(playUrl); } catch (e) {}
  }
  $.require('uiavxq').renderDetail({
    vod_id: vid, vod_name: title, vod_pic: pic,
    play_url: playUrl ? ('正片$' + playUrl) : ''
  });
};

$.exports = X;
})();