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
  .cats { display: flex; gap: 8px; overflow-x: auto; padding: 2px 2px 10px;
    scrollbar-width: none; }
  .cats::-webkit-scrollbar { display: none; }
  .cats.sub { padding-bottom: 12px; }
  .cat { flex-shrink: 0; font-size: 12.5px; font-weight: 600; color: #D9CDEF;
    border: 1px solid rgba(177,75,255,.35); border-radius: 999px; padding: 6px 14px;
    background: rgba(25,16,41,.92); cursor: pointer; white-space: nowrap; }
  .cat.on { color: #fff; background: linear-gradient(135deg, #B14BFF, #7C3AED);
    border-color: transparent; box-shadow: 0 2px 10px rgba(177,75,255,.45); }
  .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  .card {
    border-radius: 12px; overflow: hidden; background: rgba(25,16,41,.92);
    border: 1px solid rgba(177,75,255,.28); display: flex; flex-direction: column;
  }
  .card:active { transform: scale(.98); }
  .card .picwrap { position: relative; }
  .card .epbadge { position: absolute; left: 6px; bottom: 6px; font-size: 11px;
    font-weight: 700; color: #fff; background: rgba(0,0,0,.62); border-radius: 6px;
    padding: 2px 6px; }
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
  .d-head .posterwrap { position: relative; width: 96px; flex-shrink: 0; align-self: center; }
  .d-head .poster { width: 100%; aspect-ratio: 2/3; object-fit: cover; display: block;
    border-radius: 10px; background: linear-gradient(160deg, #22143A, #150C26); }
  .d-head .posterplay { position: absolute; inset: 0; display: flex;
    align-items: center; justify-content: center; cursor: pointer; }
  .d-head .posterplay span { width: 42px; height: 42px; border-radius: 50%;
    background: rgba(11,6,23,.6); border: 1.5px solid rgba(255,255,255,.9);
    color: #fff; font-size: 17px; display: flex; align-items: center;
    justify-content: center; padding-left: 3px; box-shadow: 0 2px 12px rgba(0,0,0,.5); }
  .d-head .posterplay:active span { transform: scale(.92); }
  .d-player { position: relative; aspect-ratio: 16/9; border-radius: 14px;
    margin-bottom: 14px; background: linear-gradient(160deg, #22143A, #150C26);
    border: 1px solid rgba(177,75,255,.28); display: flex;
    align-items: center; justify-content: center; cursor: pointer; }
  .d-player:active { transform: scale(.99); }
  .d-player .pbtn { width: 62px; height: 62px; border-radius: 50%;
    background: linear-gradient(135deg, #B14BFF, #7C3AED); color: #fff;
    font-size: 25px; display: flex; align-items: center; justify-content: center;
    padding-left: 4px; box-shadow: 0 4px 18px rgba(177,75,255,.45); }
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
  .loading { padding: 40px 10px; text-align: center; color: #B4A5CE; font-size: 13px; }
  .loading .spin, .play-loading .spin { width: 26px; height: 26px; margin: 0 auto 12px;
    border-radius: 50%; border: 3px solid rgba(177,75,255,.25); border-top-color: #B14BFF;
    animation: hkspin .8s linear infinite; }
  @keyframes hkspin { to { transform: rotate(360deg); } }
  .play-loading { position: fixed; inset: 0; z-index: 50; display: none;
    align-items: center; justify-content: center; background: rgba(11,6,23,.55); }
  .play-loading .box { text-align: center; color: #fff; font-size: 13px; }
  body.hk-inline-playing .d-head { display: none; }
  /* 规则级 col_type 版式（M23/M24）：与海阔组件样式同名同形。 */
  .grid2 { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
  .marquee { display: flex; gap: 12px; overflow-x: auto; padding-bottom: 6px; scrollbar-width: none; }
  .marquee::-webkit-scrollbar { display: none; }
  .marquee .card { flex: 0 0 118px; }
  .rows { display: flex; flex-direction: column; gap: 10px; }
  .rowitem { display: flex; gap: 10px; align-items: center; border-radius: 12px;
    overflow: hidden; background: rgba(25,16,41,.92); border: 1px solid rgba(177,75,255,.28); padding: 8px; }
  .rowitem:active { transform: scale(.99); }
  .rowitem .thumb { width: 64px; aspect-ratio: 2/3; object-fit: cover; border-radius: 8px; flex-shrink: 0;
    background: linear-gradient(160deg, #22143A, #150C26); }
  .rowitem .thumb.wide { width: 96px; aspect-ratio: 16/10; }
  .rowitem .rmeta { min-width: 0; flex: 1; }
  .rowitem .rtitle { font-size: 13.5px; font-weight: 700; line-height: 1.4;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .rowitem .rdesc { margin-top: 3px; font-size: 11.5px; color: #B4A5CE;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .vpic { text-align: center; margin-bottom: 12px; }
  .vpic img { width: 150px; aspect-ratio: 2/3; object-fit: cover; border-radius: 12px; }
  .vpic .vt { margin-top: 8px; font-size: 14px; font-weight: 700; }
  .vpic .vd { margin-top: 4px; font-size: 12px; color: #B4A5CE; }
  .vblur { position: relative; overflow: hidden; border-radius: 14px; padding: 18px 12px; margin-bottom: 12px;
    border: 1px solid rgba(177,75,255,.28); background: rgba(25,16,41,.92); }
  .vblur .bg { position: absolute; inset: -18px; background-size: cover; background-position: center; filter: blur(18px) brightness(.45); }
  .vblur .fg { position: relative; text-align: center; }
  .vblur img { width: 120px; aspect-ratio: 2/3; object-fit: cover; border-radius: 10px; }
  .textrows { display: flex; flex-direction: column; }
  .textrow { padding: 11px 4px; font-size: 14px; border-bottom: 1px solid rgba(177,75,255,.16); }
  .textrow.center { text-align: center; }
  .textrow .hl-red { color: #FF6B6B; } .textrow .hl-orange { color: #FFA940; }
  .textgrid { display: grid; gap: 8px; margin-bottom: 8px; }
  .textgrid .tcell { padding: 9px 6px; text-align: center; font-size: 13px; border-radius: 10px;
    background: rgba(25,16,41,.92); border: 1px solid rgba(177,75,255,.22); }
  .longtext { font-size: 14px; line-height: 1.8; color: #D9CDEF; white-space: pre-wrap; word-break: break-word; padding: 6px 2px 12px; }
  .richtext { font-size: 14px; line-height: 1.7; color: #D9CDEF; word-break: break-word; padding: 6px 2px 12px; }
  .richtext img { max-width: 100%; border-radius: 8px; }
  .picgrid { display: grid; gap: 8px; }
  .picgrid img { width: 100%; display: block; border-radius: 10px; object-fit: cover; }
  .picfull { width: 100%; display: block; border-radius: 12px; margin-bottom: 10px; }
  .piccenter { text-align: center; margin-bottom: 10px; }
  .piccenter img { max-width: 82%; border-radius: 12px; }
  .iconrow { display: grid; gap: 14px 8px; padding: 4px 2px 10px; }
  .iconitem { display: flex; flex-direction: column; align-items: center; min-width: 0; }
  .iconitem img, .iconitem .iglyph { width: 52px; height: 52px; border-radius: 13px; object-fit: cover;
    display: flex; align-items: center; justify-content: center; font-size: 22px; font-weight: 700; color: #fff; }
  .iconitem.round img, .iconitem.round .iglyph { border-radius: 50%; }
  .iconitem.small img, .iconitem.small .iglyph { width: 40px; height: 40px; font-size: 17px; border-radius: 10px; }
  .iconitem .it { margin-top: 6px; font-size: 12px; font-weight: 600; text-align: center; line-height: 1.3;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .divider { height: 1px; background: rgba(177,75,255,.3); margin: 12px 0; }
  .blankblock { height: 18px; }
  .avatarrow { display: flex; gap: 10px; align-items: center; padding: 10px 4px; border-bottom: 1px solid rgba(177,75,255,.14); }
  .avatarrow img { width: 46px; height: 46px; border-radius: 50%; object-fit: cover; flex-shrink: 0; }
  .avatarrow .at { flex: 1; min-width: 0; font-size: 14px; font-weight: 600; }
  .avatarrow .ad { font-size: 12px; color: #B4A5CE; text-align: right; }
  .chips { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 10px; }
  .chips.scroll { flex-wrap: nowrap; overflow-x: auto; padding-bottom: 4px; scrollbar-width: none; }
  .chips.scroll::-webkit-scrollbar { display: none; }
  .chipbtn { flex-shrink: 0; font-size: 13px; padding: 7px 14px; border-radius: 999px;
    background: rgba(25,16,41,.92); border: 1px solid rgba(177,75,255,.35); color: #E7DCF7; }
  .cardpic { position: relative; overflow: hidden; border-radius: 14px; aspect-ratio: 1; }
  .cardpic .bg { position: absolute; inset: -14px; background-size: cover; background-position: center; filter: blur(12px) brightness(.55); }
  .cardpic .fg { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px; padding: 10px; }
  .cardpic img { width: 56%; aspect-ratio: 2/3; object-fit: cover; border-radius: 8px; }
  .cardpic .ct { font-size: 12px; font-weight: 700; text-align: center; line-height: 1.3;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .inputrow { display: flex; gap: 8px; margin-bottom: 12px; }
  .inputrow input { flex: 1; min-width: 0; padding: 10px 12px; border-radius: 10px; font-size: 14px; color: #fff;
    background: rgba(25,16,41,.92); border: 1px solid rgba(177,75,255,.4); outline: none; }
  .inputrow button { padding: 0 16px; border-radius: 10px; border: none; font-size: 13px; font-weight: 700; color: #fff;
    background: linear-gradient(135deg, #B14BFF, #7C3AED); }
  .searchrow { display: flex; align-items: center; gap: 8px; padding: 11px 12px; border-radius: 10px; margin-bottom: 12px;
    background: rgba(25,16,41,.92); border: 1px solid rgba(177,75,255,.3); color: #B4A5CE; font-size: 13.5px; }
  .gallery img { width: 100%; display: block; border-radius: 12px; margin-bottom: 10px; }
  .vgrad { position: absolute; inset: 0; background: linear-gradient(180deg, rgba(0,0,0,.05), rgba(0,0,0,.55)); pointer-events: none; }
  .cardpair { display: flex; flex-direction: column; gap: 8px; }
  .cardpair .cardpic { flex: 1; aspect-ratio: auto; min-height: 120px; }
  .title.mq { display: flex; overflow: hidden; white-space: nowrap; }
  .title.mq span { flex-shrink: 0; padding-right: 28px; animation: hkmq 9s linear infinite; }
  @keyframes hkmq { from { transform: translateX(0); } to { transform: translateX(-100%); } }
  .x5wrap { position: relative; margin-bottom: 12px; }
  .x5spin { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; color: #B4A5CE; font-size: 13px; background: rgba(25,16,41,.6); }
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
<div id="playLoading" class="play-loading"><div class="box"><div class="spin"></div>正在解析…</div></div>
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
  // 站内分类/筛选：只用规则真实声明的 class_name/class_url 与
  // sort_name/sort_url（& 并列）。规则的 find_rule 从 MY_URL 的
  // ## 分段读：pp[1] 是分类值、pp[3] 是排序值；area/year 没有
  // 规则消费的分段约定，不渲染假行。'全部' = 空分类值，规则
  // 按首页处理。仅当规则地址含 ## 机制时显示胶囊行。
  var ruleCats = parseRulePairs('class_name', 'class_url');
  var ruleSorts = parseRulePairs('sort_name', 'sort_url');
  var ruleAreas = parseRulePairs('area_name', 'area_url');
  var ruleYears = parseRulePairs('year_name', 'year_url');
  var selectedCls = '';
  var selectedSort = ruleSorts.length ? ruleSorts[0].value : '';
  var selectedArea = '';
  var selectedYear = '';
  function parseRulePairs(nameKey, urlKey) {
    var rule = PROGRAM.rule || {};
    // 分段分隔符：& 并列为主，个别规则用换行并列，两种都认。
    var names = String(rule[nameKey] || '').split(/[&\n]/);
    var urls = String(rule[urlKey] || '').split(/[&\n]/);
    var out = [];
    var n = Math.min(names.length, urls.length);
    for (var i = 0; i < n; i++) {
      var name = String(names[i]).replace(/^\s+|\s+$/g, '');
      var value = String(urls[i]).replace(/^\s+|\s+$/g, '');
      if (name && value) out.push({ name: name, value: value });
    }
    return out;
  }
  function hasCategoryRows() {
    // 只要规则声明了任一筛选对就显示行：以前要求 url 含 ##，
    // 无 ## 的规则分类行直接消失。firstHeader=class 的规则
    // 同样走这里（分类行本来就在最前）。
    return ruleCats.length > 0 || ruleSorts.length > 0 ||
      ruleAreas.length > 0 || ruleYears.length > 0;
  }
  function categoryRowsHtml() {
    if (!hasCategoryRows()) return '';
    var html = '';
    if (ruleCats.length > 0) {
      html += '<div class="cats">';
      html += '<button type="button" class="cat' + (selectedCls === '' ? ' on' : '') + '" onclick="__haikuoSelectCat(-1)">全部</button>';
      ruleCats.forEach(function (c, i) {
        html += '<button type="button" class="cat' + (selectedCls === c.value ? ' on' : '') + '" onclick="__haikuoSelectCat(' + i + ')">' + escapeHtml(c.name) + '</button>';
      });
      html += '</div>';
    }
    if (ruleSorts.length > 0) {
      html += '<div class="cats sub">';
      ruleSorts.forEach(function (s, i) {
        html += '<button type="button" class="cat' + (selectedSort === s.value ? ' on' : '') + '" onclick="__haikuoSelectSort(' + i + ')">' + escapeHtml(s.name) + '</button>';
      });
      html += '</div>';
    }
    if (ruleAreas.length > 0) {
      html += '<div class="cats sub">';
      html += '<button type="button" class="cat' + (selectedArea === '' ? ' on' : '') + '" onclick="__haikuoSelectArea(-1)">全部地区</button>';
      ruleAreas.forEach(function (a, i) {
        html += '<button type="button" class="cat' + (selectedArea === a.value ? ' on' : '') + '" onclick="__haikuoSelectArea(' + i + ')">' + escapeHtml(a.name) + '</button>';
      });
      html += '</div>';
    }
    if (ruleYears.length > 0) {
      html += '<div class="cats sub">';
      html += '<button type="button" class="cat' + (selectedYear === '' ? ' on' : '') + '" onclick="__haikuoSelectYear(-1)">全部年份</button>';
      ruleYears.forEach(function (y, i) {
        html += '<button type="button" class="cat' + (selectedYear === y.value ? ' on' : '') + '" onclick="__haikuoSelectYear(' + i + ')">' + escapeHtml(y.name) + '</button>';
      });
      html += '</div>';
    }
    return html;
  }
  // ---------- 加载反馈与取数缓存 ----------
  // 规则脚本里的 fetch() 是同步 XHR：脚本一跑，WebView 在取数回来
  // 之前画不出任何东西，点分类/点播放看起来像“死了几秒”。所以
  // 导航与解析都先画加载态、再把执行让到下一个任务，让浏览器
  // 先把加载态画出来。没有 setTimeout 的求值环境（桩验沙箱）
  // 同步执行，行为不变。navToken 保证连点时只有最后一次导航
  // 真正执行，早到的延迟任务直接丢弃。
  var navToken = 0;
  function defer(fn) {
    if (typeof setTimeout === 'function') { setTimeout(fn, 30); }
    else { fn(); }
  }
  function loadingHtml() {
    return (isDetail ? '' : categoryRowsHtml()) +
      '<div class="loading"><div class="spin"></div>正在加载…</div>';
  }
  function showListLoading() { listEl.innerHTML = loadingHtml(); }
  // 规则调的 showLoading(text)/hideLoading：全屏遮罩 + 可选文字，
  // 与内部列表加载态分开（以前同名函数只在 IIFE 局部，规则调不到）。
  function showLoading(text) {
    var el = document.getElementById('playLoading');
    if (!el) return;
    var box = el.querySelector ? el.querySelector('.box') : null;
    if (box) {
      var label = text === undefined || text === null || text === '' ? '正在加载…' : String(text);
      box.innerHTML = '<div class="spin"></div>' + escapeHtml(label);
    }
    el.style.display = 'flex';
  }
  function hideLoading() { showPlayLoading(false); }
  function showPlayLoading(show) {
    var el = document.getElementById('playLoading');
    if (el && el.style) el.style.display = show ? 'flex' : 'none';
  }
  // 本次打开内的 GET 响应缓存：来回切分类不再重复全量取数。
  // 只缓存 GET 成功响应；POST 与失败响应不缓存。条目 60 秒过期，
  // 最多 60 条、单条超过 2MB 不缓存；页面重载即失效。
  var fetchCache = {};
  var fetchCacheKeys = [];
  var FETCH_CACHE_MAX = 60;
  var FETCH_CACHE_TTL_MS = 60000;
  var FETCH_CACHE_MAX_BODY = 2 * 1024 * 1024;
  function fetchCacheKey(method, url, headers) {
    return method + '\n' + url + '\n' + JSON.stringify(headers || {});
  }
  var lastResponseHeaders = {};
  function fetchCacheGet(key) {
    var hit = fetchCache[key];
    if (!hit) return null;
    if (Date.now() - hit.at > FETCH_CACHE_TTL_MS) {
      delete fetchCache[key];
      return null;
    }
    resCode = hit.code;
    lastResponseHeaders = hit.headers || {};
    return hit.body;
  }
  function fetchCachePut(key, code, body, headers) {
    if (body == null || body.length > FETCH_CACHE_MAX_BODY) return;
    if (!Object.prototype.hasOwnProperty.call(fetchCache, key)) {
      fetchCacheKeys.push(key);
      while (fetchCacheKeys.length > FETCH_CACHE_MAX) {
        delete fetchCache[fetchCacheKeys.shift()];
      }
    }
    fetchCache[key] = { code: code, body: body, headers: headers || {}, at: Date.now() };
  }
  function reloadHome() {
    clearPageTasks();
    // ## 规则保持原样：hiker://empty##分类##页##排序（规则按分段自取）。
    // 非 ## 规则把筛选值挂在首页地址的 ## 分段后：# 后是片段，
    // 不会发给服务器，fetch(MY_URL) 仍取首页地址，脚本按分段
    // 读分类/排序/地区/年份；分段约定 pp[1]分类 pp[2]页 pp[3]排序
    // pp[4]地区 pp[5]年份，同时 fyclass/fyarea/fyyear 全局变量同步。
    var base = homeUrl();
    var url;
    if (base.indexOf('##') >= 0 || base === '' || base.indexOf('hiker://') === 0) {
      url = 'hiker://empty##' + selectedCls + '##1' + (selectedSort ? '##' + selectedSort : '') +
        (selectedArea ? '##' + selectedArea : '') + (selectedYear ? '##' + selectedYear : '');
    } else {
      url = base + '##' + selectedCls + '##1' + (selectedSort ? '##' + selectedSort : '') +
        (selectedArea ? '##' + selectedArea : '') + (selectedYear ? '##' + selectedYear : '');
    }
    setGlobals(url, 1);
    try { window.fyclass = selectedCls; window.fyarea = selectedArea; window.fyyear = selectedYear; } catch (e) {}
    syncFilterGlobals();
    navStack.length = 0;
    showBack(false);
    isDetail = false;
    var token = ++navToken;
    showListLoading();
    defer(function () {
      if (token !== navToken) return;
      runPrerule();
      runSource(PROGRAM.script);
    });
  }
  window.__haikuoSelectCat = function (index) {
    selectedCls = index < 0 ? '' : (ruleCats[index] ? ruleCats[index].value : '');
    reloadHome();
  };
  window.__haikuoSelectSort = function (index) {
    selectedSort = ruleSorts[index] ? ruleSorts[index].value : '';
    reloadHome();
  };
  window.__haikuoSelectArea = function (index) {
    selectedArea = index < 0 ? '' : (ruleAreas[index] ? ruleAreas[index].value : '');
    reloadHome();
  };
  window.__haikuoSelectYear = function (index) {
    selectedYear = index < 0 ? '' : (ruleYears[index] ? ruleYears[index].value : '');
    reloadHome();
  };
  function selectedCatName() {
    if (selectedCls === '') return '';
    for (var i = 0; i < ruleCats.length; i++) {
      if (ruleCats[i].value === selectedCls) return ruleCats[i].name;
    }
    return '';
  }
  // 集数徽标：只认条目自带的信息——显式集数字段，或 desc/备注里
  // 的“共N集/更新至N集/全N集”；没有就不显示，绝不编一个数。
  function episodeBadge(it) {
    if (!it) return '';
    var n = it.episodeCount || it.totalEpisodes || it.episodes;
    if (typeof n === 'number' && n > 0) return '共' + n + '集';
    var text = String(it.desc || it.remarks || it.note || '');
    var m = text.match(/共\s*(\d+)\s*集/) || text.match(/更新至\s*(?:第)?(\d+)\s*集/) ||
      text.match(/全\s*(\d+)\s*集/) || text.match(/(\d+)\s*集\s*全/);
    if (m) return '共' + m[1] + '集';
    return '';
  }

  function native(payload) {
    try { window.HaikuoNative.postMessage(JSON.stringify(payload)); } catch (e) {}
  }
  function say(text) {
    if (!text) return;
    statusEl.style.display = 'block';
    statusEl.textContent = String(text).slice(0, 3000);
  }
  function toast(msg) { native({ type: 'toast', text: String(msg == null ? '' : msg) }); }

  // 完整响应版请求：返回 {body, code, headers}。规则 UA 在此补：
  // 脚本没带 User-Agent 时用规则的 ua 字段；脚本自带头优先。
  // opt.timeout（毫秒，夹在 5 秒到 120 秒之间）、opt.redirect===false、
  // opt.onlyHeaders、opt.toHex、opt.cache===false 都经查询参数
  // 交给 Dart 代理执行；响应头存进 lastResponseHeaders 供
  // withHeaders / getResCode 链路用。
  function rawHttpEx(method, url, opt) {
    opt = opt || {};
    // webview:// 前缀：改走 WebView 取码（带后缀的已在 fetch() 里拆好）。
    if (String(url || '').indexOf('webview://') === 0) {
      var wvHtml = fetchCodeByWebView(String(url).slice(10), opt);
      return { body: wvHtml, code: wvHtml ? 200 : 0, headers: {}, url: String(url || '') };
    }
    // proxy 改写行（`原地址=>新地址`，包含匹配）：改写后地址进缓存键。
    url = applyProxyRewrites(String(url || ''));
    var headers = {};
    var srcHeaders = opt.headers || {};
    for (var hk in srcHeaders) {
      if (Object.prototype.hasOwnProperty.call(srcHeaders, hk)) {
        headers[hk] = String(srcHeaders[hk]);
      }
    }
    var hasUA = false;
    for (var uk in headers) {
      if (String(uk).toLowerCase() === 'user-agent') { hasUA = true; break; }
    }
    var ruleUa = PROGRAM.rule && PROGRAM.rule.ua;
    if (!hasUA && ruleUa) headers['User-Agent'] = String(ruleUa);
    var body = opt.body;
    var bodyWasObject = false;
    if (body !== undefined && body !== null && typeof body !== 'string') {
      bodyWasObject = true;
      try { body = JSON.stringify(body); } catch (e) { body = String(body); }
    }
    // 对象 body 按官方行为自动加 application/json（指南有载）；
    // 规则自带 content-type 时不动（胖大AV 站方缺此头回 415）。
    if (bodyWasObject) {
      var hasCT = false;
      for (var ctk in headers) {
        if (String(ctk).toLowerCase() === 'content-type') { hasCT = true; break; }
      }
      if (!hasCT) headers['Content-Type'] = 'application/json';
    }
    var upperMethod = (method || 'GET').toUpperCase();
    var noCache = opt.cache === false;
    if (!noCache) {
      for (var ck in headers) {
        if (String(ck).toLowerCase() === 'cache-control' &&
            String(headers[ck]).toLowerCase().indexOf('no-cache') >= 0) {
          noCache = true;
        }
      }
    }
    var cacheKey = null;
    if (upperMethod === 'GET' && !noCache && !opt.onlyHeaders && !opt.toHex) {
      cacheKey = fetchCacheKey('GET', url, headers);
      var cached = fetchCacheGet(cacheKey);
      if (cached !== null) return { body: cached, code: resCode, headers: lastResponseHeaders, url: url };
    }
    var timeoutMs = 30000;
    if (typeof opt.timeout === 'number' && isFinite(opt.timeout)) {
      timeoutMs = Math.max(5000, Math.min(120000, Math.floor(opt.timeout)));
    }
    // 字符集：后缀里的优先，其次请求头 Content-Type 里的 charset=。
    var charset = opt.charset || '';
    if (!charset) {
      for (var ck2 in headers) {
        if (String(ck2).toLowerCase() === 'content-type') {
          var cm = /charset=([^;,\s]+)/i.exec(String(headers[ck2]));
          if (cm) charset = cm[1].toLowerCase();
        }
      }
    }
    var query = '/__fetch?m=' + encodeURIComponent(upperMethod) +
      '&u=' + encodeURIComponent(url) +
      '&h=' + encodeURIComponent(JSON.stringify(headers)) +
      '&b=' + encodeURIComponent(body == null ? '' : body) +
      '&t=' + timeoutMs +
      (charset ? '&cs=' + encodeURIComponent(charset) : '') +
      (opt.redirect === false ? '&r=0' : '') +
      (opt.onlyHeaders ? '&o=1' : '') +
      (opt.toHex ? '&hex=1' : '');
    var xhr = new XMLHttpRequest();
    try {
      xhr.open('GET', query, false);
      xhr.send(null);
    } catch (e) {
      say('请求失败：' + url + '\n' + e);
      return { body: '', code: 0, headers: {}, url: url };
    }
    if (xhr.status !== 200) {
      say('请求失败：HTTP ' + xhr.status + '\n' + url);
      return { body: '', code: 0, headers: {}, url: url };
    }
    var text = xhr.responseText || '';
    try {
      var parsed = JSON.parse(text);
      if (parsed && typeof parsed === 'object' && 'body' in parsed) {
        resCode = parsed.code || 0;
        lastResponseHeaders = parsed.headers || {};
        var out = parsed.body == null ? '' : String(parsed.body);
        if (opt.toHex) out = base64ToHex(out);
        if (cacheKey) fetchCachePut(cacheKey, resCode, out, lastResponseHeaders);
        return { body: out, code: resCode, headers: lastResponseHeaders, url: parsed.url || url };
      }
    } catch (e) { /* 不是包装结构，原样返回 */ }
    if (cacheKey) fetchCachePut(cacheKey, resCode, text, {});
    return { body: text, code: resCode, headers: {}, url: url };
  }
  // 规则 proxy 字段的改写行缓存：同一规则对象只解析一次。
  var proxyRewriteCache = { rule: null, list: [] };
  function proxyRewriteList() {
    var rule = PROGRAM.rule;
    if (proxyRewriteCache.rule === rule) return proxyRewriteCache.list;
    var list = [];
    var raw = String((rule && rule.proxy) || '');
    if (raw.indexOf('=>') >= 0) {
      var lines = raw.split(/\r?\n/);
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line) continue;
        var idx = line.indexOf('=>');
        if (idx <= 0) continue;
        var from = line.slice(0, idx).trim();
        var to = line.slice(idx + 2).trim();
        if (from && to) list.push([from, to]);
      }
    }
    proxyRewriteCache = { rule: rule, list: list };
    return list;
  }
  function applyProxyRewrites(url) {
    var list = proxyRewriteList();
    for (var i = 0; i < list.length; i++) {
      var idx = url.indexOf(list[i][0]);
      if (idx >= 0) {
        return url.slice(0, idx) + list[i][1] + url.slice(idx + list[i][0].length);
      }
    }
    return url;
  }
  function base64ToHex(b64) {
    try {
      var bin = atob(String(b64 || ''));
      var hex = '';
      for (var i = 0; i < bin.length; i++) {
        var h = bin.charCodeAt(i).toString(16);
        hex += h.length < 2 ? '0' + h : h;
      }
      return hex;
    } catch (e) { return ''; }
  }
  function rawHttp(method, url, opt) {
    return rawHttpEx(method, url, opt).body;
  }

  // ---------- 海阔虚拟页 hiker:// 解析 ----------
  // 资源标识旗标（官方文档）：请求/比对时自动剥掉，只做标识。
  var PAGE_FLAG_RE = /#(noLoading|noHistory|noRecordHistory|noRefresh|noPre|autoPage|autoCache|cacheOnly|background|pre|immersiveTheme|fullTheme|readTheme|gameTheme|originalSize|ignoreVideo=true|isVideo=true|ignoreImg=true|isMusic=true|ignoreMusic=true|ignoreM3U8|isM3u8|m3u8)#/g;
  function stripFlags(text) {
    return String(text || '').replace(PAGE_FLAG_RE, '');
  }
  function hasFlag(text, name) {
    return String(text || '').indexOf('#' + name + '#') >= 0;
  }
  // 子页引用拆成 路径 + 查询串：查询串供 getParam() 读，不参与
  // 子页匹配（以前查询串计入路径，60 条带查询串的链接全找不到）。
  function splitPageRef(ref) {
    var text = stripFlags(String(ref || ''));
    var qi = text.indexOf('?');
    if (qi < 0) return { path: text, query: '' };
    var query = text.slice(qi + 1);
    var hi = query.indexOf('#');
    if (hi >= 0) query = query.slice(0, hi);
    return { path: text.slice(0, qi), query: query };
  }
  function rulePages() {
    var pages = PROGRAM.rule && PROGRAM.rule.pages;
    if (typeof pages === 'string') {
      try { pages = JSON.parse(pages); } catch (e) { pages = []; }
    }
    return Array.isArray(pages) ? pages : [];
  }
  function findPage(path) {
    var pages = rulePages();
    var ref = splitPageRef(path);
    var want = ref.path;
    var decoded = want;
    try { decoded = decodeURIComponent(want); } catch (e) {}
    for (var i = 0; i < pages.length; i++) {
      if (pages[i] && String(pages[i].path) === want) return pages[i];
    }
    if (decoded !== want) {
      for (var j = 0; j < pages.length; j++) {
        if (pages[j] && String(pages[j].path) === decoded) return pages[j];
      }
    }
    // name 字段兜底：个别规则用子页的 name 引用。
    for (var k = 0; k < pages.length; k++) {
      if (pages[k] && pages[k].name &&
          (String(pages[k].name) === want || String(pages[k].name) === decoded)) {
        return pages[k];
      }
    }
    return null;
  }
  // 规则标题归一（JS 侧，与 Dart normalizeRuleTitle 对应）：
  // 去 🔞、NFKC 折花体/全角、去空白、转小写。
  function normalizeRuleTitleJS(title) {
    var t = String(title == null ? '' : title).replace(/🔞/g, '');
    try { t = t.normalize('NFKC'); } catch (e) {}
    return t.trim().toLowerCase();
  }
  function currentRuleTitle() {
    return String((PROGRAM.rule && (PROGRAM.rule.title || PROGRAM.rule.name)) || '');
  }
  function isCurrentRuleTitle(title) {
    var want = normalizeRuleTitleJS(title);
    return !!want && want === normalizeRuleTitleJS(currentRuleTitle());
  }
  function parseQueryParams(query) {
    var out = {};
    var qs = String(query || '');
    if (!qs) return out;
    var pairs = qs.split('&');
    for (var i = 0; i < pairs.length; i++) {
      var eq = pairs[i].indexOf('=');
      var k = eq >= 0 ? pairs[i].slice(0, eq) : pairs[i];
      var v = eq >= 0 ? pairs[i].slice(eq + 1) : '';
      try { k = decodeURIComponent(k); } catch (e) {}
      try { v = decodeURIComponent(v); } catch (e) {}
      if (k && !(k in out)) out[k] = v;
    }
    return out;
  }
  function pageRuleText(page) {
    var r = page ? page.rule : '';
    if (typeof r === 'string') return r;
    try { return JSON.stringify(r == null ? '' : r); } catch (e) { return ''; }
  }
  // 跨规则取页：Dart 侧 /__rulepage/ 按标题归一匹配，返回
  // {rule, page:{name,path,rule}}；找不到返回 null（不抛错）。
  function fetchRulePageObject(title, path) {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', window.location.origin + '/__rulepage/?rule=' +
        encodeURIComponent(String(title)) + '&path=' + encodeURIComponent(String(path)), false);
      xhr.send(null);
      if (xhr.status !== 200) return null;
      var parsed = JSON.parse(xhr.responseText || '{}');
      if (parsed && parsed.page) return parsed;
      return null;
    } catch (e) { return null; }
  }
  // 跨规则取规则是否存在：/__findrule?title=，返回匹配到的标题或 ''。
  function findRuleTitle(title) {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', window.location.origin + '/__findrule?title=' + encodeURIComponent(String(title)), false);
      xhr.send(null);
      if (xhr.status !== 200) return '';
      var parsed = JSON.parse(xhr.responseText || '{}');
      return parsed && parsed.name ? String(parsed.name) : '';
    } catch (e) { return ''; }
  }
  // 临时切换当前规则上下文（PROGRAM.rule / MY_RULE），执行完恢复。
  // 存储隔离（P0-4）按 MY_RULE.title 实时算键，切换期间自然走目标规则。
  function withRuleContext(ruleObj, fn) {
    var savedRule = PROGRAM.rule;
    var savedMyRule = MY_RULE;
    PROGRAM.rule = ruleObj;
    MY_RULE = ruleObj;
    try { window.MY_RULE = ruleObj; } catch (e) {}
    try { return fn(); }
    finally {
      PROGRAM.rule = savedRule;
      MY_RULE = savedMyRule;
      try { window.MY_RULE = savedMyRule; } catch (e) {}
    }
  }
  // fetch/request 的子页对象模式：hiker://page/… 回 JSON 字符串
  // {name, path, rule}（规则原文，不执行）；不是子页引用返回 null。
  function fetchPageObject(text) {
    var m = /^hiker:\/\/page\/(.+)$/.exec(String(text || ''));
    if (!m) return null;
    var ref = splitPageRef(m[1]);
    var params = parseQueryParams(ref.query);
    if (params.rule && !isCurrentRuleTitle(params.rule)) {
      var fetched = fetchRulePageObject(params.rule, ref.path);
      if (!fetched) {
        say('子页不存在：规则「' + params.rule + '」没有子页 ' + ref.path);
        return '';
      }
      try {
        return JSON.stringify({
          name: fetched.page.name || '',
          path: String(fetched.page.path || ref.path),
          rule: pageRuleText(fetched.page)
        });
      } catch (e) { return ''; }
    }
    var page = findPage(ref.path);
    if (!page) {
      say('子页不存在：' + ref.path);
      return '';
    }
    try {
      return JSON.stringify({
        name: page.name || '',
        path: String(page.path || ref.path),
        rule: pageRuleText(page)
      });
    } catch (e) { return ''; }
  }
  // 直接写 JS 的（如 var d = []; 开头）。以前 runPageRule 只认
  // js: 前缀，裸 JS 会被原样当数据返回，调用方 JSON.parse 拿到
  // 脚本源码就报 Unexpected token 'v'（“国外精品”整页失败即此
  // 形态）。判法只看去注释后的首词：var/let/const/function/
  // return/async 或 $. 调用；JSON 数据（{ [ 开头）、选择器、
  // 纯文本仍走原样返回，数据页行为不变。
  function isBareJsRule(text) {
    var t = String(text == null ? '' : text).replace(/^\uFEFF/, '').trim();
    var guard = 0;
    while (guard++ < 10) {
      if (t.indexOf('//') === 0) {
        var nl = t.indexOf('\n');
        if (nl < 0) { t = ''; break; }
        t = t.slice(nl + 1).trim();
      } else if (t.indexOf('/*') === 0) {
        var end = t.indexOf('*/', 2);
        if (end < 0) { t = ''; break; }
        t = t.slice(end + 2).trim();
      } else { break; }
    }
    if (t === '') return false;
    // JSON 数据（{ [ 开头）与 HTML（< 开头）永远不当 JS 执行。
    var first = t.charAt(0);
    if (first === '{' || first === '[' || first === '<') return false;
    if (/^(var|let|const|function|return|async function|if|for|while|do|switch|try|catch|eval|new|delete|void|typeof|throw|class|await|with|export|import|yield)\b/.test(t)) return true;
    if (t.indexOf('$.') === 0 || t.indexOf('$(') === 0) return true;
    // IIFE 与一元表达式开头：(function… / !function… / +x / -x / ~x。
    if (first === '(' || first === '!' || first === '+' || first === '-' || first === '~') return true;
    // 调用/赋值/取下标语句开头：setResult( / foo = / foo[0]。
    // 选择器首段后跟 && 或空白+标识符，不会撞上这一条；
    // div.card 这类带点的选择器也不在内（点号故意不算）。
    if (/^[A-Za-z_$][\w$]*\s*(\(|=|\[)/.test(t)) return true;
    return false;
  }
  function runPageRule(rule, pageRef) {
    var text = String(rule == null ? '' : rule);
    var trimmed = text.replace(/^\uFEFF/, '').trim();
    // 带查询串的子页引用：执行期间 MY_URL 带上查询串，getParam()
    // 才能读到；执行完恢复原 MY_URL 与 input，不污染外层。
    var ref = splitPageRef(pageRef || '');
    var savedUrl = MY_URL;
    var savedInput = currentInput;
    var switched = false;
    if (ref.query) {
      switched = true;
      setGlobals('hiker://page/' + ref.path + '?' + ref.query, MY_PAGE);
      setCurrentInput(ref.query);
    }
    try {
      if (trimmed.indexOf('js:') === 0 || isBareJsRule(text)) {
        var code = trimmed.indexOf('js:') === 0 ? trimmed.slice(3) : trimmed;
        try {
          var fn = new Function(code);
          var out = fn();
          return out === undefined || out === null ? '' : String(out);
        } catch (error) {
          say('子页执行失败：' + (error && error.message ? error.message : error));
          return '';
        }
      }
      if (trimmed.indexOf('rule:') === 0) return trimmed.slice(5);
      if (/^https?:\/\//.test(trimmed)) return rawHttp('GET', trimmed, {});
      // 声明式子页：含 && 选择器链时按声明式求值（上下文取当前
      // MY_URL 的页面）；求不出结果时回落原样返回，数据页不变。
      if (trimmed.indexOf('&&') >= 0 && trimmed.charAt(0) !== '{' && trimmed.charAt(0) !== '[') {
        var decl = evalDeclarativePage(trimmed);
        if (decl !== null) return decl;
      }
      return text;
    } finally {
      if (switched) { setGlobals(savedUrl, MY_PAGE); setCurrentInput(savedInput); }
    }
  }
  // 声明式子页求值：取当前 MY_URL 的页面 HTML，跑声明式解析，
  // 有条目则返回 JSON 字符串（调用方按 JSON 消费），否则 null。
  function evalDeclarativePage(ruleText) {
    var html = '';
    if (/^https?:\/\//.test(MY_URL)) {
      html = rawHttp('GET', MY_URL, {});
    } else {
      var virtual = resolveVirtual(MY_URL);
      if (typeof virtual === 'string' && virtual) html = virtual;
    }
    if (!html) return null;
    var items = evalDeclarative(html, ruleText);
    if (!items || !items.length) return null;
    try { return JSON.stringify(items); } catch (e) { return null; }
  }
  function resolveVirtual(url) {
    var text = String(url || '');
    if (text.indexOf('hiker://empty') === 0) {
      var idx = text.indexOf('##');
      if (idx >= 0) {
        var rest = text.slice(idx + 2);
        if (/^https?:\/\//.test(rest)) return rawHttp('GET', substituteTemplates(rest), {});
        return rest;
      }
      return '';
    }
    // hiker://files/ 与 hiker://assets/：当次 saveFile 的内容优先，
    // 其次找 Dart 侧 /__files/（运行页收到的文件与预置模块）。
    // crypto-java.js 是规则引用的加密桥模块，壳内合成，不取外文件。
    if (text.indexOf('hiker://files/') === 0 || text.indexOf('hiker://assets/') === 0) {
      var key = stripFlags(text).split('/').pop().split('?')[0];
      try { key = decodeURIComponent(key); } catch (e) {}
      if (key === 'crypto-java.js' && typeof window.__haikuoCryptoJava === 'function') {
        return '$.exports = window.__haikuoCryptoJava();';
      }
      if (typeof savedFiles !== 'undefined' && savedFiles[key] !== undefined) {
        return savedFiles[key];
      }
      var fetched = rawHttp('GET', filesUrl(key), {});
      return fetched || '';
    }
    // hiker://images/<地址>：后缀就是真实图片地址（可能 URL 编码过），
    // 解出来交给调用方当图片地址用。
    if (text.indexOf('hiker://images/') === 0) {
      var inner = stripFlags(text.slice('hiker://images/'.length));
      try { inner = decodeURIComponent(inner); } catch (e) {}
      if (/^https?:\/\//.test(inner)) return inner;
      return '';
    }
    var m = /^hiker:\/\/page\/(.+)$/.exec(stripFlags(text));
    if (m) {
      var ref = splitPageRef(m[1]);
      var page = findPage(ref.path);
      if (page) {
        return runPageRule(page.rule, ref.path + (ref.query ? '?' + ref.query : ''));
      }
      return '';
    }
    if (text.indexOf('hiker://') === 0) return '';
    return null;
  }

  // ---------- 海阔内置函数 ----------
  var searchKeyword = '';
  // 网址模板替换（只对 http(s) 地址与 hiker://empty## 后的 http
  // 地址做；MY_URL 本身的 ## 分段不动，脚本 split 行为不变）。
  function substituteTemplates(url) {
    var out = String(url || '');
    if (/^(hiker|js|data|file|blob):/i.test(out)) return out;
    var page = Number(MY_PAGE || 1) || 1;
    // [firstPage=地址]：第 1 页整条地址换成括号里的，第 2 页起去掉括号。
    var fp = /\[firstPage=([^\]]*)\]/.exec(out);
    if (fp) {
      if (page === 1) out = fp[1];
      else out = out.replace(/\[firstPage=[^\]]*\]/, '');
    }
    // fypage@起值@*步长@：起值 + (页-1)*步长；fypage@偏移：页 + 偏移。
    // 两者都要先于裸 fypage 替换，否则裸替换会把带 @ 的形态截断。
    out = out.replace(/fypage@(-?\d+)@\*(-?\d+)@/g, function (m, s, st) {
      return String(Number(s) + (page - 1) * Number(st));
    });
    out = out.replace(/fypage@(-?\d+)(?!@)/g, function (m, off) {
      return String(page + Number(off));
    });
    out = out.replace(/\bfypage\b/g, String(page));
    out = out.replace(/\bfyclass\b/g, String(selectedCls || ''));
    out = out.replace(/\bfyarea\b/g, String(selectedArea || ''));
    out = out.replace(/\bfyyear\b/g, String(selectedYear || ''));
    out = out.replace(/\bfysort\b/g, String(selectedSort || ''));
    out = out.replace(/fyAll/g, '');
    out = out.replace(/%%/g, '**');
    if (out.indexOf('**') >= 0) out = out.split('**').join(searchKeyword || '');
    out = out.replace(/\{([A-Za-z_][\w]*)\}/g, function (m, name) {
      if (name === 'host') {
        var ruleUrl = String((PROGRAM.rule && PROGRAM.rule.url) || '');
        var hm = /^https?:\/\/([^\/:?#]+)/.exec(ruleUrl);
        if (hm) return hm[1];
        var gv = getVar('host');
        return gv ? gv : m;
      }
      var v = getVar(name);
      return v ? v : m;
    });
    return out;
  }
  // 括号匹配：从 text[start] 处的 `{` 起找配对的 `}`，跳过字符串与转义。
  // 找不到返回 -1。
  function matchBrace(text, start) {
    var depth = 0;
    var inStr = null;
    for (var i = start; i < text.length; i++) {
      var ch = text.charAt(i);
      if (inStr) {
        if (ch === '\\') { i++; continue; }
        if (ch === inStr) inStr = null;
        continue;
      }
      if (ch === '"' || ch === "'") { inStr = ch; continue; }
      if (ch === '{') depth++;
      else if (ch === '}') {
        depth--;
        if (depth === 0) return i;
      }
    }
    return -1;
  }
  // `url;GET|POST;字符集;{头@值&&头2@值2}` 后缀：方法/头/体拆出来，
  // 其余部分当地址。头值里的 .js: 按 JS 求值（input 取地址本身）。
  // 另支持 `?JsonBody={json}`：括号匹配摘出 JSON 作请求体（默认 POST，
  // 补 Content-Type: application/json），JSON 里的占位符照常替换。
  function parseUrlSuffix(url, opt) {
    var text = String(url || '');
    var jsonBody = null;
    var jbIdx = text.search(/[?&]JsonBody=\{/);
    if (jbIdx >= 0) {
      var braceStart = text.indexOf('{', jbIdx);
      var braceEnd = matchBrace(text, braceStart);
      if (braceEnd > braceStart) {
        jsonBody = text.slice(braceStart, braceEnd + 1);
        text = text.slice(0, jbIdx) + text.slice(braceEnd + 1);
      }
    }
    var parts = text.split(';');
    if (parts.length < 2 && jsonBody === null) return { url: text, opt: opt };
    var head = parts[0].replace(/？？/g, '?');
    var method = null;
    var headers = null;
    var body = null;
    var charset = null;
    var valid = jsonBody !== null;
    for (var i = 1; i < parts.length; i++) {
      var seg = parts[i].trim();
      if (/^(get|post|put|delete|head|patch)$/i.test(seg)) {
        method = seg.toUpperCase();
        valid = true;
      } else if (seg.charAt(0) === '{' && seg.slice(-1) === '}') {
        headers = {};
        var inner = seg.slice(1, -1);
        var pairs = inner.split('&&');
        for (var j = 0; j < pairs.length; j++) {
          var at = pairs[j].indexOf('@');
          if (at > 0) {
            var hk = pairs[j].slice(0, at).trim();
            var hv = pairs[j].slice(at + 1).replace(/；；/g, ';');
            if (hv.indexOf('.js:') === 0) {
              hv = evalJsTransform(hv.slice(4), head);
            }
            if (hk) headers[hk] = hv;
          }
        }
        valid = true;
      } else if (/^(utf-?8|gbk|gb2312|gb18030|big5|iso-?8859-?1)$/i.test(seg)) {
        charset = seg.toLowerCase().replace('utf-8', 'utf8').replace('iso-8859-1', 'latin1');
        valid = true;
      } else if (seg !== '') {
        body = seg;
        valid = true;
      }
    }
    if (!valid) return { url: text, opt: opt };
    var merged = {};
    for (var k in opt) {
      if (Object.prototype.hasOwnProperty.call(opt, k)) merged[k] = opt[k];
    }
    if (method) merged.method = method;
    if (charset && merged.charset === undefined) merged.charset = charset;
    if (headers) {
      merged.headers = {};
      var oh = opt.headers || {};
      for (var hk2 in oh) {
        if (Object.prototype.hasOwnProperty.call(oh, hk2)) merged.headers[hk2] = oh[hk2];
      }
      for (var hk3 in headers) merged.headers[hk3] = headers[hk3];
    }
    if (jsonBody !== null) {
      merged.body = substituteTemplates(jsonBody);
      if (!method && merged.method === undefined) merged.method = 'POST';
      merged.headers = merged.headers || {};
      var hasCt = false;
      for (var hk4 in merged.headers) {
        if (String(hk4).toLowerCase() === 'content-type') hasCt = true;
      }
      if (!hasCt) merged.headers['Content-Type'] = 'application/json';
    } else if (body !== null && merged.body === undefined) {
      merged.body = body;
    }
    return { url: head, opt: merged };
  }
  // `.js:` 变换：先求表达式（return (code)），语法不对再按语句跑，
  // 语句跑完返回 input（规则常写 input = input.replace(…) 这类）。
  function evalJsTransform(code, inputValue) {
    var src = String(code || '');
    try {
      var expr = new Function('input', 'return (' + src + ')');
      var out = expr(inputValue);
      return out === undefined || out === null ? '' : String(out);
    } catch (e1) {
      try {
        var stmt = new Function('input', src + '\n;return input;');
        var out2 = stmt(inputValue);
        return out2 === undefined || out2 === null ? '' : String(out2);
      } catch (e2) {
        say('JS 变换失败：' + (e2 && e2.message ? e2.message : e2));
        return String(inputValue == null ? '' : inputValue);
      }
    }
  }
  // 求值并保留原值（不转字符串）：图片解密、代理服务、批量执行用。
  // 表达式形态先试，失败按语句跑（语句跑完返回 input）。
  function evalJsValue(code, inputValue) {
    var src = String(code || '');
    try {
      var expr = new Function('input', 'return (' + src + ')');
      return expr(inputValue);
    } catch (e1) {
      try {
        var stmt = new Function('input', src + '\n;return input;');
        return stmt(inputValue);
      } catch (e2) {
        say('JS 求值失败：' + (e2 && e2.message ? e2.message : e2));
        return inputValue;
      }
    }
  }
  function fetch(url, opt) {
    opt = opt || {};
    var text = stripFlags(String(url || ''));
    // 子页对象模式：fetch('hiker://page/…') 回 {name,path,rule} 字符串。
    var pageObj = fetchPageObject(text);
    if (pageObj !== null) {
      return wrapFetchResult(pageObj, 0, {}, opt);
    }
    var virtual = resolveVirtual(text);
    if (virtual !== null) {
      return wrapFetchResult(virtual, 0, {}, opt);
    }
    var parsed = parseUrlSuffix(text, opt);
    var target = parsed.url;
    var options = parsed.opt;
    // `.js:` 变换后缀：左边是地址，先取数，再把正文当 input 求右边的 JS。
    var jsIdx = target.indexOf('.js:');
    if (jsIdx > 0) {
      var left = target.slice(0, jsIdx);
      if (/^https?:\/\//.test(left) || left.charAt(0) === '/' || left.indexOf('://') >= 0) {
        var fetched = fetch(substituteTemplates(left), options);
        return evalJsTransform(target.slice(jsIdx + 4), fetched);
      }
    }
    target = substituteTemplates(target);
    var res = rawHttpEx(options.method || 'GET', target, options);
    return wrapFetchResult(res.body, res.code, res.headers, opt, res.url);
  }
  // withHeaders/withStatusCode：按官方文档回 JSON 字符串，
  // 每个头的值都是数组：{body, headers:{'Set-Cookie':['a=b']}}。
  // onlyHeaders：只要响应头不取正文，同样回 JSON 字符串，带
  // statusCode 与跟随重定向后的最终地址 url（包内 4 条规则取
  // .url/.statusCode，旧实现回空串导致 JSON.parse 抛错）。
  function wrapFetchResult(body, code, headers, opt, finalUrl) {
    if (opt.withHeaders || opt.withStatusCode || opt.onlyHeaders) {
      var map = {};
      for (var k in headers) {
        if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
        var v = headers[k];
        map[k] = Array.isArray(v) ? v : [String(v)];
      }
      var obj = { body: body, headers: map };
      if (opt.withStatusCode || opt.onlyHeaders) obj.statusCode = code;
      if (opt.onlyHeaders) obj.url = finalUrl || '';
      try { return JSON.stringify(obj); } catch (e) { return body; }
    }
    return body;
  }
  function request(url, opt) { return fetch(url, opt); }
  function post(url, body, opt) {
    opt = opt || {};
    opt.method = 'POST';
    opt.body = body;
    return fetch(url, opt);
  }
  // fetchCookie：取数后只抽 Set-Cookie，回 JSON 字符串数组。
  function fetchCookie(url, opt) {
    var res = rawHttpEx((opt && opt.method) || 'GET', substituteTemplates(stripFlags(String(url || ''))), opt || {});
    var cookies = [];
    var headers = res.headers || {};
    for (var k in headers) {
      if (String(k).toLowerCase() === 'set-cookie') {
        var v = headers[k];
        if (Array.isArray(v)) cookies = cookies.concat(v);
        else if (v) cookies.push(String(v));
      }
    }
    try { return JSON.stringify(cookies); } catch (e) { return '[]'; }
  }
  function batchFetch(tasks) {
    var out = [];
    var list = Array.isArray(tasks) ? tasks : [];
    for (var i = 0; i < list.length; i++) {
      var task = list[i] || {};
      try { out.push(fetch(task.url, task.options || task)); }
      catch (e) { out.push(''); }
    }
    return out;
  }
  function buildUrl(url, params) {
    var base = String(url || '');
    if (!params) return base;
    var qs = [];
    if (typeof params === 'string') return base + (base.indexOf('?') >= 0 ? '&' : '?') + params;
    for (var k in params) {
      if (Object.prototype.hasOwnProperty.call(params, k)) {
        qs.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(params[k])));
      }
    }
    if (!qs.length) return base;
    return base + (base.indexOf('?') >= 0 ? '&' : '?') + qs.join('&');
  }
  function getResCode() { return resCode; }
  function getUrl() { return MY_URL; }
  function setPageTitle(title) { pageTitle = title || pageTitle; titleEl.textContent = pageTitle; }
  function getPageTitle() { return pageTitle; }
  function log() { say(Array.prototype.slice.call(arguments).join(' ')); }

  // ---------- 解析缓存 ----------
  // 规则常对同一段 HTML 反复调 pdfa/pdfh：列表页整页查多次，每条目
  // 的片段又各查标题/封面/简介多次；原来每次都重跑 DOMParser，
  // 整个列表下来要解析上百次，全堵在 WebView 主线程上。
  // 按字符串同一性缓存最近 4 份解析结果：pdfa/pdfh 只读不改文档，
  // 缓存的文档不会被规则改脏；不同字符串各占一位，互不干扰。
  var parseCache = [];
  function parseDoc(html) {
    var text = String(html == null ? '' : html);
    for (var i = 0; i < parseCache.length; i++) {
      if (parseCache[i].html === text) {
        var hit = parseCache[i];
        parseCache.splice(i, 1);
        parseCache.unshift(hit);
        return hit.doc;
      }
    }
    var doc = new DOMParser().parseFromString(text, 'text/html');
    parseCache.unshift({ html: text, doc: doc });
    if (parseCache.length > 4) parseCache.pop();
    return doc;
  }
  // 选择器链：`a&&b&&c&&Text` 逐级在上一级的结果里查；
  // 最后一段是尾巴（Text/Html/OuterHtml/属性名）还是选择器，
  // 按“已知标签名 → 选择器，其余裸名 → 属性”区分。
  var HTML_TAG_NAMES = { a: 1, div: 1, span: 1, p: 1, img: 1, li: 1, ul: 1, ol: 1, body: 1, html: 1, table: 1, td: 1, tr: 1, th: 1, thead: 1, tbody: 1, h1: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1, section: 1, article: 1, em: 1, i: 1, b: 1, strong: 1, video: 1, source: 1, button: 1, input: 1, form: 1, head: 1, title: 1, meta: 1, link: 1, script: 1, style: 1, dl: 1, dt: 1, dd: 1, nav: 1, header: 1, footer: 1, main: 1, figure: 1, figcaption: 1, label: 1, select: 1, option: 1, textarea: 1, iframe: 1, canvas: 1, svg: 1, pre: 1, code: 1, blockquote: 1, hr: 1, br: 1 };
  function isTailSegment(seg, isOnly) {
    if (isOnly) return false;
    if (seg === 'Text' || seg === 'Html' || seg === 'OuterHtml') return true;
    // 带选择器字符的一定是选择器；裸名且不是标签名的当属性。
    if (/[.#[:\s>+~*,()'"=]/.test(seg)) return false;
    if (/^[A-Za-z_][\w:.-]*$/.test(seg) && !HTML_TAG_NAMES[seg.toLowerCase()]) return true;
    return false;
  }
  function splitChain(rule) {
    var text = String(rule == null ? '' : rule).trim();
    var parts = text.split('&&').map(function (p) { return p.trim(); }).filter(function (p) { return p !== ''; });
    if (!parts.length) return { selectors: ['html'], tail: '' };
    var tail = '';
    if (parts.length > 1 && isTailSegment(parts[parts.length - 1], false)) {
      tail = parts.pop();
    }
    return { selectors: parts.length ? parts : ['html'], tail: tail };
  }
  function splitRule(rule) {
    var chain = splitChain(rule);
    return { css: chain.selectors[0] || 'html', tail: chain.tail };
  }
  // 一段选择器里的 jQuery 伪类与下标后缀：先剥下来，查完再过滤。
  // 支持 :eq(n) :first :last :contains(x) :gt(n) :lt(n) 与末尾 ,N / ,N:M；
  // :not() 留给浏览器原生；查不到的伪类（如 :matches）剥掉后重试，
  // 不让整条规则因一个选择器抛错而回空。
  function parseSelectorSegment(seg) {
    var text = String(seg || '');
    var indexSlice = null;
    var mIdx = /,(-?\d+)(?::(-?\d*))?$/.exec(text);
    if (mIdx) {
      indexSlice = {
        start: parseInt(mIdx[1], 10),
        end: mIdx[2] === undefined ? null : (mIdx[2] === '' ? null : parseInt(mIdx[2], 10)),
        hadColon: mIdx[2] !== undefined
      };
      text = text.slice(0, mIdx.index);
    }
    var filters = [];
    var mContains = /:contains\(([^)]*)\)/.exec(text);
    if (mContains) {
      filters.push({ kind: 'contains', value: mContains[1].replace(/^['"]|['"]$/g, '') });
      text = text.replace(mContains[0], '');
    }
    var mEq = /:eq\((-?\d+)\)/.exec(text);
    if (mEq) { filters.push({ kind: 'eq', value: parseInt(mEq[1], 10) }); text = text.replace(mEq[0], ''); }
    var mGt = /:gt\((-?\d+)\)/.exec(text);
    if (mGt) { filters.push({ kind: 'gt', value: parseInt(mGt[1], 10) }); text = text.replace(mGt[0], ''); }
    var mLt = /:lt\((-?\d+)\)/.exec(text);
    if (mLt) { filters.push({ kind: 'lt', value: parseInt(mLt[1], 10) }); text = text.replace(mLt[0], ''); }
    if (/:first\b/.test(text)) { filters.push({ kind: 'first' }); text = text.replace(/:first\b/, ''); }
    if (/:last\b/.test(text)) { filters.push({ kind: 'last' }); text = text.replace(/:last\b/, ''); }
    return { selector: text.trim() || '*', filters: filters, indexSlice: indexSlice };
  }
  function applyNodeFilters(nodes, parsed) {
    var out = nodes;
    parsed.filters.forEach(function (f) {
      if (f.kind === 'contains') {
        out = out.filter(function (n) { return (n.textContent || '').indexOf(f.value) >= 0; });
      } else if (f.kind === 'eq') {
        var idx = f.value < 0 ? out.length + f.value : f.value;
        out = (idx >= 0 && idx < out.length) ? [out[idx]] : [];
      } else if (f.kind === 'gt') {
        out = out.filter(function (n, i) { return i > f.value; });
      } else if (f.kind === 'lt') {
        out = out.filter(function (n, i) { return i < f.value; });
      } else if (f.kind === 'first') {
        out = out.length ? [out[0]] : [];
      } else if (f.kind === 'last') {
        out = out.length ? [out[out.length - 1]] : [];
      }
    });
    // 下标后缀：,N 取第 N 个（负数从末尾数）；,N: 取 N 之后全部；,N:M 取 [N,M)。
    if (parsed.indexSlice) {
      var s = parsed.indexSlice;
      var len = out.length;
      var start = s.start < 0 ? len + s.start : s.start;
      if (!s.hadColon) {
        out = (start >= 0 && start < len) ? [out[start]] : [];
      } else if (s.end === null) {
        out = out.slice(Math.max(0, start));
      } else {
        var end = s.end < 0 ? len + s.end : s.end;
        out = out.slice(Math.max(0, start), end);
      }
    }
    return out;
  }
  function queryWithin(context, parsed) {
    var nodes = [];
    try {
      nodes = Array.prototype.slice.call(context.querySelectorAll(parsed.selector));
    } catch (e) {
      // 不认识的伪类导致抛错：剥掉除 :not 外的伪类再试一次。
      var cleaned = parsed.selector.replace(/:(?!not\()[a-zA-Z-]+(\([^)]*\))?/g, '');
      try {
        nodes = Array.prototype.slice.call(context.querySelectorAll(cleaned || '*'));
      } catch (e2) { nodes = []; }
    }
    return applyNodeFilters(nodes, parsed);
  }
  function nodesOf(doc, sel) {
    try { return Array.prototype.slice.call(doc.querySelectorAll(sel)); } catch (e) { return []; }
  }
  function chainSelect(contexts, selectors) {
    var current = contexts;
    for (var i = 0; i < selectors.length; i++) {
      var parsed = parseSelectorSegment(selectors[i]);
      var next = [];
      for (var j = 0; j < current.length; j++) {
        var found = queryWithin(current[j], parsed);
        for (var k = 0; k < found.length; k++) next.push(found[k]);
      }
      current = next;
      if (!current.length) break;
    }
    return current;
  }
  function valueOf(node, tail) {
    if (!node) return '';
    if (!tail || tail === 'Text') return (node.textContent || '').trim();
    if (tail === 'Html') return node.innerHTML || '';
    if (tail === 'OuterHtml') return node.outerHTML || '';
    return node.getAttribute ? (node.getAttribute(tail) || '') : '';
  }
  function resolveUrl(rel, base) {
    var value = String(rel || '');
    if (!value) return value;
    if (/^(https?:|hiker:|pics:|toast:|javascript:|data:|file:|#)/i.test(value)) return value;
    try { return new URL(value, base || MY_URL || 'http://localhost/').href; }
    catch (e) { return value; }
  }
  function docOf(html) {
    return typeof html === 'string' ? parseDoc(html) : html;
  }
  function pdfa(html, rule) {
    var chain = splitChain(rule);
    var nodes = chainSelect([docOf(html)], chain.selectors);
    // pdfa 无尾巴时回元素外层 HTML（海阔语义）：调用方再拿它
    // 当 HTML 继续 pdfh 细查；以前回纯文本，嵌套解析全断。
    var tail = chain.tail || 'OuterHtml';
    return nodes.map(function (node) { return valueOf(node, tail); });
  }
  function pdfh(html, rule) {
    var chain = splitChain(rule);
    var nodes = chainSelect([docOf(html)], chain.selectors);
    return valueOf(nodes[0], chain.tail);
  }
  // parseDom（缩写 pd）：按指南与 pdfh 功能一致（取第一个匹配
  // 的值），区别只在属性尾巴（href/src 等）按 baseUrl 补全相对
  // 地址（默认 MY_URL），文本不动。列表形态走 pdfa。
  // 旧实现回数组：规则拿它当字符串用时，空数组恒真吞掉兜底、
  // indexOf 永远 -1（AnySex 首页因此一条视频都出不来）。
  function parseDom(html, rule, baseUrl) {
    var chain = splitChain(rule);
    var nodes = chainSelect([docOf(html)], chain.selectors);
    if (!nodes.length) return '';
    var tail = chain.tail || 'OuterHtml';
    var v = valueOf(nodes[0], tail);
    if (tail && tail !== 'Text' && tail !== 'Html' && tail !== 'OuterHtml') {
      return resolveUrl(v, baseUrl || MY_URL);
    }
    return v;
  }
  function parseDomForHtml(html, rule) { return pdfh(html, rule); }
  function parseDomForArray(html, rule) { return pdfa(html, rule); }
  // ---------- 声明式规则求值 ----------
  // 形态：`列表链;字段段;字段段…`，字段段分两种写法——
  // 具名 `title&&a&&Text` / `pic&&img&&src` / `url&&a&&href`，
  // 位置 `a&&Text`（第 1 段=标题，2=图片，3=简介，4=链接，5=正文）。
  // 字段段尾可带 `.js:` 变换（input=取到的值）。相对地址按 MY_URL 补全。
  var DECL_FIELD_NAMES = { title: 'title', pic: 'pic', pic_url: 'pic', img: 'pic', cover: 'pic', desc: 'desc', remarks: 'desc', note: 'desc', url: 'url', link: 'url', content: 'content', col_type: 'col_type', coltype: 'col_type' };
  var DECL_POSITIONAL = ['', 'title', 'pic', 'desc', 'url', 'content', 'col_type'];
  function evalFieldSegment(contextNode, segment) {
    var seg = String(segment || '').trim();
    if (!seg) return null;
    var jsCode = null;
    var jsIdx = seg.indexOf('.js:');
    if (jsIdx >= 0) {
      jsCode = seg.slice(jsIdx + 4);
      seg = seg.slice(0, jsIdx);
    }
    var parts = seg.split('&&').map(function (p) { return p.trim(); }).filter(function (p) { return p !== ''; });
    if (!parts.length) return null;
    var field = null;
    var chainParts = parts;
    var firstLower = parts[0].toLowerCase();
    if (parts.length > 1 && DECL_FIELD_NAMES[firstLower]) {
      field = DECL_FIELD_NAMES[firstLower];
      chainParts = parts.slice(1);
    }
    var chain = splitChain(chainParts.join('&&'));
    var nodes = chainSelect([contextNode], chain.selectors);
    var value = valueOf(nodes[0], chain.tail);
    if (jsCode !== null) value = evalJsTransform(jsCode, value);
    return { field: field, value: value, chain: chain };
  }
  function evalDeclarative(html, ruleText) {
    var text = String(ruleText || '').trim();
    if (!text || text === '*') return [];
    var doc = docOf(html);
    var segments = text.split(';');
    var listSeg = segments[0].trim();
    var contexts;
    if (listSeg === '' || listSeg === '*') {
      contexts = [doc];
    } else {
      var listChain = splitChain(listSeg);
      contexts = chainSelect([doc], listChain.selectors);
    }
    if (!contexts.length) return [];
    // 只有一条链、没有字段段：当成取值规则，整页算一个条目。
    if (segments.length === 1) {
      var single = valueOf(contexts[0], splitChain(listSeg).tail);
      if (!single) return [];
      return [{ title: single, desc: '', url: MY_URL, col_type: 'text_1' }];
    }
    var items = [];
    for (var i = 0; i < contexts.length; i++) {
      var item = { title: '', pic_url: '', desc: '', url: '' };
      var anyValue = false;
      for (var j = 1; j < segments.length; j++) {
        var res = evalFieldSegment(contexts[i], segments[j]);
        if (!res) continue;
        var field = res.field || DECL_POSITIONAL[j] || null;
        if (!field) continue;
        var v = res.value;
        // 链接段写 `*`：继承上一级地址（当前页 MY_URL）。
        var segCore = String(segments[j]).split('.js:')[0].trim();
        if (field === 'url' && (segCore === '*' || /^url&&\*$/i.test(segCore))) v = MY_URL;
        if (v) anyValue = true;
        if (field === 'pic') {
          item.pic_url = resolveUrl(v, MY_URL);
          item.img = item.pic_url;
        } else if (field === 'url') {
          item.url = resolveUrl(v, MY_URL);
        } else {
          item[field] = v;
        }
      }
      if (anyValue || item.title || item.url) items.push(item);
    }
    return items;
  }
  // 声明式取值（last_chapter_rule 等）：整页按链取第一个值。
  function evalDeclarativeText(html, ruleText) {
    var text = String(ruleText || '').trim();
    if (!text || text === '*') return '';
    var jsIdx = text.indexOf('.js:');
    var jsCode = null;
    if (jsIdx >= 0) {
      jsCode = text.slice(jsIdx + 4);
      text = text.slice(0, jsIdx);
    }
    var chain = splitChain(text);
    var nodes = chainSelect([docOf(html)], chain.selectors);
    var value = valueOf(nodes[0], chain.tail);
    if (jsCode !== null) value = evalJsTransform(jsCode, value);
    return value;
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
  function itemPic(it) {
    var pic = (it && (it.pic || it.img || it.cover || it.pic_url)) || '';
    if (!pic) return '';
    // #ignoreImg=true# 的图不显示。
    if (hasFlag(pic, 'ignoreImg=true')) return '';
    return imageSrc(pic);
  }
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
  // 海报播放键的目标：优先第一集；无选集时，只有头项本身带
  // lazy 解析或直链媒体地址才算可播——普通详情链接点按只会
  // 再次打开详情，不能当播放目标（否则按钮点了没反应）。
  function firstPlayTarget() {
    if (currentEpisodes.length) return currentEpisodes[0];
    if (!headItem) return null;
    var u = String((headItem.url || headItem.link) || '');
    if (u.indexOf('@lazyRule=') >= 0) return headItem;
    if (typeof isMedia === 'function' && isMedia(u)) return headItem;
    return null;
  }
  // 详情选集上下文：被点的条目是当前选集之一时，play 消息带上
  // 全部选集标题 + 序号 + 剧名，原生播放器据此显示选集面板。
  function episodeContext(item) {
    var idx = currentEpisodes.indexOf(item);
    if (idx < 0 && item === headItem && currentEpisodes.length) idx = 0;
    if (idx < 0) return null;
    // playlist 分组：按 cls 里含 playlist 的连续段切分，供播放器参考。
    var groups = [];
    var currentGroup = null;
    for (var i = 0; i < currentEpisodes.length; i++) {
      var cls = itemExtraCls(currentEpisodes[i]);
      var isPlaylist = /(^|\s)playlist(\s|$)/.test(cls);
      var key = isPlaylist ? cls : '';
      if (!currentGroup || currentGroup.key !== key) {
        currentGroup = { key: key, cls: cls, start: i, count: 0 };
        groups.push(currentGroup);
      }
      currentGroup.count++;
    }
    return {
      episodes: currentEpisodes.map(function (ep) { return itemTitle(ep) || '选集'; }),
      index: idx,
      series: detailTitle,
      groups: groups
    };
  }
  // 播放 JSON：{urls:[...], subtitle, lyric, audioUrls, headers, names}。
  // 只认以 `{` 开头、带非空 urls 数组的对象串；其余原样放行。
  function parsePlayJson(text) {
    var t = String(text || '').trim();
    if (t.charAt(0) !== '{') return null;
    try {
      var obj = JSON.parse(t);
      if (!obj || typeof obj !== 'object' || !Array.isArray(obj.urls) || !obj.urls.length) return null;
      var first = String(obj.urls[0] || '');
      if (!first) return null;
      return { url: first, subtitle: obj.subtitle, lyric: obj.lyric, audioUrls: obj.audioUrls, headers: normalizePlayHeaders(obj.headers), names: obj.names };
    } catch (e) { return null; }
  }
  function normalizePlayHeaders(h) {
    if (!h) return null;
    if (typeof h === 'object') {
      var out = {};
      for (var k in h) {
        if (Object.prototype.hasOwnProperty.call(h, k)) out[k] = String(h[k]);
      }
      return out;
    }
    if (typeof h === 'string') {
      var out2 = {};
      var parts = h.replace(/；；/g, ';').split(';');
      for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim();
        if (!p) continue;
        var at = p.indexOf('@');
        var colon = p.indexOf(':');
        if (at > 0) out2[p.slice(0, at).trim()] = p.slice(at + 1).trim();
        else if (colon > 0) out2[p.slice(0, colon).trim()] = p.slice(colon + 1).trim();
      }
      return out2;
    }
    return null;
  }
  // 媒体判定（含旗标）：#m3u8#/#isM3u8# 强制认媒体，#ignoreM3U8#
  // 让 m3u8 不认媒体，#isMusic=true# 认音频，#ignoreMusic=true# 拒纯音频。
  function isMediaLink(url, raw) {
    var r = String(raw == null ? url : raw);
    if (hasFlag(r, 'ignoreM3U8') && /\.m3u8(\?|#|$)/i.test(String(url))) return false;
    if (hasFlag(r, 'm3u8') || hasFlag(r, 'isM3u8')) return true;
    if (hasFlag(r, 'isMusic=true')) return true;
    if (hasFlag(r, 'ignoreMusic=true')) {
      var u = String(url);
      if (/\.(mp3|m4a|flac|wav|ogg|aac|wma)(\?|#|$)/i.test(u) &&
          !/\.(mp4|m3u8|mkv|webm|flv|mov|avi)(\?|#|$)/i.test(u)) return false;
    }
    return isMedia(url);
  }
  function sendPlay(url, item, fromDetail, playExtras) {
    // detail：播放是否从详情页发起。原生据此决定内嵌播放
    // （详情页海报墙就地变播放器）还是推一个新播放页。
    // 详情页内的播放入口（海报播放键、选集点按）显式传 true，
    // 不依赖点击时刻 isDetail 全局变量的状态；列表页不传，
    // 仍按 isDetail 判定、保持推新页。
    var payload = { type: 'play', url: url, title: itemTitle(item), detail: fromDetail === true ? true : isDetail };
    var ctx = episodeContext(item);
    if (ctx) { payload.episodes = ctx.episodes; payload.index = ctx.index; payload.series = ctx.series; }
    // 字幕/弹幕地址随 play 消息带给播放器（条目自带才有，没有不编）。
    if (item) {
      var sub = item.subtitle || item.subtitleUrl || item.subs || item.caption;
      if (sub) payload.subtitle = String(sub);
      var dm = item.danmu || item.danmaku || item.danmuUrl;
      if (dm) payload.danmaku = String(dm);
    }
    if (playExtras) {
      if (playExtras.subtitle) payload.subtitle = String(playExtras.subtitle);
      if (playExtras.lyric) payload.lyric = String(playExtras.lyric);
      if (playExtras.audioUrls) payload.audioUrls = playExtras.audioUrls;
      if (playExtras.headers) payload.headers = playExtras.headers;
    }
    // 历史记录：条目地址优先（点历史回到详情），没有则记播放地址。
    var historyUrl = (item && (item.url || item.link)) || url;
    recordHistoryThrottled(itemTitle(item), historyUrl, item ? itemPic(item) : '');
    native(payload);
  }
  // lazy 解析结果的统一出口：lazyMap、@lazyRule=、嗅探三路共用。
  function handleLazyResult(result, item, fromDetail) {
    if (result === '' || result === null || result === undefined) {
      toast('解析失败');
      return;
    }
    if (typeof result === 'object') {
      // lazyRule 直接回对象：{urls:[...]} 多线路播放形态（胖大AV）。
      if (Array.isArray(result.urls) && result.urls.length) {
        var firstUrl = String(result.urls[0] || '');
        if (firstUrl) {
          sendPlay(stripFlags(firstUrl), item, fromDetail, {
            headers: normalizePlayHeaders(result.headers),
            names: result.names,
            subtitle: result.subtitle,
            lyric: result.lyric,
            audioUrls: result.audioUrls
          });
          return;
        }
      }
      return; // 其他对象形态：函数自己已处理（如内部调了 play）
    }
    if (typeof result !== 'string') return; // 函数自己已处理（如内部调了 play）
    if (!result) { toast('解析失败'); return; }
    var clean = stripFlags(result);
    if (clean.indexOf('toast://') === 0) {
      toast(clean.slice('toast://'.length) || '解析失败');
      return;
    }
    var playJson = parsePlayJson(clean);
    if (playJson) {
      sendPlay(stripFlags(playJson.url), item, fromDetail, playJson);
      return;
    }
    if (clean.indexOf('hiker://') === 0 || clean.indexOf('pics://') === 0 ||
        clean.indexOf('novel://') === 0 ||
        clean.indexOf('video://') === 0 || clean.indexOf('webRule://') === 0 ||
        clean.indexOf('x5Rule://') === 0) {
      openItem({ url: clean, title: itemTitle(item), extra: item ? item.extra : null }, fromDetail);
      return;
    }
    if (isMediaLink(clean, result) || hasFlag(result, 'isVideo=true')) {
      sendPlay(clean, item, fromDetail);
      return;
    }
    if (/^https?:\/\//.test(clean)) {
      native({ type: 'open', url: clean, title: itemTitle(item) });
      return;
    }
    renderText(clean);
  }
  // 长按菜单（extra.longClick）：500ms 触摸长按或右键菜单触发，
  // 选标题后把标题写进 input、执行该项 js，js 返回地址则走 openItem。
  // 无 longClick 的条目不绑任何监听，点按行为完全不变。
  function bindLongClick(el, item, fromDetail) {
    var menu = item && item.extra && item.extra.longClick;
    if (!Array.isArray(menu) || !menu.length) return;
    var showMenu = function () {
      var titles = menu.map(function (m) { return String((m && m.title) || ''); });
      var idx = dialogSelect('请选择', titles);
      if (idx < 0 || idx >= menu.length) return;
      var entry = menu[idx] || {};
      setCurrentInput(titles[idx]);
      var js = entry.js;
      if (typeof js === 'function') {
        try {
          var out = js(titles[idx]);
          if (typeof out === 'string' && out) openItem({ url: out, title: titles[idx] }, fromDetail);
        } catch (e) { say('执行失败：' + e); }
      } else if (typeof js === 'string' && js) {
        try {
          var res = (0, eval)(js);
          if (typeof res === 'string' && res) openItem({ url: res, title: titles[idx] }, fromDetail);
        } catch (e) { say('执行失败：' + e); }
      }
    };
    el.addEventListener('contextmenu', function (ev) {
      if (ev && ev.preventDefault) ev.preventDefault();
      el.__hkLongPressed = true;
      showMenu();
    });
    var timer = null;
    var startX = 0, startY = 0;
    el.addEventListener('touchstart', function (ev) {
      if (timer) clearTimeout(timer);
      var t = ev && ev.touches && ev.touches[0];
      startX = t ? t.clientX : 0; startY = t ? t.clientY : 0;
      timer = setTimeout(function () {
        timer = null;
        el.__hkLongPressed = true;
        showMenu();
      }, 500);
    });
    var cancel = function () { if (timer) { clearTimeout(timer); timer = null; } };
    el.addEventListener('touchend', cancel);
    el.addEventListener('touchcancel', cancel);
    el.addEventListener('touchmove', function (ev) {
      var t = ev && ev.touches && ev.touches[0];
      if (t && (Math.abs(t.clientX - startX) > 10 || Math.abs(t.clientY - startY) > 10)) cancel();
    });
  }
  function openItem(item, fromDetail, clickIndex) {
    if (!item) return;
    var rawUrl = item.url || item.link || '';
    if (!rawUrl) return;
    var url = stripFlags(rawUrl);
    // fyIndex：点击时替换成被点条目的下标。
    if (clickIndex !== undefined && clickIndex !== null && url.indexOf('fyIndex') >= 0) {
      url = url.split('fyIndex').join(String(clickIndex));
    }
    // 收藏/历史里别规则的条目：交给原生开那个规则的运行页并进详情。
    if (item && item.extra && item.extra.__hkRule && !isCurrentRuleTitle(item.extra.__hkRule)) {
      native({ type: 'openRule', rule: String(item.extra.__hkRule), url: rawUrl, title: itemTitle(item) });
      return;
    }
    // 播放 JSON 串：urls[0] 播，字幕/歌词/头随消息带给播放器。
    var playJson = parsePlayJson(url);
    if (playJson) {
      sendPlay(stripFlags(playJson.url), item, fromDetail, playJson);
      return;
    }
    // 跨规则子页链接：?rule= 指向别的规则，在目标规则上下文里执行。
    var pageMatch = /^hiker:\/\/page\/(.+)$/i.exec(url);
    if (pageMatch) {
      var crossRef = splitPageRef(pageMatch[1]);
      var crossParams = parseQueryParams(crossRef.query);
      if (crossParams.rule && !isCurrentRuleTitle(crossParams.rule)) {
        var fetched = fetchRulePageObject(crossParams.rule, crossRef.path);
        if (fetched && fetched.page) {
          var crossText = withRuleContext(fetched.rule || {}, function () {
            return runPageRule(pageRuleText(fetched.page), crossRef.path + (crossRef.query ? '?' + crossRef.query : ''));
          });
          if (crossText) { renderVirtual(crossText, url); return; }
        }
        say('子页不存在：规则「' + crossParams.rule + '」没有子页 ' + crossRef.path);
        return;
      }
    }
    // 相对地址按当前 http 页补全（MY_URL 是虚拟地址时不动）。
    if (url.charAt(0) === '/' && /^https?:\/\//.test(MY_URL)) {
      url = resolveUrl(url, MY_URL);
    }
    // @lazyRule= 嵌入式播放：代码以 base 为 input 求值，结果走统一出口。
    // 代码形态有三种：JS 代码、纯地址、声明式选择器（全角 ＆＆＆＆ 先转半角）。
    var lazyIdx = url.indexOf('@lazyRule=');
    if (lazyIdx >= 0) {
      var lazyBase = url.slice(0, lazyIdx);
      var lazyCode = url.slice(lazyIdx + '@lazyRule='.length).replace(/＆/g, '&');
      if (lazyCode.indexOf('.js:') === 0) lazyCode = lazyCode.slice(4);
      else if (lazyCode.indexOf('js:') === 0) lazyCode = lazyCode.slice(3);
      var lazyQuiet = hasFlag(rawUrl, 'noLoading');
      if (!lazyQuiet) showPlayLoading(true);
      defer(function () {
        try {
          setCurrentInput(lazyBase);
          var result;
          if (/^https?:\/\//.test(lazyCode)) {
            result = lazyCode;
          } else if (lazyCode.indexOf('&&') >= 0 && !/function|=>|\breturn\b|\bvar\b|\blet\b|\bconst\b|\$\.|===|==|\?/.test(lazyCode)) {
            // 声明式选择器：取 base 页内容，跑选择器链取结果。
            var lazyHtml = '';
            try { lazyHtml = fetch(lazyBase); } catch (e) { lazyHtml = ''; }
            var lazyDoc = parseDoc(lazyHtml);
            var lazyEval = lazyDoc ? evalFieldSegment(lazyDoc, lazyCode) : null;
            result = lazyEval ? lazyEval.value : '';
          } else {
            result = evalJsTransform(lazyCode, lazyBase);
          }
          handleLazyResult(result, item, fromDetail);
        } catch (error) { say('执行失败：' + error); }
        finally { if (!lazyQuiet) showPlayLoading(false); }
      });
      return;
    }
    // @rule= 动态规则链接：取 base 页内容，代码以内容为 input 求解析。
    var ruleIdx = url.indexOf('@rule=');
    if (ruleIdx >= 0) {
      var ruleBase = url.slice(0, ruleIdx);
      var ruleCode = url.slice(ruleIdx + '@rule='.length).replace(/＆/g, '&');
      if (ruleCode.indexOf('.js:') === 0) ruleCode = ruleCode.slice(4);
      else if (ruleCode.indexOf('js:') === 0) ruleCode = ruleCode.slice(3);
      navStack.push({ url: MY_URL, page: MY_PAGE });
      setGlobals(ruleBase, 1);
      showBack(true);
      isDetail = false;
      showListLoading();
      defer(function () {
        var content = '';
        try { content = fetch(ruleBase); } catch (e) { content = ''; }
        setCurrentInput(content);
        try {
          var out = evalJsTransform(ruleCode, content);
          if (typeof out === 'string' && out) {
            try {
              var parsed = JSON.parse(out);
              if (Array.isArray(parsed)) { render(parsed); return; }
            } catch (e) { /* 不是数组就当文本 */ }
            renderText(out);
          }
        } catch (error) { say('执行失败：' + error); }
      });
      return;
    }
    if (url.indexOf('hiker://lazy#') === 0) {
      var entry = lazyMap[url.slice('hiker://lazy#'.length)];
      if (entry) {
        // 解析是同步 XHR 链：先亮遮罩、再延迟执行，让浏览器
        // 先把“正在解析”画出来；遮罩在解析结束时一定撤掉。
        // #noLoading# 旗标压住遮罩。点击前先把绑定的 input 写进全局。
        var quiet = hasFlag(rawUrl, 'noLoading');
        if (!quiet) showPlayLoading(true);
        defer(function () {
          try {
            if (typeof entry === 'function') {
              handleLazyResult(entry(), item, fromDetail);
            } else {
              setCurrentInput(entry.input === undefined ? '' : entry.input);
              handleLazyResult(entry.fn(entry.input), item, fromDetail);
            }
          } catch (error) { say('执行失败：' + error); }
          finally { if (!quiet) showPlayLoading(false); }
        });
      }
      return;
    }
    if (handleLinkScheme(url, item, fromDetail)) return;
    if (/^hiker:\/\//i.test(url)) {
      if (url.indexOf('hiker://empty') === 0) return; // 占位行，什么都不做
      var pageUrl = url;
      // extra.url：子页链接带上 url 参数，子页里 getParam('url') 可读。
      if (item && item.extra && item.extra.url && /^hiker:\/\/page\//i.test(url)) {
        pageUrl = url + (url.indexOf('?') >= 0 ? '&' : '?') + 'url=' + encodeURIComponent(String(item.extra.url));
      }
      var virtual = resolveVirtual(pageUrl);
      if (virtual) { renderVirtual(virtual, url); return; }
      return;
    }
    // 有详情规则时，点卡片进详情页（跑 detail_find_rule），
    // 而不是直接开原站网页——否则详情页与播放入口永远到不了。
    if (/^https?:\/\//.test(url) && !isMediaLink(url, rawUrl) && !hasFlag(rawUrl, 'isVideo=true') && hasDetailRule()) {
      openDetail(url);
      return;
    }
    if (isMediaLink(url, rawUrl) || hasFlag(rawUrl, 'isVideo=true')) {
      if (!hasFlag(rawUrl, 'ignoreVideo=true')) { sendPlay(url, item, fromDetail); return; }
    }
    native({ type: 'open', url: url, title: itemTitle(item) });
  }
  // 虚拟页结果渲染：JSON 数组按列表渲染（用子页自己的 col_type），
  // 否则当文本显示。
  function renderVirtual(text, url) {
    preResultItems = [];
    var trimmed = String(text || '').trim();
    if (trimmed.charAt(0) === '[') {
      try {
        var items = JSON.parse(trimmed);
        if (Array.isArray(items)) {
          var colType = '';
          var m = /^hiker:\/\/page\/([^?#]+)/.exec(url || '');
          if (m) {
            var page = findPage(m[1]);
            if (page && page.col_type) colType = String(page.col_type);
          }
          isDetail = false;
          render(items, colType);
          return;
        }
      } catch (e) { /* 不是合法数组，往下当文本 */ }
    }
    renderText(text);
  }
  // 链接路由（官方文档）：各 scheme 在此分流；返回 true 表示已处理。
  function handleLinkScheme(url, item, fromDetail) {
    if (url.indexOf('toast://') === 0) {
      toast(decodeURIComponentSafe(url.slice('toast://'.length)));
      return true;
    }
    if (url.indexOf('copy://') === 0) {
      var copyText = url.slice('copy://'.length);
      var jsIdx = copyText.indexOf('.js:');
      if (jsIdx >= 0) copyText = evalJsTransform(copyText.slice(jsIdx + 4), copyText.slice(0, jsIdx));
      native({ type: 'copy', text: copyText });
      toast('已复制');
      return true;
    }
    if (url.indexOf('javascript:') === 0) {
      try { (0, eval)(url.slice('javascript:'.length)); } catch (e) { say('执行失败：' + e); }
      return true;
    }
    if (url.indexOf('pics://') === 0) {
      renderGallery(url.slice('pics://'.length).split('&&').filter(function (s) { return s; }));
      return true;
    }
    if (url.indexOf('novel://') === 0) {
      // 小说正文：走播放消息，原生侧按 novel:// 分流进阅读器
      // （与视频同一入口，列表/详情/搜索结果点按一致）。
      sendPlay(url, item, fromDetail);
      return true;
    }
    if (url.indexOf('download://') === 0) {
      native({ type: 'download', url: url.slice('download://'.length), title: itemTitle(item) });
      return true;
    }
    if (url.indexOf('x5Play://') === 0) {
      sendPlay(url.slice('x5Play://'.length), item, fromDetail);
      return true;
    }
    if (url.indexOf('x5://') === 0 || url.indexOf('web://') === 0) {
      var webUrl = url.replace(/^(x5|web):\/\//, '');
      if (!/^https?:\/\//.test(webUrl)) webUrl = 'https://' + webUrl;
      native({ type: 'open', url: webUrl, title: itemTitle(item) });
      return true;
    }
    if (url.indexOf('x5WebView://') === 0) {
      // 页里已有 x5 单行网页时刷新它，否则按普通网页打开。
      var x5Url = url.slice('x5WebView://'.length);
      if (!/^https?:\/\//.test(x5Url)) x5Url = 'https://' + x5Url;
      if (x5Frame()) { refreshX5WebView(x5Url); return true; }
      native({ type: 'open', url: x5Url, title: itemTitle(item) });
      return true;
    }
    if (url.indexOf('webview://') === 0) {
      // 点击形态：去掉前缀后按普通链接重走（取数形态走 rawHttpEx）。
      openItem({ url: url.slice('webview://'.length), title: itemTitle(item), extra: item ? item.extra : null }, fromDetail);
      return true;
    }
    if (url.indexOf('func://background') === 0) {
      native({ type: 'pop' });
      return true;
    }
    if (url.indexOf('rule://') === 0 || url.indexOf('海阔视界') === 0) {
      native({ type: 'importCode', text: url });
      return true;
    }
    if (url.indexOf('video://') === 0 || url.indexOf('webRule://') === 0 || url.indexOf('x5Rule://') === 0) {
      startSniff(url, item, fromDetail);
      return true;
    }
    if (url.indexOf('input://') === 0) {
      openInputDialog(url.slice('input://'.length));
      return true;
    }
    if (url.indexOf('confirm://') === 0) {
      var rest = url.slice('confirm://'.length);
      var cIdx = rest.indexOf('.js:');
      var cText = cIdx >= 0 ? rest.slice(0, cIdx) : rest;
      var cCode = cIdx >= 0 ? rest.slice(cIdx + 4) : '';
      if (dialogConfirm(cText, '')) {
        if (cCode) {
          try { setCurrentInput(cText); (0, eval)(cCode); } catch (e) { say('执行失败：' + e); }
        }
      }
      return true;
    }
    if (url.indexOf('select://') === 0) {
      openSelectDialog(url.slice('select://'.length));
      return true;
    }
    if (url.indexOf('share://') === 0) {
      native({ type: 'copy', text: url.slice('share://'.length) });
      toast('链接已复制，可分享给他人');
      return true;
    }
    if (url.indexOf('openFile://') === 0) {
      var fileText = resolveVirtual(url.slice('openFile://'.length));
      if (fileText) renderText(fileText);
      return true;
    }
    if (url.indexOf('editFile://') === 0) {
      toast('暂不支持在应用内编辑文件');
      return true;
    }
    if (url.indexOf('fileSelect://') === 0) {
      native({ type: 'pickFile', code: url.slice('fileSelect://'.length) });
      return true;
    }
    if (url.indexOf('hiker://search') === 0) {
      var q = splitPageRef(url).query;
      var params = parseQuery(q);
      native({ type: 'openSearch', keyword: params.s || '', rule: params.rule || '', group: params.group || '', auto: params.simple === 'false' });
      return true;
    }
    if (url.indexOf('hiker://home') === 0) {
      var atIdx = url.indexOf('@');
      if (atIdx > 0) {
        // hiker://home@规则1||规则2||http://…：按序取第一个存在的规则，
        // 都没有则开最后的网址；都没有且无网址时提示。
        var candidates = url.slice(atIdx + 1).split('||');
        var opened = false;
        for (var ci = 0; ci < candidates.length; ci++) {
          var cand = candidates[ci].trim();
          if (!cand) continue;
          if (/^https?:\/\//.test(cand)) {
            native({ type: 'open', url: cand, title: itemTitle(item) });
            opened = true;
            break;
          }
          var found = findRuleTitle(cand);
          if (found) {
            native({ type: 'openRule', rule: found, url: '', title: '' });
            opened = true;
            break;
          }
        }
        if (!opened) toast('没有找到可用的规则或地址');
      } else {
        reloadHome();
      }
      return true;
    }
    if (url.indexOf('hiker://page/push') === 0) {
      var pushParams = parseQuery(splitPageRef(url).query);
      var pushUrl = pushParams.pushurl || pushParams.url || '';
      if (pushUrl) {
        pushNavigate(pushUrl);
      }
      return true;
    }
    if (url.indexOf('hiker://page/list') === 0) {
      var listPage = findPage('list');
      if (listPage) {
        var listText = runPageRule(listPage.rule, 'list');
        if (listText) { renderVirtual(listText, url); return true; }
      }
      reloadHome();
      return true;
    }
    if (url.indexOf('hiker://page/search') === 0) {
      var searchPage = findPage('search');
      if (searchPage) {
        var searchText = runPageRule(searchPage.rule, 'search');
        if (searchText) { renderVirtual(searchText, url); return true; }
      }
      native({ type: 'openSearch', keyword: '', rule: '', group: '', auto: false });
      return true;
    }
    if (url.indexOf('hiker://collection') === 0 || url.indexOf('hiker://history') === 0 || url.indexOf('hiker://bookmark') === 0) {
      var kind = url.indexOf('hiker://history') === 0 ? 'history' : (url.indexOf('hiker://bookmark') === 0 ? 'bookmark' : 'collection');
      renderCollectionList(kind, splitPageRef(url).query);
      return true;
    }
    if (url.indexOf('hiker://setting') === 0) {
      toast('暂不支持打开应用设置页');
      return true;
    }
    if (url.indexOf('hiker://download') === 0) {
      toast('暂不支持打开下载管理页');
      return true;
    }
    if (url.indexOf('hiker://js') === 0) {
      toast('暂不支持打开 JS 管理页');
      return true;
    }
    if (url.indexOf('hiker://adUrl') === 0 || url.indexOf('hiker://adRule') === 0) {
      toast('暂不支持打开广告规则页');
      return true;
    }
    return false;
  }
  function decodeURIComponentSafe(s) {
    try { return decodeURIComponent(s); } catch (e) { return s; }
  }
  function parseQuery(q) {
    var out = {};
    var text = String(q || '');
    if (!text) return out;
    text.split('&').forEach(function (pair) {
      var eq = pair.indexOf('=');
      if (eq > 0) out[decodeURIComponentSafe(pair.slice(0, eq))] = decodeURIComponentSafe(pair.slice(eq + 1));
      else if (pair) out[decodeURIComponentSafe(pair)] = '';
    });
    return out;
  }
  // push 导航：新地址当首页脚本跑，返回栈压入当前页。
  function pushNavigate(pushUrl) {
    clearPageTasks();
    var target = decodeURIComponentSafe(pushUrl);
    navStack.push({ url: MY_URL, page: MY_PAGE });
    setGlobals(target, 1);
    showBack(true);
    isDetail = false;
    showListLoading();
    var token = ++navToken;
    defer(function () {
      if (token !== navToken) return;
      runPrerule();
      runSource(PROGRAM.script);
    });
  }
  // pics:// 多图浏览：图片纵排显示，返回键回首页脚本。
  function renderGallery(urls) {
    if (!urls.length) return;
    navStack.push({ url: MY_URL, page: MY_PAGE });
    showBack(true);
    isDetail = false;
    var html = '<div class="gallery">';
    urls.forEach(function (u) {
      var src = /^https?:\/\//.test(u) ? u : resolveUrl(u, MY_URL);
      html += '<img loading="lazy" src="' + escapeHtml(imageSrc(src)) + '">';
    });
    html += '</div>';
    listEl.innerHTML = html;
  }
  // 嗅探：交给 Dart 侧隐藏 WebView 加载 + 轮询，结果回调 __haikuoSniffResult。
  var sniffSeq = 0;
  var sniffPending = {};
  function startSniff(url, item, fromDetail) {
    var id = 'sniff' + (++sniffSeq);
    var extra = (item && item.extra) || {};
    sniffPending[id] = { item: item, fromDetail: fromDetail, cacheM3u8: !!extra.cacheM3u8 };
    showPlayLoading(true);
    var mode = 'video';
    var js = '';
    var target = url;
    if (url.indexOf('webRule://') === 0 || url.indexOf('x5Rule://') === 0) {
      mode = 'webRule';
      var schemeEnd = url.indexOf('://') + 3;
      var at = url.indexOf('@', schemeEnd);
      if (at < 0) { showPlayLoading(false); toast('嗅探链接格式不对'); return; }
      target = url.slice(schemeEnd, at);
      js = url.slice(at + 1);
      if (js.indexOf('.js:') === 0) js = js.slice(4);
      else if (js.indexOf('js:') === 0) js = js.slice(3);
    } else if (url.indexOf('video://') === 0) {
      target = url.slice('video://'.length);
    }
    native({
      type: 'sniff', id: id, url: target, js: js, mode: mode,
      pageJs: extra.js || '', cacheM3u8: !!extra.cacheM3u8,
      videoRules: extra.videoRules || [], videoExcludeRules: extra.videoExcludeRules || [],
      blockRules: extra.blockRules || [], ua: extra.ua || '', referer: extra.referer || ''
    });
  }
  window.__haikuoSniffResult = function (id, result) {
    showPlayLoading(false);
    var pending = sniffPending[id];
    delete sniffPending[id];
    if (!pending) return;
    if (!result) { toast('嗅探失败，没有找到可播地址'); return; }
    // video:// 附加 cacheM3u8：嗅到的 m3u8 先缓存再播。
    if (pending.cacheM3u8 && /\.m3u8(\?|#|$)/i.test(String(result))) {
      try { result = cacheM3u8(result); } catch (e) {}
    }
    handleLazyResult(result, pending.item, pending.fromDetail);
  };
  window.__haikuoFileSelected = function (path, code) {
    if (!path) return;
    try {
      setCurrentInput(path);
      (0, eval)(String(code || ''));
    } catch (e) { say('执行失败：' + e); }
  };
  // ---------- 原生对话框桥 ----------
  // 同步 XHR 打到 Dart /__dialog：用户点完按钮后响应才回来，
  // 规则的 confirm()/input:// 才能拿到真正的选择结果。
  function dialogRequest(params) {
    var qs = [];
    for (var k in params) {
      if (Object.prototype.hasOwnProperty.call(params, k)) {
        qs.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(params[k])));
      }
    }
    var xhr = new XMLHttpRequest();
    try {
      xhr.open('GET', '/__dialog?' + qs.join('&'), false);
      xhr.send(null);
    } catch (e) { return null; }
    if (xhr.status !== 200) return null;
    try { return JSON.parse(xhr.responseText || 'null'); }
    catch (e) { return null; }
  }
  function dialogConfirm(text, title) {
    var res = dialogRequest({ type: 'confirm', title: title || '', content: String(text || '') });
    return !!(res && res.result === true);
  }
  function dialogAlert(text) {
    dialogRequest({ type: 'alert', content: String(text || '') });
  }
  function dialogInput(value, hint, title) {
    var res = dialogRequest({ type: 'input', value: value || '', hint: hint || '', title: title || '' });
    if (!res) return null;
    return res.result === undefined || res.result === null ? null : String(res.result);
  }
  function dialogSelect(title, options, col) {
    var params = { type: 'select', title: title || '', options: JSON.stringify(options || []) };
    if (col !== undefined && col !== null && col !== '') params.col = String(col);
    var res = dialogRequest(params);
    if (!res) return -1;
    var idx = parseInt(res.result, 10);
    return isNaN(idx) ? -1 : idx;
  }
  // confirm 宿主函数：字符串形态回布尔；对象形态按选择执行
  // confirm/cancel 里的代码串（代码不能引用外层变量，与官方一致）。
  function confirmFn(arg) {
    if (arg !== null && typeof arg === 'object') {
      var ok = dialogConfirm(arg.content || '', arg.title || '');
      var code = ok ? arg.confirm : arg.cancel;
      if (code !== undefined && code !== null && code !== '') {
        try { (0, eval)(String(code)); } catch (e) { say('执行失败：' + e); }
      }
      return ok;
    }
    return dialogConfirm(arg, '');
  }
  function openInputDialog(jsonText) {
    var cfg = {};
    try { cfg = JSON.parse(jsonText); } catch (e) { cfg = {}; }
    var initial = cfg.value || '';
    // value 为空时取剪贴板内容作初始值。
    if (!initial) {
      try {
        var cxhr = new XMLHttpRequest();
        cxhr.open('GET', window.location.origin + '/__clipboard', false);
        cxhr.send(null);
        if (cxhr.status === 200) initial = cxhr.responseText || '';
      } catch (e) {}
    }
    var value = dialogInput(initial, cfg.hint || '', cfg.title || '');
    if (value === null) return;
    if (cfg.js) {
      try {
        setCurrentInput(value);
        (0, eval)(String(cfg.js));
      } catch (e) { say('执行失败：' + e); }
    }
  }
  function openSelectDialog(jsonText) {
    var cfg = {};
    try { cfg = JSON.parse(jsonText); } catch (e) { cfg = {}; }
    var options = Array.isArray(cfg.options) ? cfg.options : [];
    var idx = dialogSelect(cfg.title || '', options, cfg.col);
    if (idx < 0 || idx >= options.length) return;
    if (cfg.js) {
      try {
        setCurrentInput(String(options[idx]));
        (0, eval)(String(cfg.js));
      } catch (e) { say('执行失败：' + e); }
    }
  }
  function renderText(text) {
    listEl.innerHTML = '<div class="empty">' + escapeHtml(String(text).slice(0, 4000)) + '</div>';
  }
  // 当前渲染的条目（updateItem/deleteItem 等动态接口的操作对象，
  // 按条目 extra.id / extra.cls 定位，与官方文档一致）。
  var currentItems = [];
  var currentMode = 'list';
  function itemExtraId(it) {
    return (it && it.extra && it.extra.id !== undefined && it.extra.id !== null) ? String(it.extra.id) : '';
  }
  function itemExtraCls(it) {
    return (it && it.extra && it.extra.cls) ? String(it.extra.cls) : '';
  }
  function rerenderCurrent() {
    var items = currentItems.slice();
    if (currentMode === 'detail') renderDetail(items);
    else render(items);
  }
  function updateItem(id, patch) {
    var found = false;
    for (var i = 0; i < currentItems.length; i++) {
      if (itemExtraId(currentItems[i]) === String(id)) {
        var next = {};
        var old = currentItems[i];
        for (var k in old) {
          if (Object.prototype.hasOwnProperty.call(old, k)) next[k] = old[k];
        }
        if (patch) {
          for (var pk in patch) {
            if (Object.prototype.hasOwnProperty.call(patch, pk)) next[pk] = patch[pk];
          }
        }
        currentItems[i] = next;
        found = true;
        break;
      }
    }
    if (found) rerenderCurrent();
    return found;
  }
  function deleteItem(ids) {
    var list = Array.isArray(ids) ? ids.map(String) : [String(ids)];
    var before = currentItems.length;
    currentItems = currentItems.filter(function (it) { return list.indexOf(itemExtraId(it)) < 0; });
    if (currentItems.length !== before) rerenderCurrent();
  }
  function deleteItemByCls(cls) {
    var wanted = String(cls || '').split(/\s+/).filter(function (s) { return s; });
    var before = currentItems.length;
    currentItems = currentItems.filter(function (it) {
      var classes = itemExtraCls(it).split(/\s+/);
      for (var i = 0; i < wanted.length; i++) {
        if (classes.indexOf(wanted[i]) >= 0) return false;
      }
      return true;
    });
    if (currentItems.length !== before) rerenderCurrent();
  }
  function addItemAfter(id, items) {
    var list = Array.isArray(items) ? items : [items];
    var idx = -1;
    for (var i = 0; i < currentItems.length; i++) {
      if (itemExtraId(currentItems[i]) === String(id)) { idx = i; break; }
    }
    var at = idx >= 0 ? idx + 1 : currentItems.length;
    for (var j = list.length - 1; j >= 0; j--) currentItems.splice(at, 0, list[j]);
    rerenderCurrent();
  }
  function addItemBefore(id, items) {
    var list = Array.isArray(items) ? items : [items];
    var idx = -1;
    for (var i = 0; i < currentItems.length; i++) {
      if (itemExtraId(currentItems[i]) === String(id)) { idx = i; break; }
    }
    var at = idx >= 0 ? idx : 0;
    for (var j = list.length - 1; j >= 0; j--) currentItems.splice(at, 0, list[j]);
    rerenderCurrent();
  }
  function findItem(id) {
    for (var i = 0; i < currentItems.length; i++) {
      if (itemExtraId(currentItems[i]) === String(id)) return currentItems[i];
    }
    return null;
  }
  function findItemsByCls(cls) {
    var wanted = String(cls || '').split(/\s+/).filter(function (s) { return s; });
    return currentItems.filter(function (it) {
      var classes = itemExtraCls(it).split(/\s+/);
      for (var i = 0; i < wanted.length; i++) {
        if (classes.indexOf(wanted[i]) < 0) return false;
      }
      return wanted.length > 0;
    });
  }
  // 前置结果（setPreResult）：先于主结果渲染的固定行（分类头、
  // 搜索行、首屏 loading 占位），与随后 setResult 的主结果拼成
  // 同一页；setPreResult([]) 清掉。每次 runSource 重置，详情页
  // 不拼前置行。指南无此接口定义，语义按包内 10 条规则的实际
  // 用法取最小可信集（见 COVERAGE_MATRIX）。
  var preResultItems = [];
  function setPreResult(items) {
    if (Array.isArray(items)) preResultItems = items.slice();
    else if (items) preResultItems = [items];
    else preResultItems = [];
    if (!resultCapture && !isDetail) render([]);
  }
  function render(items, forcedColType) {
    if (!Array.isArray(items)) items = items ? [items] : [];
    var mainItems = items;
    // 聚合搜索捕获模式：只收条目，不画页面、不动当前状态。
    // 前置行一并捕获（搜索脚本清掉 loading 后前置为空，不污染）。
    if (resultCapture) {
      var cap = (!isDetail && preResultItems.length) ? preResultItems.concat(items) : items;
      for (var ci = 0; ci < cap.length; ci++) resultCapture.push(cap[ci]);
      return;
    }
    currentItems = mainItems.slice();
    if (!isDetail && preResultItems.length) items = preResultItems.concat(items);
    currentMode = isDetail ? 'detail' : 'list';
    currentEpisodes = [];
    detailTitle = '';
    headItem = null;
    if (isDetail) { renderDetail(items); return; }
    var rowsHtml = categoryRowsHtml();
    if (!items.length) {
      listEl.innerHTML = rowsHtml + '<div class="empty"><div class="big">🍃</div>这个页面没有返回内容</div>';
      return;
    }
    var ruleColType = String(forcedColType || (PROGRAM.rule && PROGRAM.rule.col_type) || '');
    // 按有效 col_type 分段：连续同版式的条目画成一组，条目级
    // col_type 优先于规则级（JS 解析结果支持混排，官方语义）。
    var sections = [];
    items.forEach(function (it, index) {
      var col = colTypeOf(it) || ruleColType;
      var last = sections[sections.length - 1];
      if (last && last.col === col && !isSingleBlockCol(col)) {
        last.indexes.push(index);
      } else {
        sections.push({ col: col, indexes: [index] });
      }
    });
    var html = rowsHtml;
    sections.forEach(function (sec) {
      html += sectionHtml(sec.col, sec.indexes, items);
    });
    listEl.innerHTML = html;
    bindX5Frames();
    Array.prototype.forEach.call(listEl.querySelectorAll('[data-index]'), function (el) {
      el.addEventListener('click', function () {
        var idx = Number(el.getAttribute('data-index'));
        if (el.__hkLongPressed) { el.__hkLongPressed = false; return; }
        openItem(items[idx], false, idx);
      });
      bindLongClick(el, items[Number(el.getAttribute('data-index'))], false);
    });
    Array.prototype.forEach.call(listEl.querySelectorAll('.hk-searchrow'), function (el) {
      el.addEventListener('click', function () {
        native({ type: 'openSearch', keyword: '', rule: '', group: '', auto: false });
      });
    });
    Array.prototype.forEach.call(listEl.querySelectorAll('[data-input-index]'), function (el) {
      var btn = el.querySelector('button');
      var inputEl = el.querySelector('input');
      if (!btn || !inputEl) return;
      var submit = function () {
        var it = items[Number(el.getAttribute('data-input-index'))];
        // 聚合搜索：extra.rules 存在时，输入的关键词分发给各规则搜。
        if (it && it.extra && it.extra.rules) {
          runAggregatedSearch(inputEl.value, it.extra.rules, false);
          return;
        }
        var code = String((it && (it.url || it.link)) || '');
        if (!code) return;
        try {
          setCurrentInput(inputEl.value);
          // 输入行 JS 按语句执行（常直接调 setResult/toast）；只有
          // 它显式返回字符串时才走结果出口，避免误报“解析失败”。
          var fn = new Function('input', code);
          var out = fn(inputEl.value);
          if (typeof out === 'string' && out) handleLazyResult(out, it, false);
        } catch (e) { say('执行失败：' + e); }
      };
      btn.addEventListener('click', submit);
      inputEl.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter') submit();
      });
    });
  }
  function isSingleBlockCol(col) {
    return col === 'line' || col === 'line_blank' || col === 'blank_block' ||
      col === 'rich_text' || col === 'long_text' || col === 'input' ||
      col === 'icon_1_search' || col === 'movie_1_vertical_pic' ||
      col === 'movie_1_vertical_pic_blur' || col === 'pic_1_full' ||
      col === 'pic_1_center' || col === 'avatar';
  }
  function markupTitle(raw) {
    // text_1 混色：中文双引号里的字标红、单引号里的字标橙。
    var esc = escapeHtml(raw);
    esc = esc.replace(/“([^”]*)”/g, '<span class="hl-red">$1</span>');
    esc = esc.replace(/‘([^’]*)’/g, '<span class="hl-orange">$1</span>');
    return esc;
  }
  function sanitizeRichHtml(raw) {
    var html = String(raw || '');
    html = html.replace(/<script[\s\S]*?<\/script>/gi, '');
    html = html.replace(/<style[\s\S]*?<\/style>/gi, '');
    html = html.replace(/\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, '');
    html = html.replace(/href\s*=\s*("javascript:[^"]*"|'javascript:[^']*')/gi, 'href="#"');
    // #originalSize#：图片按原尺寸显示（去掉旗标 + 取消最大宽度限制）。
    html = html.replace(/<img\b[^>]*>/gi, function (tag) {
      if (tag.indexOf('#originalSize#') < 0) return tag;
      var t = tag.replace(/#originalSize#/g, '');
      if (/style\s*=\s*"/.test(t)) {
        t = t.replace(/style\s*=\s*"([^"]*)"/, 'style="$1;max-width:none;width:auto"');
      } else if (/style\s*=\s*'/.test(t)) {
        t = t.replace(/style\s*=\s*'([^']*)'/, "style='$1;max-width:none;width:auto'");
      } else {
        t = t.replace(/<img\b/, '<img style="max-width:none;width:auto"');
      }
      return t;
    });
    return html;
  }
  function cardHtml(it, index, marquee) {
    var pic = itemPic(it);
    var rawTitle = itemTitle(it);
    var title = escapeHtml(rawTitle);
    var ph = tileGlyph(rawTitle);
    var descText = itemDesc(it) || selectedCatName();
    var desc = escapeHtml(descText);
    var badge = episodeBadge(it);
    var picHtml = pic
      ? '<img class="pic" loading="lazy" src="' + escapeHtml(pic) + '" onerror="this.className=\'pic placeholder\';this.removeAttribute(\'src\');this.textContent=\'' + ph + '\'">'
      : '<div class="pic placeholder">' + escapeHtml(ph) + '</div>';
    // 跑马灯版式：长标题双份滚动，短标题不动。
    var titleHtml = (marquee && rawTitle.length > 8)
      ? '<div class="title mq"><span>' + title + '</span><span>' + title + '</span></div>'
      : '<div class="title">' + title + '</div>';
    return '<div class="card" data-index="' + index + '">' +
      '<div class="picwrap">' + picHtml +
      (badge ? '<span class="epbadge">' + escapeHtml(badge) + '</span>' : '') +
      '</div>' +
      '<div class="meta">' + titleHtml +
      (desc ? '<div class="desc">' + desc + '</div>' : '') +
      '</div></div>';
  }
  function tileHtml(it, index) {
    var name = itemTitle(it) || '未命名';
    var desc = itemDesc(it);
    return '<div class="tile" data-index="' + index + '">' +
      '<div class="glyph" style="background:' + tileColor(name) + '">' + escapeHtml(tileGlyph(name)) + '</div>' +
      '<div class="t">' + escapeHtml(name) + '</div>' +
      (desc ? '<div class="d">' + escapeHtml(desc) + '</div>' : '') +
      '</div>';
  }
  function extraOf(it) { return (it && it.extra) || {}; }
  // 文本尺寸/行距（long_text/rich_text 的 extra.textSize/lineSpacing）。
  function textStyleExtra(it) {
    var ex = extraOf(it);
    var style = '';
    var fs = parseInt(ex.textSize, 10);
    if (isFinite(fs) && fs > 0) style += 'font-size:' + fs + 'px;';
    var ls = parseInt(ex.lineSpacing, 10);
    if (isFinite(ls)) {
      var base = (isFinite(fs) && fs > 0) ? fs : 16;
      style += 'line-height:' + (base + ls) + 'px;';
    }
    return style;
  }
  // 底部分界线：extra.lineVisible === false 时去掉 textrow 的分隔线。
  function lineVisibleStyle(it) {
    return extraOf(it).lineVisible === false ? 'border-bottom:none;' : '';
  }
  // 卡片背景模糊度：desc 填 0–25 的数字，默认 15。
  function cardBlurPx(it) {
    var n = parseFloat(String((it && it.desc) || ''));
    if (isFinite(n) && n >= 0 && n <= 25) return n;
    return 15;
  }
  function sectionHtml(col, indexes, items) {
    var html = '';
    var i, it, index;
    if (col === 'movie_2') {
      html += '<div class="grid2">';
      for (i = 0; i < indexes.length; i++) html += cardHtml(items[indexes[i]], indexes[i]);
      html += '</div>';
      return html;
    }
    if (col === 'movie_3_marquee') {
      html += '<div class="marquee">';
      for (i = 0; i < indexes.length; i++) html += cardHtml(items[indexes[i]], indexes[i], true);
      html += '</div>';
      return html;
    }
    if (col === 'x5_webview_single') {
      for (i = 0; i < indexes.length; i++) html += x5RowHtml(items[indexes[i]], indexes[i]);
      return html;
    }
    if (col === 'movie_1' || col === 'movie_1_left_pic') {
      html += '<div class="rows">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var pic = itemPic(it);
        html += '<div class="rowitem" data-index="' + index + '">' +
          (pic ? '<img class="thumb' + (col === 'movie_1_left_pic' ? ' wide' : '') + '" loading="lazy" src="' + escapeHtml(pic) + '">' : '') +
          '<div class="rmeta"><div class="rtitle">' + escapeHtml(itemTitle(it)) + '</div>' +
          (itemDesc(it) ? '<div class="rdesc">' + escapeHtml(itemDesc(it)) + '</div>' : '') +
          '</div></div>';
      }
      html += '</div>';
      return html;
    }
    if (col === 'movie_1_vertical_pic' || col === 'movie_1_vertical_pic_blur') {
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var vpic = itemPic(it);
        if (col === 'movie_1_vertical_pic_blur') {
          html += '<div class="vblur" data-index="' + index + '">' +
            (vpic ? '<div class="bg" style="background-image:url(\'' + escapeHtml(vpic) + '\')"></div>' : '') +
            (extraOf(it).gradient ? '<div class="vgrad"></div>' : '') +
            '<div class="fg">' + (vpic ? '<img loading="lazy" src="' + escapeHtml(vpic) + '">' : '') +
            '<div class="vt">' + escapeHtml(itemTitle(it)) + '</div>' +
            (itemDesc(it) ? '<div class="vd">' + escapeHtml(itemDesc(it)) + '</div>' : '') + '</div></div>';
        } else {
          html += '<div class="vpic" data-index="' + index + '">' +
            (vpic ? '<img loading="lazy" src="' + escapeHtml(vpic) + '">' : '') +
            '<div class="vt">' + escapeHtml(itemTitle(it)) + '</div>' +
            (itemDesc(it) ? '<div class="vd">' + escapeHtml(itemDesc(it)) + '</div>' : '') + '</div>';
        }
      }
      return html;
    }
    if (col === 'text_1' || col === 'text_center_1') {
      html += '<div class="textrows">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var lvStyle = lineVisibleStyle(it);
        html += '<div class="textrow' + (col === 'text_center_1' ? ' center' : '') + '" data-index="' + index + '"' + (lvStyle ? ' style="' + lvStyle + '"' : '') + '>' +
          markupTitle(itemTitle(it)) +
          (itemDesc(it) ? '<div class="d" style="font-size:12px;color:#B4A5CE">' + escapeHtml(itemDesc(it)) + '</div>' : '') +
          '</div>';
      }
      html += '</div>';
      return html;
    }
    var textGridMatch = /^text_([2-9])$/.exec(col);
    if (textGridMatch) {
      var cols = parseInt(textGridMatch[1], 10);
      html += '<div class="textgrid" style="grid-template-columns:repeat(' + cols + ',1fr)">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var align = extraOf(it).textAlign;
        var alignStyle = (align === 'left' || align === 'right' || align === 'center') ? ' style="text-align:' + align + '"' : '';
        html += '<div class="tcell" data-index="' + index + '"' + alignStyle + '>' + escapeHtml(itemTitle(it) || '选集') + '</div>';
      }
      html += '</div>';
      return html;
    }
    if (col === 'long_text') {
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var ltStyle = textStyleExtra(it);
        html += '<div class="longtext" data-index="' + index + '"' + (ltStyle ? ' style="' + ltStyle + '"' : '') + '>' + escapeHtml(itemTitle(it)) + '</div>';
      }
      return html;
    }
    if (col === 'rich_text') {
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var rawHtml = String((it && (it.title || it.desc)) || '');
        var rtStyle = textStyleExtra(it);
        html += '<div class="richtext" data-index="' + index + '"' + (rtStyle ? ' style="' + rtStyle + '"' : '') + '>' + sanitizeRichHtml(rawHtml) + '</div>';
      }
      return html;
    }
    if (col === 'pic_3' || col === 'pic_3_square' || col === 'pic_2' || col === 'pic_2_card' || col === 'pic_1' || col === 'pic_1_card') {
      var picCols = (col === 'pic_2' || col === 'pic_2_card') ? 2 : (col === 'pic_1' || col === 'pic_1_card') ? 1 : 3;
      html += '<div class="picgrid" style="grid-template-columns:repeat(' + picCols + ',1fr)">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i];
        var ppic = itemPic(items[index]);
        if (ppic) html += '<img loading="lazy" data-index="' + index + '" src="' + escapeHtml(ppic) + '"' + (col === 'pic_3_square' ? ' style="aspect-ratio:1"' : ' style="aspect-ratio:2/3"') + '>';
      }
      html += '</div>';
      return html;
    }
    if (col === 'pic_1_full' || col === 'pic_1_center') {
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i];
        var fpic = itemPic(items[index]);
        if (!fpic) continue;
        if (col === 'pic_1_full') html += '<img class="picfull" loading="lazy" data-index="' + index + '" src="' + escapeHtml(fpic) + '">';
        else html += '<div class="piccenter" data-index="' + index + '"><img loading="lazy" src="' + escapeHtml(fpic) + '"></div>';
      }
      return html;
    }
    if (/^icon_/.test(col)) {
      var iconCols = col === 'icon_2' || col === 'icon_2_round' ? 2 : col === 'icon_small_3' ? 3 : 4;
      var round = col.indexOf('round') >= 0;
      var small = col.indexOf('small') >= 0;
      html += '<div class="iconrow" style="grid-template-columns:repeat(' + iconCols + ',1fr)">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var ipic = itemPic(it);
        var iname = itemTitle(it) || '未命名';
        html += '<div class="iconitem' + (round ? ' round' : '') + (small ? ' small' : '') + '" data-index="' + index + '">' +
          (ipic ? '<img loading="lazy" src="' + escapeHtml(ipic) + '">'
            : '<div class="iglyph" style="background:' + tileColor(iname) + '">' + escapeHtml(tileGlyph(iname)) + '</div>') +
          '<div class="it">' + escapeHtml(iname) + '</div></div>';
      }
      html += '</div>';
      return html;
    }
    if (col === 'line') {
      for (i = 0; i < indexes.length; i++) html += '<div class="divider"></div>';
      return html;
    }
    if (col === 'line_blank' || col === 'blank_block') {
      for (i = 0; i < indexes.length; i++) html += '<div class="blankblock"></div>';
      return html;
    }
    if (col === 'avatar') {
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var apic = itemPic(it);
        // avatar 的 desc 支持富文本：按富文本清洗后渲染，不转义。
        var aDescRaw = String((it && (it.desc || it.remarks || it.note)) || '');
        var aDesc = aDescRaw ? sanitizeRichHtml(decodeEntities(aDescRaw)) : '';
        html += '<div class="avatarrow" data-index="' + index + '">' +
          (apic ? '<img loading="lazy" src="' + escapeHtml(apic) + '">' : '') +
          '<div class="at">' + escapeHtml(itemTitle(it)) + '</div>' +
          (aDesc ? '<div class="ad">' + aDesc + '</div>' : '') + '</div>';
      }
      return html;
    }
    if (col === 'text_icon') {
      html += '<div class="textrows">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var tpic = itemPic(it);
        var tiStyle = lineVisibleStyle(it);
        html += '<div class="textrow" data-index="' + index + '"' + (tiStyle ? ' style="' + tiStyle + '"' : '') + '>' +
          (tpic ? '<img style="width:22px;height:22px;border-radius:6px;vertical-align:middle;margin-right:8px" src="' + escapeHtml(tpic) + '">' : '') +
          escapeHtml(itemTitle(it)) + '</div>';
      }
      html += '</div>';
      return html;
    }
    if (col === 'flex_button' || col === 'scroll_button') {
      html += '<div class="chips' + (col === 'scroll_button' ? ' scroll' : '') + '">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i];
        html += '<button type="button" class="chipbtn" data-index="' + index + '">' + escapeHtml(itemTitle(items[index])) + '</button>';
      }
      html += '</div>';
      return html;
    }
    if (/^card_pic_/.test(col)) {
      // card_pic_2_2：连续两张叠成一列（右半边两张小卡），单张落单时独占一列。
      if (col === 'card_pic_2_2' || col === 'card_pic_2_2_left') {
        html += '<div class="picgrid" style="grid-template-columns:repeat(2,1fr)">';
        for (i = 0; i < indexes.length; i += 2) {
          html += '<div class="cardpair">';
          for (var pi = 0; pi < 2 && i + pi < indexes.length; pi++) {
            index = indexes[i + pi]; it = items[index];
            var ppic = itemPic(it);
            html += '<div class="cardpic half" data-index="' + index + '">' +
              (ppic ? '<div class="bg" style="background-image:url(\'' + escapeHtml(ppic) + '\');filter:blur(' + cardBlurPx(it) + 'px) brightness(.55)"></div>' : '') +
              '<div class="fg">' + (ppic ? '<img loading="lazy" src="' + escapeHtml(ppic) + '">' : '') +
              '<div class="ct">' + escapeHtml(itemTitle(it)) + '</div></div></div>';
          }
          html += '</div>';
        }
        html += '</div>';
        return html;
      }
      var cardCols = col === 'card_pic_1' ? 1 : col === 'card_pic_3' ? 3 : 2;
      html += '<div class="picgrid" style="grid-template-columns:repeat(' + cardCols + ',1fr)">';
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var cpic = itemPic(it);
        html += '<div class="cardpic" data-index="' + index + '">' +
          (cpic ? '<div class="bg" style="background-image:url(\'' + escapeHtml(cpic) + '\');filter:blur(' + cardBlurPx(it) + 'px) brightness(.55)"></div>' : '') +
          '<div class="fg">' + (cpic ? '<img loading="lazy" src="' + escapeHtml(cpic) + '">' : '') +
          '<div class="ct">' + escapeHtml(itemTitle(it)) + '</div></div></div>';
      }
      html += '</div>';
      return html;
    }
    if (col === 'input') {
      for (i = 0; i < indexes.length; i++) {
        index = indexes[i]; it = items[index];
        var extra = it.extra || {};
        var defVal = extra.defaultValue || '';
        var placeholder = extra.titleVisible === false ? '' : (itemTitle(it) || '请输入');
        html += '<div class="inputrow" data-input-index="' + index + '">' +
          '<input type="' + (extra.type === 'password' ? 'password' : extra.type === 'number' ? 'number' : 'text') + '" value="' + escapeHtml(defVal) + '" placeholder="' + escapeHtml(placeholder) + '">' +
          '<button type="button">确定</button></div>';
      }
      return html;
    }
    if (col === 'icon_1_search') {
      for (i = 0; i < indexes.length; i++) {
        html += '<div class="searchrow hk-searchrow">🔍 ' + escapeHtml(itemTitle(items[indexes[i]]) || '搜索') + '</div>';
      }
      return html;
    }
    // 默认：有图画卡片墙，无图画平铺（与旧行为一致）。
    var sectionHasPic = false;
    for (i = 0; i < indexes.length; i++) {
      if (itemPic(items[indexes[i]])) { sectionHasPic = true; break; }
    }
    if (sectionHasPic) {
      html += '<div class="grid">';
      for (i = 0; i < indexes.length; i++) html += cardHtml(items[indexes[i]], indexes[i]);
      html += '</div>';
    } else {
      html += '<div class="tiles">';
      for (i = 0; i < indexes.length; i++) html += tileHtml(items[indexes[i]], indexes[i]);
      html += '</div>';
    }
    return html;
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
    var cardGridOpen = false;
    var playlistGroupKey = null;
    function closeEpGrid() { if (epGridOpen) { html += '</div>'; epGridOpen = false; } playlistGroupKey = null; }
    function closeCardGrid() { if (cardGridOpen) { html += '</div>'; cardGridOpen = false; } }
    items.forEach(function (it, index) {
      var col = colTypeOf(it);
      if (col === '*') col = ''; // sdetail_col_type 的 * = 默认处理
      var title = itemTitle(it);
      var desc = itemDesc(it);
      var url = (it && (it.url || it.link)) || '';
      if (col !== 'movie_3' && col !== 'movie_2') closeCardGrid();
      if (index === headIndex) {
        detailTitle = title;
        headItem = it;
        var pic = itemPic(it);
        // 海报播放键占位（HAIKUO_POSTERPLAY）：循环结束、选集数已知
        // 后才决定是否在海报上叠播放键。
        html += '<div class="d-head" data-index="' + index + '">' +
          (pic ? '<div class="bg" style="background-image:url(\'' + escapeHtml(pic) + '\')"></div>' : '') +
          '<div class="fg">' +
          (pic ? '<div class="posterwrap"><img class="poster" loading="lazy" src="' + escapeHtml(pic) + '"><!--HAIKUO_POSTERPLAY--></div>' : '') +
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
        var dDescStyle = textStyleExtra(it);
        html += '<div class="d-desc" data-index="' + index + '"' + (dDescStyle ? ' style="' + dDescStyle + '"' : '') + '>' + escapeHtml(body) + '</div>';
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
      if (col === 'line') {
        closeEpGrid();
        html += '<div class="divider"></div>';
        return;
      }
      if (col === 'line_blank' || col === 'blank_block') {
        closeEpGrid();
        html += '<div class="blankblock"></div>';
        return;
      }
      if (col === 'long_text') {
        closeEpGrid();
        var dLongStyle = textStyleExtra(it);
        html += '<div class="longtext" data-index="' + index + '"' + (dLongStyle ? ' style="' + dLongStyle + '"' : '') + '>' + escapeHtml(title) + '</div>';
        return;
      }
      if (col === 'x5_webview_single') {
        closeEpGrid();
        html += x5RowHtml(it, index);
        return;
      }
      if (col === 'pic_1_full' || col === 'pic_1' || col === 'pic_1_center') {
        closeEpGrid();
        var dPic = itemPic(it);
        if (dPic) {
          if (col === 'pic_1_center') html += '<div class="piccenter" data-index="' + index + '"><img loading="lazy" src="' + escapeHtml(dPic) + '"></div>';
          else html += '<img class="picfull" loading="lazy" data-index="' + index + '" src="' + escapeHtml(dPic) + '">';
        }
        return;
      }
      if (col === 'movie_3' || col === 'movie_2') {
        closeEpGrid();
        if (!cardGridOpen) { html += '<div class="' + (col === 'movie_2' ? 'grid2' : 'grid') + '">'; cardGridOpen = true; }
        html += cardHtml(it, index);
        return;
      }
      if (col === 'movie_1_left_pic' || col === 'movie_1') {
        closeEpGrid();
        var rPic = itemPic(it);
        html += '<div class="rowitem" data-index="' + index + '">' +
          (rPic ? '<img class="thumb wide" loading="lazy" src="' + escapeHtml(rPic) + '">' : '') +
          '<div class="rmeta"><div class="rtitle">' + escapeHtml(title) + '</div>' +
          (desc ? '<div class="rdesc">' + escapeHtml(desc) + '</div>' : '') + '</div></div>';
        return;
      }
      if (col === 'movie_1_vertical_pic' || col === 'movie_1_vertical_pic_blur') {
        closeEpGrid();
        var vPic = itemPic(it);
        if (col === 'movie_1_vertical_pic_blur') {
          html += '<div class="vblur" data-index="' + index + '">' +
            (vPic ? '<div class="bg" style="background-image:url(\'' + escapeHtml(vPic) + '\')"></div>' : '') +
            (extraOf(it).gradient ? '<div class="vgrad"></div>' : '') +
            '<div class="fg">' + (vPic ? '<img loading="lazy" src="' + escapeHtml(vPic) + '">' : '') +
            '<div class="vt">' + escapeHtml(title) + '</div>' +
            (desc ? '<div class="vd">' + escapeHtml(desc) + '</div>' : '') + '</div></div>';
        } else {
          html += '<div class="vpic" data-index="' + index + '">' +
            (vPic ? '<img loading="lazy" src="' + escapeHtml(vPic) + '">' : '') +
            '<div class="vt">' + escapeHtml(title) + '</div>' +
            (desc ? '<div class="vd">' + escapeHtml(desc) + '</div>' : '') + '</div>';
        }
        return;
      }
      if (col === 'input') {
        closeEpGrid();
        var dExtra = it.extra || {};
        html += '<div class="inputrow" data-input-index="' + index + '">' +
          '<input type="text" value="' + escapeHtml(dExtra.defaultValue || '') + '" placeholder="' + escapeHtml(title) + '">' +
          '<button type="button">确定</button></div>';
        return;
      }
      if (/^text_[2-9]$/.test(col) || (col === '' && isPlayableUrl(url))) {
        // playlist 分组：cls 含 playlist 的选集按 cls 换组，组头画线路行。
        var epCls = itemExtraCls(it);
        var epIsPlaylist = /(^|\s)playlist(\s|$)/.test(epCls);
        var epGroupKey = epIsPlaylist ? epCls : '';
        if (playlistGroupKey !== null && playlistGroupKey !== epGroupKey) {
          closeEpGrid();
          var label = epCls.replace(/\bplaylist\b/g, '').trim() || '选集';
          html += '<div class="d-line"><span class="tag">线路</span><span>' + escapeHtml(label) + '</span></div>';
        }
        playlistGroupKey = epGroupKey;
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
    closeCardGrid();
    // 海报播放键：有选集（或头项本身可播）才画，点海报播第一集，
    // 走与点选集同一条 openItem→sendPlay 链路。有头项海报时把
    // 播放键叠在海报中央；无头项海报时，在详情最上方放一个
    // 播放器样式的播放区（同样是播放键，不是文字按钮）。
    var playTarget = firstPlayTarget();
    if (html.indexOf('<!--HAIKUO_POSTERPLAY-->') >= 0) {
      html = html.replace('<!--HAIKUO_POSTERPLAY-->',
        playTarget ? '<div class="posterplay" onclick="__haikuoPosterTap(event)"><span>▶</span></div>' : '');
    } else if (playTarget) {
      html = '<div class="d-player" onclick="__haikuoPlayFirst()"><div class="pbtn">▶</div></div>' + html;
    }
    listEl.innerHTML = html;
    bindX5Frames();
    // 历史记录：详情页渲染完成记一条（同地址节流，旗标可压住）。
    recordHistoryThrottled(detailTitle || itemTitle(items[0]), MY_URL, headItem ? itemPic(headItem) : '');
    Array.prototype.forEach.call(listEl.querySelectorAll('[data-index]'), function (el) {
      el.addEventListener('click', function () {
        // 详情页内的一切点按都带 fromDetail：选集、头项点播
        // 一律走内嵌槽位，不走推新页。
        var idx = Number(el.getAttribute('data-index'));
        if (el.__hkLongPressed) { el.__hkLongPressed = false; return; }
        openItem(items[idx], true, idx);
      });
      bindLongClick(el, items[Number(el.getAttribute('data-index'))], true);
    });
    Array.prototype.forEach.call(listEl.querySelectorAll('[data-input-index]'), function (el) {
      var btn = el.querySelector('button');
      var inputEl = el.querySelector('input');
      if (!btn || !inputEl) return;
      var submit = function () {
        var it = items[Number(el.getAttribute('data-input-index'))];
        if (it && it.extra && it.extra.rules) {
          runAggregatedSearch(inputEl.value, it.extra.rules, true);
          return;
        }
        var code = String((it && (it.url || it.link)) || '');
        if (!code) return;
        try {
          setCurrentInput(inputEl.value);
          var fn = new Function('input', code);
          var out = fn(inputEl.value);
          if (typeof out === 'string' && out) handleLazyResult(out, it, true);
        } catch (e) { say('执行失败：' + e); }
      };
      btn.addEventListener('click', submit);
      inputEl.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter') submit();
      });
    });
  }
  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function setResult(items) { render(items); }
  // refreshPage：真刷新——详情页重跑详情脚本，列表页重跑首页
  // 脚本（含 prerule）；传 false 时保持滚动位置。并触发 onRefresh 监听。
  var refreshListeners = [];
  function fireRefreshListeners() {
    refreshListeners.forEach(function (code) {
      try { (0, eval)(String(code)); } catch (e) { /* 监听代码出错不拦刷新 */ }
    });
  }
  function refreshPage(toTop) {
    var keepScroll = toTop === false;
    var y = 0;
    try { y = window.scrollY || 0; } catch (e) { y = 0; }
    fireRefreshListeners();
    var token = ++navToken;
    showListLoading();
    defer(function () {
      if (token !== navToken) return;
      if (isDetail) {
        runSource(detailScript());
      } else {
        runPrerule();
        runSource(PROGRAM.script);
      }
      if (keepScroll) {
        try { window.scrollTo(0, y); } catch (e) {}
      }
    });
  }
  function setPage() {}
  function join(url) { openItem({ url: url }); }
  function play(url, title) { native({ type: isMedia(url) ? 'play' : 'open', url: url, title: title || '', detail: isDetail }); }
  function open(url) { native({ type: 'open', url: url }); }
  function playVideo(url, title) { play(url, title); }
  function download(url, dest) {
    native({ type: 'download', url: String(url || ''), title: String(dest || '') });
  }
  function getVar(key, fallback) {
    try {
      var v = localStorage.getItem('v_' + key);
      return v === null ? (fallback === undefined ? '' : fallback) : v;
    } catch (e) { return fallback === undefined ? '' : fallback; }
  }
  function putVar(key, value) { try { localStorage.setItem('v_' + key, value == null ? '' : String(value)); } catch (e) {} }
  function clearVar(key) {
    try {
      if (key === undefined || key === null || key === '') {
        var keys = [];
        for (var i = 0; i < localStorage.length; i++) {
          var k = localStorage.key(i);
          if (k && k.indexOf('v_') === 0) keys.push(k);
        }
        keys.forEach(function (k) { localStorage.removeItem(k); });
      } else {
        localStorage.removeItem('v_' + key);
      }
    } catch (e) {}
  }
  // MyVar/Item 按规则隔离：键 = 前缀 + 归一化规则标题 + '_' + 键名。
  // 读时新键优先、旧全局键兜底（老规则已存的值不丢）；写只写新键。
  function ruleStorageKey() {
    try {
      var rule = (typeof MY_RULE !== 'undefined' && MY_RULE) || (PROGRAM.rule || {});
      return encodeURIComponent(normalizeRuleTitleJS(rule.title || rule.name || ''));
    } catch (e) { return ''; }
  }
  function myVarStorageKey(key) { return 'mv_' + ruleStorageKey() + '_' + String(key); }
  function itemStorageKey(key) { return 'it_' + ruleStorageKey() + '_' + String(key); }
  function clearMyVar(key) {
    try {
      if (key === undefined || key === null || key === '') {
        var prefix = 'mv_' + ruleStorageKey() + '_';
        var keys = [];
        for (var i = 0; i < localStorage.length; i++) {
          var k = localStorage.key(i);
          if (k && k.indexOf(prefix) === 0) keys.push(k);
        }
        keys.forEach(function (k) { localStorage.removeItem(k); });
      } else {
        localStorage.removeItem(myVarStorageKey(key));
      }
    } catch (e) {}
  }
  function listMyVarKeys() {
    var out = [];
    try {
      var prefix = 'mv_' + ruleStorageKey() + '_';
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (k && k.indexOf(prefix) === 0) out.push(k.slice(prefix.length));
      }
    } catch (e) {}
    return out;
  }
  // sleep：同步忙等（运行时本就是同步 XHR 模型），上限 10 秒防卡死。
  function sleep(ms) {
    var wait = Math.max(0, Math.min(10000, Number(ms) || 0));
    var end = Date.now() + wait;
    while (Date.now() < end) { /* busy wait */ }
  }
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
  function getMyVar(key, fallback) {
    var fb = fallback === undefined ? '' : fallback;
    try {
      var v = localStorage.getItem(myVarStorageKey(key));
      if (v !== null) return v;
      var legacy = localStorage.getItem('v_' + key);
      if (legacy !== null) return legacy;
      return fb;
    } catch (e) { return fb; }
  }
  function putMyVar(key, value) { try { localStorage.setItem(myVarStorageKey(key), value == null ? '' : String(value)); } catch (e) {} }
  function getItem(key, fallback) {
    var fb = fallback === undefined ? '' : fallback;
    try {
      var v = localStorage.getItem(itemStorageKey(key));
      if (v !== null) return v;
      var legacy = localStorage.getItem('i_' + key);
      if (legacy !== null) return legacy;
      return fb;
    } catch (e) { return fb; }
  }
  function setItem(key, value) { try { localStorage.setItem(itemStorageKey(key), value == null ? '' : String(value)); } catch (e) {} }
  function clearItem(key) { try { localStorage.removeItem(itemStorageKey(key)); } catch (e) {} }
  // storage0：JSON 型存储对象，8 个方法与上面同名函数一一对应，
  // 存时 JSON.stringify、取时 JSON.parse（解析失败回原字符串）。
  function storage0Get(raw, fallback) {
    if (raw === null || raw === undefined) return fallback === undefined ? null : fallback;
    if (raw === '') return fallback === undefined ? null : fallback;
    try { return JSON.parse(raw); } catch (e) { return raw; }
  }
  var storage0 = {
    putMyVar: function (key, value) { putMyVar(key, JSON.stringify(value)); },
    getMyVar: function (key, fallback) { return storage0Get(getMyVar(key, null), fallback); },
    putVar: function (key, value) { putVar(key, JSON.stringify(value)); },
    getVar: function (key, fallback) { return storage0Get(getVar(key, null), fallback); },
    setItem: function (key, value) { setItem(key, JSON.stringify(value)); },
    getItem: function (key, fallback) { return storage0Get(getItem(key, null), fallback); },
    setPublicItem: function (key, value) { setPublicItem(key, JSON.stringify(value)); },
    getPublicItem: function (key, fallback) { return storage0Get(getPublicItem(key, null), fallback); }
  };
  // 公共存储：全部规则共享（p_ 命名空间），规则删除后仍保留。
  function getPublicItem(key, fallback) {
    try {
      var v = localStorage.getItem('p_' + key);
      if (v === null) return fallback === undefined ? '' : fallback;
      return v;
    } catch (e) { return fallback === undefined ? '' : fallback; }
  }
  function setPublicItem(key, value) { try { localStorage.setItem('p_' + key, value == null ? '' : String(value)); } catch (e) {} }
  function clearPublicItem(key) { try { localStorage.removeItem('p_' + key); } catch (e) {} }
  // /__files/ 请求地址：带上当前规则标题，供 Dart 侧预置模块解析。
  function filesUrl(key) {
    var url = window.location.origin + '/__files/' + encodeURIComponent(key);
    var rt = currentRuleTitle();
    if (rt) url += '?rule=' + encodeURIComponent(rt);
    return url;
  }
  function readFile(name, flag) {
    try {
      var key = String(name || '').split('/').pop();
      if (!key) return '';
      if (savedFiles[key] !== undefined) return savedFiles[key];
      var content = rawHttp('GET', filesUrl(key), {});
      return content || '';
    } catch (e) { return ''; }
  }
  function deleteFile(name) {
    try {
      var key = String(name || '').split('/').pop();
      if (!key) return false;
      var had = savedFiles[key] !== undefined;
      delete savedFiles[key];
      native({ type: 'deleteFile', name: key });
      return had;
    } catch (e) { return false; }
  }
  function fileExist(path) {
    try {
      var p = String(path || '');
      var key = p.split('/').pop();
      if (!key) return false;
      if (savedFiles[key] !== undefined) return true;
      if (p.indexOf('hiker://files/') === 0) {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', filesUrl(key), false);
        xhr.send(null);
        return xhr.status === 200;
      }
      return false;
    } catch (e) { return false; }
  }
  function base64Encode(text) { try { return btoa(unescape(encodeURIComponent(text))); } catch (e) { return ''; } }
  function base64Decode(text) { try { return decodeURIComponent(escape(atob(text))); } catch (e) { return ''; } }

  // ---------- 杂项宿主接口 ----------
  var MOBILE_UA = 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
  var PC_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
  var config = {};
  function initConfig(obj) {
    config = obj || {};
    try { window.config = config; } catch (e) {}
  }
  function getParam(key, fallback) {
    var q = '';
    var qi = MY_URL.indexOf('?');
    if (qi >= 0) {
      q = MY_URL.slice(qi + 1);
      var hi = q.indexOf('#');
      if (hi >= 0) q = q.slice(0, hi);
    }
    if (key === undefined || key === null) return q;
    var params = parseQuery(q);
    var v = params[String(key)];
    return v === undefined ? (fallback === undefined ? '' : fallback) : v;
  }
  function getHome(url) {
    var target = String(url === undefined || url === null ? MY_URL : url);
    var m = /^(https?:\/\/[^\/:?#]+)/i.exec(target);
    if (m) return m[1];
    var idx = target.indexOf('##');
    if (idx >= 0) {
      var rest = target.slice(idx + 2);
      var m2 = /^(https?:\/\/[^\/:?#]+)/i.exec(rest);
      if (m2) return m2[1];
    }
    return '';
  }
  function getRule() { return MY_RULE; }
  function setError(msg) { say(msg); }
  function getColTypes() {
    return ['movie_3', 'movie_3_marquee', 'movie_2', 'movie_1', 'movie_1_left_pic', 'movie_1_vertical_pic', 'movie_1_vertical_pic_blur', 'text_1', 'text_center_1', 'text_2', 'text_3', 'text_4', 'text_5', 'long_text', 'rich_text', 'pic_3', 'pic_3_square', 'pic_2', 'pic_2_card', 'pic_1', 'pic_1_full', 'pic_1_center', 'icon_4', 'icon_4_card', 'icon_small_4', 'icon_small_3', 'icon_round_4', 'icon_round_small_4', 'icon_2', 'icon_2_round', 'line', 'line_blank', 'avatar', 'text_icon', 'blank_block', 'flex_button', 'scroll_button', 'card_pic_2', 'card_pic_1', 'card_pic_2_2', 'card_pic_2_2_left', 'card_pic_3', 'input', 'icon_1_search', 'x5_webview_single'];
  }
  function back(refresh) {
    if (navStack.length) goBack();
    else native({ type: 'pop' });
  }
  function copyFn(text) {
    native({ type: 'copy', text: String(text == null ? '' : text) });
  }
  var searchMode = 0;
  function getSearchMode() { return searchMode; }
  function setSearchMode(m) { searchMode = m ? 1 : 0; }
  function searchContains(text, key, ignoreCase) {
    var t = String(text || '');
    var k = String(key || '');
    if (ignoreCase) { t = t.toLowerCase(); k = k.toLowerCase(); }
    var words = k.split(/\s+/).filter(function (w) { return w; });
    for (var i = 0; i < words.length; i++) {
      if (t.indexOf(words[i]) < 0) return false;
    }
    return true;
  }
  function xpath(html, expr) {
    var doc = docOf(html);
    try {
      var res = doc.evaluate(String(expr || ''), doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      var node = res.singleNodeValue;
      return node ? (node.textContent || '') : '';
    } catch (e) { return ''; }
  }
  function xpathArray(html, expr) {
    var doc = docOf(html);
    var out = [];
    try {
      var res = doc.evaluate(String(expr || ''), doc, null, XPathResult.ORDERED_NODE_ITERATOR_TYPE, null);
      var node = res.iterateNext();
      while (node) {
        out.push(node.textContent || '');
        node = res.iterateNext();
      }
    } catch (e) { /* ignore */ }
    return out;
  }
  function rc4Crypt(str, key) {
    var s = [];
    for (var i = 0; i < 256; i++) s[i] = i;
    var j = 0;
    var keyStr = String(key || '');
    for (var a = 0; a < 256; a++) {
      j = (j + s[a] + keyStr.charCodeAt(a % keyStr.length)) & 0xFF;
      var tmp = s[a]; s[a] = s[j]; s[j] = tmp;
    }
    var out = '';
    var x = 0;
    var y = 0;
    var data = String(str || '');
    for (var b = 0; b < data.length; b++) {
      x = (x + 1) & 0xFF;
      y = (y + s[x]) & 0xFF;
      var tmp2 = s[x]; s[x] = s[y]; s[y] = tmp2;
      out += String.fromCharCode(data.charCodeAt(b) ^ s[(s[x] + s[y]) & 0xFF]);
    }
    return out;
  }
  var rc4 = {
    encode: function (str, key, charset) { return rc4Crypt(str, key); },
    decode: function (str, key, charset) { return rc4Crypt(str, key); }
  };
  function hexToBytes(hex) {
    var text = String(hex || '').replace(/[^0-9a-fA-F]/g, '');
    var out = [];
    for (var i = 0; i + 1 < text.length; i += 2) {
      out.push(parseInt(text.slice(i, i + 2), 16));
    }
    return out;
  }
  function hexToBase64(hex) {
    var bytes = hexToBytes(hex);
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    try { return btoa(bin); } catch (e) { return ''; }
  }
  function fetchPC(url, opt) {
    opt = opt || {};
    opt.headers = opt.headers || {};
    var hasUA = false;
    for (var k in opt.headers) {
      if (String(k).toLowerCase() === 'user-agent') hasUA = true;
    }
    if (!hasUA) opt.headers['User-Agent'] = PC_UA;
    return fetch(url, opt);
  }
  function postPC(url, body, opt) {
    opt = opt || {};
    opt.method = 'POST';
    opt.body = body;
    return fetchPC(url, opt);
  }
  function setPageParams(params) {
    MY_PARAMS = params || {};
    try { window.MY_PARAMS = MY_PARAMS; } catch (e) {}
  }
  // Cookie 读写：Dart 侧内存罐（代理取数时自动带上同主机的 Cookie）。
  function cookieRequest(op, url, cookie) {
    var xhr = new XMLHttpRequest();
    try {
      xhr.open('GET', '/__cookie?op=' + encodeURIComponent(op) +
        '&u=' + encodeURIComponent(url || '') + '&c=' + encodeURIComponent(cookie || ''), false);
      xhr.send(null);
    } catch (e) { return ''; }
    if (xhr.status !== 200) return '';
    try {
      var res = JSON.parse(xhr.responseText || '{}');
      return res.cookie || '';
    } catch (e) { return ''; }
  }
  function getCookie(url) { return cookieRequest('get', url || MY_URL, ''); }
  function setCookie(url, cookie) { cookieRequest('set', url || MY_URL, cookie || ''); }
  // 摘要：Dart 侧 crypto 包算，回十六进制小写。
  function cryptoRequest(payload) {
    var xhr = new XMLHttpRequest();
    try {
      xhr.open('GET', '/__crypto?q=' + encodeURIComponent(JSON.stringify(payload)), false);
      xhr.send(null);
    } catch (e) { return ''; }
    if (xhr.status !== 200) return '';
    try {
      var res = JSON.parse(xhr.responseText || '{}');
      return res.result || '';
    } catch (e) { return ''; }
  }
  function md5(text) {
    var t = String(text == null ? '' : text);
    // hiker://files/ 形态：取文件字节的 MD5（Dart 侧读已存文件）。
    if (t.indexOf('hiker://files/') === 0) {
      var key = t.split('/').pop().split('?')[0];
      return cryptoRequest({ op: 'md5file', name: key });
    }
    return cryptoRequest({ op: 'md5', text: t });
  }
  function sha1(text) { return cryptoRequest({ op: 'sha1', text: String(text == null ? '' : text) }); }
  function sha256(text) { return cryptoRequest({ op: 'sha256', text: String(text == null ? '' : text) }); }
  function sha512(text) { return cryptoRequest({ op: 'sha512', text: String(text == null ? '' : text) }); }
  // 远程模块缓存：localStorage 存文本 + 时间戳，过期重取。
  function cacheKeyFor(url) { return 'rc_' + encodeURIComponent(String(url)); }
  function readRemoteCache(url, hours) {
    try {
      var raw = localStorage.getItem(cacheKeyFor(url));
      if (!raw) return null;
      var obj = JSON.parse(raw);
      if (!obj || typeof obj.text !== 'string') return null;
      var ageMs = Date.now() - (obj.at || 0);
      if (ageMs > (Number(hours) || 0) * 3600000) return null;
      return obj.text;
    } catch (e) { return null; }
  }
  function writeRemoteCache(url, text) {
    try {
      localStorage.setItem(cacheKeyFor(url), JSON.stringify({ at: Date.now(), text: text }));
    } catch (e) {}
  }
  function fetchCache(url, hours) {
    var cached = readRemoteCache(url, hours);
    if (cached !== null) return cached;
    var text = fetch(url);
    if (text) writeRemoteCache(url, text);
    return text;
  }
  function requireCache(url, hours) {
    var text = fetchCache(url, hours);
    if (text) {
      try { (0, eval)(text); } catch (e) { say('远程模块执行失败：' + e); }
    }
    return text;
  }
  // 远程模块：按 md5(url) 缓存正文；传 version 时版本不一致强制刷新。
  // 执行时临时提供 module/exports 全局，捕获 $.exports 与 CommonJS 导出。
  function requireRemote(url, headers, version) {
    var opt = {};
    if (headers) opt.headers = headers;
    var text = '';
    var cacheKey = null;
    var wantVersion = (version === undefined || version === null) ? null : String(version);
    try {
      cacheKey = 'rq_' + md5(String(url));
      var cached = localStorage.getItem(cacheKey);
      if (cached) {
        var entry = JSON.parse(cached);
        if (entry && typeof entry.text === 'string') {
          if (wantVersion === null || entry.version === wantVersion) text = entry.text;
        }
      }
    } catch (e) { cacheKey = null; }
    if (!text) {
      // 绕开 fetch() 的 60 秒内存缓存：requireRemote 自带版本化持久
      // 缓存（rq_），版本不一致强制刷新时必须真正重新取数。
      opt.cache = false;
      text = fetch(url, opt);
      if (text && cacheKey) {
        try { localStorage.setItem(cacheKey, JSON.stringify({ version: wantVersion, text: text })); } catch (e) {}
      }
    }
    if (!text) return {};
    var savedExports = moduleState.exports;
    var freshExports = {};
    moduleState.exports = freshExports;
    var savedModule = window.module;
    var hadModule = 'module' in window;
    var savedExportsG = window.exports;
    var hadExports = 'exports' in window;
    var moduleObj = { exports: {} };
    try { window.module = moduleObj; window.exports = moduleObj.exports; } catch (e) {}
    try { (0, eval)(text); } catch (e) { say('远程模块执行失败：' + e); }
    var exported = moduleState.exports;
    moduleState.exports = savedExports;
    try {
      if (hadModule) window.module = savedModule; else delete window.module;
      if (hadExports) window.exports = savedExportsG; else delete window.exports;
    } catch (e) {}
    if (exported !== freshExports || hasOwnProps(exported)) return exported;
    if (hasOwnProps(moduleObj.exports)) return moduleObj.exports;
    return {};
  }
  function deleteCache(url) {
    try {
      if (url) {
        localStorage.removeItem(cacheKeyFor(url));
      } else {
        var keys = [];
        for (var i = 0; i < localStorage.length; i++) {
          var k = localStorage.key(i);
          if (k && k.indexOf('rc_') === 0) keys.push(k);
        }
        keys.forEach(function (k) { localStorage.removeItem(k); });
      }
    } catch (e) {}
  }
  function downloadFile(url, dest, headers) {
    native({ type: 'downloadFile', url: String(url || ''), dest: String(dest || ''), headers: headers || {} });
    return String(dest || '');
  }
  function saveImage(urls, dest) {
    var list = Array.isArray(urls) ? urls : [urls];
    native({ type: 'saveImage', urls: list.map(String), dest: String(dest || '') });
    return true;
  }
  function convertBase64Image(url) {
    var target = String(url || '');
    var res = rawHttpEx('GET', substituteTemplates(target), { toHex: true });
    if (!res.body) return '';
    var b64 = hexToBase64(res.body);
    var mime = 'image/jpeg';
    if (/\.png(\?|#|$)/i.test(target)) mime = 'image/png';
    else if (/\.gif(\?|#|$)/i.test(target)) mime = 'image/gif';
    else if (/\.webp(\?|#|$)/i.test(target)) mime = 'image/webp';
    return 'data:' + mime + ';base64,' + b64;
  }
  // m3u8 相对地址补全：分片行与 #EXT-X-KEY 的 URI 都按播放地址补全。
  function fixM3u8(url, content) {
    var base = String(url || '');
    var text = String(content || '');
    var lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.indexOf('#EXT-X-KEY') === 0 || line.indexOf('#EXT-X-MAP') === 0) {
        lines[i] = line.replace(/URI="([^"]+)"/, function (m, uri) {
          return 'URI="' + resolveUrl(uri, base) + '"';
        });
      } else if (line && line.charAt(0) !== '#') {
        lines[i] = resolveUrl(line.trim(), base);
      }
    }
    return lines.join('\n');
  }
  function cacheM3u8(url, options, fileName) {
    var target = String(url || '');
    var opt = {};
    if (options && typeof options === 'object') opt = options;
    else if (typeof options === 'string' && !fileName) fileName = options;
    var content = fetch(target, opt);
    if (!content) return target;
    content = fixM3u8(target, content);
    var name = fileName || ('cache_' + Math.abs(hashString(target)) + '.m3u8');
    saveFile(name, content);
    return getPath('hiker://files/' + name) + '##' + target;
  }
  function batchCacheM3u8(urls, options) {
    var list = Array.isArray(urls) ? urls : [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      try { out.push(cacheM3u8(list[i], options)); }
      catch (e) { out.push(String(list[i])); }
    }
    return out;
  }
  function hashString(s) {
    var h = 0;
    var text = String(s || '');
    for (var i = 0; i < text.length; i++) { h = (h * 31 + text.charCodeAt(i)) | 0; }
    return h;
  }
  // 自定义 DNS：本运行时无法改 Dart 代理的解析，记下来并明说未生效，
  // 不让 prerule 因为调了它就整段 abort。
  var dnsMappings = {};
  var dnsWarned = false;
  function registerDNS(map) {
    if (map && typeof map === 'object') {
      for (var k in map) {
        if (Object.prototype.hasOwnProperty.call(map, k)) dnsMappings[k] = map[k];
      }
    }
    if (!dnsWarned) {
      dnsWarned = true;
      say('规则请求的自定义 DNS 在本运行时未生效（代理层不支持改解析）');
    }
  }
  function dnsFn(map) { registerDNS(map); }

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
  function collectModuleNames(code) {
    var names = {};
    var found = [];
    function add(name) {
      if (!name || names[name]) return;
      if (name === 'require' || name === 'module' || name === 'exports' ||
          name === 'console' || name === 'input') return;
      names[name] = true;
      found.push(name);
    }
    var src = String(code || '');
    var re1 = /(?:^|[;\n}])\s*(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/g;
    var m;
    while ((m = re1.exec(src)) !== null) add(m[1]);
    var re2 = /(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)/g;
    while ((m = re2.exec(src)) !== null) add(m[1]);
    var re3 = /(?:^|[;\n])\s*([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>)/g;
    while ((m = re3.exec(src)) !== null) add(m[1]);
    // 固定 8 个名永远在列（老规则只定义其中几个时也不漏）。
    var fixed = ['home', 'detail', 'search', 'category', 'play', 'lazy', 'init', 'main'];
    for (var i = 0; i < fixed.length; i++) add(fixed[i]);
    return found;
  }
  function loadModule(path, param) {
    var rawPath = String(path || '');
    var ref = splitPageRef(rawPath.replace(/^hiker:\/\/page\//, ''));
    var key = ref.path;
    var importParam = param;
    if (importParam === undefined && ref.query) importParam = ref.query;
    var crossRuleObj = null;
    var restoreCrossRule = function () {};
    var params = parseQueryParams(ref.query);
    var page = null;
    var rule = '';
    if (params.rule && !isCurrentRuleTitle(params.rule)) {
      // 跨规则子页：?rule= 指向别的规则，取页后在目标规则上下文里执行。
      var fetched = fetchRulePageObject(params.rule, key);
      if (!fetched || !fetched.page) {
        say('模块加载失败：规则「' + params.rule + '」没有子页 ' + key);
        return {};
      }
      crossRuleObj = fetched.rule || {};
      rule = pageRuleText(fetched.page);
      key = 'xrule:' + normalizeRuleTitleJS(params.rule) + '|' + key;
      if (importParam === undefined) {
        // importParam 只留 rule 以外的查询参数。
        var rest = [];
        var pairs = String(ref.query || '').split('&');
        for (var qi = 0; qi < pairs.length; qi++) {
          if (pairs[qi].split('=')[0] !== 'rule') rest.push(pairs[qi]);
        }
        importParam = rest.join('&') || undefined;
      }
    } else {
      page = findPage(key);
      if (page) {
        rule = String(page.rule || '');
      } else if (rawPath.indexOf('hiker://files/') === 0 || rawPath.indexOf('hiker://assets/') === 0) {
        // 外部模块文件：当次 saveFile / 运行页收到的文件可直接当模块跑。
        rule = resolveVirtual(rawPath) || '';
        if (!rule) {
          say('模块加载失败：找不到 ' + rawPath);
          return {};
        }
      } else if (rawPath.indexOf('file://') === 0) {
        // file:// 模块：按基名走预置模块解析（壳内无文件系统路径）。
        var base = rawPath.split('/').pop().split('?')[0];
        try { base = decodeURIComponent(base); } catch (e) {}
        rule = resolveVirtual('hiker://files/' + base) || '';
        if (!rule) {
          say('模块加载失败：找不到 ' + rawPath);
          return {};
        }
      } else if (/^https?:\/\//.test(rawPath)) {
        var forceHttp = !!param;
        if (!forceHttp && Object.prototype.hasOwnProperty.call(moduleCache, key)) {
          return moduleCache[key];
        }
        var remote = requireRemote(rawPath);
        if (!forceHttp) moduleCache[key] = remote;
        return remote;
      } else {
        say('模块加载失败：找不到子页 ' + key + '（已查 path/name/解码三种匹配）');
        return {};
      }
    }
    if (crossRuleObj) {
      var savedRule = PROGRAM.rule;
      var savedMyRule = MY_RULE;
      PROGRAM.rule = crossRuleObj;
      MY_RULE = crossRuleObj;
      try { window.MY_RULE = crossRuleObj; } catch (e) {}
      restoreCrossRule = function () {
        PROGRAM.rule = savedRule;
        MY_RULE = savedMyRule;
        try { window.MY_RULE = savedMyRule; } catch (e) {}
      };
    }
    var force = !!param;
    if (!force && Object.prototype.hasOwnProperty.call(moduleCache, key)) {
      restoreCrossRule();
      return moduleCache[key];
    }
    var trimmedRule = rule.replace(/^\uFEFF/, '').trim();
    if (trimmedRule.indexOf('js:') !== 0 && !isBareJsRule(rule)) {
      var value = runPageRule(rule);
      if (!force) moduleCache[key] = value;
      restoreCrossRule();
      return value;
    }
    var code = trimmedRule.indexOf('js:') === 0 ? trimmedRule.slice(3) : trimmedRule;
    var freshExports = {};
    var savedExports = moduleState.exports;
    var savedImportParam = moduleState.importParam;
    moduleState.exports = freshExports;
    moduleState.importParam = importParam;
    var moduleObj = { exports: {} };
    var initialModuleExports = moduleObj.exports;
    var collected = null;
    try {
      var names = collectModuleNames(code);
      var returnParts = names.map(function (n) {
        return n + ': typeof ' + n + ' !== "undefined" ? ' + n + ' : null';
      });
      var factory = new Function(
        'require', 'module', 'exports', 'console', 'input',
        code + '\n;return {' + returnParts.join(',') + '};'
      );
      collected = factory(
        function (p, prm) { return loadModule(p, prm); },
        moduleObj, moduleObj.exports, { log: log }, input
      );
    } catch (error) {
      say('模块加载失败：' + key + '\n' + (error && error.message ? error.message : error));
      moduleState.exports = savedExports;
      moduleState.importParam = savedImportParam;
      restoreCrossRule();
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
      for (var i = 0; i < names.length; i++) {
        if (collected[names[i]] !== null && collected[names[i]] !== undefined) {
          result[names[i]] = collected[names[i]];
          anyFn = true;
        }
      }
      if (!anyFn) result = {};
    }
    if (result === null || result === undefined) result = {};
    if (!force) moduleCache[key] = result;
    restoreCrossRule();
    return result;
  }

  // ---------- 海阔的 $ 工具箱（只实现常用的一层） ----------
  function fnSource(fn) {
    if (typeof fn === 'function') return String(fn);
    return String(fn == null ? '' : fn);
  }
  function registerLazy(fn, inputArg) {
    if (typeof fn !== 'function') return 'hiker://empty';
    var key = 'lazy' + Math.random().toString(36).slice(2);
    // 存 {fn, input}：点击时先把 input 绑到全局，再调 fn(input)。
    lazyMap[key] = { fn: fn, input: inputArg };
    return 'hiker://lazy#' + key;
  }
  // 参数序列化（$.toString / $().image 共用）：函数取源码，undefined
  // 取字面量，其余 JSON.stringify（循环引用等失败时转字符串再包一层）。
  function serializeArg(arg) {
    if (typeof arg === 'function') return fnSource(arg);
    if (arg === undefined) return 'undefined';
    try {
      var s = JSON.stringify(arg);
      return s === undefined ? JSON.stringify(String(arg)) : s;
    } catch (e) {
      return JSON.stringify(String(arg));
    }
  }
  // $.toString(fn, ...args)：函数转可直接求值的 IIFE 串，参数内联绑定。
  function dollarToString(value) {
    if (typeof value !== 'function') return String(value);
    var args = [];
    for (var i = 1; i < arguments.length; i++) args.push(serializeArg(arguments[i]));
    return '(' + fnSource(value) + ')(' + args.join(',') + ')';
  }
  function dollarType(value) {
    if (value === null) return 'null';
    if (value === undefined) return 'undefined';
    var tag = Object.prototype.toString.call(value);
    var m = /^\[object (\w+)\]$/.exec(tag);
    var name = m ? m[1].toLowerCase() : typeof value;
    if (name === 'number' || name === 'string' || name === 'boolean' ||
        name === 'symbol' || name === 'bigint' || name === 'function') {
      return typeof value;
    }
    return name;
  }
  function dollarStringify(value) {
    if (typeof value === 'function') return fnSource(value);
    try {
      return JSON.stringify(value, function (k, v) {
        return typeof v === 'function' ? fnSource(v) : v;
      });
    } catch (e) { return ''; }
  }
  function dateFormatImpl(a, b) {
    var date = new Date();
    var fmt = 'yyyy-MM-dd HH:mm:ss';
    if (a instanceof Date) { date = a; if (typeof b === 'string') fmt = b; }
    else if (typeof a === 'number') { date = new Date(a); if (typeof b === 'string') fmt = b; }
    else if (typeof a === 'string') {
      if (typeof b === 'string') { date = new Date(a); fmt = b; }
      else fmt = a;
    }
    function pad(n, len) {
      var s = String(n);
      while (s.length < (len || 2)) s = '0' + s;
      return s;
    }
    var y = date.getFullYear();
    var mo = date.getMonth() + 1;
    var d = date.getDate();
    var H = date.getHours();
    var startOfYear = new Date(y, 0, 1);
    var dayOfYear = Math.floor((date.getTime() - startOfYear.getTime()) / 86400000) + 1;
    var weekOfYear = Math.ceil((dayOfYear + startOfYear.getDay()) / 7);
    var weekOfMonth = Math.ceil(d / 7);
    var wd = date.getDay();
    var wdShort = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][wd];
    var wdLong = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'][wd];
    var tzOff = -date.getTimezoneOffset();
    var tzSign = tzOff >= 0 ? '+' : '-';
    var tzAbs = Math.abs(tzOff);
    var tzZ = tzSign + pad(Math.floor(tzAbs / 60)) + pad(tzAbs % 60);
    var tzName = 'GMT' + tzZ.slice(0, 3) + ':' + tzZ.slice(3);
    var tzMatch = /\(([^)]+)\)/.exec(date.toString());
    if (tzMatch) tzName = tzMatch[1];
    var h12 = H % 12 === 0 ? 12 : H % 12;
    var map = {
      'yyyy': String(y),
      'yy': String(y).slice(-2),
      'G': y > 0 ? '公元' : '公元前',
      'MMMM': pad(mo),
      'MMM': pad(mo),
      'MM': pad(mo),
      'M': String(mo),
      'ww': pad(weekOfYear),
      'w': String(weekOfYear),
      'WW': pad(weekOfMonth),
      'W': String(weekOfMonth),
      'DDD': pad(dayOfYear, 3),
      'DD': pad(dayOfYear),
      'D': String(dayOfYear),
      'F': String(weekOfMonth),
      'EEEE': wdLong,
      'EEE': wdShort,
      'EE': wdShort,
      'E': wdShort,
      'a': H < 12 ? '上午' : '下午',
      'dd': pad(d),
      'd': String(d),
      'HH': pad(H),
      'H': String(H),
      'kk': pad(H === 0 ? 24 : H),
      'k': String(H === 0 ? 24 : H),
      'KK': pad(H % 12),
      'K': String(H % 12),
      'hh': pad(h12),
      'h': String(h12),
      'mm': pad(date.getMinutes()),
      'm': String(date.getMinutes()),
      'ss': pad(date.getSeconds()),
      's': String(date.getSeconds()),
      'SSS': pad(date.getMilliseconds(), 3),
      'S': String(date.getMilliseconds()),
      'zzzz': tzName,
      'zzz': tzName,
      'zz': tzName,
      'z': tzName,
      'Z': tzZ
    };
    return fmt.replace(/yyyy|yy|MMMM|MMM|MM|M|ww|w|WW|W|DDD|DD|D|F|EEEE|EEE|EE|E|a|dd|d|HH|H|kk|k|KK|K|hh|h|mm|m|ss|s|SSS|S|zzzz|zzz|zz|z|Z|G/g, function (tok) { return map[tok]; });
  }
  var closeListeners = [];
  var $api = {
    require: function (path, param) { return loadModule(path, param); },
    toString: dollarToString,
    post: function (url, body, headers) { return post(url, body, { headers: headers || {} }); },
    get: function (url, headers) { return fetch(url, { headers: headers || {} }); },
    lazyRule: function (fn, input) {
      return registerLazy(fn, input);
    },
    random: function (n) { return Math.floor(Math.random() * (n || 1000)); },
    base64Encode: base64Encode,
    base64Decode: base64Decode,
    log: function () { log.apply(null, arguments); return arguments[0]; },
    stringify: dollarStringify,
    parse: function (text) { return JSON.parse(text); },
    dateFormat: dateFormatImpl,
    type: dollarType,
    hiker: {},
    addListener: function (event, code) {
      var codeStr = fnSource(code);
      if (event === 'onRefresh') refreshListeners.push(codeStr);
      else if (event === 'onClose') closeListeners.push(codeStr);
    }
  };
  // 规则里写的是 $() / $(url) / $(url, headers)（函数调用形式），
  // 不是 $.lazyRule；$api 本身是普通对象，$() 会报 TypeError。
  // 包一层可调用函数：永远返回带链式方法的派生对象（无参时地址
  // 为空串，$api 方法经原型链可用；$().image 不再抛错）。
  function $(selector, headers) {
    var url = typeof selector === 'string' ? selector : '';
    var chained = Object.create($api);
    chained.rule = function (fn) {
      return url + '@rule=.js:(' + fnSource(fn) + ')()';
    };
    chained.lazyRule = function (fn, inputArg) {
      return registerLazy(fn, inputArg === undefined ? url : inputArg);
    };
    chained.image = function (fn, s1, s2) {
      // fn 的参数：有 s1/s2 就序列化内联；都没有就把图片数据 input 传进去。
      var args = [];
      if (s1 !== undefined) args.push(serializeArg(s1));
      if (s2 !== undefined) args.push(serializeArg(s2));
      if (!args.length) args.push('input');
      return url + '@headers=' + JSON.stringify(headers || {}) + '@js=(' + fnSource(fn) + ')(' + args.join(',') + ')';
    };
    chained.x5Rule = function (fn) {
      return 'javascript:(' + fnSource(fn) + ')()';
    };
    chained.input = function (fn) {
      return 'input://' + JSON.stringify({ value: url, js: '(' + fnSource(fn) + ')(input)' });
    };
    chained.confirm = function (fn) {
      return 'confirm://' + url + '.js:(' + fnSource(fn) + ')()';
    };
    return chained;
  }
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
  var MY_TYPE = 'home';
  var MY_PARAMS = {};
  var MY_NAME = '魔蚁box';
  var MY_CLASS_URL = '';
  var MY_AREA = '';
  var MY_SORT = '';
  var MY_YEAR = '';
  var fypage = '1';
  var fyclass = '';
  var fyarea = '';
  var fyyear = '';
  // input 全局变量：首页 ''、详情页=详情地址、搜索=关键词、
  // lazy/子页=绑定值。IIFE 内的 var 与 window.input 双份同步，
  // new Function 代码（全局作用域）与工厂参数两路都能读到。
  var currentInput = '';
  var input = '';
  function setCurrentInput(value) {
    currentInput = value == null ? '' : String(value);
    input = currentInput;
    try { window.input = currentInput; } catch (e) {}
  }
  // 详情页导航栈：只记回首页要用的 MY_URL/MY_PAGE。
  var navStack = [];

  function setGlobals(myUrl, myPage) {
    MY_URL = myUrl || '';
    MY_PAGE = myPage || 1;
    fypage = String(MY_PAGE);
    window.MY_URL = MY_URL;
    window.MY_PAGE = MY_PAGE;
    window.fypage = fypage;
    try { window.MY_HOME = getHome(MY_URL); } catch (e) {}
  }
  // 筛选状态同步到规则全局变量：分类/地区/排序/年份当前选中值，
  // 未选中为空串；首页加载与切筛选时调用。
  function syncFilterGlobals() {
    MY_CLASS_URL = String(selectedCls || '');
    MY_AREA = String(selectedArea || '');
    MY_SORT = String(selectedSort || '');
    MY_YEAR = String(selectedYear || '');
    try {
      window.MY_CLASS_URL = MY_CLASS_URL;
      window.MY_AREA = MY_AREA;
      window.MY_SORT = MY_SORT;
      window.MY_YEAR = MY_YEAR;
    } catch (e) {}
  }
  function hasDetailRule() {
    var r = PROGRAM.rule || {};
    return String(r.detail_find_rule || r.sdetail_find_rule || '').trim().length > 0;
  }
  function detailScript() {
    var r = PROGRAM.rule || {};
    var detail = String(r.detail_find_rule || '').trim();
    var sdetail = String(r.sdetail_find_rule || '').trim();
    // `*` = 复用另一条详情规则，两边对称解析；都为 `*` 或都为空时
    // 保持原样（复用目标未证实，不猜成 find_rule）。
    if (detail === '*' && sdetail && sdetail !== '*') return sdetail;
    if (sdetail === '*' && detail && detail !== '*') return detail;
    if (detail) return detail;
    return sdetail;
  }
  function showBack(show) {
    var btn = document.getElementById('backBtn');
    if (btn) btn.style.display = show ? 'inline-block' : 'none';
  }
  function openDetail(url) {
    clearPageTasks();
    navStack.push({ url: MY_URL, page: MY_PAGE });
    setGlobals(url, 1);
    setCurrentInput(url);
    showBack(true);
    isDetail = true;
    var token = ++navToken;
    showListLoading();
    defer(function () {
      if (token !== navToken) return;
      runSource(detailScript());
      showLastChapter();
    });
  }
  function goBack() {
    clearPageTasks();
    var prev = navStack.pop();
    showBack(navStack.length > 0);
    if (prev) setGlobals(prev.url, prev.page);
    else setGlobals(homeUrl(), 1);
    MY_TYPE = 'home';
    try { window.MY_TYPE = 'home'; } catch (e) {}
    setCurrentInput('');
    isDetail = false;
    var token = ++navToken;
    showListLoading();
    defer(function () {
      if (token !== navToken) return;
      runPrerule();
      runSource(PROGRAM.script || '');
    });
  }
  function runSource(source) {
    preResultItems = [];
    var text = String(source || '');
    if (text.indexOf('js:') === 0) text = text.slice(3);
    if (!text.trim()) return false;
    // 声明式规则不进 JS 求值：取当前页 HTML 跑声明式解析。
    if (!isBareJsRule(text) && looksDeclarative(text)) {
      return runDeclarativeSource(text);
    }
    try {
      var factory = new Function(
        'require', 'module', 'exports', 'console', 'input',
        text + '\n;return {' +
        'home: typeof home === "function" ? home : null,' +
        'detail: typeof detail === "function" ? detail : null,' +
        'search: typeof search === "function" ? search : null,' +
        'category: typeof category === "function" ? category : null,' +
        'init: typeof init === "function" ? init : null,' +
        'main: typeof main === "function" ? main : null' +
        '};'
      );
      var api = factory(
        function (p, prm) { return loadModule(p, prm); },
        {}, {}, { log: log }, currentInput
      );
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
  function looksDeclarative(text) {
    var t = String(text || '').trim();
    if (t === '*') return true;
    if (t.indexOf('&&') < 0) return false;
    if (/\b(var|let|const|function|return|fetch|setResult|eval|require)\b/.test(t)) return false;
    return true;
  }
  function fetchPageHtml() {
    if (/^https?:\/\//.test(MY_URL)) {
      return rawHttp('GET', substituteTemplates(MY_URL), {});
    }
    var v = resolveVirtual(MY_URL);
    return typeof v === 'string' ? v : '';
  }
  function runDeclarativeSource(text) {
    var trimmed = String(text || '').trim();
    if (trimmed === '*') {
      // sdetail '*'：无独立解析时，取本页标题与正文摘要显示一条。
      var starHtml = fetchPageHtml();
      if (!starHtml) { render([]); return true; }
      var doc = parseDoc(starHtml);
      var titleText = '';
      try {
        var titleEl = doc.querySelector('title');
        titleText = titleEl ? (titleEl.textContent || '').trim() : '';
      } catch (e) { titleText = ''; }
      var bodyText = '';
      try { bodyText = (doc.body ? doc.body.textContent || '' : '').replace(/\s+/g, ' ').trim().slice(0, 500); }
      catch (e) { bodyText = ''; }
      render([{
        title: titleText || pageTitle,
        desc: bodyText,
        url: MY_URL,
        col_type: 'rich_text'
      }]);
      return true;
    }
    var html = fetchPageHtml();
    if (!html) { render([]); return true; }
    render(evalDeclarative(html, trimmed));
    return true;
  }
  // prerule：首页与搜索解析之前都跑一遍（官方语义）；出错只记
  // 一句，不拦主脚本。prerule 本身就是 JS，js: 前缀可有可无。
  function runPrerule() {
    var rule = PROGRAM.rule || {};
    var pre = String(rule.prerule || rule.preRule || '');
    if (!pre.trim()) return;
    var code = pre.trim();
    if (code.indexOf('js:') === 0) code = code.slice(3);
    try {
      var fn = new Function(
        'require', 'module', 'exports', 'console', 'input', code
      );
      fn(
        function (p, prm) { return loadModule(p, prm); },
        { exports: {} }, {}, { log: log }, currentInput
      );
    } catch (error) {
      say('prerule 执行失败：' + (error && error.message ? error.message : error));
    }
  }
  // storage 种子：规则自带的配置只在键不存在时预置，绝不覆盖
  // 用户已改过的值；对象/JSON 字符串两种形态都认。
  function seedStorage() {
    var rule = PROGRAM.rule || {};
    var storage = rule.storage;
    if (!storage) return;
    var obj = null;
    if (typeof storage === 'string') {
      try { obj = JSON.parse(storage); } catch (e) { return; }
    } else if (typeof storage === 'object') {
      obj = storage;
    }
    if (!obj) return;
    for (var k in obj) {
      if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
      try {
        // 种子走隔离后的 Item 键：新旧键都不存在才预置。
        if (getItem(k, null) === null) {
          var v = obj[k];
          setItem(k, typeof v === 'string' ? v : JSON.stringify(v));
        }
      } catch (e) { /* ignore */ }
    }
  }
  // 搜索：search_url 模板替换（**/fypage/fyAll/fyclass）后当 MY_URL，
  // prerule 先跑，再跑 searchFind（没有则回落 find_rule）。
  function runSearch(keyword, page) {
    clearPageTasks();
    var rule = PROGRAM.rule || {};
    var kw = String(keyword == null ? '' : keyword);
    searchKeyword = kw;
    var searchUrl = String(rule.search_url || '');
    var searchFind = String(rule.searchFind || rule.searchfind || '');
    var script = searchFind || String(rule.find_rule || PROGRAM.script || '');
    if (!script.trim() && !searchUrl) { toast('这条规则没有搜索'); return; }
    var myUrl;
    if (searchUrl) {
      myUrl = searchUrl.split('**').join(kw);
      myUrl = myUrl.replace(/\bfypage\b/g, String(page || 1));
      myUrl = myUrl.replace(/fyAll/g, '');
      myUrl = myUrl.replace(/\bfyclass\b/g, String(selectedCls || ''));
    } else {
      myUrl = 'hiker://empty?word=' + encodeURIComponent(kw) + '&page=' + (page || 1);
    }
    navStack.push({ url: MY_URL, page: MY_PAGE });
    setGlobals(myUrl, page || 1);
    MY_TYPE = 'search';
    try { window.MY_TYPE = 'search'; } catch (e) {}
    setCurrentInput(kw);
    showBack(true);
    isDetail = false;
    showListLoading();
    var token = ++navToken;
    defer(function () {
      if (token !== navToken) return;
      runPrerule();
      runSource(script);
    });
  }
  window.__haikuoSearch = function (keyword, page) { runSearch(keyword, page); };
  // last_chapter_rule：详情页显示“更新至…”；JS 形态截获 setResult
  // 拿字符串，声明式形态直接取值。无显示面时只记不画。
  var lastChapterRuleText = '';
  function setLastChapterRule(ruleText) {
    lastChapterRuleText = String(ruleText || '');
  }
  function evalLastChapter() {
    var rule = PROGRAM.rule || {};
    var text = String(lastChapterRuleText || rule.last_chapter_rule || '');
    if (!text.trim() || text.trim() === '*') return '';
    var trimmed = text.trim();
    var code = trimmed.indexOf('js:') === 0 ? trimmed.slice(3) : trimmed;
    if (trimmed.indexOf('js:') === 0 || isBareJsRule(code)) {
      var captured = '';
      var savedSetResult = window.setResult;
      try {
        window.setResult = function (v) {
          captured = v == null ? '' : (typeof v === 'string' ? v : JSON.stringify(v));
        };
        var fn = new Function('input', code);
        var out = fn(currentInput);
        if (!captured && out !== undefined && out !== null) captured = String(out);
      } catch (e) { captured = ''; }
      window.setResult = savedSetResult;
      return captured;
    }
    var html = fetchPageHtml();
    if (!html) return '';
    return evalDeclarativeText(html, trimmed);
  }
  function showLastChapter() {
    var text = '';
    try { text = evalLastChapter(); } catch (e) { text = ''; }
    if (!text) return;
    try {
      window.__haikuoLastChapter = text;
      var div = document.createElement('div');
      div.className = 'd-line';
      div.innerHTML = '<span class="tag">更新</span><span></span>';
      div.querySelector('span:last-child').textContent = text;
      if (listEl.firstChild) listEl.insertBefore(div, listEl.firstChild);
      else listEl.appendChild(div);
    } catch (e) { /* ignore */ }
  }

  // __CRYPTOJS_FACTORY_START__
  // CryptoJS 子集（官方用法：eval(getCryptoJS()) 后用 CryptoJS.*）。
  // 覆盖规则实际会用的部分：enc.Utf8/Hex/Base64/Latin1、
  // lib.WordArray/CipherParams、AES（CBC/ECB/CTR + Pkcs7/
  // ZeroPadding/NoPadding，含口令 + OpenSSL Salted__ 形态）、
  // RC4/RC4Drop、MD5（纯 JS）、SHA1/SHA256/SHA512 与 Hmac*
  // （走 Dart 摘要接口）、EvpKDF/OpenSSL KDF、PBKDF2（走 Dart 端）。
  // DES/TripleDES/CFB/OFB 不在本子集内（见回报）。
  function __cryptoJSFactory() {
    function bytesToWA(bytes) {
      var words = [];
      for (var i = 0; i < bytes.length; i++) {
        words[i >>> 2] |= (bytes[i] & 0xFF) << (24 - (i % 4) * 8);
      }
      return new WA(words, bytes.length);
    }
    function waToBytes(wa) {
      var bytes = [];
      var words = wa.words;
      var sigBytes = wa.sigBytes;
      for (var i = 0; i < sigBytes; i++) {
        bytes.push((words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xFF);
      }
      return bytes;
    }
    function waToHex(wa) {
      var bytes = waToBytes(wa);
      var hex = '';
      for (var i = 0; i < bytes.length; i++) {
        var h = bytes[i].toString(16);
        hex += h.length < 2 ? '0' + h : h;
      }
      return hex;
    }
    function hexToWA(hex) {
      var text = String(hex || '').replace(/[^0-9a-fA-F]/g, '');
      var bytes = [];
      for (var i = 0; i + 1 < text.length; i += 2) {
        bytes.push(parseInt(text.slice(i, i + 2), 16));
      }
      return bytesToWA(bytes);
    }
    function utf8ToBytes(str) {
      var text = String(str == null ? '' : str);
      if (typeof TextEncoder !== 'undefined') {
        try { return Array.prototype.slice.call(new TextEncoder().encode(text)); } catch (e) { /* fallback */ }
      }
      var s = unescape(encodeURIComponent(text));
      var out = [];
      for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 0xFF);
      return out;
    }
    function bytesToUtf8(bytes) {
      if (typeof TextDecoder !== 'undefined') {
        try { return new TextDecoder('utf-8').decode(new Uint8Array(bytes)); } catch (e) { /* fallback */ }
      }
      var s = '';
      for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
      try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
    }
    function bytesToB64(bytes) {
      var bin = '';
      for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      return btoa(bin);
    }
    function b64ToBytes(str) {
      var bin = '';
      try { bin = atob(String(str || '').replace(/\s+/g, '')); } catch (e) { bin = ''; }
      var out = [];
      for (var i = 0; i < bin.length; i++) out.push(bin.charCodeAt(i) & 0xFF);
      return out;
    }
    function WA(words, sigBytes) {
      this.words = words || [];
      this.sigBytes = sigBytes === undefined ? this.words.length * 4 : sigBytes;
    }
    WA.prototype.clone = function () {
      return new WA(this.words.slice(), this.sigBytes);
    };
    WA.prototype.concat = function (other) {
      var bytes = waToBytes(this).concat(waToBytes(other));
      var merged = bytesToWA(bytes);
      this.words = merged.words;
      this.sigBytes = merged.sigBytes;
      return this;
    };
    WA.prototype.toString = function (encoder) {
      return (encoder || Hex).stringify(this);
    };
    WA.create = function (words, sigBytes) { return new WA(words, sigBytes); };
    WA.random = function (nBytes) {
      var words = [];
      var n = nBytes || 16;
      if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
        var arr = new Uint8Array(n);
        crypto.getRandomValues(arr);
        return bytesToWA(Array.prototype.slice.call(arr));
      }
      for (var i = 0; i < n; i++) {
        words[i >>> 2] |= (Math.floor(Math.random() * 256) & 0xFF) << (24 - (i % 4) * 8);
      }
      return new WA(words, n);
    };
    var Hex = {
      stringify: function (wa) { return waToHex(wa); },
      parse: function (str) { return hexToWA(str); }
    };
    var Latin1 = {
      stringify: function (wa) {
        var bytes = waToBytes(wa);
        var s = '';
        for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return s;
      },
      parse: function (str) {
        var text = String(str || '');
        var bytes = [];
        for (var i = 0; i < text.length; i++) bytes.push(text.charCodeAt(i) & 0xFF);
        return bytesToWA(bytes);
      }
    };
    var Utf8 = {
      stringify: function (wa) { return bytesToUtf8(waToBytes(wa)); },
      parse: function (str) { return bytesToWA(utf8ToBytes(str)); }
    };
    var Base64 = {
      stringify: function (wa) { return bytesToB64(waToBytes(wa)); },
      parse: function (str) { return bytesToWA(b64ToBytes(str)); }
    };
    function toWA(x) {
      if (typeof x === 'string') return Utf8.parse(x);
      if (x && typeof x === 'object' && Array.isArray(x.words) && typeof x.sigBytes === 'number') return x;
      if (Array.isArray(x)) return bytesToWA(x);
      return bytesToWA(utf8ToBytes(String(x == null ? '' : x)));
    }
    // ---- MD5（纯 JS，标准实现） ----
    function md5Bytes(bytes) {
      function safeAdd(x, y) {
        var l = (x & 0xFFFF) + (y & 0xFFFF);
        var m = (x >> 16) + (y >> 16) + (l >> 16);
        return (m << 16) | (l & 0xFFFF);
      }
      function bitRol(num, cnt) { return (num << cnt) | (num >>> (32 - cnt)); }
      function md5cmn(q, a, b, x, s, t) {
        return safeAdd(bitRol(safeAdd(safeAdd(a, q), safeAdd(x, t)), s), b);
      }
      function md5ff(a, b, c, d, x, s, t) { return md5cmn((b & c) | ((~b) & d), a, b, x, s, t); }
      function md5gg(a, b, c, d, x, s, t) { return md5cmn((b & d) | (c & (~d)), a, b, x, s, t); }
      function md5hh(a, b, c, d, x, s, t) { return md5cmn(b ^ c ^ d, a, b, x, s, t); }
      function md5ii(a, b, c, d, x, s, t) { return md5cmn(c ^ (b | (~d)), a, b, x, s, t); }
      function md5cycle(x, k) {
        var a = x[0], b = x[1], c = x[2], d = x[3];
        a = md5ff(a, b, c, d, k[0], 7, -680876936);
        d = md5ff(d, a, b, c, k[1], 12, -389564586);
        c = md5ff(c, d, a, b, k[2], 17, 606105819);
        b = md5ff(b, c, d, a, k[3], 22, -1044525330);
        a = md5ff(a, b, c, d, k[4], 7, -176418897);
        d = md5ff(d, a, b, c, k[5], 12, 1200080426);
        c = md5ff(c, d, a, b, k[6], 17, -1473231341);
        b = md5ff(b, c, d, a, k[7], 22, -45705983);
        a = md5ff(a, b, c, d, k[8], 7, 1770035416);
        d = md5ff(d, a, b, c, k[9], 12, -1958414417);
        c = md5ff(c, d, a, b, k[10], 17, -42063);
        b = md5ff(b, c, d, a, k[11], 22, -1990404162);
        a = md5ff(a, b, c, d, k[12], 7, 1804603682);
        d = md5ff(d, a, b, c, k[13], 12, -40341101);
        c = md5ff(c, d, a, b, k[14], 17, -1502002290);
        b = md5ff(b, c, d, a, k[15], 22, 1236535329);
        a = md5gg(a, b, c, d, k[1], 5, -165796510);
        d = md5gg(d, a, b, c, k[6], 9, -1069501632);
        c = md5gg(c, d, a, b, k[11], 14, 643717713);
        b = md5gg(b, c, d, a, k[0], 20, -373897302);
        a = md5gg(a, b, c, d, k[5], 5, -701558691);
        d = md5gg(d, a, b, c, k[10], 9, 38016083);
        c = md5gg(c, d, a, b, k[15], 14, -660478335);
        b = md5gg(b, c, d, a, k[4], 20, -405537848);
        a = md5gg(a, b, c, d, k[9], 5, 568446438);
        d = md5gg(d, a, b, c, k[14], 9, -1019803690);
        c = md5gg(c, d, a, b, k[3], 14, -187363961);
        b = md5gg(b, c, d, a, k[8], 20, 1163531501);
        a = md5gg(a, b, c, d, k[13], 5, -1444681467);
        d = md5gg(d, a, b, c, k[2], 9, -51403784);
        c = md5gg(c, d, a, b, k[7], 14, 1735328473);
        b = md5gg(b, c, d, a, k[12], 20, -1926607734);
        a = md5hh(a, b, c, d, k[5], 4, -378558);
        d = md5hh(d, a, b, c, k[8], 11, -2022574463);
        c = md5hh(c, d, a, b, k[11], 16, 1839030562);
        b = md5hh(b, c, d, a, k[14], 23, -35309556);
        a = md5hh(a, b, c, d, k[1], 4, -1530992060);
        d = md5hh(d, a, b, c, k[4], 11, 1272893353);
        c = md5hh(c, d, a, b, k[7], 16, -155497632);
        b = md5hh(b, c, d, a, k[10], 23, -1094730640);
        a = md5hh(a, b, c, d, k[13], 4, 681279174);
        d = md5hh(d, a, b, c, k[0], 11, -358537222);
        c = md5hh(c, d, a, b, k[3], 16, -722521979);
        b = md5hh(b, c, d, a, k[6], 23, 76029189);
        a = md5hh(a, b, c, d, k[9], 4, -640364487);
        d = md5hh(d, a, b, c, k[12], 11, -421815835);
        c = md5hh(c, d, a, b, k[15], 16, 530742520);
        b = md5hh(b, c, d, a, k[2], 23, -995338651);
        a = md5ii(a, b, c, d, k[0], 6, -198630844);
        d = md5ii(d, a, b, c, k[7], 10, 1126891415);
        c = md5ii(c, d, a, b, k[14], 15, -1416354905);
        b = md5ii(b, c, d, a, k[5], 21, -57434055);
        a = md5ii(a, b, c, d, k[12], 6, 1700485571);
        d = md5ii(d, a, b, c, k[3], 10, -1894986606);
        c = md5ii(c, d, a, b, k[10], 15, -1051523);
        b = md5ii(b, c, d, a, k[1], 21, -2054922799);
        a = md5ii(a, b, c, d, k[8], 6, 1873313359);
        d = md5ii(d, a, b, c, k[15], 10, -30611744);
        c = md5ii(c, d, a, b, k[6], 15, -1560198380);
        b = md5ii(b, c, d, a, k[13], 21, 1309151649);
        a = md5ii(a, b, c, d, k[4], 6, -145523070);
        d = md5ii(d, a, b, c, k[11], 10, -1120210379);
        c = md5ii(c, d, a, b, k[2], 15, 718787259);
        b = md5ii(b, c, d, a, k[9], 21, -343485551);
        x[0] = safeAdd(a, x[0]);
        x[1] = safeAdd(b, x[1]);
        x[2] = safeAdd(c, x[2]);
        x[3] = safeAdd(d, x[3]);
      }
      var bitLen = bytes.length * 8;
      var padded = bytes.slice();
      padded.push(0x80);
      while (padded.length % 64 !== 56) padded.push(0);
      for (var i = 0; i < 8; i++) padded.push(Math.floor(bitLen / Math.pow(2, i * 8)) & 0xFF);
      var state = [1732584193, -271733879, -1732584194, 271733878];
      for (var off = 0; off < padded.length; off += 64) {
        var block = [];
        for (var j = 0; j < 16; j++) {
          var o = off + j * 4;
          block[j] = padded[o] | (padded[o + 1] << 8) | (padded[o + 2] << 16) | (padded[o + 3] << 24);
        }
        md5cycle(state, block);
      }
      var out = [];
      for (var w = 0; w < 4; w++) {
        out.push(state[w] & 0xFF, (state[w] >>> 8) & 0xFF, (state[w] >>> 16) & 0xFF, (state[w] >>> 24) & 0xFF);
      }
      return out;
    }
    // ---- AES（无表实现：S 盒由 GF 运算生成，避免抄表抄错） ----
    function gfMul(a, b) {
      var p = 0;
      for (var i = 0; i < 8; i++) {
        if (b & 1) p ^= a;
        var hi = a & 0x80;
        a = (a << 1) & 0xFF;
        if (hi) a ^= 0x1B;
        b >>= 1;
      }
      return p;
    }
    function gfPow(a, e) {
      var r = 1;
      while (e > 0) {
        if (e & 1) r = gfMul(r, a);
        a = gfMul(a, a);
        e >>= 1;
      }
      return r;
    }
    function rotl8(x, n) { return ((x << n) | (x >> (8 - n))) & 0xFF; }
    var SBOX = [];
    var INV_SBOX = [];
    (function buildSbox() {
      for (var i = 0; i < 256; i++) {
        var inv = i === 0 ? 0 : gfPow(i, 254);
        var s = (inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63) & 0xFF;
        SBOX[i] = s;
        INV_SBOX[s] = i;
      }
    })();
    function aesExpandKey(keyBytes) {
      var Nk = keyBytes.length / 4;
      var Nr = Nk + 6;
      var w = [];
      for (var i = 0; i < Nk; i++) {
        w[i] = ((keyBytes[4 * i] << 24) | (keyBytes[4 * i + 1] << 16) | (keyBytes[4 * i + 2] << 8) | keyBytes[4 * i + 3]) >>> 0;
      }
      var rcon = 1;
      for (var j = Nk; j < 4 * (Nr + 1); j++) {
        var temp = w[j - 1];
        if (j % Nk === 0) {
          temp = (((SBOX[(temp >> 16) & 0xFF] << 24) | (SBOX[(temp >> 8) & 0xFF] << 16) | (SBOX[temp & 0xFF] << 8) | SBOX[(temp >>> 24) & 0xFF]) ^ (rcon << 24)) >>> 0;
          rcon = gfMul(rcon, 2);
        } else if (Nk > 6 && j % Nk === 4) {
          temp = ((SBOX[(temp >>> 24) & 0xFF] << 24) | (SBOX[(temp >> 16) & 0xFF] << 16) | (SBOX[(temp >> 8) & 0xFF] << 8) | SBOX[temp & 0xFF]) >>> 0;
        }
        w[j] = (w[j - Nk] ^ temp) >>> 0;
      }
      return { words: w, rounds: Nr };
    }
    function addRoundKey(state, w, round) {
      for (var c = 0; c < 4; c++) {
        var word = w[round * 4 + c];
        state[4 * c] ^= (word >>> 24) & 0xFF;
        state[4 * c + 1] ^= (word >>> 16) & 0xFF;
        state[4 * c + 2] ^= (word >>> 8) & 0xFF;
        state[4 * c + 3] ^= word & 0xFF;
      }
    }
    function subBytes(state, box) {
      for (var i = 0; i < 16; i++) state[i] = box[state[i]];
    }
    function shiftRows(state, inv) {
      for (var r = 1; r < 4; r++) {
        var row = [state[r], state[4 + r], state[8 + r], state[12 + r]];
        for (var c = 0; c < 4; c++) {
          state[4 * c + r] = inv ? row[(c - r + 4) % 4] : row[(c + r) % 4];
        }
      }
    }
    function mixColumns(state, inv) {
      for (var c = 0; c < 4; c++) {
        var o = 4 * c;
        var s0 = state[o], s1 = state[o + 1], s2 = state[o + 2], s3 = state[o + 3];
        if (!inv) {
          state[o] = gfMul(s0, 2) ^ gfMul(s1, 3) ^ s2 ^ s3;
          state[o + 1] = s0 ^ gfMul(s1, 2) ^ gfMul(s2, 3) ^ s3;
          state[o + 2] = s0 ^ s1 ^ gfMul(s2, 2) ^ gfMul(s3, 3);
          state[o + 3] = gfMul(s0, 3) ^ s1 ^ s2 ^ gfMul(s3, 2);
        } else {
          state[o] = gfMul(s0, 14) ^ gfMul(s1, 11) ^ gfMul(s2, 13) ^ gfMul(s3, 9);
          state[o + 1] = gfMul(s0, 9) ^ gfMul(s1, 14) ^ gfMul(s2, 11) ^ gfMul(s3, 13);
          state[o + 2] = gfMul(s0, 13) ^ gfMul(s1, 9) ^ gfMul(s2, 14) ^ gfMul(s3, 11);
          state[o + 3] = gfMul(s0, 11) ^ gfMul(s1, 13) ^ gfMul(s2, 9) ^ gfMul(s3, 14);
        }
      }
    }
    function aesEncryptBlock(block, expanded) {
      var state = block.slice();
      addRoundKey(state, expanded.words, 0);
      for (var round = 1; round < expanded.rounds; round++) {
        subBytes(state, SBOX);
        shiftRows(state, false);
        mixColumns(state, false);
        addRoundKey(state, expanded.words, round);
      }
      subBytes(state, SBOX);
      shiftRows(state, false);
      addRoundKey(state, expanded.words, expanded.rounds);
      return state;
    }
    function aesDecryptBlock(block, expanded) {
      var state = block.slice();
      addRoundKey(state, expanded.words, expanded.rounds);
      for (var round = expanded.rounds - 1; round >= 1; round--) {
        shiftRows(state, true);
        subBytes(state, INV_SBOX);
        addRoundKey(state, expanded.words, round);
        mixColumns(state, true);
      }
      shiftRows(state, true);
      subBytes(state, INV_SBOX);
      addRoundKey(state, expanded.words, 0);
      return state;
    }
    function aesCryptBytes(dataBytes, keyBytes, ivBytes, mode, encrypt, padding) {
      var data = dataBytes.slice();
      var inputLen = data.length;
      if (encrypt) {
        if (padding === 'Pkcs7') {
          var padLen = 16 - (data.length % 16);
          for (var p = 0; p < padLen; p++) data.push(padLen);
        } else if (padding === 'ZeroPadding') {
          while (data.length % 16 !== 0) data.push(0);
        }
      }
      var expanded = aesExpandKey(keyBytes);
      var out = [];
      var prev = ivBytes ? ivBytes.slice() : [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      var counter = ivBytes ? ivBytes.slice() : [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      for (var off = 0; off < data.length; off += 16) {
        var block = data.slice(off, off + 16);
        while (block.length < 16) block.push(0);
        var result;
        if (mode === 'ECB') {
          result = encrypt ? aesEncryptBlock(block, expanded) : aesDecryptBlock(block, expanded);
        } else if (mode === 'CTR') {
          var keystream = aesEncryptBlock(counter, expanded);
          result = block.map(function (b, i) { return b ^ keystream[i]; });
          for (var ci = 15; ci >= 0; ci--) {
            counter[ci] = (counter[ci] + 1) & 0xFF;
            if (counter[ci] !== 0) break;
          }
        } else {
          if (encrypt) {
            var xored = block.map(function (b, i) { return b ^ prev[i]; });
            result = aesEncryptBlock(xored, expanded);
            prev = result.slice();
          } else {
            var dec = aesDecryptBlock(block, expanded);
            result = dec.map(function (b, i) { return b ^ prev[i]; });
            prev = block.slice();
          }
        }
        out = out.concat(result);
      }
      if (mode === 'CTR') {
        // 流模式：输出与输入等长，末块补的零不算数。
        out = out.slice(0, inputLen);
        return out;
      }
      if (!encrypt) {
        if (padding === 'Pkcs7' && out.length) {
          var plen = out[out.length - 1];
          if (plen >= 1 && plen <= 16) out = out.slice(0, out.length - plen);
        } else if (padding === 'ZeroPadding') {
          while (out.length && out[out.length - 1] === 0) out.pop();
        }
      }
      return out;
    }
    function modeNameOf(mode, def) {
      if (mode && typeof mode === 'object' && mode.name) return mode.name;
      if (typeof mode === 'string') return mode;
      return def;
    }
    function padNameOf(padding, def) {
      if (padding && typeof padding === 'object' && padding.name) return padding.name;
      if (typeof padding === 'string') return padding;
      return def;
    }
    function evpKDF(passwordWA, saltWA, cfg) {
      var keySize = (cfg && cfg.keySize) || 4;
      var iterations = (cfg && cfg.iterations) || 1;
      var derived = [];
      var block = null;
      while (derived.length < keySize * 4) {
        var input = [];
        if (block) input = input.concat(block);
        input = input.concat(waToBytes(passwordWA));
        if (saltWA) input = input.concat(waToBytes(saltWA));
        block = md5Bytes(input);
        for (var it = 1; it < iterations; it++) block = md5Bytes(block);
        derived = derived.concat(block);
      }
      return bytesToWA(derived.slice(0, keySize * 4));
    }
    function opensslKDF(password, keySizeWords, ivSizeWords, saltWA) {
      var derived = evpKDF(toWA(password), saltWA, { keySize: keySizeWords + ivSizeWords, iterations: 1 });
      var dBytes = waToBytes(derived);
      return {
        key: bytesToWA(dBytes.slice(0, keySizeWords * 4)),
        iv: bytesToWA(dBytes.slice(keySizeWords * 4, (keySizeWords + ivSizeWords) * 4)),
        salt: saltWA
      };
    }
    var OpenSSLFormatter = {
      stringify: function (cp) {
        var ctBytes = waToBytes(cp.ciphertext);
        if (cp.salt) {
          var saltBytes = waToBytes(cp.salt);
          var out = [0x53, 0x61, 0x6C, 0x74, 0x65, 0x64, 0x5F, 0x5F].concat(saltBytes, ctBytes);
          return bytesToB64(out);
        }
        return bytesToB64(ctBytes);
      },
      parse: function (str) {
        var bytes = b64ToBytes(str);
        var salt = null;
        var ct = bytes;
        if (bytes.length >= 16 && bytes[0] === 0x53 && bytes[1] === 0x61 && bytes[2] === 0x6C && bytes[3] === 0x74 && bytes[4] === 0x65 && bytes[5] === 0x64 && bytes[6] === 0x5F && bytes[7] === 0x5F) {
          salt = bytesToWA(bytes.slice(8, 16));
          ct = bytes.slice(16);
        }
        return { ciphertext: bytesToWA(ct), salt: salt };
      }
    };
    var HexFormatter = {
      stringify: function (cp) { return waToHex(cp.ciphertext); },
      parse: function (str) { return { ciphertext: hexToWA(str), salt: null }; }
    };
    function CipherParams(props) {
      props = props || {};
      this.ciphertext = props.ciphertext;
      this.key = props.key;
      this.iv = props.iv;
      this.salt = props.salt;
      this.algorithm = props.algorithm;
      this.mode = props.mode;
      this.padding = props.padding;
      this.blockSize = props.blockSize || 4;
      this.formatter = props.formatter;
    }
    CipherParams.prototype.toString = function (formatter) {
      return (formatter || this.formatter || OpenSSLFormatter).stringify(this);
    };
    CipherParams.create = function (props) { return new CipherParams(props); };
    var AES = {
      keySize: 8,
      ivSize: 4,
      encrypt: function (message, key, cfg) {
        cfg = cfg || {};
        var msgWA = toWA(message);
        var mode = modeNameOf(cfg.mode, 'CBC');
        var pad = padNameOf(cfg.padding, 'Pkcs7');
        var keyWA;
        var ivWA;
        var saltWA = null;
        if (typeof key === 'string') {
          saltWA = cfg.salt ? toWA(cfg.salt) : WA.random(8);
          var derived = opensslKDF(key, 8, 4, saltWA);
          keyWA = derived.key;
          ivWA = derived.iv;
        } else {
          keyWA = toWA(key);
          ivWA = cfg.iv ? toWA(cfg.iv) : bytesToWA([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        }
        var ctBytes = aesCryptBytes(waToBytes(msgWA), waToBytes(keyWA), waToBytes(ivWA), mode, true, pad);
        return new CipherParams({ ciphertext: bytesToWA(ctBytes), key: keyWA, iv: ivWA, salt: saltWA, mode: cfg.mode, padding: cfg.padding });
      },
      decrypt: function (ciphertext, key, cfg) {
        cfg = cfg || {};
        var cp;
        if (typeof ciphertext === 'string') cp = OpenSSLFormatter.parse(ciphertext);
        else if (ciphertext && ciphertext.ciphertext) cp = ciphertext;
        else cp = { ciphertext: toWA(ciphertext), salt: null };
        var mode = modeNameOf(cfg.mode, 'CBC');
        var pad = padNameOf(cfg.padding, 'Pkcs7');
        var keyWA;
        var ivWA;
        if (typeof key === 'string') {
          var saltWA = cp.salt || (cfg.salt ? toWA(cfg.salt) : bytesToWA([0, 0, 0, 0, 0, 0, 0, 0]));
          var derived = opensslKDF(key, 8, 4, saltWA);
          keyWA = derived.key;
          ivWA = derived.iv;
        } else {
          keyWA = toWA(key);
          ivWA = cfg.iv ? toWA(cfg.iv) : bytesToWA([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        }
        var ptBytes = aesCryptBytes(waToBytes(cp.ciphertext), waToBytes(keyWA), waToBytes(ivWA), mode, false, pad);
        return bytesToWA(ptBytes);
      }
    };
    function rc4Bytes(dataBytes, keyBytes, drop) {
      var S = [];
      for (var i = 0; i < 256; i++) S[i] = i;
      var j = 0;
      for (var a = 0; a < 256; a++) {
        j = (j + S[a] + keyBytes[a % keyBytes.length]) & 0xFF;
        var t = S[a]; S[a] = S[j]; S[j] = t;
      }
      var x = 0;
      var y = 0;
      function nextByte() {
        x = (x + 1) & 0xFF;
        y = (y + S[x]) & 0xFF;
        var t2 = S[x]; S[x] = S[y]; S[y] = t2;
        return S[(S[x] + S[y]) & 0xFF];
      }
      for (var d = 0; d < (drop || 0); d++) nextByte();
      var out = [];
      for (var b = 0; b < dataBytes.length; b++) out.push(dataBytes[b] ^ nextByte());
      return out;
    }
    function rc4Cipher(drop) {
      return {
        encrypt: function (message, key, cfg) {
          var ct = rc4Bytes(waToBytes(toWA(message)), waToBytes(toWA(key)), drop);
          return new CipherParams({ ciphertext: bytesToWA(ct) });
        },
        decrypt: function (ciphertext, key, cfg) {
          var ctWA;
          if (typeof ciphertext === 'string') ctWA = Base64.parse(ciphertext);
          else if (ciphertext && ciphertext.ciphertext) ctWA = ciphertext.ciphertext;
          else ctWA = toWA(ciphertext);
          var pt = rc4Bytes(waToBytes(ctWA), waToBytes(toWA(key)), drop);
          return bytesToWA(pt);
        }
      };
    }
    function hashViaEndpoint(op, message) {
      var hex = waToHex(toWA(message));
      var outHex = '';
      try {
        if (typeof window !== 'undefined' && window.__haikuoHash) {
          outHex = window.__haikuoHash(op, hex, true) || '';
        }
      } catch (e) { outHex = ''; }
      return hexToWA(outHex);
    }
    function hmacViaEndpoint(op, message, key) {
      var keyHex = waToHex(toWA(key));
      var msgHex = waToHex(toWA(message));
      var outHex = '';
      try {
        if (typeof window !== 'undefined' && window.__haikuoHmac) {
          outHex = window.__haikuoHmac(op, keyHex, msgHex) || '';
        }
      } catch (e) { outHex = ''; }
      return hexToWA(outHex);
    }
    // PBKDF2：密钥派生走 Dart 端（单次同步请求完成全部轮次，
    // 避免每轮一次摘要请求）。cfg.keySize 单位是字（默认 4=128 位），
    // cfg.iterations 默认 1，上限 10000；hasher 可传字符串或 algo 标记。
    function pbkdf2ViaEndpoint(password, salt, cfg) {
      cfg = cfg || {};
      var keySize = cfg.keySize || 4;
      var iterations = cfg.iterations || 1;
      if (iterations > 10000) iterations = 10000;
      if (iterations < 1) iterations = 1;
      var hash = 'sha1';
      var h = cfg.hasher;
      if (typeof h === 'string') {
        var hn = h.toLowerCase().replace(/[^a-z0-9]/g, '');
        if (hn === 'sha256' || hn === 'sha512' || hn === 'sha1' || hn === 'md5') hash = hn;
      } else if (h && typeof h === 'object' && h._hashName) {
        hash = h._hashName;
      }
      var pwHex = waToHex(toWA(password));
      var saltHex = salt ? waToHex(toWA(salt)) : '';
      var outHex = '';
      try {
        if (typeof window !== 'undefined' && window.__haikuoPbkdf2) {
          outHex = window.__haikuoPbkdf2(pwHex, saltHex, iterations, keySize * 4, hash) || '';
        }
      } catch (e) { outHex = ''; }
      return hexToWA(outHex);
    }
    return {
      lib: { WordArray: WA, CipherParams: CipherParams },
      enc: { Hex: Hex, Latin1: Latin1, Utf8: Utf8, Base64: Base64 },
      mode: { CBC: { name: 'CBC' }, ECB: { name: 'ECB' }, CTR: { name: 'CTR' } },
      pad: { Pkcs7: { name: 'Pkcs7' }, ZeroPadding: { name: 'ZeroPadding' }, NoPadding: { name: 'NoPadding' } },
      algo: {
        MD5: { _hashName: 'md5' }, SHA1: { _hashName: 'sha1' },
        SHA256: { _hashName: 'sha256' }, SHA512: { _hashName: 'sha512' },
        HmacMD5: { _hashName: 'md5' }, HmacSHA1: { _hashName: 'sha1' },
        HmacSHA256: { _hashName: 'sha256' }, HmacSHA512: { _hashName: 'sha512' }
      },
      PBKDF2: pbkdf2ViaEndpoint,
      format: { OpenSSL: OpenSSLFormatter, Hex: HexFormatter },
      kdf: { OpenSSL: { execute: opensslKDF } },
      AES: AES,
      RC4: rc4Cipher(0),
      RC4Drop: rc4Cipher(192),
      MD5: function (message) { return bytesToWA(md5Bytes(waToBytes(toWA(message)))); },
      SHA1: function (message) { return hashViaEndpoint('sha1', message); },
      SHA256: function (message) { return hashViaEndpoint('sha256', message); },
      SHA512: function (message) { return hashViaEndpoint('sha512', message); },
      HmacMD5: function (message, key) { return hmacViaEndpoint('md5', message, key); },
      HmacSHA1: function (message, key) { return hmacViaEndpoint('sha1', message, key); },
      HmacSHA256: function (message, key) { return hmacViaEndpoint('sha256', message, key); },
      HmacSHA512: function (message, key) { return hmacViaEndpoint('sha512', message, key); },
      EvpKDF: function (password, salt, cfg) {
        return evpKDF(toWA(password), salt ? toWA(salt) : null, cfg);
      }
    };
  }
  var CryptoJS = __cryptoJSFactory();
  function getCryptoJS() {
    return 'var CryptoJS = (' + __cryptoJSFactory.toString() + ')();';
  }
  // __CRYPTOJS_FACTORY_END__

  // ---------- 指南补齐批：新增壳子接口 ----------
  // 字节工具：图片解密与 crypto-java 桥共用（数组 = 字节序列）。
  function bytesToHex(bytes) {
    var hex = '';
    for (var i = 0; i < bytes.length; i++) {
      var h = (bytes[i] & 0xFF).toString(16);
      hex += h.length < 2 ? '0' + h : h;
    }
    return hex;
  }
  function hexToByteArray(hex) {
    var clean = String(hex || '').replace(/[^0-9a-fA-F]/g, '');
    var out = [];
    for (var i = 0; i + 1 < clean.length; i += 2) out.push(parseInt(clean.substr(i, 2), 16));
    return out;
  }
  function byteArrayToBase64(bytes) {
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i] & 0xFF);
    return btoa(bin);
  }
  function base64ToByteArray(b64) {
    try {
      var bin = atob(String(b64 || '').replace(/\s/g, ''));
      var out = [];
      for (var i = 0; i < bin.length; i++) out.push(bin.charCodeAt(i));
      return out;
    } catch (e) { return []; }
  }
  function latin1ToBytes(str) {
    var s = String(str || '');
    var out = [];
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 0xFF);
    return out;
  }
  function bytesToLatin1(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 0xFF);
    return s;
  }
  function utf8ToBytes(str) {
    try { return latin1ToBytes(unescape(encodeURIComponent(String(str || '')))); }
    catch (e) { return latin1ToBytes(String(str || '')); }
  }
  // InputStream 垫片：Java 式 read/available/close/mark/reset，内部
  // 持一份字节数组（_hkBytes），供 @js= 图片解密与 crypto-java 桥用。
  function makeInputStream(bytes) {
    var data = bytes.slice();
    var pos = 0;
    var markPos = 0;
    return {
      _hkBytes: data,
      read: function (buf) {
        if (buf === undefined) {
          if (pos >= data.length) return -1;
          return data[pos++];
        }
        if (pos >= data.length) return -1;
        var n = Math.min(buf.length, data.length - pos);
        for (var i = 0; i < n; i++) buf[i] = data[pos++];
        return n;
      },
      readAll: function () { var rest = data.slice(pos); pos = data.length; return rest; },
      getBytes: function () { return data.slice(); },
      available: function () { return data.length - pos; },
      close: function () {},
      mark: function () { markPos = pos; },
      reset: function () { pos = markPos; },
      skip: function (n) { var s = Math.min(n, data.length - pos); pos += s; return s; }
    };
  }
  function readStreamBytes(stream) {
    if (!stream) return [];
    if (stream._hkBytes) return stream._hkBytes.slice();
    if (typeof stream.getBytes === 'function') {
      try { var g = stream.getBytes(); if (g && g.length !== undefined) return Array.prototype.slice.call(g); } catch (e) {}
    }
    if (typeof stream.readAll === 'function') {
      try { var all = stream.readAll(); if (all && all.length !== undefined) return Array.prototype.slice.call(all); } catch (e) {}
    }
    if (typeof stream.read === 'function') {
      var out = [];
      try {
        var guard = 0;
        while (guard++ < 67108864) {
          var b = stream.read();
          if (b === -1 || b === null || b === undefined) break;
          out.push(b & 0xFF);
        }
      } catch (e) {}
      return out;
    }
    if (stream.length !== undefined && typeof stream !== 'string') {
      try { return Array.prototype.slice.call(stream); } catch (e) { return []; }
    }
    if (typeof stream === 'string') return latin1ToBytes(stream);
    return [];
  }
  function dataToBytes(x) {
    if (x === null || x === undefined) return [];
    if (x._hkDataBytes) return x._hkDataBytes.slice();
    if (x._hkBytes) return x._hkBytes.slice();
    if (typeof x.toInputStream === 'function') {
      try { return readStreamBytes(x.toInputStream()); } catch (e) {}
    }
    if (Array.isArray(x)) return x.slice();
    if (typeof x === 'string') {
      var s = x.trim();
      if (/^[0-9a-fA-F\s]+$/.test(s) && s.replace(/\s/g, '').length % 2 === 0 && s.length >= 2) {
        return hexToByteArray(s);
      }
      return utf8ToBytes(x);
    }
    if (x.words && typeof x.sigBytes === 'number') {
      // CryptoJS WordArray。
      var out = [];
      for (var i = 0; i < x.sigBytes; i++) {
        out.push((x.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xFF);
      }
      return out;
    }
    if (typeof x === 'object' && x.length !== undefined) {
      try { return Array.prototype.slice.call(x); } catch (e) { return []; }
    }
    return utf8ToBytes(String(x));
  }
  function makeDataObj(bytes) {
    var data = bytes.slice();
    return {
      _hkDataBytes: data,
      toInputStream: function () { return makeInputStream(data); },
      toByteArray: function () { return data.slice(); },
      toHex: function () { return bytesToHex(data); },
      toString: function () { return bytesToLatin1(data); }
    };
  }
  // crypto-java 桥：规则用 $.require("hiker://assets/crypto-java.js")
  // 解构 {Data, AES}。壳内合成，基于已有 CryptoJS 子集实现。
  function makeCryptoJavaModule() {
    var Data = {
      parseHex: function (hex) { return makeDataObj(hexToByteArray(hex)); },
      parseInputStream: function (stream) { return makeDataObj(readStreamBytes(stream)); },
      parseUTF8: function (str) { return makeDataObj(utf8ToBytes(str)); },
      parseBytes: function (arr) { return makeDataObj(dataToBytes(arr)); }
    };
    function parseCipherOpts(opts) {
      var o = opts || {};
      var modeStr = String(o.mode || 'AES/CBC/PKCS7Padding');
      var mode = CryptoJS.mode.CBC;
      if (/ECB/i.test(modeStr)) mode = CryptoJS.mode.ECB;
      else if (/CTR/i.test(modeStr)) mode = CryptoJS.mode.CTR;
      var padding = CryptoJS.pad.Pkcs7;
      if (/NoPadding/i.test(modeStr)) padding = CryptoJS.pad.NoPadding;
      else if (/ZeroPadding/i.test(modeStr)) padding = CryptoJS.pad.ZeroPadding;
      var ivBytes = o.iv !== undefined ? dataToBytes(o.iv) : null;
      return { mode: mode, padding: padding, ivBytes: ivBytes };
    }
    function wordArrayFromBytes(bytes) {
      return CryptoJS.enc.Hex.parse(bytesToHex(bytes));
    }
    var AES = {
      decrypt: function (data, key, opts) {
        var p = parseCipherOpts(opts);
        var cipherWA = wordArrayFromBytes(dataToBytes(data));
        var keyWA = wordArrayFromBytes(dataToBytes(key));
        var cfg = { mode: p.mode, padding: p.padding };
        if (p.ivBytes) cfg.iv = wordArrayFromBytes(p.ivBytes);
        var plain = CryptoJS.AES.decrypt(CryptoJS.lib.CipherParams.create({ ciphertext: cipherWA }), keyWA, cfg);
        return makeDataObj(dataToBytes(plain));
      },
      encrypt: function (data, key, opts) {
        var p = parseCipherOpts(opts);
        var plainWA = wordArrayFromBytes(dataToBytes(data));
        var keyWA = wordArrayFromBytes(dataToBytes(key));
        var cfg = { mode: p.mode, padding: p.padding };
        if (p.ivBytes) cfg.iv = wordArrayFromBytes(p.ivBytes);
        var cipher = CryptoJS.AES.encrypt(plainWA, keyWA, cfg);
        return makeDataObj(dataToBytes(cipher.ciphertext));
      }
    };
    return { Data: Data, AES: AES };
  }

  // ---------- Java 桥最小垫片（Rhino java.* / javax.* / android.*） ----------
  // 官方海阔规则跑在 Rhino 上，可直接用 Java 类；WebView 里没有这
  // 些全局，规则一碰就报 ReferenceError（绿帽社的签名/解密即此
  // 形态：sha256 回空 → 签名无效 → 列表取不到）。这里只垫规则包
  // 里实际用到的最小子集，全部基于已有 CryptoJS 子集与 Dart 摘
  // 要接口实现；未覆盖的类/方法不在此列，碰到仍报原错，不编造。
  // 字节一律用 JS 数字数组表示；对外（digest/getBytes/doFinal）
  // 按 Java 语义回有符号字节（-128..127），内部一律掩码后运算。
  function javaBytesFrom(x) {
    if (x === undefined || x === null) return [];
    if (typeof x === 'string') return utf8ToBytes(x);
    var arr = dataToBytes(x);
    var out = [];
    for (var i = 0; i < arr.length; i++) out.push(arr[i] & 0xFF);
    return out;
  }
  function javaSignedBytes(bytes) {
    var out = [];
    for (var i = 0; i < bytes.length; i++) {
      var b = bytes[i] & 0xFF;
      out.push(b > 127 ? b - 256 : b);
    }
    return out;
  }
  function javaDecodeBytes(bytes, charset) {
    var clean = [];
    for (var i = 0; i < bytes.length; i++) clean.push(bytes[i] & 0xFF);
    try {
      if (typeof TextDecoder !== 'undefined') {
        return new TextDecoder(charset || 'utf-8').decode(new Uint8Array(clean));
      }
    } catch (e) { /* 无 TextDecoder 时走 latin1 兜底 */ }
    return bytesToLatin1(clean);
  }
  function JavaString(value, charset) {
    if (!(this instanceof JavaString)) return new JavaString(value, charset);
    var str;
    if (value === undefined || value === null) str = '';
    else if (typeof value === 'string') str = value;
    else if (typeof value === 'object' && typeof value.length === 'number') str = javaDecodeBytes(value, charset);
    else str = String(value);
    this.__str = str;
  }
  JavaString.prototype.toString = function () { return this.__str; };
  JavaString.prototype.valueOf = function () { return this.__str; };
  JavaString.prototype.getBytes = function (charset) {
    return javaSignedBytes(utf8ToBytes(this.__str));
  };
  JavaString.prototype.toCharArray = function () { return this.__str.split(''); };
  function JavaMessageDigest(algo) {
    this.algo = algo;
    this.chunks = [];
  }
  JavaMessageDigest.getInstance = function (algo) {
    var a = String(algo || '').toUpperCase().replace(/-/g, '');
    if (['MD5', 'SHA1', 'SHA256', 'SHA512'].indexOf(a) < 0) {
      throw new Error('MessageDigest 不支持：' + algo);
    }
    return new JavaMessageDigest(a);
  };
  JavaMessageDigest.prototype.update = function (data) {
    this.chunks.push(javaBytesFrom(data));
  };
  JavaMessageDigest.prototype.digest = function () {
    var all = [];
    for (var i = 0; i < this.chunks.length; i++) {
      for (var j = 0; j < this.chunks[i].length; j++) all.push(this.chunks[i][j]);
    }
    var hex = cryptoRequest({ op: this.algo.toLowerCase(), hex: bytesToHex(all) });
    return javaSignedBytes(hexToByteArray(hex || ''));
  };
  function JavaSecretKeySpec(keyBytes, algo) {
    this.keyBytes = javaBytesFrom(keyBytes);
    this.algo = algo;
  }
  function JavaIvParameterSpec(ivBytes) {
    this.ivBytes = javaBytesFrom(ivBytes);
  }
  function javaCipherOpts(transformation) {
    var modeStr = String(transformation || 'AES/CBC/PKCS5Padding');
    var mode = CryptoJS.mode.CBC;
    if (/ECB/i.test(modeStr)) mode = CryptoJS.mode.ECB;
    else if (/CTR/i.test(modeStr)) mode = CryptoJS.mode.CTR;
    var padding = CryptoJS.pad.Pkcs7;
    if (/NoPadding/i.test(modeStr)) padding = CryptoJS.pad.NoPadding;
    else if (/ZeroPadding/i.test(modeStr)) padding = CryptoJS.pad.ZeroPadding;
    return { mode: mode, padding: padding };
  }
  function JavaCipher(transformation) {
    this.opts = javaCipherOpts(transformation);
    this.mode = 0;
    this.keySpec = null;
    this.ivSpec = null;
  }
  JavaCipher.getInstance = function (transformation) {
    return new JavaCipher(transformation);
  };
  JavaCipher.ENCRYPT_MODE = 1;
  JavaCipher.DECRYPT_MODE = 2;
  JavaCipher.prototype.init = function (mode, keySpec, ivSpec) {
    this.mode = mode;
    this.keySpec = keySpec;
    this.ivSpec = ivSpec || null;
  };
  JavaCipher.prototype.doFinal = function (data) {
    var bytes = javaBytesFrom(data);
    var keyWA = CryptoJS.enc.Hex.parse(bytesToHex(this.keySpec ? this.keySpec.keyBytes : []));
    var cfg = { mode: this.opts.mode, padding: this.opts.padding };
    if (this.ivSpec) cfg.iv = CryptoJS.enc.Hex.parse(bytesToHex(this.ivSpec.ivBytes));
    var out;
    if (this.mode === JavaCipher.ENCRYPT_MODE) {
      var plainWA = CryptoJS.enc.Hex.parse(bytesToHex(bytes));
      out = CryptoJS.AES.encrypt(plainWA, keyWA, cfg).ciphertext;
    } else {
      var cipherWA = CryptoJS.enc.Hex.parse(bytesToHex(bytes));
      out = CryptoJS.AES.decrypt(
        CryptoJS.lib.CipherParams.create({ ciphertext: cipherWA }), keyWA, cfg);
    }
    return javaSignedBytes(dataToBytes(out));
  };
  var java = {
    lang: {
      String: JavaString,
      Byte: { TYPE: { __javaType: 'byte' } },
      Thread: function (fn) {
        this.__fn = (typeof fn === 'function') ? fn : (fn && typeof fn.run === 'function' ? fn.run : null);
      },
      reflect: {
        Array: {
          newInstance: function (type, len) {
            var a = [];
            for (var i = 0; i < (len || 0); i++) a.push(0);
            return a;
          }
        }
      }
    },
    security: { MessageDigest: JavaMessageDigest },
    util: {
      Arrays: {
        copyOfRange: function (arr, from, to) {
          return javaBytesFrom(arr).slice(from, to);
        }
      }
    }
  };
  java.lang.Thread.sleep = function (ms) {
    /* WebView 单线程，睡眠会冻住页面；Rhino 侧的等待语义在此无
       后台线程可等，空操作（包内 3 条规则只拿它做更新后延时）。 */
  };
  java.lang.Thread.prototype.start = function () {
    var fn = this.__fn;
    if (fn) setTimeout(function () { try { fn(); } catch (e) { /* ignore */ } }, 0);
  };
  var javax = {
    crypto: {
      Cipher: JavaCipher,
      spec: { SecretKeySpec: JavaSecretKeySpec, IvParameterSpec: JavaIvParameterSpec }
    }
  };
  var android = {
    util: {
      Base64: {
        DEFAULT: 0,
        NO_WRAP: 2,
        URL_SAFE: 8,
        decode: function (b64, flags) {
          return javaSignedBytes(base64ToByteArray(b64));
        }
      }
    }
  };
  try { window.java = java; } catch (e) {}
  try { window.javax = javax; } catch (e) {}
  try { window.android = android; } catch (e) {}

  // 同步存文件（POST /__savefile，base64 正文）：图片解密与
  // writeHexFile 用，避开 saveFile 的异步通道竞态。
  function saveFileSync(name, base64Text) {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('POST', window.location.origin + '/__savefile?n=' + encodeURIComponent(String(name)), false);
      xhr.send(String(base64Text || ''));
      return xhr.status === 200;
    } catch (e) { return false; }
  }

  // ---------- 图片地址归一（P1-6） ----------
  // 形态：base + [@Referer/@User-Agent/@Cookie 老式头] + [@headers={JSON}]
  // + [@js=解密代码]。@headers= 优先于老式头；@js= 取剩余整段。
  function parseImageSuffix(raw) {
    var text = stripFlags(String(raw || ''));
    var base = text;
    var headers = {};
    var jsCode = null;
    var cut = text.length;
    var markers = ['@headers=', '@Referer=', '@User-Agent=', '@Cookie=', '@js='];
    for (var i = 0; i < markers.length; i++) {
      var idx = text.indexOf(markers[i]);
      if (idx >= 0 && idx < cut) cut = idx;
    }
    base = text.slice(0, cut);
    var suffix = text.slice(cut);
    var jsIdx = suffix.indexOf('@js=');
    if (jsIdx >= 0) {
      jsCode = suffix.slice(jsIdx + 4);
      suffix = suffix.slice(0, jsIdx);
    }
    var hIdx = suffix.indexOf('@headers=');
    if (hIdx >= 0) {
      var braceStart = suffix.indexOf('{', hIdx);
      var braceEnd = braceStart >= 0 ? matchBrace(suffix, braceStart) : -1;
      if (braceEnd > braceStart) {
        try {
          var parsed = JSON.parse(suffix.slice(braceStart, braceEnd + 1));
          if (parsed && typeof parsed === 'object') {
            for (var k in parsed) {
              if (Object.prototype.hasOwnProperty.call(parsed, k)) headers[k] = String(parsed[k]);
            }
          }
        } catch (e) {}
        suffix = suffix.slice(0, hIdx) + suffix.slice(braceEnd + 1);
      }
    }
    var oldRe = /@(Referer|User-Agent|Cookie)=([^@]*)/g;
    var m;
    while ((m = oldRe.exec(suffix)) !== null) {
      var key = m[1] === 'Referer' ? 'Referer' : m[1];
      if (!(key in headers)) headers[key] = m[2];
    }
    return { base: base, headers: headers, jsCode: jsCode };
  }
  function defaultImageHeaders() {
    var h = {};
    var referer = getHome(MY_URL) || getHome(String((PROGRAM.rule && PROGRAM.rule.url) || ''));
    if (referer) h['Referer'] = referer;
    h['User-Agent'] = MOBILE_UA;
    return h;
  }
  var imageDecryptCache = {};
  var imageDecryptCacheKeys = [];
  function imageDecryptCachePut(key, value) {
    if (!(key in imageDecryptCache)) {
      imageDecryptCacheKeys.push(key);
      if (imageDecryptCacheKeys.length > 50) {
        var old = imageDecryptCacheKeys.shift();
        delete imageDecryptCache[old];
      }
    }
    imageDecryptCache[key] = value;
  }
  // @js= 图片解密：取原图字节 → 代码求值（input=字节流）→ 结果存
  // /__files/ → 返回本地地址。失败回落 /__img 原图地址（诚实降级）。
  function decryptImageSync(raw, parsed) {
    var cacheKey = raw;
    if (cacheKey in imageDecryptCache) return imageDecryptCache[cacheKey];
    var fallback = imgProxyUrl(parsed.base, parsed.headers);
    try {
      var res = rawHttpEx('GET', parsed.base, { headers: parsed.headers, toHex: true });
      var bytes = hexToByteArray(res.body || '');
      if (!bytes.length || bytes.length > 4194304) { imageDecryptCachePut(cacheKey, fallback); return fallback; }
      var stream = makeInputStream(bytes);
      var out = evalJsValue(parsed.jsCode, stream);
      var outBytes = null;
      var dataUrl = null;
      if (typeof out === 'string') {
        if (out.indexOf('data:') === 0) dataUrl = out;
        else outBytes = latin1ToBytes(out);
      } else if (out) {
        outBytes = readStreamBytes(typeof out.toInputStream === 'function' ? out.toInputStream() : out);
        if (!outBytes.length) outBytes = dataToBytes(out);
      }
      if (dataUrl) { imageDecryptCachePut(cacheKey, dataUrl); return dataUrl; }
      if (!outBytes || !outBytes.length) { imageDecryptCachePut(cacheKey, fallback); return fallback; }
      var ext = imageExtFromBytes(outBytes, parsed.base);
      var name = 'imgdec_' + Math.abs(hashString(raw)) + ext;
      if (!saveFileSync(name, byteArrayToBase64(outBytes))) {
        imageDecryptCachePut(cacheKey, fallback);
        return fallback;
      }
      var local = getPath('hiker://files/' + name);
      imageDecryptCachePut(cacheKey, local || fallback);
      return local || fallback;
    } catch (e) {
      imageDecryptCachePut(cacheKey, fallback);
      return fallback;
    }
  }
  function imageExtFromBytes(bytes, baseUrl) {
    if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) return '.jpg';
    if (bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) return '.png';
    if (bytes.length >= 4 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return '.gif';
    if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
        bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return '.webp';
    var m = /\.([a-zA-Z0-9]+)(\?|#|$)/.exec(String(baseUrl || ''));
    if (m) {
      var e = m[1].toLowerCase();
      if (e === 'jpg' || e === 'jpeg' || e === 'png' || e === 'gif' || e === 'webp' || e === 'bmp') return '.' + e;
    }
    return '.jpg';
  }
  function imgProxyUrl(base, headers) {
    var merged = defaultImageHeaders();
    for (var k in headers) {
      if (Object.prototype.hasOwnProperty.call(headers, k)) merged[k] = headers[k];
    }
    var url = window.location.origin + '/__img?u=' + encodeURIComponent(base) +
      '&h=' + encodeURIComponent(JSON.stringify(merged));
    return url;
  }
  // 图片地址统一出口：data:/blob: 原样；hiker://images/ 解内层；
  // http(s) 走 /__img（默认头 + 显式头）；@js= 先解密。
  function imageSrc(raw) {
    var pic = String(raw || '');
    if (!pic) return '';
    if (pic.indexOf('data:') === 0 || pic.indexOf('blob:') === 0) return pic;
    if (pic.indexOf('hiker://images/') === 0) {
      var inner = resolveVirtual(pic);
      if (!inner) return '';
      return imageSrc(inner);
    }
    var parsed = parseImageSuffix(pic);
    var base = parsed.base;
    if (!base) return '';
    if (!/^https?:\/\//.test(base)) {
      // 相对地址按当前页补全；补不出来原样返回。
      var resolved = /^https?:\/\//.test(MY_URL) ? resolveUrl(base, MY_URL) : base;
      if (!/^https?:\/\//.test(resolved)) return base;
      base = resolved;
      parsed.base = base;
    }
    if (parsed.jsCode) return decryptImageSync(pic, parsed);
    return imgProxyUrl(base, parsed.headers);
  }

  // ---------- getIP / 应用信息 ----------
  var cachedIp = null;
  function getIP() {
    if (cachedIp !== null) return cachedIp;
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', window.location.origin + '/__ip', false);
      xhr.send(null);
      cachedIp = xhr.status === 200 ? (xhr.responseText || '') : '';
    } catch (e) { cachedIp = ''; }
    return cachedIp;
  }
  var cachedAppInfo = null;
  function appInfo() {
    if (cachedAppInfo) return cachedAppInfo;
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', window.location.origin + '/__appinfo', false);
      xhr.send(null);
      if (xhr.status === 200) cachedAppInfo = JSON.parse(xhr.responseText || '{}');
    } catch (e) {}
    if (!cachedAppInfo) cachedAppInfo = { version: 1, ruleCount: 0 };
    return cachedAppInfo;
  }
  function getAppVersion() {
    var info = appInfo();
    var v = Number(info.version);
    return isFinite(v) && v > 0 ? Math.floor(v) : 1;
  }
  function getRuleCount() { return String(appInfo().ruleCount || 0); }
  function getCpuAbi() { return 'arm64-v8a'; }
  function getLastRules(count) {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', window.location.origin + '/__lastrules?n=' + encodeURIComponent(String(count == null ? 10 : count)), false);
      xhr.send(null);
      if (xhr.status === 200) return xhr.responseText || '[]';
    } catch (e) {}
    return '[]';
  }

  // ---------- 定时任务（registerTask，页面级） ----------
  var pageTasks = {};
  function registerTask(id, time, code) {
    var taskId = String(id == null || id === '' ? ('task_' + Math.random().toString(36).slice(2)) : id);
    var ms = Math.max(500, Math.floor(Number(time) || 1000));
    var codeStr = typeof code === 'function' ? dollarToString(code) : String(code == null ? '' : code);
    if (pageTasks[taskId]) { try { clearInterval(pageTasks[taskId].timer); } catch (e) {} }
    var timer = null;
    try {
      timer = setInterval(function () {
        try { (0, eval)(codeStr); } catch (e) { /* 任务内报错不中断后续轮次 */ }
      }, ms);
    } catch (e) { return taskId; }
    pageTasks[taskId] = { timer: timer, code: codeStr };
    return taskId;
  }
  function unRegisterTask(id) {
    try {
      if (typeof id === 'function') {
        var src = fnSource(id);
        var iife = dollarToString(id);
        for (var k in pageTasks) {
          if (pageTasks[k].code === src || pageTasks[k].code === iife) {
            clearInterval(pageTasks[k].timer);
            delete pageTasks[k];
          }
        }
        return;
      }
      var taskId = String(id);
      if (pageTasks[taskId]) {
        clearInterval(pageTasks[taskId].timer);
        delete pageTasks[taskId];
      }
    } catch (e) {}
  }
  function clearPageTasks() {
    for (var k in pageTasks) {
      try { clearInterval(pageTasks[k].timer); } catch (e) {}
    }
    pageTasks = {};
  }

  // ---------- m3u8 去广告 ----------
  // 与 Dart 侧 M3u8AdFilter 同构：按 #EXT-X-DISCONTINUITY 分组，
  // 比相邻组时长中位数短 5 秒以上的组丢掉；保留比例不足 50%
  // （>100 分片时不足 95%）则原样返回，宁可留广告不毁正片。
  function stripM3u8Ads(content) {
    var text = String(content || '');
    if (text.indexOf('#EXTM3U') < 0) return text;
    var lines = text.split('\n');
    var groups = [];
    var current = null;
    var leading = [];
    var headerLines = [];
    function isHeaderTag(line) {
      return line.indexOf('#EXT-X-VERSION') === 0 || line.indexOf('#EXT-X-TARGETDURATION') === 0 ||
        line.indexOf('#EXT-X-MEDIA-SEQUENCE') === 0 || line.indexOf('#EXT-X-PLAYLIST-TYPE') === 0 ||
        line.indexOf('#EXT-X-KEY') === 0 || line.indexOf('#EXT-X-MAP') === 0 ||
        line.indexOf('#EXT-X-ALLOW-CACHE') === 0 || line.indexOf('#EXT-X-I-FRAMES-ONLY') === 0;
    }
    for (var i = 0; i < lines.length; i++) {
      var rawLine = lines[i];
      var line = rawLine.trim();
      if (!line) continue;
      if (line === '#EXTM3U' || line === '#EXT-X-ENDLIST' || line.indexOf('#EXT-X-STREAM-INF') === 0) continue;
      // 头标签（尤其 KEY/MAP）统一收进头部重发，不绑在某个组上，
      // 否则丢掉首组时会连密钥一起丢掉。
      if (isHeaderTag(line)) { headerLines.push(rawLine); continue; }
      if (line.indexOf('#EXTINF') === 0) {
        if (!current) current = [];
        if (leading.length) { current = current.concat(leading); leading = []; }
        current.push(rawLine);
      } else if (line.indexOf('#EXT-X-DISCONTINUITY') === 0) {
        if (current && current.length) groups.push(current);
        current = [];
      } else if (line.charAt(0) === '#') {
        if (current) current.push(rawLine);
        else leading.push(rawLine);
      } else {
        if (current) current.push(rawLine);
      }
    }
    if (current && current.length) groups.push(current);
    if (groups.length <= 1) return text;
    function groupDuration(g) {
      var total = 0;
      for (var j = 0; j < g.length; j++) {
        var m = /^#EXTINF:([0-9.]+)/.exec(g[j].trim());
        if (m) total += parseFloat(m[1]) || 0;
      }
      return total;
    }
    var durations = groups.map(groupDuration);
    var keep = [];
    for (var gi = 0; gi < durations.length; gi++) {
      var neighbors = [];
      if (gi > 0) neighbors.push(durations[gi - 1]);
      if (gi < durations.length - 1) neighbors.push(durations[gi + 1]);
      if (!neighbors.length) { keep.push(true); continue; }
      neighbors.sort(function (a, b) { return a - b; });
      var median = neighbors.length === 1 ? neighbors[0] : (neighbors[0] + neighbors[neighbors.length - 1]) / 2;
      keep.push(!(median - durations[gi] >= 5.0));
    }
    var totalSegs = 0, keptSegs = 0;
    for (var k = 0; k < groups.length; k++) {
      var n = 0;
      for (var s = 0; s < groups[k].length; s++) if (groups[k][s].trim().indexOf('#EXTINF') === 0) n++;
      totalSegs += n;
      if (keep[k]) keptSegs += n;
    }
    var floor = totalSegs > 100 ? 0.95 : 0.5;
    if (totalSegs === 0 || keptSegs / totalSegs < floor) return text;
    var out = ['#EXTM3U'];
    for (var h = 0; h < headerLines.length; h++) out.push(headerLines[h]);
    var firstKept = true;
    for (var g = 0; g < groups.length; g++) {
      if (!keep[g]) continue;
      if (!firstKept) out.push('#EXT-X-DISCONTINUITY');
      firstKept = false;
      for (var r = 0; r < groups[g].length; r++) out.push(groups[g][r]);
    }
    out.push('#EXT-X-ENDLIST');
    return out.join('\n');
  }
  function clearM3u8Ad(url, options) {
    var target = stripFlags(String(url || ''));
    var opt = {};
    if (options && typeof options === 'object') opt = options;
    var content = fetch(target, opt);
    if (!content) return target;
    var cleaned = stripM3u8Ads(content);
    cleaned = fixM3u8(target, cleaned);
    var name = 'clear_' + Math.abs(hashString(target)) + '.m3u8';
    saveFile(name, cleaned);
    return getPath('hiker://files/' + name) + '##' + target;
  }
  function clearM3u8AdLazy(url, options) {
    var target = String(url || '');
    return registerLazy(function () { return clearM3u8Ad(target, options); }, target);
  }

  // ---------- WebView 取码 ----------
  // 同步 POST /__webview：Dart 侧在隐藏 WebView 里加载页面，
  // checkJs 轮询通过（或无 checkJs 时页面加载完成）后回 HTML。
  function fetchCodeByWebView(url, options) {
    var opt = options || {};
    var payload = {
      url: String(url || ''),
      headers: opt.headers || {},
      timeout: opt.timeout || 30000,
      checkJs: typeof opt.checkJs === 'function' ? fnSource(opt.checkJs) : (opt.checkJs || ''),
      blockRules: opt.blockRules || []
    };
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('POST', window.location.origin + '/__webview', false);
      xhr.send(JSON.stringify(payload));
      if (xhr.status !== 200) return '';
      var parsed = JSON.parse(xhr.responseText || '{}');
      return parsed && parsed.html ? String(parsed.html) : '';
    } catch (e) { return ''; }
  }

  // ---------- 本地代理服务（startProxyServer） ----------
  var proxyServers = {};
  var proxyServerSeq = 0;
  function startProxyServer(code) {
    var id = 'ps' + (++proxyServerSeq) + '_' + Math.random().toString(36).slice(2);
    proxyServers[id] = String(code == null ? '' : code);
    return window.location.origin + '/__proxyserver/' + id + '/proxy.m3u8';
  }
  function proxyServe(id, queryObj) {
    var code = proxyServers[id];
    if (code === undefined) return JSON.stringify({ statusCode: 404, body: '', headers: {} });
    var savedParams = MY_PARAMS;
    try { window.MY_PARAMS = queryObj || {}; MY_PARAMS = queryObj || {}; } catch (e) {}
    try {
      var out = evalJsValue(code, '');
      if (out === undefined || out === null) return '';
      return String(out);
    } catch (e) {
      return JSON.stringify({ statusCode: 500, body: '', headers: {} });
    } finally {
      try { window.MY_PARAMS = savedParams; MY_PARAMS = savedParams; } catch (e) {}
    }
  }

  // ---------- x5 单行网页（x5_webview_single） ----------
  // desc 形态：数字（像素高）/ auto / 数字&&list / 数字&&float /
  // list&&screen / float&&100% / list&&video / list&&screen-100 /
  // float&&top。返回 {heightCss, floatMode, topMode}。
  function parseX5Desc(desc) {
    var parts = String(desc || '').split('&&').map(function (p) { return p.trim(); });
    var heightCss = '240px';
    var floatMode = false;
    var topMode = false;
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (!p || p === 'list') continue;
      if (p === 'float') { floatMode = true; continue; }
      if (p === 'top') { topMode = true; floatMode = true; continue; }
      if (p === 'auto') { heightCss = '240px'; continue; }
      if (p === 'video') { heightCss = ''; continue; } // 16:9 由 aspect-ratio 定
      if (p === 'screen') { heightCss = '100vh'; continue; }
      if (p === '100%') { heightCss = '100%'; continue; }
      var sm = /^screen-(\d+)$/.exec(p);
      if (sm) { heightCss = 'calc(100vh - ' + sm[1] + 'px)'; continue; }
      if (/^\d+$/.test(p)) { heightCss = p + 'px'; continue; }
      if (/^\d+%$/.test(p)) { heightCss = p; continue; }
    }
    return { heightCss: heightCss, floatMode: floatMode, topMode: topMode, videoMode: parts.indexOf('video') >= 0 };
  }
  function x5RowHtml(it, index) {
    var url = stripFlags(String(it.url || it.link || ''));
    var spec = parseX5Desc(it.desc || '');
    var style = '';
    if (spec.topMode) style = 'position:fixed;left:0;right:0;top:120px;bottom:0;z-index:20;background:#fff;';
    else if (spec.floatMode) style = 'position:fixed;left:0;right:0;bottom:0;z-index:20;background:#fff;';
    var frameStyle = spec.videoMode ? 'width:100%;aspect-ratio:16/9;border:0;display:block;' :
      'width:100%;height:' + spec.heightCss + ';border:0;display:block;';
    return '<div class="x5wrap" style="' + escapeHtml(style) + '" data-x5-wrap="1">' +
      '<div class="x5spin">加载中…</div>' +
      '<iframe data-x5="1" data-index="' + index + '" src="' + escapeHtml(url) + '" style="' + frameStyle + '" allowfullscreen></iframe></div>';
  }
  function x5Frame() {
    try { return document.querySelector('iframe[data-x5]'); } catch (e) { return null; }
  }
  function refreshX5WebView(url) {
    var frame = x5Frame();
    if (!frame) return;
    if (url) frame.src = String(url);
    else frame.src = frame.src;
  }
  function refreshX5Desc(desc) {
    var frame = x5Frame();
    if (!frame) return;
    var spec = parseX5Desc(desc);
    if (spec.videoMode) {
      frame.style.aspectRatio = '16/9';
      frame.style.height = 'auto';
    } else {
      frame.style.aspectRatio = '';
      frame.style.height = spec.heightCss;
    }
  }
  function bindX5Frames() {
    try {
      var frames = document.querySelectorAll('iframe[data-x5]');
      Array.prototype.forEach.call(frames, function (frame) {
        frame.addEventListener('load', function () {
          var wrap = frame.parentNode;
          if (wrap) {
            var spin = wrap.querySelector('.x5spin');
            if (spin) spin.style.display = 'none';
          }
        });
      });
    } catch (e) {}
  }
  var pagePicUrl = '';
  function setPagePicUrl(url) {
    pagePicUrl = String(url || '');
    try {
      var poster = document.querySelector('.d-head .poster');
      if (poster && pagePicUrl) poster.src = imageSrc(pagePicUrl);
    } catch (e) {}
  }

  // ---------- 杂项小接口 ----------
  var downloadedOnce = {};
  function requireDownload(url, dest, headers) {
    var key = String(dest || url || '');
    if (key && downloadedOnce[key]) return String(dest || '');
    if (key) downloadedOnce[key] = true;
    return downloadFile(url, dest, headers);
  }
  function decodeStr(input, encoding) {
    try {
      var bytes = latin1ToBytes(String(input == null ? '' : input));
      var enc = String(encoding || 'utf-8').toLowerCase();
      if (typeof TextDecoder !== 'undefined') {
        try { return new TextDecoder(enc).decode(new Uint8Array(bytes)); }
        catch (e) { return new TextDecoder('utf-8').decode(new Uint8Array(bytes)); }
      }
      return String(input == null ? '' : input);
    } catch (e) { return String(input == null ? '' : input); }
  }
  function encodeStr(input, encoding) {
    // TextEncoder 只支持 UTF-8；GBK 等编码无编码表，原样返回并注明。
    return String(input == null ? '' : input);
  }
  function aesEncode(key, text) {
    try { return CryptoJS.AES.encrypt(String(text == null ? '' : text), String(key == null ? '' : key)).toString(); }
    catch (e) { return ''; }
  }
  function aesDecode(key, cipher) {
    try {
      var plain = CryptoJS.AES.decrypt(String(cipher == null ? '' : cipher), String(key == null ? '' : key));
      return CryptoJS.enc.Utf8.stringify(plain);
    } catch (e) { return ''; }
  }
  function batchExecute(tasks, listener, successCount) {
    var list = Array.isArray(tasks) ? tasks : [];
    var results = [];
    var successes = 0;
    var limit = (successCount === undefined || successCount === null) ? -1 : Number(successCount);
    for (var i = 0; i < list.length; i++) {
      if (limit >= 0 && successes >= limit) break;
      var task = list[i] || {};
      var ret = null;
      var err = '';
      try {
        if (typeof task.func === 'function') ret = task.func(task.param);
        else if (typeof task.func === 'string' && task.func) ret = evalJsValue(task.func, task.param);
        else ret = null;
        if (ret !== undefined && ret !== null && ret !== false) successes++;
        else if (ret !== undefined) successes++;
      } catch (e) { err = String(e && e.message ? e.message : e); }
      results.push(ret);
      var stop = false;
      try {
        if (listener) {
          if (typeof listener === 'function') {
            var lr = listener(task.param, task.id, err, ret);
            if (lr === 'break') stop = true;
          } else if (typeof listener.func === 'function') {
            var lr2 = listener.func(listener.param, task.id, err, ret);
            if (lr2 === 'break') stop = true;
          } else if (typeof listener.func === 'string' && listener.func) {
            var lr3 = evalJsValue(listener.func, listener.param);
            if (lr3 === 'break') stop = true;
          }
        }
      } catch (e) {}
      if (stop) break;
    }
    return results;
  }
  function syncExecute(task) {
    var t = task || {};
    if (typeof t.func === 'function') return t.func(t.param);
    if (typeof t.func === 'string' && t.func) return evalJsValue(t.func, t.param);
    return null;
  }
  function writeHexFile(path, hex) {
    try {
      var key = String(path || '').split('/').pop().split('?')[0];
      if (!key) return false;
      var bytes = hexToByteArray(hex);
      return saveFileSync(key, byteArrayToBase64(bytes));
    } catch (e) { return false; }
  }
  // 链式 http：http.fetch(url, options).headers(...).success(fn)
  // .error(fn).start()，start 后可继续 .fetch() 串联。
  function makeHttpChain() {
    var chain = {
      _url: '', _opt: {}, _headers: {}, _success: null, _error: null, _method: 'GET',
      fetch: function (url, options) {
        var next = makeHttpChain();
        next._url = String(url || '');
        next._opt = options || {};
        next._method = 'GET';
        return next;
      },
      post: function (url, options) {
        var next = makeHttpChain();
        next._url = String(url || '');
        next._opt = options || {};
        next._method = 'POST';
        return next;
      },
      request: function (url, options) {
        var next = makeHttpChain();
        next._url = String(url || '');
        next._opt = options || {};
        next._method = 'GET';
        return next;
      },
      headers: function (a, b) {
        if (typeof a === 'string' && b !== undefined) chain._headers[a] = String(b);
        else if (a && typeof a === 'object') {
          for (var k in a) {
            if (Object.prototype.hasOwnProperty.call(a, k)) chain._headers[k] = String(a[k]);
          }
        }
        return chain;
      },
      success: function (fn) { chain._success = fn; return chain; },
      error: function (fn) { chain._error = fn; return chain; },
      start: function () {
        var opt = {};
        for (var k in chain._opt) {
          if (Object.prototype.hasOwnProperty.call(chain._opt, k)) opt[k] = chain._opt[k];
        }
        opt.headers = {};
        var oh = chain._opt.headers || {};
        for (var hk in oh) {
          if (Object.prototype.hasOwnProperty.call(oh, hk)) opt.headers[hk] = oh[hk];
        }
        for (var hk2 in chain._headers) opt.headers[hk2] = chain._headers[hk2];
        opt.method = chain._method;
        var data = null;
        var failed = false;
        try {
          var res = rawHttpEx(chain._method, chain._url, opt);
          var body = res.body || '';
          try { data = JSON.parse(body); } catch (e) { data = body; }
          if (opt.withHeaders) data = { body: data, headers: res.headers || {}, statusCode: res.code };
          if (!res.code && !body) failed = true;
        } catch (e) { failed = true; }
        if (failed) {
          if (typeof chain._error === 'function') {
            try { chain._error('请求失败'); } catch (e) {}
          }
        } else if (typeof chain._success === 'function') {
          try { chain._success(data); } catch (e) {}
        }
        return chain;
      }
    };
    return chain;
  }
  var http = makeHttpChain();

  // ---------- 收藏 / 历史 / 书签（P1-19） ----------
  function collectionRequest(path, payload) {
    try {
      var xhr = new XMLHttpRequest();
      if (payload === undefined) {
        xhr.open('GET', window.location.origin + path, false);
        xhr.send(null);
      } else {
        xhr.open('POST', window.location.origin + path, false);
        xhr.send(JSON.stringify(payload));
      }
      if (xhr.status !== 200) return null;
      try { return JSON.parse(xhr.responseText || '{}'); } catch (e) { return null; }
    } catch (e) { return null; }
  }
  var lastHistoryKey = '';
  function recordHistoryThrottled(title, url, pic) {
    try {
      var u = String(url || '');
      if (!u) return;
      if (hasFlag(u, 'noHistory') || hasFlag(u, 'noRecordHistory') ||
          hasFlag(MY_URL, 'noHistory') || hasFlag(MY_URL, 'noRecordHistory')) return;
      var key = currentRuleTitle() + '|' + u;
      if (key === lastHistoryKey) return;
      lastHistoryKey = key;
      collectionRequest('/__history', {
        action: 'add', title: String(title || ''), url: u,
        rule: currentRuleTitle(), pic: String(pic || '')
      });
    } catch (e) {}
  }
  function renderCollectionList(kind, query) {
    var params = parseQueryParams(query || '');
    var path = '';
    if (kind === 'history') path = '/__history?rule=' + encodeURIComponent(params.rule || '');
    else if (kind === 'bookmark') path = '/__bookmark?rule=' + encodeURIComponent(params.rule || '');
    else path = '/__collection?rule=' + encodeURIComponent(params.rule || '') + '&group=' + encodeURIComponent(params.group || '');
    var res = collectionRequest(path);
    var entries = res && Array.isArray(res.entries) ? res.entries : [];
    var items = entries.map(function (e) {
      return {
        title: e.title || '', desc: e.rule || '', url: e.url || '',
        pic_url: e.pic || '', col_type: 'movie_1',
        extra: { __hkRule: e.rule || '' }
      };
    });
    // 收藏页追加更新信息：只对本规则条目跑 last_chapter_rule，上限 10 条。
    var hasLastChapter = String(lastChapterRuleText || (PROGRAM.rule && PROGRAM.rule.last_chapter_rule) || '');
    if (kind === 'collection' && hasLastChapter) {
      var budget = 10;
      for (var i = 0; i < items.length && budget > 0; i++) {
        var it = items[i];
        if (!it.url || !isCurrentRuleTitle(it.extra.__hkRule)) continue;
        budget--;
        var savedUrl = MY_URL;
        var savedInput = currentInput;
        try {
          setGlobals(it.url, 1);
          setCurrentInput(it.url);
          var text = evalLastChapter();
          if (text) it.desc = (it.desc ? it.desc + ' · ' : '') + '更新：' + text;
        } catch (e) {}
        setGlobals(savedUrl, MY_PAGE);
        setCurrentInput(savedInput);
      }
    }
    navStack.push({ url: MY_URL, page: MY_PAGE });
    showBack(true);
    isDetail = false;
    var label = kind === 'history' ? '历史' : (kind === 'bookmark' ? '书签' : '收藏');
    setPageTitle(label);
    render(items);
  }
  function currentPageInfo() {
    var title = '';
    var pic = '';
    try {
      title = String(detailTitle || pageTitle || '');
      var head = currentItems && currentItems[0];
      if (head) pic = String(itemPic(head) || '');
    } catch (e) {}
    return { title: title, url: MY_URL, pic: pic, rule: currentRuleTitle(), isDetail: !!isDetail };
  }
  function toggleCurrentFavorite() {
    var info = currentPageInfo();
    var res = collectionRequest('/__favorite', {
      action: 'toggle', title: info.title, url: info.url, rule: info.rule, pic: info.pic
    });
    return res && res.favorite === true;
  }

  // ---------- 聚合搜索（extra.rules，P1-17） ----------
  var resultCapture = null;
  function runAggregatedSearch(keyword, rulesCode, fromDetail) {
    var kw = String(keyword == null ? '' : keyword);
    var codeStr = String(rulesCode == null ? '' : rulesCode);
    var ruleList = null;
    try {
      var evaluated = evalJsValue(codeStr, '');
      if (Array.isArray(evaluated)) ruleList = evaluated;
      else if (typeof evaluated === 'string' && evaluated) ruleList = JSON.parse(evaluated);
    } catch (e) { ruleList = null; }
    if (!ruleList || !ruleList.length) {
      say('聚合搜索：没有可用的规则');
      return;
    }
    var savedRule = PROGRAM.rule;
    var savedMyRule = MY_RULE;
    var savedUrl = MY_URL;
    var savedPage = MY_PAGE;
    var savedType = MY_TYPE;
    var savedKeyword = searchKeyword;
    var savedIsDetail = isDetail;
    var collected = [];
    resultCapture = collected;
    isDetail = false;
    try {
      for (var i = 0; i < ruleList.length; i++) {
        var entry = ruleList[i] || {};
        var ruleObj = {
          title: entry.name || entry.title || '',
          _title: entry._title || entry.name || entry.title || '',
          name: entry.name || entry.title || '',
          url: entry.url || '',
          search_url: entry.search_url || '',
          searchFind: entry.searchFind || entry.searchfind || '',
          find_rule: entry.find_rule || '',
          pages: entry.pages || [],
          prerule: entry.prerule || ''
        };
        PROGRAM.rule = ruleObj;
        MY_RULE = ruleObj;
        try { window.MY_RULE = ruleObj; } catch (e) {}
        var tpl = String(ruleObj.search_url || '');
        var myUrl = tpl.split('**').join(kw).split('%%').join(kw)
          .replace(/\bfypage\b/g, '1').replace(/fyAll/g, '').replace(/\bfyclass\b/g, '');
        setGlobals(myUrl || 'hiker://empty', 1);
        MY_TYPE = 'search';
        try { window.MY_TYPE = MY_TYPE; } catch (e) {}
        searchKeyword = kw;
        setCurrentInput(kw);
        try {
          runPrerule();
          var script = String(ruleObj.searchFind || ruleObj.find_rule || '');
          if (script) runSource(script);
        } catch (e) { /* 单个规则失败不影响其他规则 */ }
      }
    } finally {
      resultCapture = null;
      isDetail = savedIsDetail;
      PROGRAM.rule = savedRule;
      MY_RULE = savedMyRule;
      try { window.MY_RULE = savedMyRule; } catch (e) {}
      setGlobals(savedUrl, savedPage);
      MY_TYPE = savedType;
      try { window.MY_TYPE = MY_TYPE; } catch (e) {}
      searchKeyword = savedKeyword;
      setCurrentInput(savedKeyword);
    }
    navStack.push({ url: savedUrl, page: savedPage });
    showBack(true);
    isDetail = false;
    render(collected);
  }

  var API = {
    fetch: fetch, request: request, post: post, getResCode: getResCode,
    fetchCookie: fetchCookie, fetchPC: fetchPC, postPC: postPC,
    batchFetch: batchFetch, bf: batchFetch, buildUrl: buildUrl,
    pdfa: pdfa, pdfh: pdfh, pd: parseDom, parseDoc: parseDoc,
    parseDom: parseDom, parseDomForHtml: parseDomForHtml, parseDomForArray: parseDomForArray,
    xpath: xpath, xpathArray: xpathArray, xpa: xpathArray,
    setResult: setResult, setHomeResult: setResult, setSearchResult: setResult,
    setPreResult: setPreResult,
    refreshPage: refreshPage, setPage: setPage, join: join, play: play, open: open,
    playVideo: playVideo, download: download,
    toast: toast, log: log, sleep: sleep,
    showLoading: showLoading, hideLoading: hideLoading,
    confirm: confirmFn, alert: dialogAlert,
    getVar: getVar, putVar: putVar, clearVar: clearVar,
    getMyVar: getMyVar, putMyVar: putMyVar, clearMyVar: clearMyVar, listMyVarKeys: listMyVarKeys,
    getItem: getItem, setItem: setItem, clearItem: clearItem,
    getPublicItem: getPublicItem, setPublicItem: setPublicItem, clearPublicItem: clearPublicItem,
    getCookie: getCookie, setCookie: setCookie,
    saveFile: saveFile, writeFile: writeFile, getPath: getPath,
    readFile: readFile, deleteFile: deleteFile, fileExist: fileExist,
    downloadFile: downloadFile, saveImage: saveImage, convertBase64Image: convertBase64Image,
    fixM3u8: fixM3u8, cacheM3u8: cacheM3u8, batchCacheM3u8: batchCacheM3u8, bcm: batchCacheM3u8,
    clearM3u8Ad: clearM3u8Ad, clearM3u8AdLazy: clearM3u8AdLazy,
    fetchCodeByWebView: fetchCodeByWebView,
    startProxyServer: startProxyServer,
    registerTask: registerTask, unRegisterTask: unRegisterTask,
    getIP: getIP, getAppVersion: getAppVersion, getRuleCount: getRuleCount,
    getCpuAbi: getCpuAbi, getLastRules: getLastRules,
    refreshX5WebView: refreshX5WebView, refreshX5Desc: refreshX5Desc,
    setPagePicUrl: setPagePicUrl, requireDownload: requireDownload,
    decodeStr: decodeStr, encodeStr: encodeStr,
    aesEncode: aesEncode, aesDecode: aesDecode,
    batchExecute: batchExecute, be: batchExecute, syncExecute: syncExecute,
    writeHexFile: writeHexFile, http: http, storage0: storage0,
    require: requireRemote, requireCache: requireCache, rc: requireCache,
    fetchCache: fetchCache, fc: fetchCache, deleteCache: deleteCache,
    getPageTitle: getPageTitle, setPageTitle: setPageTitle, getUrl: getUrl,
    getParam: getParam, getHome: getHome, getRule: getRule,
    setError: setError, error: setError, getColTypes: getColTypes,
    back: back, copy: copyFn,
    getSearchMode: getSearchMode, setSearchMode: setSearchMode, searchContains: searchContains,
    updateItem: updateItem, deleteItem: deleteItem, deleteItemByCls: deleteItemByCls,
    addItemAfter: addItemAfter, addItemBefore: addItemBefore,
    findItem: findItem, findItemsByCls: findItemsByCls,
    initConfig: initConfig, setPageParams: setPageParams,
    setLastChapterRule: setLastChapterRule,
    md5: md5, sha1: sha1, sha256: sha256, sha512: sha512,
    rc4: rc4, hexToBytes: hexToBytes, hexToBase64: hexToBase64,
    registerDNS: registerDNS, dns: dnsFn,
    getCryptoJS: getCryptoJS, CryptoJS: CryptoJS,
    base64Encode: base64Encode, base64Decode: base64Decode,
    MY_URL: MY_URL, MY_RULE: MY_RULE, MY_PAGE: MY_PAGE, MY_TYPE: MY_TYPE,
    MY_HOME: getHome(MY_URL), MY_PARAMS: MY_PARAMS, MY_NAME: MY_NAME,
    MY_CLASS_URL: MY_CLASS_URL, MY_AREA: MY_AREA, MY_SORT: MY_SORT, MY_YEAR: MY_YEAR,
    fypage: fypage, fyclass: fyclass, fyarea: fyarea, fyyear: fyyear,
    MOBILE_UA: MOBILE_UA, PC_UA: PC_UA, config: config, input: currentInput
  };
  Object.keys(API).forEach(function (key) { window[key] = API[key]; });
  window.$ = $;
  window.$$$ = $;
  window.$$ = $;
  window.MY_URL = MY_URL;
  window.MY_RULE = MY_RULE;
  window.MY_PAGE = MY_PAGE;
  window.MY_TYPE = MY_TYPE;
  window.MY_PARAMS = MY_PARAMS;
  window.MY_NAME = MY_NAME;
  window.MY_CLASS_URL = MY_CLASS_URL;
  window.MY_AREA = MY_AREA;
  window.MY_SORT = MY_SORT;
  window.MY_YEAR = MY_YEAR;
  window.fypage = fypage;
  window.fyclass = fyclass;
  window.fyarea = fyarea;
  window.fyyear = fyyear;
  window.input = currentInput;
  window.window0 = window;
  window._base64 = {
    encode: base64Encode,
    decode: base64Decode,
    encodeToString: base64Encode,
    decodeToString: base64Decode
  };
  // CryptoJS 子集的 SHA/HMAC 走 Dart 摘要接口（十六进制字节输入）。
  window.__haikuoHash = function (op, hexText, isHex) {
    if (isHex) return cryptoRequest({ op: op, hex: String(hexText || '') });
    return cryptoRequest({ op: op, text: String(hexText || '') });
  };
  window.__haikuoHmac = function (op, keyHex, msgHex) {
    return cryptoRequest({ op: 'hmac-' + op, keyHex: String(keyHex || ''), msgHex: String(msgHex || '') });
  };
  // PBKDF2 走 Dart 端（见 CryptoJS 工厂）。
  window.__haikuoPbkdf2 = function (passwordHex, saltHex, iterations, keyBytes, hash) {
    return cryptoRequest({
      op: 'pbkdf2', passwordHex: String(passwordHex || ''), saltHex: String(saltHex || ''),
      iterations: iterations, keyBytes: keyBytes, hash: String(hash || 'sha1')
    });
  };
  // crypto-java 桥模块工厂（hiker://assets/crypto-java.js 的合成内容用）。
  window.__haikuoCryptoJava = makeCryptoJavaModule;
  // 本地代理服务执行入口（Dart 侧 /__proxyserver/ 回调）。
  window.__haikuoProxyServe = function (id, queryJson) {
    var queryObj = {};
    try { queryObj = JSON.parse(queryJson || '{}') || {}; } catch (e) {}
    return proxyServe(String(id), queryObj);
  };
  // 原生收藏按钮与跨规则进详情的钩子。
  window.__haikuoCurrentPage = function () {
    try { return JSON.stringify(currentPageInfo()); } catch (e) { return '{}'; }
  };
  window.__haikuoToggleFavorite = function () {
    try { return toggleCurrentFavorite() ? '1' : '0'; } catch (e) { return '0'; }
  };
  window.__haikuoOpenDetail = function (url) {
    try { openDetail(String(url || '')); } catch (e) {}
  };
  window.__haikuoSearch = function (keyword) {
    try { runSearch(String(keyword || ''), 1); } catch (e) {}
  };
  // 浏览器原生对话框改走原生弹窗：WebView 默认行为大概率直接
  // 返回 false，规则的确认分支永远走不到。
  try { window.confirm = confirmFn; } catch (e) {}
  try { window.alert = dialogAlert; } catch (e) {}
  try {
    window.prompt = function (text, defVal) {
      var v = dialogInput(defVal || '', '', String(text || ''));
      return v === null ? null : v;
    };
  } catch (e) {}
  window.addEventListener('pagehide', function () {
    clearPageTasks();
    closeListeners.forEach(function (code) {
      try { (0, eval)(String(code)); } catch (e) { /* ignore */ }
    });
  });

  // 供原生播放器切集：按详情选集序号重走点选同一集的完整链路
  // （lazy 解析、saveFile、play 消息都与手动点选一致）。
  window.__haikuoPlayEpisode = function (index) {
    var it = currentEpisodes[Number(index)];
    if (it) openItem(it);
  };
  window.__haikuoEpisodeCount = function () { return currentEpisodes.length; };
  // 供原生内嵌播放：播放器顶在页面上方时藏起详情头项海报墙，
  // 海报墙就地由播放器代替；关闭播放器时恢复海报墙。
  window.__haikuoSetInlinePlaying = function (on) {
    try {
      if (document.body && document.body.classList) {
        if (on) document.body.classList.add('hk-inline-playing');
        else document.body.classList.remove('hk-inline-playing');
      }
    } catch (e) {}
  };
  // 详情页海报播放键：播第一集（无选集时播头项本身），与
  // 手动点选第一集同一条链路。
  window.__haikuoPlayFirst = function () {
    var it = firstPlayTarget();
    if (it) openItem(it, true);
  };
  // 海报播放键点按：截住冒泡，别触发头项的 openItem 重开详情；
  // 播放链路与 __haikuoPlayFirst 相同。
  window.__haikuoPosterTap = function (event) {
    if (event && typeof event.stopPropagation === 'function') event.stopPropagation();
    window.__haikuoPlayFirst();
  };

  function boot() {
    var backBtn = document.getElementById('backBtn');
    if (backBtn) backBtn.addEventListener('click', goBack);
    isDetail = false;
    seedStorage();
    syncFilterGlobals();
    var source = String(PROGRAM.script || '');
    if (source.indexOf('js:') === 0) source = source.slice(3);
    if (!source.trim()) {
      // 主脚本为空时，chapter_find / movie_find 当兜底入口。
      var rule = PROGRAM.rule || {};
      source = String(rule.chapter_find || rule.movie_find || '');
      if (source.indexOf('js:') === 0) source = source.slice(3);
    }
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
    runPrerule();
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
