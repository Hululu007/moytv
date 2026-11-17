(function () {
var UI = {};
UI.engine = 'aveyp';
UI.MV = 'aveyp_';

UI.navs = function (d, cats, current) {
  var navs = [{ title: '首页', id: '0' }];
  for (var i = 0; i < cats.length; i++) navs.push({ title: cats[i].name, id: String(i + 1) });
  for (var j = 0; j < navs.length; j++) {
    var active = String(current) === String(navs[j].id);
    d.push({
      title: (active ? '✓ ' : '') + navs[j].title,
      col_type: 'scroll_button',
      url: $('#noLoading##noRecordHistory#').lazyRule(function (s) {
        putMyVar('aveyp_cat', s);
        putMyVar('aveyp_pg', '1');
        refreshPage(true);
        return 'hiker://empty';
      }, navs[j].id),
      extra: { backgroundColor: active ? '#22c55e' : '' }
    });
  }
  d.push({ col_type: 'line_blank' });
};

UI.searchBox = function (d) {
  d.push({
    title: '🔍 搜索',
    desc: '输入关键词搜索',
    url: $.toString(function () {
      if (input) {
        putMyVar('aveyp_keyword', input);
        return $('hiker://empty?page=fypage&kw=' + encodeURIComponent(input)).rule(function () { $.require('aveyp').search(); });
      }
      return 'hiker://empty';
    }),
    col_type: 'input',
    extra: { onChange: $.toString(function () { putMyVar('aveyp_keyword', input); }) }
  });
  d.push({ col_type: 'line_blank' });
};

UI.cards = function (d, cards) {
  for (var i = 0; i < cards.length; i++) {
    var c = cards[i];
    d.push({
      title: c.vod_name,
      pic_url: c.vod_pic,
      desc: c.vod_remarks || '',
      url: 'hiker://empty?vod_id=' + c.vod_id + '#immersiveTheme#@rule=js:$.require("aveyp").detail("' + c.vod_id + '")',
      col_type: 'movie_3'
    });
  }
};

UI.pager = function (d, pg, pc) {
  if (pc <= 1) return;
  d.push({ col_type: 'line_blank' });
  if (pg > 1) {
    d.push({
      title: '上一页',
      url: $('#noLoading#').lazyRule(function (p) {
        putMyVar('aveyp_pg', String(parseInt(p, 10) - 1));
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
        putMyVar('aveyp_pg', String(parseInt(p, 10) + 1));
        refreshPage(false);
        return 'hiker://empty';
      }, String(pg)),
      col_type: 'text_1'
    });
  }
};

UI.render = function (data) {
  var d = [];
  var cats = data.cats || [];
  var cur = data.catIdx || 0;
  UI.navs(d, cats, cur);
  UI.searchBox(d);
  var secTitle = data.isHome ? '▍ 首页推荐' : ('▍ ' + (cats[cur - 1] ? cats[cur - 1].name : ''));
  d.push({ title: secTitle, url: 'hiker://empty', col_type: 'text_1' });
  var cards = data.cards || [];
  if (!cards.length) {
    d.push({ title: '暂无数据', url: 'hiker://empty', col_type: 'text_1' });
  } else {
    UI.cards(d, cards);
  }
  UI.pager(d, data.pg || 1, data.pc || 1, cur);
  setResult(d);
};

UI.renderSearch = function (data) {
  var d = [];
  d.push({ title: '搜索：' + (data.keyword || '') + '（第' + (data.pg || 1) + '页）', url: 'hiker://empty', col_type: 'text_1' });
  var cards = data.cards || [];
  if (!cards.length) {
    d.push({ title: '暂无数据', url: 'hiker://empty', col_type: 'text_1' });
  } else {
    UI.cards(d, cards);
  }
  setResult(d);
};

UI.renderDetail = function (data) {
  var d = [];
  d.push({
    title: data.vod_name,
    pic_url: data.vod_pic,
    desc: data.vod_remarks || '',
    url: 'hiker://empty',
    col_type: 'movie_1_vertical_pic_blur'
  });
  var lines0 = data.lines || [];
  for (var li = 0; li < lines0.length; li++) {
    d.push({ title: lines0[li].name || '默认线路', url: 'hiker://empty', col_type: 'text_1' });
  }
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
  setResult(d);
};

$.exports = UI;
})();
