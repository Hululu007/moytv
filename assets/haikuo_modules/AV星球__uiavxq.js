js:
(function () {
var UI = {};
UI.engine = 'avxq';

UI.navs = function (d, cats, current) {
  for (var j = 0; j < cats.length; j++) {
    var active = String(current) === String(j);
    d.push({
      title: (active ? '✓ ' : '') + cats[j].name,
      col_type: 'scroll_button',
      url: $('#noLoading##noRecordHistory#').lazyRule(function (s) {
        putMyVar('avxq_cat', s);
        putMyVar('avxq_page', '1');
        refreshPage(true);
        return 'hiker://empty';
      }, String(j)),
      extra: {backgroundColor: active ? '#22c55e' : ''}
    });
  }
  d.push({col_type: 'line_blank'});
};

UI.searchBox = function (d) {
  d.push({
    title: '🔍 搜索',
    desc: '搜索视频...',
    url: $.toString(function () {
      if (input) {
        return $('hiker://empty?page=fypage&kw=' + encodeURIComponent(input)).rule(function () { $.require('avxq').search(); });
      }
      return 'hiker://empty';
    }),
    col_type: 'input'
  });
  d.push({col_type: 'line_blank'});
};

UI.cards = function (d, items) {
  for (var k = 0; k < items.length; k++) {
    var it = items[k];
    d.push({
      title: it.title,
      pic_url: it.pic,
      desc: it.remarks || '',
      url: 'hiker://empty?vod_id=' + it.id + '#immersiveTheme#@rule=js:$.require("avxq").detail("' + it.id + '")',
      col_type: 'movie_3'
    });
  }
};

// 亚色模式翻页：putMyVar + refreshPage
UI.pager = function (d, pg, hasMore, varName) {
  var vn = varName || 'avxq_page';
  if (pg > 1) {
    d.push({
      title: '‹ 上一页',
      url: $('#noLoading#').lazyRule(function (p, vname) {
        putMyVar(vname, String(parseInt(p, 10) - 1));
        refreshPage(false);
        return 'hiker://empty';
      }, String(pg), vn),
      col_type: 'text_center_1'
    });
  }
  if (hasMore) {
    d.push({
      title: '下一页 ›（第' + pg + '页）',
      url: $('#noLoading#').lazyRule(function (p, vname) {
        putMyVar(vname, String(parseInt(p, 10) + 1));
        refreshPage(false);
        return 'hiker://empty';
      }, String(pg), vn),
      col_type: 'text_center_1'
    });
  }
};

UI.renderHome = function (data) {
  var d = [];
  var cats = data.cats || [];
  var cat = data.cat || 0;
  UI.navs(d, cats, cat);
  UI.searchBox(d);
  d.push({title: '▍ ' + (cats[cat] ? cats[cat].name : ''), url: 'hiker://empty', col_type: 'text_1'});
  var items = data.items || [];
  UI.cards(d, items);
  if (!items.length) d.push({title: '暂无数据', url: 'hiker://empty', col_type: 'text_center_1'});
  UI.pager(d, data.page || 1, data.hasMore, 'avxq_page');
  setResult(d);
};

UI.renderSearch = function (data) {
  var d = [];
  UI.searchBox(d);
  d.push({title: '▍ 搜索：' + data.kw, url: 'hiker://empty', col_type: 'text_1'});
  var items = data.items || [];
  UI.cards(d, items);
  if (!items.length) d.push({title: '无搜索结果', url: 'hiker://empty', col_type: 'text_center_1'});
  UI.pager(d, data.page || 1, data.hasMore, 'avxq_spage');
  setResult(d);
};

UI.renderDetail = function (data) {
  var d = [];
  if (data.vod_pic) {
    d.push({
      title: data.vod_name,
      pic_url: data.vod_pic,
      url: data.vod_pic + '#.jpg#',
      col_type: 'movie_1_vertical_pic_blur'
    });
  } else {
    d.push({title: data.vod_name, url: 'hiker://empty', col_type: 'text_1'});
  }
  if (data.play_url) {
    var parts = String(data.play_url).split('$');
    if (parts.length >= 2) {
      d.push({
        title: '▶ ' + parts[0],
        url: parts[1] + '#isVideo=true#',
        col_type: 'text_3'
      });
    }
  } else {
    d.push({title: '暂无播放地址', url: 'hiker://empty', col_type: 'text_center_1'});
  }
  setResult(d);
};

$.exports = UI;
})();