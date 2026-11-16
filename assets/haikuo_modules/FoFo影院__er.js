var tabs = 线路.map(n =>n.replace("资源",""));//[]
var lists = 选集;//[]
/*改成JSON
pdfa(html, 线路).forEach(data => {
    data = pdfh(data, 线路名)
    if (typeof(排除) != 'undefined' && 排除 != '') {
        data = data.replace(new RegExp(排除, "g"), "")
    }
    tabs.push(data)
})

pdfa(html, 选集).forEach(data => {
    lists.push(pdfa(data, 选集列表))
})
*/

addListener("onClose", $.toString(() => {
    clearMyVar("lists");
}));
storage0.putMyVar("lists", lists);
var list = lists[getMyVar(MY_URL, '0')];
var 排序 = getMyVar(MY_URL + "章节排序", '#1aad19">正序');
var 提示 = 排序 == '#FF0000">倒序' ? '#1aad19">正序' : '#FF0000">倒序';
var 排序名 = '““””<b><span style="color:排序</span></b>'

d.push({
    title: '““””<b><span style="color: ' + 排序 + '</span></b>',
    url: $("#noLoading#").lazyRule((tabs, 排序名, lazy, d) => {
        var lists = storage0.getMyVar("lists");
        var 章节 = lists[getMyVar(MY_URL, '0')];
        var 排序 = getMyVar(MY_URL + "章节排序", '#1aad19">正序');
        var 提示 = 排序 == '#FF0000">倒序' ? '#1aad19">正序' : '#FF0000">倒序';
        updateItem({
            extra: {
                id: MY_URL + "_排序",                
            },
            title: 排序名.replace('排序', 提示)
        })
        if (排序 == '#1aad19">正序') {
            章节.reverse()
        }
        let cp = 章节.map((data, ssid) => {
            return {
                title: data.title,//pdfh(data, 'a&&Text'),
                url: data.sid + lazy,//pd(data, 'a&&href') + lazy,
                col_type: 章节.length > 3 ? 'text_4' : 'text_2',
                extra: {
                    cls: MY_URL + "_选集",
                    id: data.sid,//pd(data, 'a&&href')
                }
            };
        });
        deleteItemByCls(MY_URL + "_选集");
        addItemBefore(MY_URL + "footer", cp);
        putMyVar(MY_URL + "章节排序", 提示)
        return "hiker://empty"
    }, tabs, 排序名, lazy, d[0]),
    col_type: 'flex_button',
    extra: {
        id: MY_URL + "_排序",        
    }
})

tabs.forEach((data, id) => {
    d.push({
        title: getMyVar(MY_URL, '0') == id ? '““' + data + '””' : data,
        url: $("#noLoading#").lazyRule((线路, lazy, id) => {
            var lists = storage0.getMyVar("lists");
            var 排序 = getMyVar(MY_URL + "章节排序", '#1aad19">正序');
            var 提示 = 排序 == '#FF0000">倒序' ? '#1aad19">正序' : '#FF0000">倒序';
            线路.forEach((data, xlid) => {
                updateItem({
                    title: id == xlid ? '““' + data + '””' : data,
                    extra: {
                        id: MY_URL + "_线路" + xlid
                    }
                });
            })
            putMyVar(MY_URL, id)
            var 章节 = lists[getMyVar(MY_URL, '0')];
            if (排序 == '#FF0000">倒序') {
                章节.reverse()
            }
            let cp = 章节.map((data, ssid) => {
                return {
                    title: data.title,//pdfh(data, 'a&&Text'),
                    url: data.sid + lazy,//pd(data, 'a&&href') + lazy,
                    col_type: 章节.length > 3 ? 'text_4' : 'text_2',
                    extra: {
                        cls: MY_URL + "_选集",
                        id: data.sid,//pd(data, 'a&&href')
                    }
                };
            });
            deleteItemByCls(MY_URL + "_选集");
            addItemBefore(MY_URL + "footer", cp);
            return "hiker://empty"
        }, tabs, lazy, id),
        col_type: 'flex_button',
        extra: {
            id: MY_URL + "_线路" + id
        }
    });
})

if (排序 == '#FF0000">倒序') {
    list.reverse()
}
list.forEach((data, id) => {
    d.push({
        title: data.title,//pdfh(data, 'a&&Text'),
        url: data.sid + lazy,//pd(data, 'a&&href') + lazy,
        col_type: list.length > 3 ? 'text_4' : 'text_2',
        extra: {
            cls: MY_URL + "_选集",
            id: data.sid,//pd(data, 'a&&href')
        }
    });
})
/*
setLastChapterRule('js:' + $.toString((选集, 选集列表) => {
    setResult('更新至: 第' + pdfa(getResCode(), 选集).map(data => pdfa(data, 选集列表).length).sort((a, b) => b - a)[0] + "集");
}, 选集, 选集列表));
*/
d.push({
    col_type: "big_blank_block",
    extra: {
        id: MY_URL + "footer"
    }
});