js:
var d = [];
var MY_HOME = 'https://avbebe.com';
var lazy = $('').lazyRule(() => {
    var html = fetch(input)
    var m = String(html).match(/data-item="([^"]+)"/)
    if (m) {
        try {
            var j = JSON.parse(String(m[1]).replace(/&quot;/g, '"').replace(/&#039;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'))
            if (j.sources && j.sources.length) return j.sources[0].src + '#isVideo=true#;{Referer@https://avbebe.com/}'
        } catch (e) {}
    }
    var cu = String(html).match(/"contentUrl":"([^"]+)"/)
    if (cu) return cu[1].replace(/\\u002F/g, '/').replace(/\//g, '/') + '#isVideo=true#'
    var so = String(html).match(/<source[^>]+type="application\/x-mpegurl"[^>]+src="([^"]+)"/)
    if (!so) so = String(html).match(/<source[^>]+src="([^"]+)"/)
    if (so) return so[1].replace(/\//g, '/') + '#isVideo=true#'
    var tv = String(html).match(/turbovidhls\.com\/t\/([a-z0-9]+)/)
    if (tv) {
        var pt = fetch('https://turbovidhls.com/t/' + tv[1], { headers: { Referer: 'https://avbebe.com/' } })
        var pm = String(pt).match(/['"]([^'"]*\.m3u8[^'"]*)['"]/)
        if (pm) return pm[1] + '#isVideo=true#'
    }
    return input + '@r' + 'ule=js:$.require("hiker://page/detail")'
})

var playUrl = String(MY_URL || '').split('@')[0];
var html = '';
try { html = fetch(playUrl); } catch (e) {}
if (!html) {
    d.push({ title: '加载失败', desc: e.message || '', col_type: 'text_center_1' });
    setResult(d);
} else {
    var title = pdfh(html, 'h1&&Text') || '详情';
    try { setPageTitle(title); } catch (e) {}
    d.push({ title: '‘‘’’<b><font color="#FF69B4">' + title + '</font></b>', col_type: 'rich_text' });

    var ci = html.indexOf('content-inner');
    var ce = html.indexOf('jeg_nav_bottom', ci);
    var body = html.slice(ci, ce > 0 ? ce : html.length);

    var paras = [];
    pdfa(body, 'body&&p').forEach(function(p) {
        var t = (pdfh(p, 'Text') || '').trim();
        if (t.length > 1) paras.push(t);
    });
    paras = paras.filter(function(t, i) { return paras.indexOf(t) === i; });
    if (paras.length) d.push({ title: paras.join('\n\n'), col_type: 'rich_text' });

    var items = pdfa(body, 'body&&article');
    var n = 0;
    items.forEach(function(item) {
        var _h = pd(item, 'a&&href');
        if (!_h || _h.indexOf('/archives/') < 0 || _h.indexOf('author') >= 0) return;
        var _t = pdfh(item, 'h5&&Text') || pdfh(item, 'h3&&Text') || '';
        var _img = pdfh(item, 'img&&data-src') || '';
        if (!_img || _img.indexOf('data:image') === 0) _img = pdfh(item, 'img&&src') || '';
        if (_img.indexOf('data:image') === 0) _img = '';
        if (!_t || !_img) return;
        n++;
        d.push({ title: _t, img: _img, url: _h + lazy, col_type: 'movie_3' });
    });
    if (!n) d.push({ title: '该帖无正文内容', col_type: 'text_center_1' });
    setResult(d);
}