js:
eval(JSON.parse(fetch('hiker://page/lazy')).rule);
var d = [];
if (MY_PAGE == 1 && MY_TYPE == 'home') {
    d.push({   
        title: "搜索",
        url: "'hiker://search?rule=" + MY_RULE.title + "&s='+input",
        desc: "请输入搜索关键词",
        col_type: "input"
    })
};
var res = getResCode();
var text = pdfh(res, '.home-rows-videos-title&&Text');
//log(text)
var list = text == '' ? pdfa(res, 'body&&.video-item-container[title]') : pdfa(res, 'body&&a[style^=text-decoration]');
//log(list.length)
try {
    list.forEach(i => {
        d.push({
            col_type: 'movie_2',
            title: text == '' ? pdfh(i, '.title&&Text') : pdfh(i, '.home-rows-videos-title&&Text'),
            desc: text == '' ? '🕓' + pdfh(i, '.duration&&Text') + '  👁' + pdfh(i, '.stat-item,1&&Text') + ' 👍' + pdfh(i, '.stat-item,0--.material-icons&&Text') : '',
            content: '👥' + pdfh(i, '.subtitle&&Text'),
            url: pd(i, 'a&&href') + lazy,
            img: pd(i, '[loading=lazy]&&src')
        });
    })
} catch (e) {
    //log(e)
}
setResult(d);