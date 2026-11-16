js:(function () {
var UI = {};
UI.engine = 'fem';

// 顶部横滑分类: 17 项平铺, 无二级筛选
UI.navs = function (d, cats, current) {
for (var j = 0; j < cats.length; j++) {
var active = String(current) === String(j);
d.push({
title: (active ? '✓ ' : '') + cats[j].name,
col_type: 'scroll_button',
url: $('#noLoading##noRecordHistory#').lazyRule(function (s) {
putMyVar('fem_cat', s);
putMyVar('fem_page', '1');
refreshPage(true);
return 'hiker://empty';
}, String(j)),
extra: { backgroundColor: active ? '#22c55e' : '' }
});
}
d.push({ col_type: 'line_blank' });
};

UI.renderHome = function (data) {
var d = [];

var cats = data.cats || [];
var cls = '';
try { cls = String(getMyVar('fem_cat', '0')); } catch (e) {}

UI.navs(d, cats, cls);

// 搜索框
d.push({
title: '🔍 搜索',
desc: (data.search && data.search.placeholder) || '',
url: $.toString(function () {
if (input) {
putMyVar('keyword', input);
return $('hiker://empty?page=fypage&kw=' + encodeURIComponent(input)).rule(function () { $.require('fem').search(); });
}
return 'hiker://empty';
}),
col_type: 'input',
extra: { onChange: $.toString(function () { putMyVar('keyword', input); }) }
});
d.push({ col_type: 'line_blank' });

var items = data.items || [];
for (var k = 0; k < items.length; k++) {
d.push({
title: items[k].vod_name,
pic_url: items[k].vod_pic,
desc: items[k].vod_remarks || '',
url: items[k].url,
col_type: 'movie_3'
});
}
if (!items.length) {
d.push({ title: '暂无数据', url: 'hiker://empty', col_type: 'text_center_1' });
}
var pg = parseInt(data.page || '1', 10) || 1;
var pc = parseInt(data.pagecount || '1', 10) || 1;
if (pg > 1) {
d.push({
title: '‹ 上一页',
url: $('#noLoading#').lazyRule(function (p) {
putMyVar('fem_page', String(parseInt(p, 10) - 1));
refreshPage(false);
return 'hiker://empty';
}, String(pg)),
col_type: 'text_center_1'
});
}
if (pg < pc) {
d.push({
title: '下一页 ›（第' + pg + '页）',
url: $('#noLoading#').lazyRule(function (p) {
putMyVar('fem_page', String(parseInt(p, 10) + 1));
refreshPage(false);
return 'hiker://empty';
}, String(pg)),
col_type: 'text_center_1'
});
}
setResult(d);
};

UI.renderDetail = function (data) {
var d = [];
d.push({
title: data.title,
desc: '',
pic_url: data.pic || '',
url: data.pic ? data.pic + '#.jpg#' : 'hiker://empty',
col_type: 'movie_1_vertical_pic_blur',
extra: { gradient: true }
});
if (data.desc) {
d.push({ title: data.desc.substring(0, 120) + (data.desc.length > 120 ? '...' : ''), url: 'hiker://empty', col_type: 'text_1' });
d.push({ col_type: 'line' });
}
var lines = data.lines || [];
var cur = 0;
try { cur = parseInt(getMyVar('fem_line', '0'), 10) || 0; } catch (e) {}
if (cur >= lines.length) cur = 0;
for (var li = 0; li < lines.length; li++) {
var active = li === cur;
d.push({
title: (active ? '✓ ' : '') + lines[li],
url: $('#noLoading#').lazyRule(function (idx) {
putMyVar('fem_line', idx);
refreshPage(false);
return 'hiker://empty';
}, String(li)),
col_type: 'text_2',
extra: { backgroundColor: active ? '#22c55e' : '' }
});
}
if (lines.length) d.push({ col_type: 'line_blank' });
var eps = data.episodes || [];
for (var i = 0; i < eps.length; i++) {
d.push({ title: eps[i].name, url: eps[i].url, col_type: 'text_3' });
}
setResult(d);
};

UI.renderSearch = function (data) {
var d = [];
var items = data.items || [];
if (!items.length) {
d.push({ title: '未找到相关内容', url: 'hiker://empty', col_type: 'text_center_1' });
}
for (var i = 0; i < items.length; i++) {
d.push({
title: items[i].vod_name,
pic_url: items[i].vod_pic,
desc: items[i].vod_remarks || '',
url: items[i].url,
col_type: 'movie_3'
});
}
var pg = parseInt(data.page || '1', 10) || 1;
var pc = parseInt(data.pagecount || '1', 10) || 1;
if (pg > 1) {
d.push({
title: '‹ 上一页',
url: $('#noLoading#').lazyRule(function (p) {
putMyVar('fem_spage', String(parseInt(p, 10) - 1));
refreshPage(false);
return 'hiker://empty';
}, String(pg)),
col_type: 'text_center_1'
});
}
if (pg < pc) {
d.push({
title: '下一页 ›（第' + pg + '页）',
url: $('#noLoading#').lazyRule(function (p) {
putMyVar('fem_spage', String(parseInt(p, 10) + 1));
refreshPage(false);
return 'hiker://empty';
}, String(pg)),
col_type: 'text_center_1'
});
}
setResult(d);
};

$.exports = UI;
})();
