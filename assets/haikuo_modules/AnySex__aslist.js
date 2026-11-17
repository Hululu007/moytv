js:
var ASList = {
  list: function () {
    var HOST = 'https://anysex.com';
    var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';
    var d = [];
    var page = 1;
    try { page = parseInt(MY_PAGE, 10) || 1; } catch (e) { page = 1; }

    function abs(u) {
      if (!u) return '';
      u = String(u).trim();
      if (u.indexOf('http') === 0) return u;
      if (u.indexOf('//') === 0) return 'https:' + u;
      if (u.indexOf('/') === 0) return HOST + u;
      return HOST + '/' + u;
    }
    function pageUrl(base, p) {
      base = String(base || '').replace(/\/?$/, '/');
      if (!p || p <= 1) return base;
      return base + p + '/';
    }

    var lazy = $("").lazyRule(function (host, ua) {
      try {
        var html = fetch(input, { headers: { 'User-Agent': ua, 'Referer': host + '/' } });
        var srcs = pdfa(html, 'source') || [];
        var list = [];
        for (var i = 0; i < srcs.length; i++) {
          var u = pdfh(srcs[i], 'source&&src') || '';
          var t = pdfh(srcs[i], 'source&&title') || ('线路' + (list.length + 1));
          if (u) list.push({ u: u, t: t });
        }
        if (!list.length) return 'toast://解析失败';
        list.sort(function (a, b) {
          return (parseInt(String(b.t).replace(/\D/g, ''), 10) || 0) - (parseInt(String(a.t).replace(/\D/g, ''), 10) || 0);
        });
        var urls = [];
        var names = [];
        for (var j = 0; j < list.length; j++) {
          urls.push(list[j].u + '#isVideo=true#');
          names.push(list[j].t);
        }
        return JSON.stringify({
          urls: urls,
          names: names,
          headers: [{ 'User-Agent': ua, 'Referer': host + '/', 'Origin': host }]
        });
      } catch (e) {
        return 'toast://' + e.message;
      }
    }, HOST, UA);

    var raw = String(MY_URL || '');
    var base = raw.replace('hiker://empty##', '').split('##')[0];
    if (!base || base.indexOf('http') !== 0) {
      d.push({ title: '无效链接', col_type: 'text_center_1', url: 'hiker://empty' });
      setResult(d);
      return;
    }
    var url = pageUrl(base, page);
    var html = fetch(url, { headers: { 'User-Agent': UA, 'Referer': HOST + '/' } });
    var items = pdfa(html, 'body&&.item') || [];
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      var href = pd(it, 'a.popfire&&href') || pd(it, 'a&&href') || '';
      if (!href || href.indexOf('/video/') < 0) continue;
      d.push({
        title: pdfh(it, 'strong.title&&Text') || pdfh(it, 'img&&alt') || '',
        desc: [pdfh(it, '.item-quality&&Text'), pdfh(it, '.duration&&Text')].filter(Boolean).join(' · '),
        img: abs(pd(it, 'img&&src') || '') + '@Referer=' + HOST + '/',
        url: abs(href) + lazy,
        col_type: 'movie_2'
      });
    }
    if (!d.length && page === 1) {
      d.push({ title: '暂无内容', col_type: 'text_center_1', url: 'hiker://empty' });
    }
    setResult(d);
  }
};
$.exports = ASList;
