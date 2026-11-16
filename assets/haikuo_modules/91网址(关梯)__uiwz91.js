// 91网址 UI uiwz91（QQ音乐 v19 uiq16 风格，二级分类筛选行）
var UI = UI || {};
UI.MV = 'wz91_';

// 主分类胶囊行：亚色影库模式（putMyVar + refreshPage(true)）；切换主分类时清空二级
UI.navs = function (d, cats, current) {
  var navs = [{title: '首页', id: '0'}];
  for (var i = 0; i < cats.length; i++) navs.push({title: cats[i].name, id: String(i + 1)});
  for (var j = 0; j < navs.length; j++) {
    var active = String(current) === String(navs[j].id);
    d.push({
      title: (active ? '✓ ' : '') + navs[j].title,
      col_type: 'scroll_button',
      url: $('#noLoading##noRecordHistory#').lazyRule(function (s) {
        putMyVar('wz91_cat', s);
        putMyVar('wz91_pg', '1');
        putMyVar('wz91_sub', '');
        refreshPage(true);
        return 'hiker://empty';
      }, navs[j].id),
      extra: {backgroundColor: active ? '#22c55e' : ''}
    });
  }
  d.push({col_type: 'line_blank'});
};

// 二级分类筛选行：行首 text_1 标签 + 胶囊选项（uiq16 形态）；切换时重置页码
UI.subRow = function (d, subs, current) {
  if (!subs || !subs.length) return;
  d.push({title: '二级分类', col_type: 'text_1'});
  for (var j = 0; j < subs.length; j++) {
    var active = String(current || '') === String(subs[j].id);
    d.push({
      title: (active ? '✓ ' : '') + subs[j].name,
      col_type: 'scroll_button',
      url: $('#noLoading#').lazyRule(function (s) {
        putMyVar('wz91_sub', s);
        putMyVar('wz91_pg', '1');
        refreshPage(true);
        return 'hiker://empty';
      }, subs[j].id),
      extra: {backgroundColor: active ? '#22c55e' : ''}
    });
  }
  d.push({col_type: 'line_blank'});
};

// 搜索框：fypage 子页（标准写法：$.toString 包裹，先存关键词再开子页）
UI.searchBox = function (d) {
  d.push({
    title: '请输入内容',
    desc: '🔍 搜索',
    col_type: 'input',
    url: $.toString(function () {
      if (input) {
        putMyVar('wz91_keyword', input);
        return $('hiker://empty?page=fypage').rule(function () {
          $.require('uiwz91').searchPage();
        });
      }
      return 'hiker://empty';
    })
  });
};

// 搜索子页
UI.searchPage = function () {
  var kw = '';
  try { kw = getParam('kw') || ''; } catch (e) {}
  if (!kw) { try { kw = getMyVar('wz91_keyword', ''); } catch (e2) {} }
  if (!kw) { try { kw = MY_KEYWORD || ''; } catch (e3) {} }
  while (/%[0-9a-fA-F]{2}/.test(kw)) { try { kw = decodeURIComponent(kw); } catch (e) { break; } }
  setResult(UI.renderSearch($.require('wz91').search(kw, 1)));
};

// 翻页：亚色影库模式（putMyVar + refreshPage(false)）
UI.pager = function (d, pg, pc) {
  if (pc <= 1) return;
  d.push({col_type: 'line_blank'});
  if (pg > 1) {
    d.push({
      title: '上一页',
      url: $('#noLoading#').lazyRule(function (p) {
        putMyVar('wz91_pg', String(parseInt(p, 10) - 1));
        refreshPage(false);
        return 'hiker://empty';
      }, String(pg)),
      col_type: 'text_1'
    });
  }
  if (pg < pc) {
    d.push({
      title: '下一页（' + pg + '/' + pc + '）',
      url: $('#noLoading#').lazyRule(function (p) {
        putMyVar('wz91_pg', String(parseInt(p, 10) + 1));
        refreshPage(false);
        return 'hiker://empty';
      }, String(pg)),
      col_type: 'text_1'
    });
  }
};

// 首页渲染
UI.renderHome = function (data) {
  var d = [];
  UI.navs(d, data.cats || [], data.catIdx || 0);
  UI.searchBox(d);
  // 二级分类筛选行（仅主分类页显示）
  if (data.catIdx > 0 && data.tid) {
    var subs = $.require('wz91').SUBS[data.tid] || [];
    UI.subRow(d, subs, data.sub || '');
  }
  var cards = data.cards || [];
  if (!cards.length && data.diag) {
    d.push({title: '诊断：' + data.diag, col_type: 'text_1'});
  }
  if (cards.length) {
    d.push({title: '▍ ' + (data.title || '91网址'), col_type: 'text_1'});
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i];
      d.push({
        title: c.vod_name,
        desc: c.vod_remarks || '',
        pic_url: c.vod_pic || '',
        url: c.url,
        col_type: 'movie_3'
      });
    }
    UI.pager(d, data.pg || 1, data.pc || 1);
  }
  return d;
};

// 搜索渲染
UI.renderSearch = function (data) {
  var d = [];
  var cards = data.cards || [];
  if (!cards.length) {
    d.push({title: '暂无结果' + (data.diag ? '（诊断：' + data.diag + '）' : ''), col_type: 'text_1'});
  } else {
    d.push({title: '▍ ' + (data.title || '搜索'), col_type: 'text_1'});
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i];
      d.push({
        title: c.vod_name,
        desc: c.vod_remarks || '',
        pic_url: c.vod_pic || '',
        url: c.url,
        col_type: 'movie_3'
      });
    }
  }
  return d;
};

// 详情渲染：单线路，无线路标签行，直接选集按钮
UI.renderDetail = function (data) {
  var d = [];
  d.push({
    title: data.vod_name || '91网址',
    desc: data.vod_remarks || '',
    pic_url: data.vod_pic || '',
    url: 'hiker://empty',
    col_type: 'movie_1_vertical_pic_blur'
  });
  d.push({col_type: 'line_blank'});
  var lines = data.lines || [];
  for (var i = 0; i < lines.length; i++) {
    var eps = lines[i].eps || [];
    for (var j = 0; j < eps.length; j++) {
      d.push({
        title: eps[j].name,
        url: eps[j].url,
        col_type: 'text_3'
      });
    }
  }
  return d;
};

UI.home = function () {
  var data = $.require('wz91').home();
  setResult(UI.renderHome(data));
};

UI.detail = function (vidArg) {
  var data = $.require('wz91').detail(vidArg);
  setResult(UI.renderDetail(data));
};

$.exports = UI;
