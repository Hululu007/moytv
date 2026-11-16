js:
// ==== UILib 可复用 UI 渲染模块（奈雪影视技法蒸馏，小仙女适配版：无设置子页）====
(function () {
  var UI = {};
  // 本源的引擎子页面 path
  UI.engine = 'cb';
  // 强调前缀：两个左引号+两个右引号
  var Q = '\u2018\u2018\u2019\u2019';

  // 随机色
  UI.rndColor = function () {
    return '#' + ('00000' + (Math.random() * 0x1000000 << 0).toString(16)).substr(-6);
  };

  // 高亮按钮
  UI.hi = function (text, active) {
    return active ? Q + '<b><font color="#FF5D50">' + text + '</font></b>' : text;
  };

  // 轮播（含开关）
  UI.banner = function (d, cfg) {
    var id = Math.random().toString(36).substr(2, 5) + 'lunbo';
    var items = cfg.items || [];
    if (!items.length) return;
    var time = cfg.time || 4000;
    var rnum = Math.floor(Math.random() * items.length);
    putMyVar('rnum', rnum);
    var first = items[rnum];
    d.push({
      col_type: 'pic_1_card', img: first.img || first.pic,
      desc: first.desc || '', title: first.title, url: first.url,
      extra: { id: id + 'bar' }
    });
    if (cfg.switchable === false) return;
    registerTask(id, time, $.toString(function (obj) {
      var id = obj.id;
      var data = obj.data;
      var i = Number(getMyVar('rnum', '0')) + 1;
      if (i > data.length - 1) i = 0;
      var item = data[i];
      try {
        updateItem(id + 'bar', { title: item.title, desc: item.desc || '', img: item.img || item.pic, url: item.url });
      } catch (e) { unRegisterTask(id); }
      putMyVar('rnum', i);
    }, { id: id, data: items }));
  };

  // 分类导航（scroll_button，高亮）。注意点首页时必须同时清全局筛选，否则返回首页残留筛选/分页状态。
  UI.navs = function (d, navs, current) {
    for (var i = 0; i < navs.length; i++) {
      var active = String(current) === String(navs[i].id);
      var sid = navs[i].id;
      d.push({
        title: UI.hi(navs[i].title, active),
        col_type: 'scroll_button',
        url: $('#noLoading##noRecordHistory#').lazyRule(function (s) {
          putMyVar('sd_cls', s); clearMyVar('sd_filter');
          putMyVar('sd_page', '1');
          putVar('sd_filter', '{}'); putVar('sd_fold', '0');  // 清全局筛选+折叠态
          refreshPage(true); return 'hiker://empty';
        }, sid),
        extra: { backgroundColor: active ? '#20FA7298' : '' }
      });
    }
    d.push({ col_type: 'line_blank' });
  };

  // 折叠筛选（推入主数组，保证“大类在上、筛选在下”）
  UI.filters = function (d, filters, filterKey, foldKey) {
    if (!filters.length) return;
    var s = d;   // 直接复用主数组，不再 setPreResult
    var fold = getVar(foldKey, '0');
    s.push({
      title: fold === '1' ? Q + '➥'.fontcolor('#9370db') : Q + '➦'.fontcolor('#ffbf00'),
      url: $('#noLoading#').lazyRule(function (fk, fold) {
        putVar(fk, fold === '1' ? '0' : '1'); refreshPage(false); return 'hiker://empty';
      }, foldKey, fold),
      col_type: 'scroll_button'
    });
    var state = JSON.parse(getVar(filterKey, '{}'));
    for (var fi = 0; fi < filters.length; fi++) {
      var section = filters[fi];
      if (fold !== '1' && fi > 0) break;   // 折叠时只显示第1维度
      for (var oi = 0; oi < section.options.length; oi++) {
        var opt = section.options[oi];
        var isActive = state[section.key] === opt.value;
        var t = opt.name;
        if (fold === '1' && fi > 0) t = Q + (isActive ? '<b>' + opt.name.fontcolor('#ffffff').small() + '</b>' : opt.name.small());
        else if (isActive) t = Q + opt.name.fontcolor('#ffffff').bold();
        s.push({
          title: t,
          url: $('#noLoading#').lazyRule(function (params) {
            var st = JSON.parse(getVar(params.k, '{}'));
            st[params.key] = params.val; putVar(params.k, JSON.stringify(st));
            refreshPage(true); return 'hiker://empty';
          }, { k: filterKey, key: section.key, val: opt.value }),
          col_type: 'scroll_button',
          extra: { backgroundColor: isActive ? UI.rndColor() : '' }
        });
      }
      s.push({ col_type: 'blank_block' });
    }
    d.push({ col_type: 'line_blank' });
  };

  // 分区标题（text_icon 带图标）
  UI.sectionTitle = function (d, title, icon, url) {
    d.push({
      title: '▍'.fontcolor(UI.rndColor()) + '<b>' + title + '</b>'.fontcolor('Black'),
      pic_url: icon || '', url: url || 'hiker://empty',
      col_type: 'text_icon'
    });
  };

  // 搜索下方历史按钮：avatar 行紧贴搜索框下方，使用系统图标 icon3。
  // 单击 → 进历史记录页(hiker://history?rule=<源名>#noRecordHistory#)；
  // 长按弹菜单：🛠️管理 / ⭐收藏。（本源无设置子页，不放设置项）
  UI.topBtns = function (d, cfg) {
    var rule = MY_RULE.title;
    d.push({
      url: 'hiker://history?rule=' + rule + '#noRecordHistory#',
      pic_url: 'hiker://images/icon3',
      desc: '🕐',
      col_type: 'avatar',
      title: '',
      extra: {
        longClick: [
          { title: '🛠️ 管理', js: $.toString(function (r) { return 'hiker://history?rule=' + r; }, rule) },
          { title: '⭐ 收藏', js: $.toString(function (r) { return 'hiker://collection?rule=' + r; }, rule) }
        ]
      }
    });
  };

  // ---------- 首页 ----------
  UI.renderHome = function (data) {
    var d = [];
    var page = MY_PAGE;
    var cls = String(getMyVar('sd_cls', ''));

    if (!cls) {  // 首页模式（首页无分页，忽略 page 直接渲染，防止从筛选页返回首页时 page 残留）
      // 分类导航（首页也显示，首页按钮放第一位，点击进入分类模式）
      UI.navs(d, [{ title: '首页', id: '' }].concat(data.navs || []), '');
      // 搜索框（★ 必须开 fypage 子页再搜，绝不能内联直接跑 search()，否则 fetch 返回的 "error" 会被原生 ArticleListModel 当 URL 报 Expected URL scheme）
      if (data.search) {
        d.push({
          title: '🔍 搜索',
          desc: data.search.placeholder || '',
          url: 'hiker://empty?page=fypage#noLoading##noHistory#@rule=js:' + $.toString(function (en) {
            if (input) { putMyVar('keyword', input); return $.require(en).search(); }
            return 'hiker://empty';
          }, UI.engine),
          col_type: 'input',
          extra: {
            onChange: $.toString(function () { putMyVar('keyword', input); }),
            defaultValue: getMyVar('keyword', '')
          }
        });
        d.push({ col_type: 'line_blank' });
      }
      // 搜索下方历史按钮（仅首页显示）
      UI.topBtns(d, data.topBtns);
      // 轮播：显示与否由 banner_on 控制（默认开；本源无设置页，读 getItem 默认值）
      if (data.banner && getItem('banner_on', 'true') == 'true') {
        UI.banner(d, { items: data.banner.items || [], time: data.banner.time || 4000 });
        d.push({ col_type: 'line_blank' });
      }
      // 分区
      for (var si = 0; si < data.sections.length; si++) {
        var sec = data.sections[si];
        UI.sectionTitle(d, sec.title, sec.icon, sec.url);
        var max = sec.max || (si === 0 ? 6 : 9);
        var col = sec.colType || (si === 0 ? 'movie_2' : 'movie_3');
        for (var j = 0; j < sec.items.length && j < max; j++) {
          var it = sec.items[j];
          d.push({
            title: it.title, pic_url: it.pic, desc: it.desc || '',
            url: it.url, col_type: col
          });
        }
        d.push({ col_type: 'line_blank' });
      }
      setResult(d);
    } else {  // 分类模式
      // autoPage：上拉自动翻页（App 触底自增 MY_PAGE，结果自动追加；第1页才渲染导航/筛选，不加翻页按钮）
      var autoPage = !!data.autoPage;
      var cpg = 1;
      try { cpg = parseInt(MY_PAGE, 10) || 1; } catch (eap) {}
      if (cpg < 1) cpg = 1;
      if (!autoPage || cpg === 1) {
        // 分类导航（首页按钮第一位）
        UI.navs(d, [{ title: '首页', id: '' }].concat(data.navs || []), cls);
        // 折叠筛选（排在分类下方）
        UI.filters(d, data.filters || [], 'sd_filter', 'sd_fold');
      }
      // 列表数据由各源在 homeData 里提供（AI 抓完塞入 data.listItems）
      var items = data.listItems || data.sections && data.sections[0] && data.sections[0].items || [];
      if (!items.length) {
        if (autoPage && cpg > 1) { setResult([]); return; }  // 自动翻页到底：不再追加
        setResult([{ title: '暂无数据', col_type: 'text_center_1' }]);
        return;
      }
      for (var k = 0; k < items.length; k++) {
        d.push({ title: items[k].title, pic_url: items[k].pic, desc: items[k].desc || '', url: items[k].url, col_type: 'movie_3' });
      }
      if (!autoPage) {
        // 翻页按钮（显式，仅非 autoPage 源使用）
        var pg = parseInt(data.page || '1', 10) || 1;
        if (pg > 1) {
          d.push({
            title: '‹ 上一页',
            url: $('#noLoading#').lazyRule(function (p) { putMyVar('sd_page', String(parseInt(p, 10) - 1)); refreshPage(false); return 'hiker://empty'; }, String(pg)),
            col_type: 'text_center_1'
          });
        }
        if (data.hasMore) {
          d.push({
            title: '下一页 ›（第' + pg + '页）',
            url: $('#noLoading#').lazyRule(function (p) { putMyVar('sd_page', String(parseInt(p, 10) + 1)); refreshPage(false); return 'hiker://empty'; }, String(pg)),
            col_type: 'text_center_1'
          });
        }
      }
      setResult(d);
    }
  };

  // ---------- 搜索结果页 ----------
  // 数据契约：data.items = [{ title, pic, desc, url }]（由引擎 search() 只取数据后 $.require('uil').renderSearch({items}) 交付）
  // 渲染：首屏 loading（仅第1页）→ 结果列表 → 空态；setPreResult([]) 放 setResult(d) 前先清 loading。
  UI.renderSearch = function (data) {
    var d = [];
    var items = data.items || [];

    // ① 首屏先放 loading 占位，界面立即出现，数据随后 setResult 覆盖
    if (MY_PAGE == 1) {
      var dL = [{
        img: "http://123.56.105.145/weisyr/img/Loading1.gif",
        url: "hiker://empty",
        col_type: "pic_1_full",
        extra: { id: "loading_" }
      }];
      setPreResult(dL);
    }

    // ② 渲染结果列表
    for (var i = 0; i < items.length; i++) {
      if (!items[i].title) continue;
      d.push({
        title: items[i].title || (items[i].name || ''),
        pic_url: items[i].pic || '',
        desc: items[i].desc || '',
        url: items[i].url || 'javascript:;',
        col_type: 'movie_3'
      });
    }

    // ③ 空态提示（无结果时给用户明确反馈，而非白屏）
    if (!d.length) {
      d.push({ title: '未找到相关内容', desc: '请换个关键词重试', pic_url: '', url: 'javascript:;', col_type: 'list_1' });
    }

    // ④ 先清掉首屏 loading，再正式 setResult
    setPreResult([]);
    setResult(d);
  };

  // ---------- 直播列表（带地区筛选+翻页+返回） ----------
  UI.renderLiveList = function (data) {
    var d = [];
    d.push({
      title: '‹ 返回首页',
      url: $('#noLoading#').lazyRule(function () { putMyVar('cb_gender', ''); putMyVar('cb_page', '1'); refreshPage(false); return 'hiker://empty'; }),
      col_type: 'text_center_1'
    });
    // 地区筛选
    var regs = data.regions || [], cur = data.curRegion || '', gd = data.gender || 'f';
    if (regs.length) {
      var row = [];
      for (var ri = 0; ri < regs.length; ri++) {
        (function (rv, rn) {
          row.push({
            title: (rv === cur ? '✅ ' : '') + rn,
            url: $('#noLoading#').lazyRule(function (v) { putMyVar('cb_region', v); putMyVar('cb_page', '1'); refreshPage(false); return 'hiker://empty'; }, rv),
            col_type: 'text_3'
          });
        })(regs[ri].v, regs[ri].n);
      }
      d.push({
        title: '地区筛选', desc: '', url: 'hiker://empty', col_type: 'text_1'
      });
      for (var q = 0; q < row.length; q++) d.push(row[q]);
    }
    var items = data.items || [];
    var pg = parseInt(data.page || '1', 10) || 1;
    for (var i = 0; i < items.length; i++) {
      if (!items[i].title) continue;
      d.push({
        title: items[i].title, pic_url: items[i].pic || '', desc: items[i].desc || '',
        url: items[i].url || 'javascript:;', col_type: 'movie_3'
      });
    }
    if (!items.length) {
      d.push({ title: '当前没有直播', desc: '换个分类或地区试试', pic_url: '', url: 'javascript:;', col_type: 'text_center_1' });
    }
    if (pg > 1) {
      d.push({
        title: '‹ 上一页',
        url: $('#noLoading#').lazyRule(function (p) { putMyVar('cb_page', String(parseInt(p, 10) - 1)); refreshPage(false); return 'hiker://empty'; }, String(pg)),
        col_type: 'text_center_1'
      });
    }
    if (data.hasMore) {
      d.push({
        title: '下一页 ›（第' + pg + '页）',
        url: $('#noLoading#').lazyRule(function (p) { putMyVar('cb_page', String(parseInt(p, 10) + 1)); refreshPage(false); return 'hiker://empty'; }, String(pg)),
        col_type: 'text_center_1'
      });
    }
    setResult(d);
  };

  // ---------- 详情页 ----------
  UI.renderDetail = function (data) {
    var d = [];
    var p = data.poster || {};
    // ① 海报卡
    d.push({
      title: p.title, desc: p.desc || '',
      pic_url: p.pic ? p.pic + '@Referer=' + (data.referer || '') : '',
      url: p.pic ? p.pic + '#.jpg#' : 'hiker://empty',
      col_type: 'movie_1_vertical_pic_blur',
      extra: { gradient: true }
    });
    // ② 简介 setDesc
    if (data.intro) UI.setDesc(d, data.intro, 60);
    d.push({ col_type: 'line' });
    // ③ 快速搜索（可选，受 quickSearch_on 控制，默认开）
    if (getItem('quickSearch_on', 'true') == 'true' && data.quickSearch && data.quickSearch.length) {
      var qTitle = ''; try { qTitle = getPageTitle(); } catch (e) {}
      for (var q = 0; q < data.quickSearch.length; q++) {
        var qo = data.quickSearch[q];
        var isSys = !qo.rule || qo.name === '';
        var url = $('#noLoading#').lazyRule(function (obj, qTitle) {
          return obj.rule ? obj.rule
            : ('hiker://search?s=' + qTitle + '&rule=' + obj.name);
        }, qo, qTitle);
        d.push({ title: qo.name || '海阔搜索', pic_url: qo.pic || '', url: url, col_type: 'icon_round_small_4', extra: { id: 'qs' + q } });
      }
      d.push({ col_type: 'line_blank' });
    }
    // ④ TVBox 推送区域（默认显示；tvbox_on 读 getItem 默认值）
    if (getItem('tvbox_on', 'true') == 'true' && data.tvboxShow !== false && data.tvbox) UI.tvboxUI(d, data.tvbox);
    // ⑤ 排序（在最前）+ 线路 + 剧集
    var lines = data.lines || [];
    var cur = parseInt(getMyVar('sd_line', '0'), 10);
    if (cur < 0 || cur >= lines.length) cur = 0;
    if (data.sortable) {
      var sort = getMyVar('sd_sort', 'asc');
      d.push({
        title: Q + '<b><font color="#4285F4">' + (sort === 'asc' ? '正序 ▲' : '倒序 ▼') + '</font></b>',
        col_type: 'scroll_button',
        url: $('#noLoading#').lazyRule(function (old) {
          putMyVar('sd_sort', old === 'asc' ? 'desc' : 'asc'); refreshPage(); return 'hiker://empty';
        }, sort),
        extra: { backgroundColor: '#EEEEEE', textSize: 14 }
      });
    }
    if (lines.length > 1) {
      for (var li = 0; li < lines.length; li++) {
        var active = li === cur;
        d.push({
          title: UI.hi(lines[li].name, active), col_type: 'scroll_button',
          url: $('#noLoading#').lazyRule(function (idx) {
            putMyVar('sd_line', String(idx)); refreshPage(); return 'hiker://empty';
          }, li),
          extra: { backgroundColor: active ? '#20FA7298' : '', textSize: 14 }
        });
      }
    }
    d.push({ col_type: 'blank_block', extra: { height: 8 } });
    var eps = (lines[cur] && lines[cur].episodes) || [];
    if (data.sortable && getMyVar('sd_sort', 'asc') === 'desc') eps = eps.slice().reverse();
    var ct = eps.length > 50 ? 'text_5' : eps.length > 20 ? 'text_4' : eps.length > 8 ? 'text_3' : 'text_2';
    for (var j = 0; j < eps.length; j++) {
      d.push({
        title: eps[j].name || '-',
        url: $().lazyRule(function (pu) {
          try { return '' + pu + ''; } catch (e) { return 'toast://解析失败'; }
        }, eps[j].url),
        col_type: ct
      });
    }
    setResult(d);
  };

  // ---------- TVBox 推送（奈雪技法） ----------
  UI.tvboxUI = function (d, tvbox) {
    d.push({
      title: (getItem('webpush', '0') == '1' ? '单集推送🟢' : '单集推送🔴'),
      url: "hiker://empty@lazyRule=.js:getItem('webpush','0')=='1'?setItem('webpush','0'):setItem('webpush','1');refreshPage();'toast://切换成功！'",
      col_type: 'scroll_button'
    });
    d.push({
      title: '设置电视IP',
      url: "input://" + getItem('hikertvboxset', 'http://' + getIP() + ':9978') + "////请输入tvbox推送IP地址，如http://" + getIP() + ":9978.js:setItem('hikertvboxset',input);refreshPage()",
      col_type: 'scroll_button'
    });
    if (tvbox.pushData) {
      var pushJson = JSON.stringify(tvbox.pushData);
      d.push({
        title: '推送当前页列表到TVBox',
        url: $(pushJson).lazyRule(function () {
          return 'hiker://page/push?pushurl=' + encodeURIComponent(input);
        }),
        col_type: 'scroll_button'
      });
    }
    d.push({ col_type: 'blank_block', extra: { height: 8 } });
  };

  // ---------- 简介折叠（奈雪/河马技法） ----------
  UI.setDesc = function (d, desc, num) {
    if (!desc || !String(desc).trim()) return;
    num = num || 60;
    desc = String(desc).replace(/\s+/g, ' ').replace(/&nbsp;/g, ' ').trim();
    var head = '<b><font color="#098AC1">∷剧情简介\t</font></b>';
    var m = 'desc';
    var full = '　　' + desc;
    var sdc = desc.length > num ? '　　' + desc.substr(0, num) : full;
    var isLong = desc.length > num;
    var title = head;
    if (isLong) {
      var fn = '((dc,sdc,m,cs)=>{'
        + 'var show=storage0.getItem(m,"0");'
        + 'var title=findItem(m).title;'
        + 'var re=/(<\\/small><br>.*?>).+/g;'
        + 'var exp="展开:";var ret="收起:";'
        + 'if(show=="1"){'
        + 'updateItem(m,{title:title.replace(ret,exp).replace(re,"$1"+sdc+"</small>").replace(/(<\\/small><br>\\<font color=").*?(">)/,"$1"+cs.hide+"$2")});'
        + 'storage0.setItem(m,"0");'
        + '}else{'
        + 'updateItem(m,{title:title.replace(exp,ret).replace(re,"$1"+dc+"</small>").replace(/(<\\/small><br>\\<font color=").*?(">)/,"$1"+cs.show+"$2")});'
        + 'storage0.setItem(m,"1");'
        + '}'
        + 'return "hiker://empty";})';
      var args = '(' + JSON.stringify(full) + ',' + JSON.stringify(sdc)
        + ',"' + m + '",{"show":"black","hide":"grey"})';
      var lazy = '#noLoading#@lazyRule=.js:' + fn + args;
      title += "<small><a style='text-decoration:none;' href='" + lazy + "'>展开:</a></small>";
    }
    title += '<br><font color="grey">' + sdc + '</small>';
    d.push({ title: title, col_type: 'rich_text', url: 'javascript:;', extra: { id: m, lineSpacing: 6, textSize: 15, lineVisible: false } });
  };

  $.exports = UI;
})();
