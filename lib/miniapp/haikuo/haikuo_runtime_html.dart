/// 海阔脚本运行时页面（本地 HTTP 服务里跑，脚本用同步 XHR 走同源代理发请求）。
///
/// 说明：海阔小程序的 `fetch()` 是同步返回字符串的，浏览器里跨域同步请求会被
/// 拦死，所以请求统一打到本页同源的 `/__fetch`，由 Dart 侧代为发起，
/// 脚本里照旧写 `fetch(url)` 就能拿到正文。
const String haikuoRuntimeHtml = r'''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>海阔小程序</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body {
    margin: 0; padding: 12px 12px 28px;
    background: radial-gradient(120% 80% at 50% 0%, #1B0F32 0%, #120B20 45%, #0B0617 100%);
    color: #fff; font: 14px/1.5 -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    min-height: 100vh;
  }
  header { display: flex; align-items: center; gap: 8px; margin: 4px 2px 14px; }
  header .dot { width: 8px; height: 8px; border-radius: 50%; background: #B14BFF; box-shadow: 0 0 12px #B14BFF; }
  header h1 { font-size: 16px; font-weight: 800; margin: 0; letter-spacing: .3px; }
  header .badge {
    margin-left: auto; font-size: 11px; color: #B4A5CE;
    border: 1px solid rgba(177,75,255,.45); border-radius: 999px; padding: 2px 9px;
  }
  header .back {
    font-size: 12px; color: #B4A5CE;
    border: 1px solid rgba(177,75,255,.45); border-radius: 999px; padding: 2px 9px;
    background: transparent; cursor: pointer; white-space: nowrap;
  }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(102px, 1fr)); gap: 12px; }
  .card {
    border-radius: 12px; overflow: hidden; background: rgba(25,16,41,.92);
    border: 1px solid rgba(177,75,255,.28); display: flex; flex-direction: column;
  }
  .card:active { transform: scale(.98); }
  .card .pic {
    width: 100%; aspect-ratio: 2/3; object-fit: cover; display: block;
    background: linear-gradient(160deg, #22143A, #150C26);
  }
  .card .pic.placeholder { display: flex; align-items: center; justify-content: center; font-size: 22px; color: #7E6E9C; }
  .card .meta { padding: 7px 8px 9px; }
  .card .title { font-size: 12.5px; font-weight: 700; line-height: 1.35;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .card .desc { margin-top: 3px; font-size: 11px; color: #B4A5CE;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px 8px; padding: 4px 2px; }
  .tile { display: flex; flex-direction: column; align-items: center; min-width: 0; }
  .tile:active { transform: scale(.97); }
  .tile .glyph { width: 58px; height: 58px; border-radius: 14px;
    display: flex; align-items: center; justify-content: center;
    font-size: 26px; font-weight: 700; color: #fff;
    box-shadow: 0 4px 14px rgba(0,0,0,.35); }
  .tile .t { margin-top: 7px; font-size: 12.5px; font-weight: 600; line-height: 1.35;
    text-align: center; display: -webkit-box; -webkit-line-clamp: 2;
    -webkit-box-orient: vertical; overflow: hidden; word-break: break-word; }
  .tile .d { margin-top: 2px; font-size: 11px; color: #B4A5CE; text-align: center;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
  .d-head { position: relative; overflow: hidden; border-radius: 14px;
    border: 1px solid rgba(177,75,255,.28); background: rgba(25,16,41,.92); margin-bottom: 14px; }
  .d-head .bg { position: absolute; inset: -18px; background-size: cover;
    background-position: center; filter: blur(18px) brightness(.45); }
  .d-head .fg { position: relative; display: flex; gap: 12px; padding: 14px; }
  .d-head .poster { width: 96px; aspect-ratio: 2/3; object-fit: cover;
    border-radius: 10px; flex-shrink: 0; background: linear-gradient(160deg, #22143A, #150C26); }
  .d-head .info { min-width: 0; display: flex; flex-direction: column; justify-content: center; }
  .d-head .t { font-size: 17px; font-weight: 800; line-height: 1.4; }
  .d-head .d { margin-top: 6px; font-size: 12px; color: #D9CDEF; line-height: 1.5; }
  .d-sec { display: flex; align-items: center; gap: 8px; margin: 16px 2px 8px;
    font-size: 13px; font-weight: 700; color: #E7DCF7; }
  .d-sec::before { content: ''; width: 3px; height: 14px; border-radius: 2px;
    background: #B14BFF; box-shadow: 0 0 8px #B14BFF; }
  .d-sec.center { justify-content: center; }
  .d-sec.center::before { display: none; }
  .d-desc { margin: 0 2px; font-size: 13.5px; line-height: 1.75; color: #D9CDEF;
    white-space: pre-wrap; word-break: break-word; }
  .d-line { display: flex; align-items: center; gap: 8px; margin: 14px 2px 8px;
    padding: 10px 12px; background: rgba(25,16,41,.92);
    border: 1px solid rgba(177,75,255,.24); border-radius: 12px;
    font-size: 13px; font-weight: 700; }
  .d-line .tag { font-size: 11px; color: #B14BFF;
    border: 1px solid rgba(177,75,255,.5); border-radius: 999px; padding: 1px 8px; }
  .d-eps { display: grid; grid-template-columns: repeat(auto-fill, minmax(102px, 1fr)); gap: 12px; }
  .ep { border-radius: 12px; overflow: hidden; background: rgba(25,16,41,.92);
    border: 1px solid rgba(177,75,255,.28); display: flex; flex-direction: column; }
  .ep:active { transform: scale(.98); }
  .ep .pic { width: 100%; aspect-ratio: 2/3; object-fit: cover; display: block;
    background: linear-gradient(160deg, #22143A, #150C26); }
  .ep .lbl { padding: 7px 8px 9px; font-size: 12.5px; font-weight: 700; text-align: center;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ep.chip .lbl { padding: 10px 8px; }
  .d-text { padding: 8px 2px; font-size: 13px; color: #D9CDEF; line-height: 1.6; }
  .empty, .error { padding: 26px 10px; text-align: center; color: #B4A5CE; font-size: 13px; }
  .error { color: #FF9BC8; text-align: left; white-space: pre-wrap;
    font-family: ui-monospace, SFMono-Regular, monospace; font-size: 11.5px; }
  .empty .big { font-size: 34px; margin-bottom: 10px; }
  #status { position: fixed; left: 0; right: 0; bottom: 0; padding: 8px 14px; font-size: 11.5px;
    color: #B4A5CE; background: rgba(11,6,23,.9); max-height: 28vh; overflow: auto; display: none;
    white-space: pre-wrap; }
</style>
</head>
<body>
<header>
  <button id="backBtn" class="back" type="button" style="display:none">‹ 返回</button>
  <span class="dot"></span>
  <h1 id="title">__TITLE__</h1>
  <span class="badge" id="badge">海阔</span>
</header>
<main id="list"></main>
<div id="status"></div>
<script>
(function () {
  'use strict';
  var bytes = Uint8Array.from(atob('__PROGRAM_B64__'), function (c) { return c.charCodeAt(0); });
  var PROGRAM = JSON.parse(new TextDecoder('utf-8').decode(bytes));

  var listEl = document.getElementById('list');
  var statusEl = document.getElementById('status');
  var titleEl = document.getElementById('title');
  var resCode = 0;
  var pageTitle = PROGRAM.name || '海阔小程序';
  var lazyMap = {};
  // 详情模式：openDetail() 进入、goBack()/boot() 退出。详情结果按
  // 头项→简介→线路→选集渲染；列表页（首页/分类/搜索）保持原有卡片/行渲染。
  var isDetail = false;
  // 当前详情页的选集条目（按顺序）：点选集发 play 消息时带上，
  // 原生播放器据此显示选集面板；切集时原生调 __haikuoPlayEpisode(i)。
  var currentEpisodes = [];
  var detailTitle = '';
  // 详情头项条目：点它等同于播第 1 集，play 消息同样带选集上下文。
  var headItem = null;

  function native(payload) {
    try { window.HaikuoNative.postMessage(JSON.stringify(payload)); } catch (e) {}
  }
  function say(text) {
    if (!text) return;
    statusEl.style.display = 'block';
    statusEl.textContent = String(text).slice(0, 3000);
  }
  function toast(msg) { native({ type: 'toast', text: String(msg == null ? '' : msg) }); }

  function rawHttp(method, url, opt) {
    opt = opt || {};
    var headers = opt.headers || {};
    var body = opt.body;
    if (body !== undefined && body !== null && typeof body !== 'string') {
      try { body = JSON.stringify(body); } catch (e) { body = String(body); }
    }
    var query = '/__fetch?m=' + encodeURIComponent(method || 'GET') +
      '&u=' + encodeURIComponent(url) +
      '&h=' + encodeURIComponent(JSON.stringify(headers)) +
      '&b=' + encodeURIComponent(body == null ? '' : body);
    var xhr = new XMLHttpRequest();
    try {
      xhr.open('GET', query, false);
      xhr.send(null);
    } catch (e) {
      say('请求失败：' + url + '\n' + e);
      return '';
    }
    if (xhr.status !== 200) {
      say('请求失败：HTTP ' + xhr.status + '\n' + url);
      return '';
    }
    var text = xhr.responseText || '';
    try {
      var parsed = JSON.parse(text);
      if (parsed && typeof parsed === 'object' && 'body' in parsed) {
        resCode = parsed.code || 0;
        return parsed.body == null ? '' : String(parsed.body);
      }
    } catch (e) { /* 不是包装结构，原样返回 */ }
    return text;
  }

  // ---------- 海阔虚拟页 hiker:// 解析 ----------
  function rulePages() {
    var pages = PROGRAM.rule && PROGRAM.rule.pages;
    if (typeof pages === 'string') {
      try { pages = JSON.parse(pages); } catch (e) { pages = []; }
    }
    return Array.isArray(pages) ? pages : [];
  }
  function findPage(path) {
    var pages = rulePages();
    for (var i = 0; i < pages.length; i++) {
      if (pages[i] && String(pages[i].path) === String(path)) return pages[i];
    }
    return null;
  }
  function runPageRule(rule) {
    var text = String(rule == null ? '' : rule);
    if (text.indexOf('js:') === 0) {
      try {
        var fn = new Function(text.slice(3));
        var out = fn();
        return out === undefined || out === null ? '' : String(out);
      } catch (error) {
        say('子页执行失败：' + (error && error.message ? error.message : error));
        return '';
      }
    }
    if (text.indexOf('rule:') === 0) return text.slice(5);
    if (/^https?:\/\//.test(text)) return rawHttp('GET', text, {});
    return text;
  }
  function resolveVirtual(url) {
    var text = String(url || '');
    if (text.indexOf('hiker://empty') === 0) {
      var idx = text.indexOf('##');
      if (idx >= 0) {
        var rest = text.slice(idx + 2);
        if (/^https?:\/\//.test(rest)) return rawHttp('GET', rest, {});
        return rest;
      }
      return '';
    }
    var m = /^hiker:\/\/page\/(.+)$/.exec(text);
    if (m) {
      var page = findPage(m[1]) || findPage(decodeURIComponent(m[1]));
      return page ? runPageRule(page.rule) : '';
    }
    if (text.indexOf('hiker://') === 0) return '';
    return null;
  }

  // ---------- 海阔内置函数 ----------
  function fetch(url, opt) {
    opt = opt || {};
    var virtual = resolveVirtual(url);
    if (virtual !== null) return virtual;
    return rawHttp(opt.method || 'GET', url, opt);
  }
  function request(url, opt) { return fetch(url, opt); }
  function post(url, body, opt) {
    opt = opt || {};
    opt.method = 'POST';
    opt.body = body;
    return fetch(url, opt);
  }
  function getResCode() { return resCode; }
  function getUrl() { return MY_URL; }
  function setPageTitle(title) { pageTitle = title || pageTitle; titleEl.textContent = pageTitle; }
  function getPageTitle() { return pageTitle; }
  function log() { say(Array.prototype.slice.call(arguments).join(' ')); }
  function sleep() {}

  function parseDoc(html) {
    return new DOMParser().parseFromString(String(html == null ? '' : html), 'text/html');
  }
  function splitRule(rule) {
    var text = String(rule == null ? '' : rule).trim();
    var parts = text.split('&&');
    var css = parts[0].trim();
    var tail = parts.length > 1 ? parts[1].trim() : '';
    if (!css) css = 'html';
    return { css: css, tail: tail };
  }
  function nodesOf(doc, sel) {
    try { return Array.prototype.slice.call(doc.querySelectorAll(sel)); } catch (e) { return []; }
  }
  function valueOf(node, tail) {
    if (!node) return '';
    if (!tail || tail === 'Text') return (node.textContent || '').trim();
    if (tail === 'Html') return node.innerHTML || '';
    if (tail === 'OuterHtml') return node.outerHTML || '';
    return node.getAttribute ? (node.getAttribute(tail) || '') : '';
  }
  function pdfa(html, rule) {
    var r = splitRule(rule);
    var doc = parseDoc(html);
    return nodesOf(doc, r.css).map(function (node) { return valueOf(node, r.tail); });
  }
  function pdfh(html, rule) {
    var r = splitRule(rule);
    var doc = typeof html === 'string' ? parseDoc(html) : html;
    return valueOf(nodesOf(doc, r.css)[0], r.tail);
  }

  // ---------- 结果渲染 ----------
  function isMedia(url) {
    return /\.(m3u8|mp4|flv|mkv|m4a|mp3|ts)(\?|#|$)/i.test(String(url || ''));
  }
  // HTML 转义还原（规则/站方文本里常带 &nbsp; &amp; 等）：纯正则实现，
  // 不依赖 DOM，Node 夹具里也能跑。只还原实体，不解释标签。
  var namedEntities = { nbsp: ' ', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", copy: '©', reg: '®', hellip: '…', mdash: '—', ndash: '–', laquo: '«', raquo: '»', middot: '·' };
  function decodeEntities(value) {
    var text = String(value == null ? '' : value);
    if (text.indexOf('&') < 0) return text;
    return text.replace(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/g, function (m, body) {
      if (body.charAt(0) === '#') {
        var code = (body.charAt(1) === 'x' || body.charAt(1) === 'X')
          ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
        if (!isNaN(code) && code > 0 && code < 0x110000) {
          try { return String.fromCodePoint(code); } catch (e) { return m; }
        }
        return m;
      }
      return Object.prototype.hasOwnProperty.call(namedEntities, body) ? namedEntities[body] : m;
    });
  }
  // 标题里的 HTML 标签只留文字、不做完整渲染：先去标签再解实体，
  // 这样 &lt;b&gt; 这类被转义过的尖括号仍能原样显示为文字。
  function stripTags(raw) {
    return String(raw || '').replace(/<\/?[a-zA-Z][^>]*>/g, '');
  }
  function itemPic(it) { return (it && (it.pic || it.img || it.cover || it.pic_url)) || ''; }
  function itemTitle(it) { return decodeEntities(stripTags((it && (it.title || it.name)) || '')); }
  function itemDesc(it) { return decodeEntities(stripTags((it && (it.desc || it.remarks || it.note)) || '')); }
  // 平铺色块：与海阔 tab 网格同一套色板，字形取标题首个字母/数字
  // （跳过开头的表情与符号，避免代理对截半个显示成“?”）。
  var TILE_COLORS = ['#FF8A3D', '#3B82F6', '#A855F7', '#22C55E', '#EF4444', '#14B8A6', '#F59E0B', '#6366F1'];
  function tileColor(name) {
    var hash = 0;
    var s = String(name || '');
    for (var i = 0; i < s.length; i++) { hash = (hash * 31 + s.charCodeAt(i)) | 0; }
    return TILE_COLORS[Math.abs(hash) % TILE_COLORS.length];
  }
  function tileGlyph(name) {
    var chars = Array.from(String(name || ''));
    for (var i = 0; i < chars.length; i++) {
      if (/[\p{L}\p{N}]/u.test(chars[i])) return chars[i];
    }
    return '·';
  }
  function colTypeOf(it) { return String((it && (it.col_type || it.colType)) || ''); }
  function isPlayableUrl(url) {
    var u = String(url || '');
    return u !== '' && u.indexOf('hiker://empty') !== 0;
  }
  // 详情选集上下文：被点的条目是当前选集之一时，play 消息带上
  // 全部选集标题 + 序号 + 剧名，原生播放器据此显示选集面板。
  function episodeContext(item) {
    var idx = currentEpisodes.indexOf(item);
    if (idx < 0 && item === headItem && currentEpisodes.length) idx = 0;
    if (idx < 0) return null;
    return {
      episodes: currentEpisodes.map(function (ep) { return itemTitle(ep) || '选集'; }),
      index: idx,
      series: detailTitle
    };
  }
  function sendPlay(url, item) {
    var payload = { type: 'play', url: url, title: itemTitle(item) };
    var ctx = episodeContext(item);
    if (ctx) { payload.episodes = ctx.episodes; payload.index = ctx.index; payload.series = ctx.series; }
    native(payload);
  }
  function openItem(item) {
    if (!item) return;
    var url = item.url || item.link || '';
    if (!url) return;
    if (url.indexOf('hiker://lazy#') === 0) {
      var fn = lazyMap[url.slice('hiker://lazy#'.length)];
      if (typeof fn === 'function') {
        try {
          // 播放函数返回的就是播放地址（或 toast://解析失败）；
          // 以前这里直接丢掉返回值，点播放没任何反应。
          var result = fn();
          if (result === '') {
            toast('解析失败');
          } else if (typeof result === 'string' && result) {
            if (result.indexOf('toast://') === 0) {
              toast(result.slice('toast://'.length) || '解析失败');
            } else if (isMedia(result)) {
              sendPlay(result, item);
            } else if (/^https?:\/\//.test(result)) {
              native({ type: 'open', url: result, title: item.title || item.name || '' });
            } else if (result.indexOf('hiker://') === 0) {
              var virtual = resolveVirtual(result);
              if (virtual) { renderText(virtual); }
            }
          }
          // 返回 undefined/null：函数自己已处理（如内部调了 play），不打扰。
        } catch (error) { say('执行失败：' + error); }
      }
      return;
    }
    if (/^hiker:\/\//i.test(url)) {
      var virtual = resolveVirtual(url);
      if (virtual) { renderText(virtual); return; }
      // 解析不出的 hiker:// 链接（如 hiker://empty 占位行）什么都不做，
      // 别把它当网页打开。
      return;
    }
    // 有详情规则时，点卡片进详情页（跑 detail_find_rule），
    // 而不是直接开原站网页——否则详情页与播放入口永远到不了。
    if (/^https?:\/\//.test(url) && !isMedia(url) && hasDetailRule()) {
      openDetail(url);
      return;
    }
    if (isMedia(url)) { sendPlay(url, item); return; }
    native({ type: 'open', url: url, title: itemTitle(item) });
  }
  function renderText(text) {
    listEl.innerHTML = '<div class="empty">' + escapeHtml(String(text).slice(0, 4000)) + '</div>';
  }
  function render(items) {
    if (!Array.isArray(items)) items = items ? [items] : [];
    currentEpisodes = [];
    detailTitle = '';
    headItem = null;
    if (isDetail) { renderDetail(items); return; }
    if (!items.length) {
      listEl.innerHTML = '<div class="empty"><div class="big">🍃</div>这个页面没有返回内容</div>';
      return;
    }
    var hasPic = items.some(function (it) { return it && (it.pic || it.img || it.cover); });
    var html = '';
    if (hasPic) {
      html = '<div class="grid">';
      items.forEach(function (it, index) {
        var pic = it.pic || it.img || it.cover || '';
        var rawTitle = itemTitle(it);
        var title = escapeHtml(rawTitle);
        var ph = tileGlyph(rawTitle);
        var desc = escapeHtml(itemDesc(it));
        html += '<div class="card" data-index="' + index + '">' +
          (pic
            ? '<img class="pic" loading="lazy" src="' + escapeHtml(pic) + '" onerror="this.className=\'pic placeholder\';this.removeAttribute(\'src\');this.textContent=\'' + ph + '\'">'
            : '<div class="pic placeholder">' + escapeHtml(ph) + '</div>') +
          '<div class="meta"><div class="title">' + title + '</div>' +
          (desc ? '<div class="desc">' + desc + '</div>' : '') +
          '</div></div>';
      });
      html += '</div>';
    } else {
      // 无图列表（分类页等）：平铺网格，彩色字形块 + 名称，与海阔 tab 一致。
      // 空标题仍显示“未命名”占位，块可点、条目不丢。
      html = '<div class="tiles">';
      items.forEach(function (it, index) {
        var name = itemTitle(it) || '未命名';
        var desc = itemDesc(it);
        html += '<div class="tile" data-index="' + index + '">' +
          '<div class="glyph" style="background:' + tileColor(name) + '">' + escapeHtml(tileGlyph(name)) + '</div>' +
          '<div class="t">' + escapeHtml(name) + '</div>' +
          (desc ? '<div class="d">' + escapeHtml(desc) + '</div>' : '') +
          '</div>';
      });
      html += '</div>';
    }
    listEl.innerHTML = html;
    Array.prototype.forEach.call(listEl.querySelectorAll('[data-index]'), function (el) {
      el.addEventListener('click', function () {
        openItem(items[Number(el.getAttribute('data-index'))]);
      });
    });
  }
  // 详情页渲染：按 col_type 把条目分成头项 / 章节头 / 简介正文 /
  // 播放线路 / 选集，不再全画成统一卡片。每个条目仍保留一个
  // data-index（点选行为与列表页一致；hiker://empty 的行点按无反应）。
  function renderDetail(items) {
    if (!items.length) {
      listEl.innerHTML = '<div class="empty"><div class="big">🍃</div>这个页面没有返回内容</div>';
      return;
    }
    // 头项：第一条带图、且不是选集/正文行的条目。
    var headIndex = -1;
    if (items.length > 1 && itemPic(items[0]) &&
        !/^text_[2-9]$/.test(colTypeOf(items[0])) && colTypeOf(items[0]) !== 'rich_text') {
      headIndex = 0;
    }
    var html = '';
    var epGridOpen = false;
    function closeEpGrid() { if (epGridOpen) { html += '</div>'; epGridOpen = false; } }
    items.forEach(function (it, index) {
      var col = colTypeOf(it);
      var title = itemTitle(it);
      var desc = itemDesc(it);
      var url = (it && (it.url || it.link)) || '';
      if (index === headIndex) {
        detailTitle = title;
        headItem = it;
        var pic = itemPic(it);
        html += '<div class="d-head" data-index="' + index + '">' +
          (pic ? '<div class="bg" style="background-image:url(\'' + escapeHtml(pic) + '\')"></div>' : '') +
          '<div class="fg">' +
          (pic ? '<img class="poster" loading="lazy" src="' + escapeHtml(pic) + '">' : '') +
          '<div class="info"><div class="t">' + escapeHtml(title) + '</div>' +
          (desc ? '<div class="d">' + escapeHtml(desc) + '</div>' : '') +
          '</div></div></div>';
        return;
      }
      if (col === 'rich_text') {
        closeEpGrid();
        // 简介正文在 title 里，带 &nbsp; 缩进与 <br/> 换行：先换行、
        // 去标签，再还原实体，最后转义后按 pre-wrap 显示。
        var body = String((it && (it.title || it.desc)) || '');
        body = body.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '');
        body = decodeEntities(body);
        html += '<div class="d-desc" data-index="' + index + '">' + escapeHtml(body) + '</div>';
        return;
      }
      if (col === 'text_center_1') {
        closeEpGrid();
        html += '<div class="d-sec center" data-index="' + index + '">' + escapeHtml(title) + '</div>';
        return;
      }
      if (col === 'text_1') {
        closeEpGrid();
        html += '<div class="d-line" data-index="' + index + '"><span class="tag">线路</span><span>' + escapeHtml(title) + '</span></div>';
        return;
      }
      if (/^text_[2-9]$/.test(col) || (col === '' && isPlayableUrl(url))) {
        if (!epGridOpen) { html += '<div class="d-eps">'; epGridOpen = true; }
        currentEpisodes.push(it);
        var epPic = itemPic(it);
        html += '<div class="ep' + (epPic ? '' : ' chip') + '" data-index="' + index + '">' +
          (epPic ? '<img class="pic" loading="lazy" src="' + escapeHtml(epPic) + '">' : '') +
          '<div class="lbl">' + escapeHtml(title || '选集') + '</div></div>';
        return;
      }
      if (col === '' && !isPlayableUrl(url)) {
        closeEpGrid();
        html += '<div class="d-text" data-index="' + index + '">' + escapeHtml(title) +
          (desc ? '<br>' + escapeHtml(desc) : '') + '</div>';
        return;
      }
      // 兜底：未知形态按列表卡片画一张，不丢条目。
      closeEpGrid();
      var fbPic = itemPic(it);
      var fbPh = tileGlyph(title);
      html += '<div class="card" data-index="' + index + '">' +
        (fbPic ? '<img class="pic" loading="lazy" src="' + escapeHtml(fbPic) + '">'
          : '<div class="pic placeholder">' + escapeHtml(fbPh) + '</div>') +
        '<div class="meta"><div class="title">' + escapeHtml(title) + '</div>' +
        (desc ? '<div class="desc">' + escapeHtml(desc) + '</div>' : '') + '</div></div>';
    });
    closeEpGrid();
    listEl.innerHTML = html;
    Array.prototype.forEach.call(listEl.querySelectorAll('[data-index]'), function (el) {
      el.addEventListener('click', function () {
        openItem(items[Number(el.getAttribute('data-index'))]);
      });
    });
  }
  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function setResult(items) { render(items); }
  function refreshPage() {}
  function setPage() {}
  function join(url) { openItem({ url: url }); }
  function play(url, title) { native({ type: isMedia(url) ? 'play' : 'open', url: url, title: title || '' }); }
  function open(url) { native({ type: 'open', url: url }); }
  function getVar(key) { try { return localStorage.getItem('v_' + key) || ''; } catch (e) { return ''; } }
  function putVar(key, value) { try { localStorage.setItem('v_' + key, value == null ? '' : String(value)); } catch (e) {} }
  // ---------- 本地 m3u8 存取（规则去广告后用） ----------
  // 规则 playFn 里的 saveFile('clean.m3u8', 清单)/getPath('hiker://files/clean.m3u8')
  // 原来运行时根本没有这两个函数：saveFile 一调就报 ReferenceError，
  // 被 playFn 的 try/catch 吞掉后回落到原 m3u8——能播，但广告一段没去。
  // 现在：内容先记在页内 map（getPath 立刻能用），再发给原生存在内存里，
  // 由本地服务按 /__files/<名> 提供给播放器（密钥 URI 本来就是绝对地址，不受影响）。
  var savedFiles = {};
  function saveFile(name, content, flag) {
    try {
      var key = String(name || '').split('/').pop();
      if (!key) return false;
      savedFiles[key] = String(content == null ? '' : content);
      native({ type: 'saveFile', name: key, content: savedFiles[key] });
      return true;
    } catch (e) { return false; }
  }
  function writeFile(name, content) { return saveFile(name, content, 0); }
  function getPath(path) {
    try {
      var p = String(path || '');
      var key = p.split('/').pop();
      if (!key) return '';
      if (p.indexOf('hiker://files/') === 0 || savedFiles[key] !== undefined) {
        return window.location.origin + '/__files/' + encodeURIComponent(key);
      }
      return p;
    } catch (e) { return ''; }
  }
  function getMyVar(key, fallback) { var v = getVar(key); return v === '' ? (fallback === undefined ? '' : fallback) : v; }
  function putMyVar(key, value) { putVar(key, value); }
  function getItem(key, fallback) {
    try {
      var v = localStorage.getItem('i_' + key);
      if (v === null) return fallback === undefined ? '' : fallback;
      return v;
    } catch (e) { return fallback === undefined ? '' : fallback; }
  }
  function setItem(key, value) { try { localStorage.setItem('i_' + key, value == null ? '' : String(value)); } catch (e) {} }
  function clearItem(key) { try { localStorage.removeItem('i_' + key); } catch (e) {} }
  function base64Encode(text) { try { return btoa(unescape(encodeURIComponent(text))); } catch (e) { return ''; } }
  function base64Decode(text) { try { return decodeURIComponent(escape(atob(text))); } catch (e) { return ''; } }

  // ---------- 海阔模块加载（$.require / $.exports，官方写法） ----------
  // 官方约定（docs.189.tyrantg.com）：子页脚本用 $.exports 导出模块
  // （$.exports = X，或往 $.exports 上挂属性；$.importParam 区分用法），
  // 引用处 $.require(path, importParam) 拿到导出对象再调 .home()/.detail()/.search()。
  // 之前这里对 js: 子页只返回一个裸函数，规则一调 .home 就报
  // "TypeError: $.require(...).home is not a function"。
  // 模块默认全局缓存；第二个参数传了真值时不走缓存（同时当 importParam 传进子页）。
  var moduleCache = {};
  var moduleState = { exports: {}, importParam: undefined };
  function hasOwnProps(obj) {
    if (!obj || (typeof obj !== 'object' && typeof obj !== 'function')) return false;
    for (var key in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, key)) return true;
    }
    return false;
  }
  function loadModule(path, param) {
    var key = String(path || '').replace(/^hiker:\/\/page\//, '');
    var page = findPage(key);
    if (!page) return {};
    var force = !!param;
    if (!force && Object.prototype.hasOwnProperty.call(moduleCache, key)) {
      return moduleCache[key];
    }
    var rule = String(page.rule || '');
    if (rule.indexOf('js:') !== 0) {
      var value = runPageRule(rule);
      if (!force) moduleCache[key] = value;
      return value;
    }
    var code = rule.slice(3);
    var freshExports = {};
    var savedExports = moduleState.exports;
    var savedImportParam = moduleState.importParam;
    moduleState.exports = freshExports;
    moduleState.importParam = param;
    var moduleObj = { exports: {} };
    var initialModuleExports = moduleObj.exports;
    var collected = null;
    try {
      var factory = new Function(
        'require', 'module', 'exports', 'console', 'input',
        code + '\n;return {' +
        'home: typeof home === "function" ? home : null,' +
        'detail: typeof detail === "function" ? detail : null,' +
        'search: typeof search === "function" ? search : null,' +
        'category: typeof category === "function" ? category : null,' +
        'play: typeof play === "function" ? play : null,' +
        'lazy: typeof lazy === "function" ? lazy : null,' +
        'init: typeof init === "function" ? init : null,' +
        'main: typeof main === "function" ? main : null' +
        '};'
      );
      collected = factory(
        function (p, prm) { return loadModule(p, prm); },
        moduleObj, moduleObj.exports, { log: log }, input
      );
    } catch (error) {
      say('模块加载失败：' + key + '\n' + (error && error.message ? error.message : error));
      moduleState.exports = savedExports;
      moduleState.importParam = savedImportParam;
      return {};
    }
    var exported = moduleState.exports;
    moduleState.exports = savedExports;
    moduleState.importParam = savedImportParam;
    var result = null;
    if (exported !== freshExports || hasOwnProps(exported)) {
      result = exported;
    } else if (moduleObj.exports !== initialModuleExports || hasOwnProps(moduleObj.exports)) {
      result = moduleObj.exports;
    } else if (collected) {
      result = {};
      var anyFn = false;
      var names = ['home', 'detail', 'search', 'category', 'play', 'lazy', 'init', 'main'];
      for (var i = 0; i < names.length; i++) {
        if (collected[names[i]]) { result[names[i]] = collected[names[i]]; anyFn = true; }
      }
      if (!anyFn) result = {};
    }
    if (result === null || result === undefined) result = {};
    if (!force) moduleCache[key] = result;
    return result;
  }

  // ---------- 海阔的 $ 工具箱（只实现常用的一层） ----------
  var $api = {
    require: function (path, param) { return loadModule(path, param); },
    toString: function (value) { return String(value); },
    post: function (url, body, headers) { return post(url, body, { headers: headers || {} }); },
    get: function (url, headers) { return fetch(url, { headers: headers || {} }); },
    lazyRule: function (fn, input) {
      if (typeof fn !== 'function') return 'hiker://empty';
      var key = 'lazy' + Math.random().toString(36).slice(2);
      // 官方 lazyRule 会把第二个参数当 input 传给播放函数；
      // 不绑 input 的话 playFn 拿到 undefined，取不到播放地址。
      lazyMap[key] = function () { return fn(input); };
      return 'hiker://lazy#' + key;
    },
    random: function (n) { return Math.floor(Math.random() * (n || 1000)); },
    base64Encode: base64Encode,
    base64Decode: base64Decode,
    log: function () { log.apply(null, arguments); }
  };
  // 规则里写的是 $().lazyRule(...)（函数调用形式），不是 $.lazyRule；
  // $api 本身是普通对象，$() 会报 TypeError: $ is not a function，
  // 导致所有带 toPlay 的详情页一个选集都生成不出来。
  // 包一层可调用函数：$() 返回 $api，$.lazyRule 也照常用。
  function $(selector) { return $api; }
  Object.keys($api).forEach(function (key) { $[key] = $api[key]; });
  // $.exports / $.importParam 与模块加载共用同一份状态（子页脚本读写的是 $ 上的
  // 这两个属性；直接把值拷到 $ 上会在子页重赋值后失同步，所以用访问器代理）。
  Object.defineProperty($, 'exports', {
    get: function () { return moduleState.exports; },
    set: function (value) { moduleState.exports = value; },
    configurable: true, enumerable: true
  });
  Object.defineProperty($, 'importParam', {
    get: function () { return moduleState.importParam; },
    set: function (value) { moduleState.importParam = value; },
    configurable: true, enumerable: true
  });

  // ---------- 全局环境 ----------
  function homeUrl() {
    var rawUrl = String((PROGRAM.rule && PROGRAM.rule.url) || PROGRAM.url || '');
    if (rawUrl.indexOf('##') >= 0) {
      // 带 ## 占位符的规则地址原样交给规则：规则按 MY_URL.split('##')
      // 自取分类与页码（与海阔一致）。不要在这里截掉前缀或把 fypage
      // 换成 1——那样 split 出的 [1] 会变成 '1'，规则会把 '1' 当成
      // 分类去拼地址，首页取数就空了（鉴黄师 v16 即因此空白）。
      return rawUrl;
    }
    if (rawUrl.indexOf('hiker://') === 0) return '';
    return rawUrl;
  }
  var MY_URL = homeUrl();
  var MY_RULE = PROGRAM.rule || {};
  var MY_PAGE = 1;
  var fypage = '1';
  var fyclass = '';
  var input = '';
  // 详情页导航栈：只记回首页要用的 MY_URL/MY_PAGE。
  var navStack = [];

  function setGlobals(myUrl, myPage) {
    MY_URL = myUrl || '';
    MY_PAGE = myPage || 1;
    fypage = String(MY_PAGE);
    window.MY_URL = MY_URL;
    window.MY_PAGE = MY_PAGE;
    window.fypage = fypage;
  }
  function hasDetailRule() {
    var r = PROGRAM.rule || {};
    return String(r.detail_find_rule || r.sdetail_find_rule || '').trim().length > 0;
  }
  function detailScript() {
    var r = PROGRAM.rule || {};
    return String(r.detail_find_rule || r.sdetail_find_rule || '');
  }
  function showBack(show) {
    var btn = document.getElementById('backBtn');
    if (btn) btn.style.display = show ? 'inline-block' : 'none';
  }
  function openDetail(url) {
    navStack.push({ url: MY_URL, page: MY_PAGE });
    setGlobals(url, 1);
    showBack(true);
    isDetail = true;
    listEl.innerHTML = '';
    runSource(detailScript());
  }
  function goBack() {
    var prev = navStack.pop();
    showBack(navStack.length > 0);
    if (prev) setGlobals(prev.url, prev.page);
    else setGlobals(homeUrl(), 1);
    isDetail = false;
    listEl.innerHTML = '';
    runSource(PROGRAM.script || '');
  }
  function runSource(source) {
    var text = String(source || '');
    if (text.indexOf('js:') === 0) text = text.slice(3);
    if (!text.trim()) return false;
    try {
      var factory = new Function(
        'require', 'module', 'exports', 'console',
        text + '\n;return {' +
        'home: typeof home === "function" ? home : null,' +
        'detail: typeof detail === "function" ? detail : null,' +
        'search: typeof search === "function" ? search : null,' +
        'category: typeof category === "function" ? category : null,' +
        'init: typeof init === "function" ? init : null,' +
        'main: typeof main === "function" ? main : null' +
        '};'
      );
      var api = factory(function () { return {}; }, {}, {});
      if (api.home) api.home();
      else if (api.main) api.main();
      else if (api.init) api.init();
      else if (api.category) api.category();
      else if (api.detail) api.detail();
      return true;
    } catch (error) {
      listEl.innerHTML = '<div class="error">执行失败：\n' +
        escapeHtml(error && error.stack ? error.stack : String(error)) + '</div>';
      return false;
    }
  }

  var API = {
    fetch: fetch, request: request, post: post, getResCode: getResCode,
    pdfa: pdfa, pdfh: pdfh, pd: pdfa, parseDomForHtml: parseDoc,
    setResult: setResult, setHomeResult: setResult, setSearchResult: setResult,
    refreshPage: refreshPage, setPage: setPage, join: join, play: play, open: open,
    toast: toast, log: log, sleep: sleep,
    getVar: getVar, putVar: putVar, getMyVar: getMyVar, putMyVar: putMyVar,
    getItem: getItem, setItem: setItem, clearItem: clearItem,
    saveFile: saveFile, writeFile: writeFile, getPath: getPath,
    getPageTitle: getPageTitle, setPageTitle: setPageTitle, getUrl: getUrl,
    base64Encode: base64Encode, base64Decode: base64Decode,
    MY_URL: MY_URL, MY_RULE: MY_RULE, MY_PAGE: MY_PAGE, fypage: fypage, fyclass: fyclass
  };
  Object.keys(API).forEach(function (key) { window[key] = API[key]; });
  window.$ = $;
  window.$$$ = $;
  window.$$ = $;
  window.MY_URL = MY_URL;
  window.MY_RULE = MY_RULE;
  window.MY_PAGE = MY_PAGE;
  window.fypage = fypage;
  window.fyclass = fyclass;

  // 供原生播放器切集：按详情选集序号重走点选同一集的完整链路
  // （lazy 解析、saveFile、play 消息都与手动点选一致）。
  window.__haikuoPlayEpisode = function (index) {
    var it = currentEpisodes[Number(index)];
    if (it) openItem(it);
  };
  window.__haikuoEpisodeCount = function () { return currentEpisodes.length; };

  function boot() {
    var backBtn = document.getElementById('backBtn');
    if (backBtn) backBtn.addEventListener('click', goBack);
    isDetail = false;
    var source = String(PROGRAM.script || '');
    if (source.indexOf('js:') === 0) source = source.slice(3);
    if (!source.trim()) {
      if (PROGRAM.rule && Object.keys(PROGRAM.rule).length) {
        render([{
          title: PROGRAM.name || '规则',
          desc: '这条规则没有可执行脚本，只有链接：' + (MY_URL || 'hiker://'),
          url: /^https?:\/\//.test(MY_URL) ? MY_URL : ''
        }]);
        return;
      }
      listEl.innerHTML = '<div class="empty"><div class="big">📄</div>这个条目没有可执行的脚本主体</div>';
      return;
    }
    runSource(source);
  }

  window.addEventListener('error', function (event) {
    say('页面异常：' + (event && event.message ? event.message : ''));
  });
  try { boot(); } catch (error) {
    listEl.innerHTML = '<div class="error">运行失败：' + escapeHtml(error && error.stack ? error.stack : String(error)) + '</div>';
  }
})();
</script>
</body>
</html>''';
