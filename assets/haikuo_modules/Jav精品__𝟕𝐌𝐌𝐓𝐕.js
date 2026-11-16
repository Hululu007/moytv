var Apollo = {
    version: "2026091004",
    empty: "hiker://empty",
    url: "https://7mmtv.sx/zh/",
    d: [],
    data: {
        category: getMyVar('Apo.category', '0'),
        subCate: getMyVar('Apo.subCate', '0'),
    },
    getRangeColors: function() {
        return '#' + ('00000' + (Math.random() * 0x1000000 << 0)
                .toString(16))
            .substr(-6);
    }, //随机颜色
    baseParse: () => {
        let categoryList = [{
            "title": "主頁",
            "path": "",
            "type": "home",
            "sub": []
        }, {
            "title": "無碼破解",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "無碼破解",
                "path": "https://7mmtv.sx/zh/reducing-mosaic_list/all/1.html"
            }, {
                "title": "隨機破解",
                "path": "https://7mmtv.sx/zh/censored_random/all/index.html"
            }]
        }, {
            "title": "中字AV",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "中字 A V ",
                "path": "https://7mmtv.sx/zh/chinese_list/all/1.html"
            }, {
                "title": "隨機中字",
                "path": "https://7mmtv.sx/zh/chinese_random/all/index.html"
            }]
        }, {
            "title": "有碼AV",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "有碼 A V ",
                "path": "https://7mmtv.sx/zh/censored_list/all/1.html"
            }, {
                "title": "隨機有碼",
                "path": "https://7mmtv.sx/zh/censored_random/all/index.html"
            }, {
                "title": "類別清單",
                "path": "https://7mmtv.sx/zh/censored_categorylist/list/index.html"
            }]
        }, {
            "title": "素人AV",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "素人 A V ",
                "path": "https://7mmtv.sx/zh/amateurjav_list/all/1.html"
            }, {
                "title": "隨機素人",
                "path": "https://7mmtv.sx/zh/amateurjav_random/all/index.html"
            }, {
                "title": "類別清單",
                "path": "https://7mmtv.sx/zh/amateurjav_categorylist/list/index.html"
            }, {
                "title": "シロウトT",
                "path": "https://7mmtv.sx/zh/amateurjav_makersr/1752/シロウトTV(SIRO)/1.html"
            }, {
                "title": "ラグジュT",
                "path": "https://7mmtv.sx/zh/amateurjav_makersr/1586/ラグジュTV(LUXU)/1.html"
            }, {
                "title": "ナンパT",
                "path": "https://7mmtv.sx/zh/amateurjav_makersr/1751/ナンパTV(200GANA)/1.html"
            }, {
                "title": "PRESTIGE PREMIU",
                "path": "https://7mmtv.sx/zh/amateurjav_makersr/1318/PRESTIGE PREMIUM(300MAAN)/1.html"
            }, {
                "title": "S-CUTE",
                "path": "https://7mmtv.sx/zh/amateurjav_makersr/1069/S-CUTE/1.html"
            }, {
                "title": "ARA",
                "path": "https://7mmtv.sx/zh/amateurjav_makersr/1585/ARA/1.html"
            }]
        }, {
            "title": "無碼AV",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "無碼 A V ",
                "path": "https://7mmtv.sx/zh/uncensored_list/all/1.html"
            }, {
                "title": "隨機無碼",
                "path": "https://7mmtv.sx/zh/uncensored_random/all/index.html"
            }, {
                "title": "FC2",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/37/FC2/1.html"
            }, {
                "title": "HEYZO",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/17/HEYZO/1.html"
            }, {
                "title": "東京",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/29/東京熱(Tokyo Hot)/1.html"
            }, {
                "title": "一本",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/32/一本道(1pondo)/1.html"
            }, {
                "title": "カリビアンコ",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/30/カリビアンコム(Caribbeancom)/1.html"
            }, {
                "title": "カリビアンコム PP",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/40/カリビアンコムPPV(Caribbeancompr)/1.html"
            }, {
                "title": "天然むす",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/31/天然むすめ(10musume)/1.html"
            }, {
                "title": "パコパコマ",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/36/パコパコママ(pacopacomama)/1.html"
            }, {
                "title": "ガチん娘",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/35/ガチん娘！(Gachinco)/1.html"
            }, {
                "title": "エッチな4610",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/34/エッチな4610/1.html"
            }, {
                "title": "人妻斬り0930",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/38/人妻斬り0930/1.html"
            }, {
                "title": "エッチな0930",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/39/エッチな0930/1.html"
            }, {
                "title": "トリプルエックス",
                "path": "https://7mmtv.sx/zh/uncensored_makersr/126/トリプルエックス (XXX-AV)/1.html"
            }]
        }, {
            "title": "國產影片",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "國產影片",
                "path": "https://7mmtv.sx/zh/amateur_list/all/1.html"
            }, {
                "title": "隨機國產",
                "path": "https://7mmtv.sx/zh/uncensored_random/all/index.html"
            }]
        }, {
            "title": "H漫畫貼圖",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "H漫畫貼圖",
                "path": "https://7mmtv.sx/zh/hcomic_list/all/1.html"
            }, {
                "title": "短篇&同人",
                "path": "https://7mmtv.sx/zh/hcomic_list/short/1.html"
            }, {
                "title": "中篇",
                "path": "https://7mmtv.sx/zh/hcomic_list/novellas/1.html"
            }, {
                "title": "單行本",
                "path": "https://7mmtv.sx/zh/hcomic_list/voluminous/1.html"
            }, {
                "title": "隨機H漫畫",
                "path": "https://7mmtv.sx/zh/hcomic_random/all/index.html"
            }, {
                "title": "隨機短篇&同人",
                "path": "https://7mmtv.sx/zh/hcomic_random/short/index.html"
            }, {
                "title": "隨機中篇",
                "path": "https://7mmtv.sx/zh/hcomic_random/novellas/index.html"
            }, {
                "title": "隨機單行本",
                "path": "https://7mmtv.sx/zh/hcomic_random/voluminous/index.html"
            }]
        }]
        const currentCate = categoryList[Apollo.data.category]
        let url
        let type = currentCate.type
        let path = currentCate.path
        if (currentCate.sub.length > 0) {
            url = Apollo.url + getMyVar("url", currentCate.sub[Apollo.data.subCate].path)
            path = currentCate.sub[Apollo.data.subCate].path
        } else {
            url = Apollo.url + getMyVar("url", currentCate.path)
        }
        url = url.replace(/https?.*(https?.*)/, "$1")
        if (MY_PAGE === 1) {
            categoryList.forEach((cate, index) => {
                Apollo.d.push({
                    title: parseInt(Apollo.data.category) === index ? '““””' + cate.title.fontcolor(Apollo.getRangeColors()) : cate.title,
                    url: $(Apollo.empty + "#noLoading#")
                        .lazyRule((index) => {
                            putMyVar("Apo.category", index.toString())
                            putMyVar("Apo.subCate", '0')
                            clearMyVar("url")
                            clearMyVar("sort")
                            clearMyVar("yurl");
                            refreshPage(true)
                            return "hiker://empty"
                        }, index),
                    col_type: 'scroll_button',
                })
            })
            if (currentCate.sub.length > 0) {
                Apollo.d.push({
                    col_type: 'blank_block',
                })
                currentCate.sub.forEach((cate, index) => {
                    Apollo.d.push({
                        title: parseInt(Apollo.data.subCate) === index ? '““””' + cate.title.fontcolor(Apollo.getRangeColors()) : cate.title,
                        url: $(Apollo.empty + "#noLoading#")
                            .lazyRule((index) => {
                                putMyVar("Apo.subCate", index.toString())
                                clearMyVar("url")
                                clearMyVar("sort")
                                clearMyVar("yurl");
                                refreshPage(true)
                                return "hiker://empty"
                            }, index),
                        col_type: 'scroll_button',
                    })
                })
            }
        }
        if (MY_PAGE == 1 && !/category/.test(url)) {
            Apollo.d.push({
                title: "🔍",
                url: $.toString(() => {
                    putMyVar('keyword', input);
                    var searchUrl = "https://7mmtv.sx/zh/searchall_search/all/" + input + "/1.html"
                    putMyVar("url", searchUrl);
                    refreshPage();
                    return "hiker://empty"
                }),
                desc: '搜索...',
                col_type: "input",
                extra: {
                    defaultValue: getMyVar('keyword', '') || "",
                }
            });
        }
        //翻页
        /*
        if (MY_PAGE !== 1) {
            url = url.includes("?") ? url + "&page=" + MY_PAGE : url + "?&page=" + MY_PAGE
        }
        const html = fetch(url, {
            headers: {
                "Cookie": fetchPC('hiker://files/rules/Apollo/Cookie/javlibrary_cookie.txt') || '',
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0)",
            }
        })*/
        let nextPage = getMyVar("nextPage", "");
        if (nextPage && MY_PAGE > 1) {
            if (url.includes("random")) {
                url = url
            } else {
                url = nextPage;
            }
        } else if (MY_PAGE > 1) {
            url = "没有下一页哦😑"
        }
        const html = fetch(url, {
            headers: {
                //"cookie": fetchPC('hiker://files/rules/Apollo/Cookie/javlibrary_cookie.txt') || '',
                "user-agent": "Mozilla/5.0 (Windows NT 10.0)"
            }
        })
        log(url)
        try {
            var next = pdfh(html, "body&&.pagination-row&&.previous-next:matches(>)&&a&&href")
            putMyVar("nextPage", next);
        } catch {
            clearMyVar("nextPage");
            //log("可能不存在下一页或者下一页定位有问题");
        }

        if (url.includes("searchbyid")) {
            Apollo.d.push({
                title: '““””' + "识别码搜寻结果".fontcolor("#67E0FA"),
                url: "hiker://empty",
                col_type: "text_1",
                extra: {
                    lineVisible: false
                }
            })
        }

        switch (type) {
            case 'video':
                if (url.includes("categorylist")) {
                    Apollo.seriesType(url, html)
                } else {
                    Apollo.videoType(url, html)
                }
                break
            case 'home':
                Apollo.homeType(html)
                break
            case 'series':
                Apollo.seriesType(html)
                break
            default:
                Apollo.videoType(url, html)
        }
        setResult(Apollo.d)
    },
    //首页
    homeType: (html) => {
        var tabs = pdfa(html, "body&&.block")
        tabs.forEach(tag => {
            let list = pdfa(tag, "body&&.video")
            Apollo.d.push({
                title: pdfh(tag, "h2&&Text").fontcolor("#FF00FF"),
                url: "hiker://empty",
                col_type: "rich_text",
            })
            list.forEach(item => {
                var url = pdfh(item, 'a&&href');
                var preview = pdfh(item, "video&&data-src");
                Apollo.d.push({
                    title: pdfh(item, "h3&&a&&Text"),
                    desc: pdfh(item, ".small&&Text"),
                    img: pdfh(item, "img&&data-src").replace(/\/m\//, "/b/").replace(/\/s\//, "/b/").replace(/hcomic\/b\//, "hcomic/s/"),
                    url: url + $('#noHistory#').rule(() => {
                        const Apollo = (function(){var m=null;try{m=$.require('hiker://files/rules/Apollo/𝟕𝐌𝐌𝐓𝐕.js',true);}catch(e){}if(!m||typeof m!=='object'||!Object.keys(m).length){m=$.require('hiker://page/Apollo');}return m;})()
                        Apollo.videoParse(MY_URL)
                        setResult(Apollo.d)
                    }),
                    col_type: "movie_2",
                    extra: {
                        pageTitle: pdfh(item, "h3&&a&&Text"),
                        longClick: [{
                            title: "【10秒预览】",
                            js: $.toString((preview) => {
                                return preview
                            }, preview)
                        }]
                    }
                })
            })
            Apollo.d.push({
                col_type: "blank_block"
            })
        })
    },
    //一级视频列表
    videoType: (url, html) => {
        if (url.includes("hcomic_") && !url.includes("_content")) {
            col = "movie_3";
        } else {
            col = "movie_2";
        }
        lazy = $('#noHistory#')
            .rule(() => {
                const Apollo = (function(){var m=null;try{m=$.require('hiker://files/rules/Apollo/𝟕𝐌𝐌𝐓𝐕.js',true);}catch(e){}if(!m||typeof m!=='object'||!Object.keys(m).length){m=$.require('hiker://page/Apollo?rule=𝟕𝐌𝐌𝐓𝐕');}return m;})()
                Apollo.videoParse(MY_URL)
                setResult(Apollo.d)
            })
        lazy1 = $('#noHistory#')
            .lazyRule(() => {
                var html = fetch(input)
                var script = pdfh(html, "body&&script[language]&&Html").split("i=")[0]
                eval(script)
                var pics = Large_cgurl.join("&&")
                return "pics://" + pics
            })
        try {
            var currpagenum = pdfh(html, "body&&.pagination-row&&.current&&Text")
        } catch {
            var currpagenum = "1"
        }
        try {
            if (currpagenum.includes("隨機")) {
                var lastpagenum = 1
            } else {
                var lastpagenum = pdfh(html, "body&&.pagination-row&&.previous-next:matches(>)+li&&a&&Text");
                if (lastpagenum == "") {
                    lastpagenum = pdfh(html, "body&&.pagination-row&&li:nth-last-child(2)&&Text")
                }
                if (lastpagenum == ">") {
                    lastpagenum = pdfh(html, "body&&.pagination-row&&li:nth-last-child(3)&&Text")
                }
            }
        } catch {
            var lastpagenum = currpagenum
        }
        var list = pdfa(html, "body&&.video||.comics");
        list.forEach(item => {
            var vurl = pdfh(item, 'a&&href');
            var preview = pdfh(item, "video&&data-src");
            Apollo.d.push({
                title: pdfh(item, "h3&&a&&Text"),
                desc: pdfh(item, ".small&&Text"),
                img: pdfh(item, "img&&data-src").replace(/\/m\//, "/b/").replace(/\/s\//, "/b/").replace(/hcomic\/b\//, "hcomic/s/"),
                url: !vurl.includes("hcomic_") ? vurl + lazy : vurl + lazy1,
                col_type: col,
                extra: {
                    pageTitle: pdfh(item, "h3&&a&&Text"),
                    longClick: !url.includes("content") ? [{
                        title: "【10秒预览】",
                        js: $.toString((preview) => {
                            return preview
                        }, preview)
                    }, {
                        title: '【跳页】【' + currpagenum + '<=>' + lastpagenum + '】',
                        js: $.toString((lastpagenum, url) => {
                                return $('', '正确的页码：1=>' + lastpagenum + "页")
                                    .input((url, lastpagenum) => {
                                            if (input > 0 && input % 1 == 0 && input <= parseInt(lastpagenum)) {
                                                var jumpu = url.replace(/\d+\.html/, input + ".html")
                                                putMyVar("url", jumpu);
                                                putMyVar("yurl", jumpu);
                                                refreshPage();
                                                return 'toast://你已经穿越到了' + input + '页'
                                            } else {
                                                return "toast://请输入正确的页码"
                                            }
                                        },
                                        url, lastpagenum)
                            },
                            lastpagenum, url)
                    }] : [{
                        title: "【10秒预览】",
                        js: $.toString((preview) => {
                            return preview
                        }, preview)
                    }]
                }
            })
        })
    },

    //一级系列
    seriesType: (url, html) => {
        if (MY_PAGE == 1) {
            Apollo.videoSort(html)
        }
        Apollo.videoType(url, html)
    },

    //一级sort
    videoSort: (html) => {
        Apollo.d.push({
            col_type: "blank_block",
        })
        var chtml = fetch("https://18av.mm-cg.com/zh/chinese_categorylist/list/index.html")
        const sort = pdfa(chtml, 'body&&.posts&&.post')
        sort.forEach((item, index) => {
            var title = pdfh(item, 'Text');
            Apollo.d.push({
                title: getMyVar('sort', '0') == index ? '‘‘’’<strong><font color="#ff1493">' + title + '</font></strong>' : title,
                url: pdfh(item, 'a&&href') + $('#noLoading#')
                    .lazyRule((index) => {
                        putMyVar('sort', index);
                        putMyVar("url", input);
                        refreshPage();
                        return 'hiker://empty'
                    }, index),
                col_type: 'scroll_button'
            })
            if (index == 54 || index == 123 || index == 189 || index == 294) {
                Apollo.d.push({
                    col_type: "blank_block",
                })
            }
        })
    },
    //一级页面.简
    avatarParse: (url) => {
        addListener("onClose", $.toString(() => {
            clearMyVar("yurl");
            clearMyVar("ysort");
            clearMyVar("nextPage1");
        }));
        url = url.replace(/(.*?)#.*/, "$1");
        url = getMyVar("yurl", url)
            .replace(/(.*?)#.*/, "$1");
        /*
        if (MY_PAGE !== 1) {
            url = url.includes("?") ? url + "&page=" + MY_PAGE : url + "?&page=" + MY_PAGE
        }
        const html = fetch(url, {
            headers: {
                "Cookie": fetchPC('hiker://files/rules/Apollo/Cookie/javlibrary_cookie.txt') || '',
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0)",
            }
        })
        log(url)*/
        let nextPage = getMyVar("nextPage1", "");
        if (nextPage && MY_PAGE > 1) {
            url = nextPage;
        } else if (MY_PAGE > 1) {
            url = "没有下一页哦😑"
        }
        var html = fetch(url, {
            headers: {
                //"cookie": fetchPC('hiker://files/rules/Apollo/Cookie/javlibrary_cookie.txt') || '',
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0)",
            }
        })
        log(url)
        try {
            var next = pdfh(html, "body&&.pagination-row&&.previous-next:matches(>)&&a&&href")
            putMyVar("nextPage1", next);
        } catch {
            clearMyVar("nextPage1");
            // log("可能不存在下一页或者下一页定位有问题");
        }
        Apollo.videoType(url, html)
    },

    //搜索
    searchParse: (url) => {
        url = url.replace("hiker://empty##", "")
        log(url)
        var html = fetch(url, {
            headers: {
                // "cookie": fetchPC('hiker://files/rules/Apollo/Cookie/javlibrary_cookie.txt') || '',
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0)",
            },
        });
        Apollo.videoType(url, html)
        setResult(Apollo.d)
    },

    //二级
    videoParse: (url) => {
        addListener("onClose", () => {
            clearMyVar("piclist");
        });
        log(url)
        var yiji = $('#fypage#noHistory#')
            .rule(() => {
                const Apollo = (function(){var m=null;try{m=$.require('hiker://files/rules/Apollo/𝟕𝐌𝐌𝐓𝐕.js',true);}catch(e){}if(!m||typeof m!=='object'||!Object.keys(m).length){m=$.require('hiker://page/Apollo?rule=𝟕𝐌𝐌𝐓𝐕');}return m;})()
                Apollo.avatarParse(MY_URL)
                setResult(Apollo.d)
            })
        const html = fetch(url, {
            headers: {
                // "cookie": fetchPC('hiker://files/rules/Apollo/Cookie/javlibrary_cookie.txt') || '',
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0)",
            }
        })
        try {
            var title = pdfh(html, "h1&&Text")
                .replace("免费AV在线看", "");
            Apollo.d.push({
                title: '““””' + title.fontcolor("#E57A1A").small(),
                url: url,
                col_type: 'text_1',
                extra: {
                    lineVisible: false,
                    id: 'transdesc',
                    longClick: [{
                        title: '复制',
                        js: $.toString((title) => {
                            return "copy://" + title;
                        }, title)
                    }, {
                        title: '百度翻译',
                        js: $.toString((title) => {
                            return "x5://https://fanyi.baidu.com/#jp/zh/" + title
                        }, title)
                    }, {
                        title: 'Deepl翻译',
                        js: $.toString((title) => {
                            return "x5://https://www.deepl.com/zh/translator-mobile#cn/zh/" + title
                        }, title)
                    }, {
                        title: '谷歌翻译',
                        js: $.toString((title) => {
                            return "x5://https://translate.google.com/?hl=zh-CN&sl=cn&tl=zh-CN&text=" + title
                        }, title)
                    }]
                }
            })
        } catch {}

        try {
            const img = pdfh(html, ".content_main_cover&&img&&src").replace("/b/264938_ADN-308.jpg", "/m_webp/264938_ADN-308.webp");
            var prevideo = html.match(/source src='(.*?)'/) ? html.match(/source src='(.*?)'/)[1] : "toast://此影片沒有視頻預覽哦😐";
            Apollo.d.push({
                img: img,
                url: prevideo,
                col_type: "pic_1_full",
            })
        } catch {}

        try {
            var fullvideo_showcg = pdfa(html, "#fullvideo_showallcg&&img").map(p => pdfh(p, "img&&data-src"))
            var allcgscript = pdfh(html, "body&&#fullvideo_showallcg+script&&Html").replace("new Array()", "fullvideo_showcg").split("fullvideo_showallcg_x")[0]
            eval(allcgscript)
            // log(fullvideo_showallcg_arr)
        } catch {}

        var lazypic = $('#noLoading#').lazyRule((fullvideo_showallcg_arr) => {
            if (fullvideo_showallcg_arr.length > 0) {
                return "pics://" + fullvideo_showallcg_arr.join("&&")
            } else {
                return "toast://此影片沒有圖片預覽哦😑"
            }
        }, fullvideo_showallcg_arr)

        try {
            var content = pdfh(html, ".video-introduction-images-text&&Text")
            if (content != "") {
                Apollo.setDesc(content, lazypic)
            } else {
                Apollo.d.push({
                    title: "<a style='text-decoration: none;fontcolor:red;' href='" + lazypic + "'>預覽和介紹</a>：" + "曾经沧海难为水，除却巫山不是云。取次花丛懒回顾，半缘修道半缘君。\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t------元稹".fontcolor("grey").small(),
                    url: Apollo.empty,
                    col_type: "rich_text",
                    extra: {
                        lineVisible: false
                    }
                })
            }
        } catch {}

        Apollo.PlayParse(html)
        /*
        Apollo.d.push({
            col_type: "big_blank_block"
        })
*/
        try {
            const 识别码 = pdfh(html, "body&&.fullvideo-details&&.me-3&&Text")
            if (识别码 != "") Apollo.CodeParse(识别码)
        } catch {}
        Apollo.d.push({
            col_type: "big_blank_block"
        })
        Apollo.d.push({
            col_type: "big_blank_block"
        })
        try {
            Apollo.d.push({
                title: '““””番号:' + 识别码.fontcolor("#FFD000"),
                url: "copy://" + 识别码,
                col_type: "scroll_button",
            }, {
                title: "““””" + pdfh(html, 'body&&.fullvideo-details&&.me-3,1&&Text').fontcolor("#FB0086"),
                url: 识别码 + $('#noLoading#')
                    .lazyRule(() => {
                        return "hiker://page/yj?rule=𝐉𝐚𝐯𝐃𝐁&url=" + getPublicItem('javdb0', 'https://javdb.com') + "/search？？f=all＆＆page=fypage＆＆q=" + input
                    }),
                col_type: "scroll_button",
            }, {
                title: pdfh(html, 'body&&.fullvideo-details&&.me-3,2&&Text').replace(/（.*?）/, "鐘"),
                url: Apollo.empty,
                col_type: "scroll_button",
            }, {
                col_type: 'blank_block',
            })
        } catch {}
        //导演
        try {
            var director = pdfh(html, 'body&&.fullvideo-details&&.g-1:matches(導演:)&&a&&Text');
            if (director) {
                Apollo.d.push({
                    title: "导演:",
                    url: 'hiker://empty',
                    col_type: 'scroll_button',
                })
                Apollo.d.push({
                    title: '‘‘’’<b><middle><font color="#1E90FF">' + director + '</font></middle></b>',
                    url: pdfh(html, 'body&&.fullvideo-details&&.g-1:matches(導演:)&&a&&href') + yiji,
                    col_type: 'scroll_button',
                    extra: {
                        pageTitle: director,
                    }
                });
            }
        } catch {}
        //发行商
        try {
            var label = pdfh(html, 'body&&.fullvideo-details&&.g-1:matches(發行商:)&&a&&Text');
            if (label) {
                Apollo.d.push({
                    title: "发行商:",
                    url: 'hiker://empty',
                    col_type: 'scroll_button',
                })
                Apollo.d.push({
                    title: '‘‘’’<b><middle><font color="#1E90FF">' + label + '</font></middle></b>',
                    url: pdfh(html, 'body&&.fullvideo-details&&.g-1:matches(發行商:)&&a&&href') + yiji,
                    col_type: 'scroll_button',
                    extra: {
                        pageTitle: label,
                    }
                })
            }
        } catch {}
        //片商
        try {
            var maker = pdfh(html, 'body&&.fullvideo-details&&.g-1:matches(製作商:)&&a&&Text');
            if (maker) {
                Apollo.d.push({
                    title: "片商:",
                    url: 'hiker://empty',
                    col_type: 'scroll_button',
                })
                Apollo.d.push({
                    title: '‘‘’’<b><middle><font color="#1E90FF">' + maker + '</font></middle></b>',
                    url: pdfh(html, 'body&&.fullvideo-details&&.g-1:matches(製作商:)&&a&&href') + yiji,
                    col_type: 'scroll_button',
                    extra: {
                        pageTitle: maker,
                    }
                })
            }
        } catch {}

        Apollo.d.push({
            col_type: "blank_block"
        })

        //类别
        var arts = parseDomForArray(html, 'body&&.fullvideo-details&&.categories&&a');
        if (arts.length > 0) {
            Apollo.d.push({
                col_type: "blank_block"
            })
            Apollo.d.push({
                title: "類別:",
                url: 'hiker://empty',
                col_type: 'scroll_button',
            });
            for (var i in arts) {
                var urll = pdfh(arts[i], 'a&&href');
                Apollo.d.push({
                    title: '‘‘’’<b><middle><font color="#1E8884">' + parseDomForHtml(arts[i], 'Text') + '</font></middle></b>',
                    url: urll + yiji,
                    col_type: 'scroll_button',
                    extra: {
                        pageTitle: parseDomForHtml(arts[i], 'Text')
                    }
                })
            }
        }

        //演员
        var arts = parseDomForArray(html, 'body&&.fullvideo-details&&.fullvideo-idol');
        if (arts.length > 0) {
            Apollo.d.push({
                col_type: "blank_block"
            })
            Apollo.d.push({
                title: "演員 ",
                url: 'hiker://empty',
                col_type: 'text_center_1',
                extra: {
                    lineVisible: false
                }
            })
            for (var i in arts) {
                var title = parseDomForHtml(arts[i], 'Text');
                var urll = pdfh(arts[i], 'a&&href');
                Apollo.d.push({
                    title: '‘‘’’<b><middle><font color="#c13141">' + title + '</font></middle></b>',
                    img: pdfh(arts[i], 'img&&data-src') ? pdfh(arts[i], 'img&&data-src') : "https://thumbsnap.com/i/sySMQ7Mg.jpg",
                    url: urll + yiji,
                    col_type: 'card_pic_3',
                    extra: {
                        pageTitle: title,
                        longClick: [{
                            title: '复制演员',
                            js: $.toString((title) => {
                                return "copy://" + title;
                            }, title)
                        }, {
                            title: '谷歌搜索',
                            js: $.toString((title) => {
                                return "https://www.google.com/search?q=" + title;
                            }, title)
                        }, {
                            title: '百度搜索',
                            js: $.toString((title) => {
                                return "https://www.baidu.com/s?wd=" + title;
                            }, title)
                        }, {
                            title: '磁力搜演员',
                            js: $.toString((title) => {
                                return "hiker://page/sou?rule=磁力君.简&p=fypage&searchTerms=" + title
                            }, title)
                        }]
                    }
                })
            }
        }
        Apollo.d.push({
            col_type: "blank_block"
        })

        Apollo.d.push({
            title: '““””' + "隨機主題".fontcolor("#FF00FF"),
            url: Apollo.empty,
            col_type: "text_center_1",
            extra: {
                lineVisible: false
            }
        })
        Apollo.videoType(url, html)

        Apollo.d.push({
            title: '““””' + "我是有底线的".fontcolor("grey")
                .small(),
            url: Apollo.empty,
            col_type: "text_center_1",
            extra: {
                lineVisible: false
            }
        })
        setResult(Apollo.d)
    },

    //播放列表
    PlayParse: (html) => {
        // 引入加密解密库
        eval(getCryptoJS())
        let list = [];
        let _hcdeedg252 = html.match(/hcdeedg252=\d+/)[0];
        let _hadeedg252 = html.match(/hadeedg252=\d+/)[0];
        // console.log(`_hcdeedg252:${_hcdeedg252}`);
        // console.log(`_hadeedg252:${_hadeedg252}`);
        let _argdeqweqweqwe = html.match(/.argdeqweqweqwe.=.'\w+';/)[0];
        // console.log(`_argdeqweqweqwe:${_argdeqweqweqwe}`);
        let _hdddedg252 = html.match(/.hdddedg252.=.'\w+';/)[0];
        // console.log(`_hdddedg252:${_hdddedg252}`);
        let _mvarr = html.match(/mvarr[\d_\[\]']+=\[\[.*\],\];/)[0];
        // console.log(_mvarr);
        let server = _mvarr.match(/mvarr[\d_\[\]']+/g).map(x => {
            return x.replace('mvarr[\'', '').replace('\']', '');
        });
        let mvarr = {};
        let hcdeedg252;
        let hadeedg252;
        let argdeqweqweqwe;
        let hdddedg252;
        let _js = `${_hcdeedg252},${_hadeedg252};${_argdeqweqweqwe}${_hdddedg252}${_mvarr}`;
        // console.log(_js);
        eval(_js);

        function hsdfdg252(a) {
            let hsddfdg252 = [];
            let hedeedg252 = [];
            hcdeedg252 = hcdeedg252 <= 25 ? hcdeedg252 : hcdeedg252 % 25;
            let splitStr = String.fromCharCode(hcdeedg252 + 97);
            hsddfdg252 = a.split(splitStr);
            for (let i = 0; i < hsddfdg252.length; i++) {
                let hfdeedg252 = parseInt(hsddfdg252[i], hcdeedg252);
                hfdeedg252 = (hfdeedg252 * 1) ^ hadeedg252;
                let hjdeedg252 = String.fromCharCode(hfdeedg252);
                hedeedg252.push(hjdeedg252)
            }
            let hgdeedg252 = hedeedg252.join("");
            return hgdeedg252
        }

        function decr_sun(a, b, c, d) {
            a = hsdfdg252(a);
            var e = CryptoJS.enc.Utf8.parse(argdeqweqweqwe);
            var f = CryptoJS.enc.Utf8.parse(hdddedg252);
            var g = CryptoJS.AES.decrypt(a, e, {
                iv: f,
                padding: CryptoJS.pad.Pkcs7
            });
            // console.log(b + g.toString(CryptoJS.enc.Utf8) + c);
            return b + g.toString(CryptoJS.enc.Utf8) + c;
            // $("#" + d).attr("src", b + g.toString(CryptoJS.enc.Utf8) + c)
        }

        function jfun_show_mvinnerHTML(a) {
            if (a === '7_1' || a === '28_1') {
                //return;
            }
            for (let mvarr_i = 0; mvarr_i < mvarr[a].length; mvarr_i++) {
                let res = mvarr[a][mvarr_i][2] + mvarr[a][mvarr_i][5];
                // console.log(res);
                let decUrl = decr_sun(mvarr[a][mvarr_i][1], mvarr[a][mvarr_i][3], mvarr[a][mvarr_i][4], mvarr[a][mvarr_i][0]);
                //log(decUrl)
                list.push({
                    'title': a.replace("28", "DO").replace("29", "🔥ST").replace("37", "🔥SW").replace("38", "🔥VH").replace("39", "EM").replace("40", "🔥TV").replace("41", "US").replace("42", "SP"),
                    'url': decUrl.startsWith('//') ? `https:${decUrl}` : decUrl.replace(/http.*?(http.*)/, "$1")
                });
            }
        }
        server.forEach(x => {
            jfun_show_mvinnerHTML(x);
        })

        var lazy = $('').lazyRule(() => {
            // 定义一个解析分辨率的函数
            function getResolution(name) {
                var match = name.match(/(\d+)/); // 提取降级分辨率
                return match ? parseInt(match[1], 10) : 0; // 如果没有匹配则返回0
            }
            let videoUrl = '';
            function rfetch(u, h) { var r = ''; for (var ri = 0; ri < 3; ri++) { r = fetch(u, h); if (r && r.length > 50) break; } return r; }
            var html = rfetch(input)
            //log(html)
            if (input.indexOf("7mmtv.sx/assets") != -1) {
                //TV线路42    
                if (!html) return "toast://首次加载失败，请再点一次重试";
                var group = html.match(/const videoSources[^;]+/);
                if (!group) return "toast://页面解析失败，请再点一次重试";
                eval(group[0])
                sortedData = videoSources.sort((a, b) => b.size - a.size);
                var sortedNames = sortedData.map(item => item.size);
                var sortedUrls = sortedData.map(item => item.src);
                let playlist = JSON.stringify({
                    names: sortedNames,
                    urls: sortedUrls,
                    headers: new Array(sortedData.length).fill({
                        Referer: "https://7mmtv.sx/"
                    })
                });
                return playlist;
            } else if (input.indexOf("7mmtv.sx") != -1) {
                //TV线路40               
                if (!html) return "toast://首次加载失败，请再点一次重试";
                var s = html.match(/src.?=[^\>]+/);
                if (!s) return "toast://页面解析失败，请再点一次重试";
                eval(s[0])
                var request = rfetch(src);
                if (!request) return "toast://线路请求失败，请再点一次重试";
                let playUrl = request.match(/https.*?m3u8/)[0];
                var group_quality = rfetch(playUrl, {
                    headers: {
                        'Referer': input
                    }
                });
                if (!group_quality || !/\d/.test(group_quality)) return "toast://清单获取失败，请再点一次重试";
                //log(group_quality)
                hghest_quality = (group_quality.match(/^[^#\s]+$/gm) || []).map(v => v.includes("http") ? v + "#isVideo=true#" : playUrl.replace(/[^\/]+$/, v))
                //log(hghest_quality)
                name_quality = (group_quality.match(/RESOLUTION=.*?\,/gm) || []).map(n => n.replace(/RESOLUTION=|\,/g, ""))

                // 按分辨率降序排序 分辨率 数组，并同时调整 hghest_quality
                var sortedData = name_quality.map((name, index) => ({
                        name,
                        url: hghest_quality[index]
                    }))
                    .sort((a, b) => getResolution(b.name) - getResolution(a.name));
                // 分开排序后的 names 和 urls 数组
                var sortedNames = sortedData.map(item => item.name);
                var sortedUrls = sortedData.map(item => item.url);
                let playlist = JSON.stringify({
                    names: sortedNames,
                    urls: sortedUrls,
                    headers: new Array(hghest_quality.length).fill({
                        Referer: "https://mmtv01.xyz/"
                    })
                });
                return playlist;
            } else if (input.indexOf("upns") != -1) {
                //US线路41
                //https://7mmtv.upns.live/#6kx1
                var url = "https://7mmtv.upns.live/api/v1/video?id=" + input.split("#")[1]
                var data = fetch(url)
                var Decode = (word) => {
                    word = word.trim()
                    eval(getCryptoJS())
                    let key = CryptoJS.enc.Utf8.parse("kiemtienmua911ca")
                    let iv = CryptoJS.enc.Utf8.parse("1234567890oiuytr")
                    return CryptoJS.AES.decrypt(CryptoJS.enc.Base64.stringify(CryptoJS.enc.Hex.parse(word)), key, {
                        iv: iv,
                        mode: CryptoJS.mode.CBC,
                        padding: CryptoJS.pad.Pkcs7
                    }).toString(CryptoJS.enc.Utf8)
                }
                var json = JSON.parse(Decode(data))
                return json.cf + '#isVideo=true#;{Origin@https://7mmtv.upns.live&&Referer@https://7mmtv.upns.live/}'

            } else if (input.indexOf("mm") != -1) {
                //线路SW37+VH线路38
                if (!html) return "toast://首次加载失败，请再点一次重试";
                var script = html.match(/eval(.*\))/);
                if (!script) return "toast://页面解析失败，请再点一次重试";
                playUrl = eval(script[1]).match(/(https?.*?)"/)[1]
                var group_quality = rfetch(playUrl, {
                    headers: {
                        'Referer': input
                    }
                });
                if (!group_quality) return "toast://清单获取失败，请再点一次重试";
                group_quality = group_quality.split("\n\n")[0]
                // log(group_quality)
                hghest_quality = (group_quality.match(/^[^#\s]+$/gm) || []).map(v => v.includes("http") ? v + "#isVideo=true#" : playUrl.replace(/[^\/]+$/, v + "#.m3u8"))
                //log(hghest_quality)
                name_quality = (group_quality.match(/RESOLUTION=.*?\,/gm) || []).map(n => n.replace(/RESOLUTION=|\,/g, ""))

                // 按分辨率降序排序 分辨率 数组，并同时调整 hghest_quality
                var sortedData = name_quality.map((name, index) => ({
                        name,
                        url: hghest_quality[index]
                    }))
                    .sort((a, b) => getResolution(b.name) - getResolution(a.name));
                // 分开排序后的 names 和 urls 数组
                var sortedNames = sortedData.map(item => item.name);
                var sortedUrls = sortedData.map(item => item.url);
                let playlist = JSON.stringify({
                    names: sortedNames,
                    urls: sortedUrls,
                    headers: new Array(hghest_quality.length).fill({
                        Referer: "https://7mmtv.upns.live/"
                    })
                });
                return playlist;
            } else if (input.indexOf("embedrise") != -1) {
                //EM线路39
                var url = pdfh(html, "source&&src");
                playUrl = url + "#isVideo=true#;{Referer@" + getHome(input) + "/}"
                return playUrl
            } else if (input.indexOf('dooood') != -1) {
                //DO线路28
                var redirect = JSON.parse(fetch(input, {
                    onlyHeaders: true
                })).url;
                var htmll = fetchCodeByWebView(redirect, {
                    headers: {
                        referer: input
                    }
                });
                // log(htmll)
                var pass_md5 = getHome(redirect) + htmll.match(/\/pass_md5[^"']+/)[0]
                var token = htmll.match(/cookieIndex.*?\'(.*?)\'/)[1]
                var data = fetch(pass_md5, {
                    headers: {
                        "Referer": redirect
                    }
                })

                function makePlay(token) {
                    for (var a = "",
                            t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
                            n = t.length,
                            o = 0; 10 > o; o++)
                        a += t.charAt(Math.floor(Math.random() * n));
                    return a + "?token=" + token + "&expiry=" + Date.now();
                };
                var playUrl = data + makePlay(token)
                return playUrl + "#isVideo=true#;{Referer@" + input + "}"

            } else if (input.indexOf('tapewithadblock') != -1) {
                //ST线路29
                var pattern = html.match(/\('#(.*)'\)/)[1]
                var src = "var srclink = " + html.match(new RegExp("'" + pattern + ".*?=([^;]+)"))[1]
                eval(src)
                var link = "https:" + srclink + "&stream=1"
                var urlPlay = JSON.parse(fetch(link, {
                    headers: {
                        "Referer": input,
                    },
                    onlyHeaders: true
                })).url
                videoUrl = urlPlay + ";{Referer@" + input + "}"

            } else {
                log(input)
                videoUrl = "toast://线路暂未解析=>" + input
            }
            return videoUrl;
        })
        //log(list)
        var col;
        if (list.length == 1) {
            col = "text_2"
        } else if (list.length < 6) {
            col = "text_" + list.length
        } else if (list.length < 11) {
            col = "text_" + Math.ceil(list.length / 2)
        } else {
            col = "text_5"
        }

        list.forEach((item, index) => {
            Apollo.d.push({
                title: item.title,
                url: item.url + lazy,
                col_type: col,
                extra: {
                    cls: "playlist " + index
                }
            })
        })
    },
    //外链播放
    CodeParse: (识别码) => {
        Apollo.d.push({
            col_type: 'blank_block',
        })
        var codelazy = fetch('hiker://files/rules/Apollo/𝐂𝐨𝐝𝐞𝐋𝐚𝐳𝐲.js') || "";
        if (!codelazy || codelazy == 'null' || codelazy == 'undefined') {
            Apollo.d.push({
                title: '““””<font color="#FF0000">本地 𝐂𝐨𝐝𝐞𝐋𝐚𝐳𝐲.js 不存在</font>',
                desc: '请把统一维护的 𝐂𝐨𝐝𝐞𝐋𝐚𝐳𝐲.js 放到 hiker://files/rules/Apollo/𝐂𝐨𝐝𝐞𝐋𝐚𝐳𝐲.js；本规则不会远程下载或覆盖。',
                url: 'hiker://empty',
                col_type: 'text_center_1',
                extra: { lineVisible: false }
            })
            return;
        }
        try {
            codelazy = codelazy.replace(/^\s*js:\s*/, '').replace(/d\.push/g, "Apollo.d.push");
            var __CodeLazyId = 识别码;
            eval(codelazy + "\n;CodeLazy(__CodeLazyId);");
        } catch (e) {
            var err = e && e.message ? e.message : e;
            log('本地CodeLazy加载失败：' + err);
            Apollo.d.push({
                title: '““””<font color="#FF0000">本地CodeLazy加载失败</font>',
                desc: String(err),
                url: 'hiker://empty',
                col_type: 'text_center_1',
                extra: { lineVisible: false }
            })
        }
    },

    //剧情简介（123AV 同款富文本折叠展开）
    setDesc: (desc, lazypic) => {
        function substr(str, maxLength) {
            let len = 0;
            for (let i = 0; i < str.length; i++) {
                if (str.charCodeAt(i) > 255) {
                    len += 2;
                } else {
                    len++;
                }
                if (len > maxLength) {
                    return str.slice(0, i) + '...';
                }
            }
            return str;
        }

        function setDesc(arr, desc, num) {
            //log(desc)
            if (desc == undefined) {
                return;
            }
            desc = desc.constructor == Array ? desc.join('<br>') : desc;
            if (desc.replace(/(<br>|\s+|<\/?p>|&nbsp;)/g, '').length == 0) {
                return;
            }

            const mark = 'desc';
            num = typeof(num) == 'undefined' ? 100 : num
            desc = desc.startsWith('　　') ? desc : '　　' + desc;
            desc = desc.replace(/'/g, "&#39;");
            desc = desc.replace(/\r\n/g, "<br>");
            desc = desc.replace(/\r/g, "<br>");
            desc = desc.replace(/\n/g, "<br>");
            let sdesc = substr(desc, num);

            var colors = {
                show: "#008B8B",
                hide: "#8A2BE2"
            }

            var lazy = $(`#noLoading#`).b64().lazyRule((dc, sdc, m, cs) => {
                var show = storage0.getItem(m, '0');
                var title = findItem('desc').title;
                var re = /(<\/big><br>.*?>).+/g;
                var exp = '展开:';
                var ret = '收起:';
                if (show == '1') {
                    updateItem('desc', {
                        title: title
                            .replace(ret, exp)
                            .replace(re, '$1' + sdc + '</small>')
                            .replace(/(<\/big><br>\<font color=").*?(">)/, '$1' + cs.hide + '$2')

                    })
                    storage0.setItem(m, '0');
                } else {
                    updateItem('desc', {
                        title: title
                            .replace(exp, ret)
                            .replace(re, '$1' + dc + '</small>')
                            .replace(/(<\/big><br>\<font color=").*?(">)/, '$1' + cs.show + '$2')
                    })
                    storage0.setItem(m, '1');
                }
                return `hiker://empty`
            }, desc, sdesc, mark, colors)
            var sc = storage0.getItem(mark, '0') == '0' ? '展开:' : '收起:';
            var dc = storage0.getItem(mark, '0') == '0' ? sdesc : desc;
            var cs = storage0.getItem(mark, '0') == '0' ? colors.hide : colors.show;
            var descTitle = '<b><font color="">∷ 剧情简介\t</font></b>';
            if (lazypic) descTitle = "<a style='text-decoration: none;' href='" + lazypic + "'>" + descTitle + "</a>";
            arr.push({
                title: descTitle + "<middle><a style='text-decoration: none;' href='" + lazy + "'>" + sc + '</a></big><br><font color="' + cs + '">' + dc + '</small>',
                col_type: 'rich_text',
                extra: {
                    id: 'desc',
                    lineSpacing: 6,
                    textSize: 15,
                    lineVisible: true,
                }
            })
        }

        setDesc(Apollo.d, desc, 90);
    },

}

$.exports = Apollo