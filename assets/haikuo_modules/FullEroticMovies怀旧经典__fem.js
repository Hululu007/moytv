js:// Full Erotic Movies (www.fulleroticmovies.net) 海阔引擎 fem, 移植自用户 ____fulleroticmovies______24_t2qz.py
// 2026-10-28 机房真页实测: 首页/分类/详情/搜索均 200, 列表 20 条/页。
// 偏离 py 的一处(有据): py 的 OK API 镜像域名已 NXDOMAIN(公开 DNS 查无此域, 机房 TLS 后空回),
// 站方现行播放器 kt_player_new.js 实际用 https://api.ok.ru/fb.do, 机房实测该接口 200 回真实清晰度 URL, 故引擎跟现行站方。
// 详情链: generate_mp4 参数 -> PBKDF2-HMAC-SHA512 + AES-256-CBC(Java 全局包) -> session_key -> OK API -> 各清晰度直链。
// 搜索 py 原生返回空, 但站方首页搜索表单实测为 /search/<词>/ (分页 /search/<词>/<页>/), 故按实测实现。
(function () {
  var HOST = 'https://www.fulleroticmovies.net';
  var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36';
  var OK_API = 'https://api.ok.ru/fb.do';
  var APP_KEY = 'CBAFJIICABABABABA';
  var CATS = [
    { name: '最新', path: '/videos/' }, { name: '热门', path: '/trending/' },
    { name: '最多观看', path: '/most-viewed/' }, { name: '评分最高', path: '/top-rated/' },
    { name: '90年代', path: '/category/90s/' }, { name: '80年代', path: '/category/80s/' },
    { name: '70年代', path: '/category/70s/' }, { name: '经典', path: '/category/classic/' },
    { name: '剧情', path: '/category/plot-oriented/' }, { name: '合集', path: '/category/compilation/' },
    { name: '大胸', path: '/category/big-tits/' }, { name: '肛交', path: '/category/anal/' },
    { name: 'Alpha Blue', path: '/studio/alpha-blue-archives/' }, { name: 'Vivid', path: '/studio/vivid/' },
    { name: 'VCA', path: '/studio/vca/' }, { name: 'LBO', path: '/studio/lbo/' }, { name: 'VCX', path: '/studio/vcx/' }
  ];
  var QUALITY = ['ultrahd', 'fullhd', 'quadhd', 'high', 'medium', 'low', 'mobile', 'tiny'];
  function hdr() {
    return { 'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.9' };
  }
  function get(url) {
    try {
      var r = fetch(url, { headers: hdr() });
      if (r === null || r === undefined) return '';
      r = String(r);
      return r === 'error' ? '' : r;
    } catch (e) { return ''; }
  }
  function squash(s) { return String(s || '').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, ''); }
  function stripTags(s) { return String(s || '').replace(/<[^>]+>/g, ' '); }
  function unesc(s) {
    s = String(s || '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>');
    s = s.replace(/&nbsp;/g, ' ').replace(/&hellip;/g, '…').replace(/&mdash;/g, '—').replace(/&ndash;/g, '–').replace(/&ldquo;/g, '“').replace(/&rdquo;/g, '”').replace(/&lsquo;/g, '‘').replace(/&rsquo;/g, '’').replace(/&middot;/g, '·').replace(/&laquo;/g, '《').replace(/&raquo;/g, '》').replace(/&copy;/g, '©').replace(/&reg;/g, '®');
    s = s.replace(/&#(\d+);/g, function (m, code) {
      var c = parseInt(code, 10);
      if (c > 0xFFFF) { c -= 0x10000; return String.fromCharCode(0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF)); }
      return String.fromCharCode(c);
    });
    s = s.replace(/&#x([0-9a-fA-F]+);/g, function (m, code) {
      var c = parseInt(code, 16);
      if (c > 0xFFFF) { c -= 0x10000; return String.fromCharCode(0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF)); }
      return String.fromCharCode(c);
    });
    return s;
  }
  function cleanUrl(url) {
    url = String(url || '').trim();
    if (!url) return '';
    if (url.indexOf('//') === 0) return 'https:' + url;
    if (url.charAt(0) === '/') return HOST + url;
    return url;
  }
  function b64dec(str) {
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
    var out = [];
    str = String(str || '').replace(/[^A-Za-z0-9\+\/\=]/g, '');
    for (var i = 0; i < str.length;) {
      var e1 = chars.indexOf(str.charAt(i++));
      var e2 = chars.indexOf(str.charAt(i++));
      var e3 = chars.indexOf(str.charAt(i++));
      var e4 = chars.indexOf(str.charAt(i++));
      if (e1 < 0 || e2 < 0) break;
      out.push((e1 << 2) | (e2 >> 4));
      if (e3 !== 64 && e3 >= 0) out.push(((e2 & 15) << 4) | (e3 >> 2));
      if (e4 !== 64 && e4 >= 0) out.push(((e3 & 3) << 6) | e4);
    }
    return out;
  }
  function hexBytes(hex) {
    var out = [];
    hex = String(hex || '');
    for (var i = 0; i + 1 < hex.length; i += 2) out.push(parseInt(hex.substr(i, 2), 16));
    return out;
  }
  function jBytes(arr) {
    var jb = java.lang.reflect.Array.newInstance(java.lang.Byte.TYPE, arr.length);
    for (var i = 0; i < arr.length; i++) { var b = arr[i] & 0xFF; jb[i] = b >= 128 ? b - 256 : b; }
    return jb;
  }
  function utf8Decode(bytes) {
    var out = '', i = 0;
    while (i < bytes.length) {
      var b = bytes[i]; if (b < 0) b += 256;
      var cp = 0, need = 0;
      if (b < 0x80) { cp = b; need = 0; }
      else if ((b & 0xE0) === 0xC0) { cp = b & 0x1F; need = 1; }
      else if ((b & 0xF0) === 0xE0) { cp = b & 0x0F; need = 2; }
      else if ((b & 0xF8) === 0xF0) { cp = b & 0x07; need = 3; }
      else { i++; continue; }
      var ok = true;
      for (var j = 1; j <= need; j++) {
        var cb = bytes[i + j]; if (cb === undefined) { ok = false; break; }
        if (cb < 0) cb += 256;
        if ((cb & 0xC0) !== 0x80) { ok = false; break; }
        cp = (cp << 6) | (cb & 0x3F);
      }
      if (!ok) { i++; continue; }
      i += need + 1;
      if (cp > 0xFFFF) { cp -= 0x10000; out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF)); }
      else out += String.fromCharCode(cp);
    }
    return out;
  }
  function decryptSessionKey(encrypted, password) {
    try {
      var info = JSON.parse(utf8Decode(b64dec(encrypted)));
      var salt = hexBytes(info.salt);
      var iv = hexBytes(info.iv);
      var ct = b64dec(info.ciphertext);
      var it = parseInt(info.iterations || 999, 10) || 999;
      var chars = new java.lang.String(password).toCharArray();
      var spec = new javax.crypto.spec.PBEKeySpec(chars, jBytes(salt), it, 256);
      var skf = javax.crypto.SecretKeyFactory.getInstance('PBKDF2WithHmacSHA512');
      var keyBytes = skf.generateSecret(spec).getEncoded();
      var keySpec = new javax.crypto.spec.SecretKeySpec(keyBytes, 'AES');
      var ivSpec = new javax.crypto.spec.IvParameterSpec(jBytes(iv));
      var cipher = javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
      cipher.init(javax.crypto.Cipher.DECRYPT_MODE, keySpec, ivSpec);
      var plain = cipher.doFinal(jBytes(ct));
      return utf8Decode(plain);
    } catch (e) { return ''; }
  }
  function cardUrl(detailUrl) {
    return 'hiker://empty?vod_id=' + encodeURIComponent(detailUrl) + '#immersiveTheme#@rule=js:$.require("fem").detail("' + detailUrl + '")';
  }
  function pageUrl(base, pg) {
    base = base.replace(/\/$/, '') + '/';
    return pg <= 1 ? base : base + pg + '/';
  }
  function parseList(html) {
    var out = [], seen = {};
    if (!html) return out;
    var re = /<a\s+class="item-video[^>]+href="([^"]+)"[^>]*title="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, m;
    while ((m = re.exec(html)) !== null) {
      var href = cleanUrl(unesc(m[1]));
      if (!href || seen[href]) continue;
      var inner = m[3];
      var pic = '';
      var im = inner.match(/data-original="([^"]+)"/i) || inner.match(/src="([^"]+\.(?:webp|jpe?g|png)(?:\?[^"]*)?)"/i);
      if (im) pic = cleanUrl(unesc(im[1]));
      var rm = inner.match(/class="[^" ]*rating[^" ]*"[^>]*>\s*([^<]+)/i);
      seen[href] = true;
      out.push({ vod_name: squash(unesc(m[2])), vod_pic: pic, vod_remarks: rm ? squash(unesc(rm[1])) : '', url: cardUrl(href), vid: href });
    }
    return out;
  }
  function pageCount(html) {
    if (!html) return 1;
    var pm = 1;
    var re = /href="[^"]+\/(\d+)\/"[^>]*>\s*(\d+)\s*</g, m;
    while ((m = re.exec(html)) !== null) {
      if (m[1] === m[2]) { var n = parseInt(m[1], 10); if (n > pm) pm = n; }
    }
    return pm;
  }
  function cachePut(url, title, pic) {
    try {
      var raw = getMyVar('fem_cache', '');
      var map = raw ? JSON.parse(raw) : {};
      map[url] = { t: title, p: pic };
      var keys = [];
      for (var k in map) keys.push(k);
      while (keys.length > 60) { delete map[keys.shift()]; }
      putMyVar('fem_cache', JSON.stringify(map));
    } catch (e) {}
  }
  function cacheGet(url) {
    try {
      var raw = getMyVar('fem_cache', '');
      if (!raw) return null;
      var map = JSON.parse(raw);
      return map[url] || null;
    } catch (e) { return null; }
  }
  function okUrls(encrypted, password, okid) {
    var key = decryptSessionKey(encrypted, password);
    if (!key) return [];
    var fields = 'video.url_tiny,video.url_low,video.url_high,video.url_medium,video.url_quadhd,video.url_mobile,video.url_ultrahd,video.url_fullhd';
    var url = OK_API + '?application_key=' + APP_KEY + '&fields=' + encodeURIComponent(fields) + '&method=video.get&session_key=' + encodeURIComponent(key) + '&vids=' + encodeURIComponent(okid);
    var resp = get(url);
    if (!resp) return [];
    var j = null;
    try { j = JSON.parse(resp); } catch (e) { return []; }
    var video = (j.videos && j.videos[0]) || {};
    var out = [];
    for (var i = 0; i < QUALITY.length; i++) {
      var q = QUALITY[i], v = video['url_' + q];
      if (v) out.push({ name: q, url: v });
    }
    return out;
  }
  function resolveId(vidArg) {
    if (vidArg) return vidArg;
    try {
      var u = String(MY_URL || '').split('#')[0];
      var m = u.match(/[?&]vod_id=([^&]*)/);
      if (m) return decodeURIComponent(m[1]);
    } catch (e) {}
    try {
      var u2 = String(MY_URL || '');
      if (u2.indexOf('http') === 0 && u2.indexOf('/video/') > 0) return u2.split('#')[0].split('?')[0];
    } catch (e2) {}
    try { var p = getParam('vod_id'); if (p) return p; } catch (e3) {}
    try { var v = getMyVar('fem_vid', ''); if (v) return v; } catch (e4) {}
    return '';
  }

  var FEM = {};
  FEM.home = function () {
    var idx = 0;
    try { idx = parseInt(getMyVar('fem_cat', '0'), 10) || 0; } catch (e) {}
    if (idx < 0 || idx >= CATS.length) idx = 0;
    var pg = 1;
    try { pg = parseInt(getMyVar('fem_page', '1'), 10) || 1; } catch (e2) {}
    var html = get(HOST + pageUrl(CATS[idx].path, pg));
    var items = parseList(html);
    for (var i = 0; i < items.length; i++) cachePut(items[i].vid, items[i].vod_name, items[i].vod_pic);
    var pc = pageCount(html);
    $.require('uiq16').renderHome({
      cats: CATS, isCat: true, catIdx: idx,
      items: items, page: pg, pagecount: pc,
      search: { placeholder: '搜索片名...' }
    });
  };
  FEM.detail = function (vidArg) {
    var url = resolveId(vidArg);
    if (!url) { $.require('uiq16').renderDetail({ title: '参数错误', pic: '', desc: '', lines: [], episodes: [] }); return; }
    try { putMyVar('fem_vid', url); } catch (e) {}
    var html = get(url);
    var cached = cacheGet(url);
    var title = cached && cached.t ? cached.t : '';
    if (!title) {
      var hm = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
      if (hm) title = squash(unesc(stripTags(hm[1])));
    }
    var pic = cached && cached.p ? cached.p : '';
    if (!pic) {
      var pm = html.match(/preview_url:\s*'([^']+)'/);
      if (pm) pic = cleanUrl(pm[1]);
    }
    var desc = '';
    var dm = html.match(/<div[^>]*class="[^" ]*description[^" ]*"[^>]*>([\s\S]*?)<\/div>/i);
    if (dm) desc = squash(unesc(stripTags(dm[1])));
    var streams = [];
    var am = html.match(/generate_mp4\('([^']+)',\s*'([^']+)',\s*'([^']+)',\s*'([^']+)'\)/);
    if (am) streams = okUrls(am[1], am[2], am[3]);
    var eps = [];
    for (var i = 0; i < streams.length; i++) eps.push({ name: streams[i].name, url: streams[i].url + '#isVideo=true#' });
    $.require('uiq16').renderDetail({
      title: title, pic: pic,
      desc: eps.length ? desc : ('⚠️ 暂无可播资源' + (desc ? '\n' + desc : '')),
      lines: eps.length ? ['官方线路'] : [], episodes: eps
    });
  };
  FEM.search = function () {
    var kw = '';
    try { kw = getParam('kw') || ''; } catch (e) {}
    if (!kw) { try { kw = getMyVar('keyword', ''); } catch (e2) {} }
    if (!kw) kw = String(MY_KEYWORD || '');
    for (var d = 0; d < 5; d++) {
      if (kw.indexOf('%') === -1) break;
      try { var nk = decodeURIComponent(kw); if (nk === kw) break; kw = nk; } catch (e3) { break; }
    }
    kw = kw.trim();
    if (!kw) { $.require('uiq16').renderSearch({ items: [], page: 1, pagecount: 1 }); return; }
    var pg = 1;
    try { pg = parseInt(getMyVar('fem_spage', '1'), 10) || 1; } catch (e4) {}
    var base = '/search/' + encodeURIComponent(kw) + '/';
    var html = get(HOST + pageUrl(base, pg));
    var items = parseList(html);
    $.require('uiq16').renderSearch({ items: items, page: pg, pagecount: pageCount(html) });
  };
  $.exports = FEM;
})();
