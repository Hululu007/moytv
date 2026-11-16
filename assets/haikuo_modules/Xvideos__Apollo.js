const Apollo = {
    version: "20250614",
    empty: 'hiker://empty',
    url: "https://www.xvideos.com",
    d: [],
    getRangeColors: function() {
        return '#' + ('00000' + (Math.random() * 0x1000000 << 0)
                .toString(16))
            .substr(-6);
    }, //随机颜色
    pageAdd: function(page) {
        if (getMyVar("page")) {
            putMyVar("page", (parseInt(page) + 1) + '');
        }
        return;
    }, //翻页
    pageMoveto: function(page, pages) {
        var longClick = [{
            title: "首页",
            js: $.toString(() => {
                putMyVar("page", "0");
                refreshPage();
                return "hiker://empty";
            }),
        }, {
            title: "上页",
            js: $.toString((page) => {
                if (page > 0) {
                    putMyVar("page", (parseInt(page) - 1));
                    refreshPage();
                    return "hiker://empty";
                }
            }, page),
        }, {
            title: "第" + page + "页",
            js: "",
        }, {
            title: "跳转",
            js: $.toString(() => {
                return $("").input(() => {
                    putMyVar("page", input);
                    refreshPage();
                });
            }),
        }];
        if (typeof(pages) != 'undefined') {
            var extra1 = {
                title: "尾页" + pages,
                js: $.toString((pages) => {
                    putMyVar("page", pages);
                    refreshPage();
                    return "hiker://empty";
                }, pages),
            };
            longClick.push(extra1)
        }
        return longClick
    }, //长按跳页
    data: {
        category: getMyVar('Apollo.category', '0'),
        subCate: getMyVar('Apollo.subCate', '0'),
    },
    baseParse: () => {
        putMyVar("MY_TYPE", "主页");
        var page = getMyVar("page", (MY_PAGE - 1) + "")
        let categoryList = [{
            "title": "首页",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "English",
                "path": "/new"
            }, {
                "title": "Arabic",
                "path": "/lang/arabic"
            }, {
                "title": "Bulgarian",
                "path": "/lang/bulgarian"
            }, {
                "title": "Chinese",
                "path": "/lang/chinese"
            }, {
                "title": "Croatian",
                "path": "/lang/hrvatski"
            }, {
                "title": "Czech",
                "path": "/lang/cestina"
            }, {
                "title": "Danish",
                "path": "/lang/dansk"
            }, {
                "title": "Dutch",
                "path": "/lang/nederlands"
            }, {
                "title": "Estonian",
                "path": "/lang/eesti"
            }, {
                "title": "Finnish",
                "path": "/lang/suomi"
            }, {
                "title": "French",
                "path": "/lang/francais"
            }, {
                "title": "German",
                "path": "/lang/deutsch"
            }, {
                "title": "Greek",
                "path": "/lang/greek"
            }, {
                "title": "Hebrew",
                "path": "/lang/hebrew"
            }, {
                "title": "Hindi",
                "path": "/lang/hindi"
            }, {
                "title": "Hungarian",
                "path": "/lang/magyar"
            }, {
                "title": "Indonesian",
                "path": "/lang/indonesia"
            }, {
                "title": "Italian",
                "path": "/lang/italiano"
            }, {
                "title": "Japanese",
                "path": "/lang/japanese"
            }, {
                "title": "Korean",
                "path": "/lang/korean"
            }, {
                "title": "Latvian",
                "path": "/lang/latviesu"
            }, {
                "title": "Lithuanian",
                "path": "/lang/lietuviu"
            }, {
                "title": "Malay",
                "path": "/lang/melayu"
            }, {
                "title": "Norwegian",
                "path": "/lang/norsk"
            }, {
                "title": "Persian",
                "path": "/lang/persian"
            }, {
                "title": "Polish",
                "path": "/lang/polski"
            }, {
                "title": "Portuguese",
                "path": "/lang/portugues"
            }, {
                "title": "Romanian",
                "path": "/lang/romana"
            }, {
                "title": "Russian",
                "path": "/lang/russian"
            }, {
                "title": "Serbian",
                "path": "/lang/srpski"
            }, {
                "title": "Slovak",
                "path": "/lang/slovencina"
            }, {
                "title": "Slovenian",
                "path": "/lang/slovenscina"
            }, {
                "title": "Spanish",
                "path": "/lang/espanol"
            }, {
                "title": "Swedish",
                "path": "/lang/svenska"
            }, {
                "title": "Thai",
                "path": "/lang/thai"
            }, {
                "title": "Turkish",
                "path": "/lang/turkce"
            }, {
                "title": "Ukrainian",
                "path": "/lang/ukrainian"
            }, {
                "title": "Urdu",
                "path": "/lang/urdu"
            }, {
                "title": "Vietnamese",
                "path": "/lang/viet_nam"
            }]
        }, {
            "title": "最佳",
            "path": "/best/",
            "type": "video",
            "sub": []
        }, {
            "title": "分类",
            "path": "",
            "type": "video",
            "sub": [{
                "title": "国产",
                "path": "/?k=%E5%9B%BD%E4%BA%A7&top"
            }, {
                "title": "3d",
                "path": "/?k=3d&top"
            }, {
                "title": "阿拉伯",
                "path": "/c/Arab-159"
            }, {
                "title": "按摩",
                "path": "/?k=%E6%8C%89%E6%91%A9&top"
            }, {
                "title": "成熟",
                "path": "/c/Mature-38"
            }, {
                "title": "出轨背叛",
                "path": "/c/Cuckold-237"
            }, {
                "title": "调教",
                "path": "/c/Femdom-235"
            }, {
                "title": "动漫",
                "path": "/?k=%E5%8A%A8%E6%BC%AB&top"
            }, {
                "title": "肛交",
                "path": "/c/Anal-12"
            }, {
                "title": "褐发",
                "path": "/c/Brunette-25"
            }, {
                "title": "黑人",
                "path": "/c/Black_Woman-30"
            }, {
                "title": "紅髮",
                "path": "/c/Redhead-31"
            }, {
                "title": "家庭乱搞",
                "path": "/c/Fucked_Up_Family-81"
            }, {
                "title": "金髮",
                "path": "/c/Blonde-20"
            }, {
                "title": "巨屌",
                "path": "/c/Big_Cock-34"
            }, {
                "title": "巨乳",
                "path": "/c/Big_Tits-23"
            }, {
                "title": "巨乳",
                "path": "/?k=%E5%B7%A8%E4%B9%B3&top"
            }, {
                "title": "巨臀",
                "path": "/c/Big_Ass-24"
            }, {
                "title": "口交",
                "path": "/c/Blowjob-15"
            }, {
                "title": "拉丁裔",
                "path": "/c/Latina-16"
            }, {
                "title": "辣媽",
                "path": "/c/Milf-19"
            }, {
                "title": "裂开",
                "path": "/c/Gapes-167"
            }, {
                "title": "麻豆",
                "path": "/?k=%E9%BA%BB%E8%B1%86&top"
            }, {
                "title": "美臀",
                "path": "/c/Ass-14"
            }, {
                "title": "男同",
                "path": "/gay?fmc=1"
            }, {
                "title": "女同",
                "path": "/c/Lesbian-26"
            }, {
                "title": "胖女",
                "path": "/c/bbw-51"
            }, {
                "title": "喷出",
                "path": "/c/Squirting-56"
            }, {
                "title": "拳交",
                "path": "/c/Fisting-165"
            }, {
                "title": "羣交",
                "path": "/c/Gangbang-69"
            }, {
                "title": "人妻",
                "path": "/?k=%E4%BA%BA%E5%A6%BB&top"
            }, {
                "title": "人妖",
                "path": "/shemale?fmc=1"
            }, {
                "title": "日本",
                "path": "/?k=%E6%97%A5%E6%9C%AC&top"
            }, {
                "title": "少女",
                "path": "/c/Teen-13"
            }, {
                "title": "射顏",
                "path": "/c/Cumshot-18"
            }, {
                "title": "摄像頭",
                "path": "/c/Cam_Porn-58"
            }, {
                "title": "雙性戀",
                "path": "/c/Bi_Sexual-62"
            }, {
                "title": "絲襪",
                "path": "/c/Stockings-28"
            }, {
                "title": "台灣",
                "path": "/?k=%E5%8F%B0%E7%81%A3&top"
            }, {
                "title": "探花",
                "path": "/?k=%E6%8E%A2%E8%8A%B1&top"
            }, {
                "title": "塗油",
                "path": "/c/Oiled-22"
            }, {
                "title": "香港",
                "path": "/?k=%E9%A6%99%E6%B8%AF&top"
            }, {
                "title": "性感内衣",
                "path": "/c/Lingerie-83"
            }, {
                "title": "亞洲的",
                "path": "/c/Asian_Woman-32"
            }, {
                "title": "业余",
                "path": "/c/Amateur-65"
            }, {
                "title": "異族",
                "path": "/c/Interracial-27"
            }, {
                "title": "印度的",
                "path": "/c/Indian-89"
            }, {
                "title": "中出",
                "path": "/c/Creampie-40"
            }, {
                "title": "中国",
                "path": "/?k=%E4%B8%AD%E5%9B%BD&top"
            }, {
                "title": "中國",
                "path": "/?k=%E4%B8%AD%E5%9C%8B&top"
            }, {
                "title": "自慰",
                "path": "/c/Solo_and_Masturbation-33"
            }, {
                "title": "自慰",
                "path": "/?k=%E8%87%AA%E6%85%B0&top"
            }, {
                "title": "AI",
                "path": "/c/AI-243"
            }, {
                "title": "ASMR",
                "path": "/c/ASMR-229"
            }, {
                "title": "Cosplay",
                "path": "/?k=cosplay&top"
            }, {
                "title": "Hong kong",
                "path": "/?k=hong+kong&top"
            }, {
                "title": "Japanese wife",
                "path": "/?k=japanese+wife&top"
            }, {
                "title": "Mmd",
                "path": "/?k=mmd&top"
            }, {
                "title": "Movie",
                "path": "/?k=movie&top"
            }, {
                "title": "Sm",
                "path": "/?k=sm&top"
            }, {
                "title": "同性視頻",
                "path": "/gay?fmc=1"
            }, {
                "title": "人妖色情",
                "path": "/shemale?fmc=1"
            }]
        }, {
            "title": "模特",
            "path": "/pornstars-index",
            "type": "articles",
            "sub": []
        }, {
            "title": "频道",
            "path": "/channels-index",
            "type": "articles",
            "sub": []
        }, {
            "title": "标签",
            "path": "/tags",
            "type": "tags",
            "sub": []
        }]
        const currentCate = categoryList[Apollo.data.category]
        let url
        var type = currentCate.type
        var path = currentCate.path
        if (currentCate.sub.length > 0) {
            url = getMyVar("url", Apollo.url + currentCate.sub[Apollo.data.subCate].path)
        } else {
            url = getMyVar("url", Apollo.url + currentCate.path)
        }
        if (url.endsWith("/best/")) {
            url = JSON.parse(fetch(url, {
                onlyHeaders: true,
                timeout: 5000
            })).url
        }
        url = url.replace(/\/\d+$|$/, (match) => {
            if (page > 0) {
                if (match.startsWith("/")) {
                    return match.charAt(0) + page
                } else {
                    return "/" + page;
                }
            } else {
                if (match.startsWith("/")) {
                    return match.charAt(0)
                } else {
                    return ""
                }
            }
        });
        if (page == 0) {
            url = url.replace("new", "")
        }
        Apollo.pageAdd(page)
        if (url.includes("k=")) {
            url = url.replace("&top", "").replace(/\/\d+$/, "&p=" + page)
        }
        log(url)
        if (MY_PAGE == 1) {
            categoryList.forEach((cate, index) => {
                Apollo.d.push({
                    title: parseInt(Apollo.data.category) === index ?
                        '‘‘’’' + cate.title.fontcolor("#FFFFFF") : cate.title,
                    url: $(Apollo.empty + "#noLoading#").lazyRule((index) => {
                        putMyVar("Apollo.category", index.toString())
                        putMyVar("Apollo.subCate", '0')
                        clearMyVar("url")
                        clearMyVar("page")
                        refreshPage(true)
                        return "hiker://empty"
                    }, index),
                    extra: {
                        'backgroundColor': parseInt(Apollo.data.category) === index ? Apollo.getRangeColors() : ''
                    },
                    col_type: 'scroll_button',
                })
            })
            if (currentCate.sub.length > 0) {
                Apollo.d.push({
                    col_type: 'blank_block',
                })
                currentCate.sub.forEach((cate, index) => {
                    Apollo.d.push({
                        title: parseInt(Apollo.data.subCate) === index ?
                            '‘‘’’' + cate.title.fontcolor("#FFFFFF") : cate.title,
                        url: $(Apollo.empty + "#noLoading#").lazyRule((index) => {
                            putMyVar("Apollo.subCate", index.toString());
                            clearMyVar("url")
                            clearMyVar("page")
                            refreshPage(true)
                            return "hiker://empty"
                        }, index),
                        extra: {
                            'backgroundColor': parseInt(Apollo.data.subCate) === index ? Apollo.getRangeColors() : ''
                        },
                        col_type: 'scroll_button',
                    })
                })
            }
        }
        const html = fetch(url, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0)',
                //"cookie": "xg_country=" + getMyVar("countrycode", "")
            }
        });
        //动态分类
        Apollo.videoSort(html)
        Apollo.DynamicSort(html)
        //搜索
        if (url.includes("/?k=")) {
            type = "search"
        }
        if (MY_PAGE == 1) {
            Apollo.d.push({
                title: "🔍",
                url: $.toString((url) => {
                    if (input.trim() != "") {
                        putMyVar('keyword', input);
                        var searchUrl = getHome(url) + "/?k=" + input
                        putMyVar("url", searchUrl);
                        refreshPage();
                        return "hiker://empty"
                    } else {
                        let keys = listMyVarKeys();
                        for (let it of keys) {
                            clearMyVar(it);
                        }
                        refreshPage();
                        return "hiker://empty"
                        //return "confirm://搜索内容为空.js:'hiker://empty'"
                    }
                }, url),
                desc: '搜索...',
                col_type: "input",
                extra: {
                    defaultValue: getMyVar('keyword', '') || "",
                }
            });
        }
        if (url == Apollo.url + "/") {
            Apollo.countryType()
        }

        switch (type) {
            case 'video':
                Apollo.videoType(html, page)
                break
            case 'articles':
                Apollo.articlesType(html, page)
                break
            case 'tags':
                if (page == 0) {
                    Apollo.tagsType(html)
                }
                break
            case 'search':
                if (MY_PAGE == 1) {
                    Apollo.d.push({
                        title: '““””' + "搜寻结果".fontcolor("#FF00FF"),
                        url: "hiker://empty",
                        col_type: "text_1",
                        extra: {
                            lineVisible: false
                        }
                    })
                }
                Apollo.videoType(html, page)
                break
            default:
                Apollo.videoType(html, page)
        }
        setResult(Apollo.d)
    },

    //一级sort
    videoSort: (html) => {
        if (MY_PAGE == 1) {
            Apollo.d.push({
                col_type: "blank_block",
            });
            try {
                var sort = pdfa(html, ".date-links||.ordered-label-list||.stripe,-1&&a[href]:not(:matches(所有語言))")
                sort.forEach((item, index) => {
                    var title = pdfh(item, 'Text');
                    var urll = Apollo.url + pdfh(item, 'a&&href');
                    urll = urll.replace(/https?.*(https?.*)/, "$1");
                    Apollo.d.push({
                        title: title,
                        url: urll + $('#noLoading#')
                            .lazyRule((index) => {
                                if (getMyVar("MY_TYPE") == "主页") {
                                    putMyVar('sort', index);
                                    putMyVar("url", input);
                                } else {
                                    putMyVar('ysort', index);
                                    putMyVar("yurl", input);
                                }
                                clearMyVar("page")
                                refreshPage();
                                return 'hiker://empty'
                            }, index),
                        col_type: 'scroll_button',
                        extra: {
                            'backgroundColor': (getMyVar("MY_TYPE") == "主页" ? getMyVar('sort', '0') == index : getMyVar('ysort', '0') == index) ? Apollo.getRangeColors() : ''
                        }
                    })
                })
            } catch {}
        }
    },
    //动态分类
    DynamicSort: (html) => {
        const 分类颜色 = Apollo.getRangeColors()
        const 大类定位 = "body&&.uls,0:3"
        const 拼接分类 = ""
        const 小类定位 = "body&&a"
        const 分类标题 = "Text"
        const 分类链接 = "a&&href"
        try {
            if (typeof(拼接分类) != 'undefined' && 拼接分类 != '') {
                var categories = pdfa(html, 大类定位).concat(pdfa(html, 拼接分类))
            } else {
                var categories = pdfa(html, 大类定位)
            }
        } catch {
            var categories = pdfa(html, 大类定位)
        }
        let init_cate = []
        for (let i = 0; i < 20; i++) {
            init_cate.push("0")
        }
        if (getMyVar("MY_TYPE") == "主页") {
            var cate_temp_json = getMyVar("dsort", JSON.stringify(init_cate))
        } else {
            var cate_temp_json = getMyVar("ydsort", JSON.stringify(init_cate))
        }
        var cate_temp = JSON.parse(cate_temp_json)

        if (MY_PAGE == 1) {
            Apollo.d.push({
                col_type: "blank_block"
            });
            categories.forEach((category, index) => {
                let sub_categories = pdfa(category, 小类定位);
                sub_categories.forEach((item, key) => {
                    let title = pdfh(item, 分类标题)
                    if (typeof(排除) != 'undefined' && 排除 != '') {
                        title = title.replace(new RegExp(排除, "g"), "")
                    };
                    Apollo.d.push({
                        title: key.toString() === cate_temp[index] ? '““””' + title.fontcolor(分类颜色) : title,
                        url: Apollo.url + $(pdfh(item, 分类链接) + '#noLoading#').lazyRule((params) => {
                            params.cate_temp[params.index] = params.key.toString()
                            if (getMyVar("MY_TYPE") == "主页") {
                                putMyVar('dsort', JSON.stringify(params.cate_temp));
                                putMyVar("url", input);
                            } else {
                                putMyVar('ydsort', JSON.stringify(params.cate_temp));
                                putMyVar("yurl", input);
                            }
                            clearMyVar("page")
                            refreshPage(true)
                            return "hiker://empty"
                        }, {
                            cate_temp: cate_temp,
                            index: index,
                            key: key,
                            page: MY_PAGE,
                        }),
                        col_type: 'scroll_button',
                        extra: {
                            'backgroundColor': key.toString() === cate_temp[index] ? Apollo.getRangeColors() : ''
                        }
                    })
                })
                Apollo.d.push({
                    col_type: "blank_block"
                });
            })
        }
    },

    //搜索
    searchParse: (url) => {
        var searchUrl = Apollo.url + "/?k=" + url.split("##")[1] + "&p=" + (MY_PAGE == 1 ? "" : MY_PAGE - 1)
        log(searchUrl)
        const html = fetch(searchUrl, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0)'
            }
        })
        Apollo.videoType(html);
        setResult(Apollo.d)
    },
    //视频列表
    videoType: (html, page) => {
        try {
            var pages = pdfh(html, ".pagination&&.last-page&&Text").match(/\d+/)[0]
        } catch (e) {
            var pages = 1
        }
        const list = pdfa(html, "body&&.frame-block||.video-container")
        list.forEach(item => {
            var title = pdfh(item, '.title||.video-title&&Text');
            var urll = Apollo.url + pdfh(item, 'a&&href');
            urll = urll.replace(/.*(https?.*)/, "$1").replace(/THUMBNUM/, "23");
            Apollo.d.push({
                title: title,
                url: urll + $('#noHistory#').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    Apollo.videoParse(MY_URL)
                }),
                pic_url: pdfh(item, 'img&&data-src').replace(/THUMBNUM/, "23"),
                desc: pdfh(item, '.video-hd-mark&&Text') + "⏰" + pdfh(item, '.duration&&Text'),
                col_type: 'movie_2',
                extra: {
                    pageTitle: title,
                    longClick: page ? Apollo.pageMoveto(page, pages) : ""
                }
            })
        })
    },
    //二级
    videoParse: (url) => {
        const html = fetch(url, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
            }
        })
        var title = pdfh(html, '.page-title&&Text')
        log(url)
        //setPageTitle(title)
        Apollo.d.push({
            title: '““””' + title.fontcolor("#D2691E").small(),
            url: "hiker://empty" + $('#noLoading#')
                .lazyRule((title) => {
                    var desc = findItem('transdesc')
                        .desc
                    if (!desc) {
                        const Apollo = $.require('hiker://page/Apollo')
                        title = title.replace(/\d+分钟.*/, "")
                        var translates = Apollo.translate(title)
                        updateItem("transdesc", {
                            desc: '““””' + translates.fontcolor("red"),
                        })
                    } else {
                        updateItem("transdesc", {
                            desc: '',
                        })
                    }
                    return "hiker://empty"
                }, title),
            col_type: 'text_1',
            extra: {
                lineVisible: false,
                id: 'transdesc',
                longClick: [{
                    title: '网页',
                    js: $.toString(() => {
                        return "web://" + MY_URL
                    })
                }, {
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
        const play = html.split("html5player.setVideoHLS('")[1].split("'")[0];
        Apollo.d.push({
            pic_url: pdfh(html, 'meta[property=og:image]&&content'),
            url: $(Apollo.empty + '#noHistory#').lazyRule((play) => {
                var hls = request(play).match(/hls-.*?m3u8/g);
                JSON.stringify(hls.sort(function(a, b) {
                    return b.match(/\d+/) - a.match(/\d+/)
                }));
                hghest_quality = hls.map(v => play.split('hls.')[0] + v, )
                name_quality = hls.map(v => v.split('-')[1].replace('.m3u8', ''))
                let playlist = {
                    urls: hghest_quality,
                    names: name_quality,
                    headers: new Array(hghest_quality.length).fill({
                        Referer: ""
                    })
                };
                return playlist;
            }, play),
            col_type: 'pic_1_full',
        })
        /*                var content = pdfh(html, '.info&&.item&&Text');
                        if (content.trim() != "") {
                            Apollo.setDesc(content)
                        }*/
        //标签
        try {
            var list = pdfa(html, ".video-tags-list&&a[href!=#]");
            list.forEach(item => {
                var vurl = Apollo.url + pdfh(item, 'a&&href');
                vurl = vurl.replace(/https?.*(https?.*)/, "$1")
                var title = pdfh(item, ".name||span||a&&Text");
                Apollo.d.push({
                    title: '““””' + title.fontcolor("#AAAAAA"),
                    url: "hiker://empty#" + vurl + $('##fypage')
                        .rule(() => {
                            const Apollo = $.require('hiker://page/Apollo')
                            Apollo.yijiParse(MY_URL.split("##")[0])
                            setResult(Apollo.d)
                        }),
                    col_type: "flex_button",
                    extra: {
                        pageTitle: title,
                        'backgroundColor': Apollo.getRangeColors()
                    }
                })
            })
        } catch {}
        //相关
        Apollo.d.push({
            title: "相关视频".fontcolor("#D2691E").bold(),
            col_type: "rich_text"
        })

        var json = JSON.parse(pdfh(html, '#video-player-bg&&script&&Html').split(';window.wpn_categories')[0].split('var video_related=')[1]);
        for (var j in json) {
            var title = json[j].tf;
            try {
                title = title.replace(/https?.*?\s/, "")
            } catch {}
            Apollo.d.push({
                title: title,
                desc: json[j].d,
                pic_url: json[j].ip ? json[j].ip : json[j].i,
                url: Apollo.url + json[j].u + $('#noHistory#').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    Apollo.videoParse(MY_URL)
                }),
                extra: {
                    pageTitle: title
                },
                col_type: "movie_2"
            })
        }

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

    //一级.简
    yijiParse: (url) => {
        putMyVar("MY_TYPE", "一级")
        var page = getMyVar("page", (MY_PAGE - 1) + "")
        try {
            var pages = pdfh(html, ".pagination&&.last&&Text").match(/\d+/)[0]
        } catch {
            var pages = 1
        }
        addListener("onClose", $.toString(() => {
            clearMyVar("yurl");
            clearMyVar("ysort");
            clearMyVar("ydsort");
            clearMyVar("page")
        }));
        url = getMyVar("yurl", url).replace("hiker://empty#", "")

        if (url.includes("/tags/")) {
            url = url.replace(/\/\d+$|$/, (match) => {
                if (page > 0) {
                    if (match.startsWith("/")) {
                        return match.charAt(0) + page
                    } else {
                        return "/" + page;
                    }
                } else {
                    if (match.startsWith("/")) {
                        return match.charAt(0)
                    } else {
                        return ""
                    }
                }
            })
            log(url)
            Apollo.pageAdd(page)
            var html = fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0)'
                }
            })
            Apollo.videoSort(html)
            Apollo.DynamicSort(html)
            Apollo.videoType(html, page)
        } else {
            if (/\/models\/|\/pornstars\/|\/amateurs\/|profiles\//.test(url)) {
                url = url + "/videos/best/" + page
            } else {
                url = url.replace("com", "com/channels") + "/videos/best/" + page
            }
            log(url)
            Apollo.pageAdd(page)
            var html = fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0)'
                }
            })
            try {
                var json = JSON.parse(html).videos;
                for (var j in json) {
                    var title = json[j].tf.replace(/https?.*?\s/, "");
                    Apollo.d.push({
                        title: title,
                        desc: json[j].d,
                        pic_url: json[j].ip ? json[j].ip : json[j].i,
                        url: Apollo.url + json[j].u + $('#noHistory#').rule(() => {
                            const Apollo = $.require('hiker://page/Apollo')
                            Apollo.videoParse(MY_URL)
                        }),
                        extra: {
                            pageTitle: title
                        },
                        col_type: "movie_2"
                    })
                }
            } catch {}
        }
    },
    //频道，明星
    articlesType: (html, page) => {
        if (page == 0) {
            Apollo.d.push({
                title: pdfh(html, ".page-title||.bg-title&&Text"),
                url: "hiker://empty",
                col_type: "text_1",
                extra: {
                    lineVisible: false
                }
            })
        }
        try {
            var pages = pdfh(html, ".pagination&&.last-page&&Text").match(/\d+/)[0]
        } catch {
            var pages = 1
        }
        const list = pdfa(html, "body&&.thumb-block")
        list.forEach(item => {
            var vurl = Apollo.url + pdfh(item, 'a&&href');
            vurl = vurl.replace(/https?.*(https?.*)/, "$1")
            Apollo.d.push({
                title: pdfh(item, '.profile-name&&Text'),
                desc: pdfh(item, ".flag&&title") + pdfh(item, ".with-sub&&Text"),
                url: "hiker://empty#" + vurl + $('##fypage').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    Apollo.yijiParse(MY_URL.split("##")[0])
                    setResult(Apollo.d)
                }),
                pic_url: pdfh(item, '.thumb&&Html').match(/https?.*?\.jpg/)[0],
                col_type: 'movie_2',
                extra: {
                    longClick: page ? Apollo.pageMoveto(page, pages) : ""
                }
            })
        })
    },
    //标签
    tagsType: (html) => {
        var list = pdfa(html, '#tags&&li');
        list.forEach(item => {
            var vurl = Apollo.url + pdfh(item, 'a&&href');
            vurl = vurl.replace(/https?.*(https?.*)/, "$1")
            var title = pdfh(item, 'a--span&&Text');
            Apollo.d.push({
                title: title,
                url: "hiker://empty#" + vurl + $('##fypage')
                    .rule(() => {
                        const Apollo = $.require('hiker://page/Apollo')
                        Apollo.yijiParse(MY_URL.split("##")[0])
                        setResult(Apollo.d)
                    }),
                col_type: "text_2",
                extra: {
                    pageTitle: title
                }
            })
        })
    },

    setDesc: (desc) => {
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
                show: "#008000",
                hide: "#8A2BE2"
            }

            var lazy = $(`#noLoading#`).lazyRule((dc, sdc, m, cs) => {
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
            arr.push({
                title: '' + '<b><font color="#D2691E">∷ 剧情简介	</font></b>' + "<middle><a style='text-decoration: none;' href='" + lazy + "'>" + sc + '</a></big><br><font color="' + cs + '">' + `${dc}` + '</small>',
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

    //翻译
    translate: (text) => {
        var switchtrans = getItem("翻译", "彩云小译");
        if (switchtrans == true || switchtrans == "彩云小译") {
            try {
                var to = 'zh'
                var from = 'auto'

                function init_data(source_lang, target_lang) {
                    return {
                        source: '',
                        detect: true,
                        os_type: 'ios',
                        device_id: 'F1F902F7-1780-4C88-848D-71F35D88A602',
                        trans_type: source_lang + '2' + target_lang,
                        media: 'text',
                        request_id: 424238335,
                        user_id: '',
                        dict: true,
                    }
                }

                function getRandomNumber() {
                    const rand = Math.floor(Math.random() * 99999) + 100000
                    return rand * 1000
                }
                const post_data = init_data(from, to)
                post_data.source = text
                post_data.request_id = getRandomNumber()
                let res = fetch('https://interpreter.cyapi.cn/v1/translator', {
                    method: 'POST',
                    header: {
                        'Content-Type': 'application/json',
                        'x-authorization': 'token ssdj273ksdiwi923bsd9',
                        'user-agent': 'caiyunInterpreter/5 CFNetwork/1404.0.5 Darwin/22.3.0',
                    },
                    body: post_data,
                })
                let result = JSON.parse(res)
                    .target
                return result + "【☁️】"
            } catch {
                log("翻译失败，使用原文");
                return text
            }
        } else if (switchtrans == "小牛翻译") {
            try {
                var url = "https://api.niutrans.com/NiuTransServer/translation";
                var api = "ae337b61113bd81db91120dc4ef9b055";
                if (api) {
                    if (text != "") {
                        var lang = "https://test.niutrans.com/NiuTransServer/language?src_text=" + text + "&source=text";
                        var from = JSON.parse(fetch(lang, {
                                timeout: 1000
                            }))
                            .language;
                        var result = post(url, {
                            body: {
                                src_text: text,
                                from: from,
                                to: "zh",
                                apikey: api,
                            },
                            timeout: 1223
                        });
                        var data = JSON.parse(result)
                        if (data.tgt_text) {
                            return data.tgt_text + "【🐮】"
                        } else {
                            log("翻译失败，使用原文");
                            return text
                        }
                    } else {
                        log("翻译失败，原文为空");
                        return text
                    }
                } else {
                    toast("预处理请填写翻译api")
                    return text
                }
            } catch {
                log("翻译失败，使用原文");
                return text
            }
        } else {
            return text
        }
    },

    countryType: () => {
        //https://www.xvideos.com/account/getcountries/zh
        // 获取所有的键
        //const keys = Object.keys(obj);
        // 获取所有的值
        //const values = Object.values(obj);
        var country = [{
            "code": "CN",
            "name": "中国"
        }, {
            "code": "AL",
            "name": "阿尔巴尼亚"
        }, {
            "code": "DZ",
            "name": "阿尔及利亚"
        }, {
            "code": "AF",
            "name": "阿富汗"
        }, {
            "code": "AR",
            "name": "阿根廷"
        }, {
            "code": "AE",
            "name": "阿拉伯联合酋长国"
        }, {
            "code": "SY",
            "name": "阿拉伯叙利亚"
        }, {
            "code": "AW",
            "name": "阿鲁巴"
        }, {
            "code": "OM",
            "name": "阿曼人"
        }, {
            "code": "AZ",
            "name": "阿塞拜疆"
        }, {
            "code": "EG",
            "name": "埃及"
        }, {
            "code": "ET",
            "name": "埃塞俄比亚"
        }, {
            "code": "IE",
            "name": "爱尔兰"
        }, {
            "code": "EE",
            "name": "爱沙尼亚"
        }, {
            "code": "AD",
            "name": "安道尔"
        }, {
            "code": "AO",
            "name": "安哥拉"
        }, {
            "code": "AI",
            "name": "安圭拉"
        }, {
            "code": "AG",
            "name": "安提瓜和巴布达"
        }, {
            "code": "AT",
            "name": "奥地利"
        }, {
            "code": "AX",
            "name": "奥兰群岛"
        }, {
            "code": "AU",
            "name": "澳大利亚"
        }, {
            "code": "MO",
            "name": "澳门"
        }, {
            "code": "BB",
            "name": "巴巴多斯"
        }, {
            "code": "PG",
            "name": "巴布亚新几内亚"
        }, {
            "code": "BS",
            "name": "巴哈马"
        }, {
            "code": "PK",
            "name": "巴基斯坦人"
        }, {
            "code": "PY",
            "name": "巴拉圭"
        }, {
            "code": "PS",
            "name": "巴勒斯坦领地"
        }, {
            "code": "BH",
            "name": "巴林"
        }, {
            "code": "PA",
            "name": "巴拿马"
        }, {
            "code": "BR",
            "name": "巴西"
        }, {
            "code": "BY",
            "name": "白俄罗斯"
        }, {
            "code": "BM",
            "name": "百慕大"
        }, {
            "code": "BG",
            "name": "保加利亚"
        }, {
            "code": "MP",
            "name": "北马里亚纳"
        }, {
            "code": "BJ",
            "name": "贝宁"
        }, {
            "code": "BE",
            "name": "比利时"
        }, {
            "code": "IS",
            "name": "冰岛"
        }, {
            "code": "PR",
            "name": "波多黎各"
        }, {
            "code": "PL",
            "name": "波兰"
        }, {
            "code": "BA",
            "name": "波斯尼亚"
        }, {
            "code": "BO",
            "name": "玻利维亚"
        }, {
            "code": "BZ",
            "name": "伯利兹"
        }, {
            "code": "BW",
            "name": "博茨瓦纳"
        }, {
            "code": "BT",
            "name": "不丹"
        }, {
            "code": "BF",
            "name": "布基纳法索"
        }, {
            "code": "BI",
            "name": "布隆迪"
        }, {
            "code": "BV",
            "name": "布维岛"
        }, {
            "code": "KP",
            "name": "朝鲜"
        }, {
            "code": "GQ",
            "name": "赤道几内亚"
        }, {
            "code": "DK",
            "name": "丹麦"
        }, {
            "code": "DE",
            "name": "德国"
        }, {
            "code": "TL",
            "name": "东帝汶"
        }, {
            "code": "TG",
            "name": "多哥"
        }, {
            "code": "DM",
            "name": "多米尼加"
        }, {
            "code": "DO",
            "name": "多明尼加"
        }, {
            "code": "RU",
            "name": "俄罗斯"
        }, {
            "code": "EC",
            "name": "厄瓜多尔"
        }, {
            "code": "ER",
            "name": "厄立特里亚"
        }, {
            "code": "FR",
            "name": "法国"
        }, {
            "code": "FO",
            "name": "法罗群岛"
        }, {
            "code": "PF",
            "name": "法属波利尼西亚"
        }, {
            "code": "GF",
            "name": "法属圭亚那"
        }, {
            "code": "TF",
            "name": "法属南部领地"
        }, {
            "code": "PH",
            "name": "菲律宾"
        }, {
            "code": "FJ",
            "name": "斐济"
        }, {
            "code": "FI",
            "name": "芬兰"
        }, {
            "code": "CV",
            "name": "佛得角"
        }, {
            "code": "FK",
            "name": "福克兰群岛"
        }, {
            "code": "GM",
            "name": "冈比亚"
        }, {
            "code": "CG",
            "name": "刚果"
        }, {
            "code": "CD",
            "name": "刚果民主"
        }, {
            "code": "CO",
            "name": "哥伦比亚"
        }, {
            "code": "CR",
            "name": "哥斯达黎加"
        }, {
            "code": "GD",
            "name": "格林纳达"
        }, {
            "code": "GL",
            "name": "格陵兰"
        }, {
            "code": "GG",
            "name": "根西岛"
        }, {
            "code": "CU",
            "name": "古巴"
        }, {
            "code": "GP",
            "name": "瓜德罗普岛"
        }, {
            "code": "GU",
            "name": "关岛"
        }, {
            "code": "GY",
            "name": "圭亚那"
        }, {
            "code": "KZ",
            "name": "哈萨克斯坦"
        }, {
            "code": "HT",
            "name": "海地"
        }, {
            "code": "KR",
            "name": "韩国"
        }, {
            "code": "NL",
            "name": "荷兰"
        }, {
            "code": "BQ",
            "name": "荷兰加勒比区"
        }, {
            "code": "AN",
            "name": "荷属安的列斯"
        }, {
            "code": "HM",
            "name": "赫德岛"
        }, {
            "code": "ME",
            "name": "黑山"
        }, {
            "code": "HN",
            "name": "洪都拉斯"
        }, {
            "code": "KI",
            "name": "基里巴斯"
        }, {
            "code": "DJ",
            "name": "吉布提"
        }, {
            "code": "KG",
            "name": "吉尔吉斯斯坦"
        }, {
            "code": "GN",
            "name": "几内亚"
        }, {
            "code": "GW",
            "name": "几内亚比绍"
        }, {
            "code": "CA",
            "name": "加拿大"
        }, {
            "code": "GH",
            "name": "加纳"
        }, {
            "code": "GA",
            "name": "加蓬"
        }, {
            "code": "KH",
            "name": "柬埔寨"
        }, {
            "code": "CZ",
            "name": "捷克"
        }, {
            "code": "ZW",
            "name": "津巴布韦"
        }, {
            "code": "CM",
            "name": "喀麦隆"
        }, {
            "code": "QA",
            "name": "卡塔尔人"
        }, {
            "code": "KY",
            "name": "开曼群岛"
        }, {
            "code": "CC",
            "name": "科科斯群岛"
        }, {
            "code": "KM",
            "name": "科摩罗"
        }, {
            "code": "XK",
            "name": "科索沃"
        }, {
            "code": "CI",
            "name": "科特迪瓦"
        }, {
            "code": "KW",
            "name": "科威特"
        }, {
            "code": "HR",
            "name": "克罗地亚"
        }, {
            "code": "KE",
            "name": "肯尼亚"
        }, {
            "code": "CK",
            "name": "库克群岛"
        }, {
            "code": "CW",
            "name": "库拉索"
        }, {
            "code": "LV",
            "name": "拉脱维亚"
        }, {
            "code": "LS",
            "name": "莱索托"
        }, {
            "code": "LA",
            "name": "老挝"
        }, {
            "code": "LB",
            "name": "黎巴嫩"
        }, {
            "code": "LT",
            "name": "立陶宛"
        }, {
            "code": "LR",
            "name": "利比里亚"
        }, {
            "code": "LY",
            "name": "利比亚"
        }, {
            "code": "LI",
            "name": "列支敦士登"
        }, {
            "code": "RE",
            "name": "留尼旺"
        }, {
            "code": "LU",
            "name": "卢森堡"
        }, {
            "code": "RW",
            "name": "卢旺达"
        }, {
            "code": "VA",
            "name": "罗马教廷"
        }, {
            "code": "RO",
            "name": "罗马尼亚"
        }, {
            "code": "MG",
            "name": "马达加斯加"
        }, {
            "code": "IM",
            "name": "马恩岛"
        }, {
            "code": "MV",
            "name": "马尔代夫"
        }, {
            "code": "MT",
            "name": "马耳他"
        }, {
            "code": "MW",
            "name": "马拉维"
        }, {
            "code": "MY",
            "name": "马来西亚"
        }, {
            "code": "ML",
            "name": "马里"
        }, {
            "code": "MK",
            "name": "马其顿"
        }, {
            "code": "MH",
            "name": "马绍尔群岛"
        }, {
            "code": "MQ",
            "name": "马提尼克岛"
        }, {
            "code": "YT",
            "name": "马约特岛"
        }, {
            "code": "MU",
            "name": "毛里求斯"
        }, {
            "code": "MR",
            "name": "毛里塔尼亚"
        }, {
            "code": "US",
            "name": "美国"
        }, {
            "code": "UM",
            "name": "美国本土外小岛屿"
        }, {
            "code": "VI",
            "name": "美国维尔京"
        }, {
            "code": "AS",
            "name": "美属萨摩亚"
        }, {
            "code": "MN",
            "name": "蒙古"
        }, {
            "code": "MS",
            "name": "蒙特塞拉特"
        }, {
            "code": "BD",
            "name": "孟加拉国"
        }, {
            "code": "PE",
            "name": "秘鲁"
        }, {
            "code": "FM",
            "name": "密克罗尼西亚"
        }, {
            "code": "MM",
            "name": "缅甸"
        }, {
            "code": "MD",
            "name": "摩尔多瓦"
        }, {
            "code": "MA",
            "name": "摩洛哥"
        }, {
            "code": "MC",
            "name": "摩纳哥"
        }, {
            "code": "MZ",
            "name": "莫桑比克"
        }, {
            "code": "MX",
            "name": "墨西哥"
        }, {
            "code": "NA",
            "name": "纳米比亚"
        }, {
            "code": "NG",
            "name": "奈及利亚"
        }, {
            "code": "ZA",
            "name": "南非"
        }, {
            "code": "AQ",
            "name": "南极洲"
        }, {
            "code": "GS",
            "name": "南乔治亚岛"
        }, {
            "code": "SS",
            "name": "南苏丹"
        }, {
            "code": "NR",
            "name": "瑙鲁"
        }, {
            "code": "NI",
            "name": "尼加拉瓜"
        }, {
            "code": "NP",
            "name": "尼泊尔"
        }, {
            "code": "NE",
            "name": "尼日尔"
        }, {
            "code": "NU",
            "name": "纽埃"
        }, {
            "code": "NO",
            "name": "挪威"
        }, {
            "code": "NF",
            "name": "诺福克岛"
        }, {
            "code": "PW",
            "name": "帕劳"
        }, {
            "code": "PN",
            "name": "皮特凯恩"
        }, {
            "code": "PT",
            "name": "葡萄牙"
        }, {
            "code": "GE",
            "name": "乔治亚"
        }, {
            "code": "JP",
            "name": "日本"
        }, {
            "code": "SE",
            "name": "瑞典"
        }, {
            "code": "CH",
            "name": "瑞士"
        }, {
            "code": "SV",
            "name": "萨尔瓦多"
        }, {
            "code": "WS",
            "name": "萨摩亚"
        }, {
            "code": "RS",
            "name": "塞尔维亚"
        }, {
            "code": "SL",
            "name": "塞拉利昂"
        }, {
            "code": "SN",
            "name": "塞内加尔"
        }, {
            "code": "CY",
            "name": "塞浦路斯"
        }, {
            "code": "SC",
            "name": "塞舌尔"
        }, {
            "code": "SA",
            "name": "沙特阿拉伯"
        }, {
            "code": "BL",
            "name": "圣巴泰勒米"
        }, {
            "code": "CX",
            "name": "圣诞岛"
        }, {
            "code": "ST",
            "name": "圣多美和普林西比"
        }, {
            "code": "SH",
            "name": "圣海伦娜"
        }, {
            "code": "KN",
            "name": "圣基茨和尼维斯"
        }, {
            "code": "LC",
            "name": "圣卢西亚"
        }, {
            "code": "SX",
            "name": "圣马丁"
        }, {
            "code": "MF",
            "name": "圣马丁"
        }, {
            "code": "SM",
            "name": "圣马力诺"
        }, {
            "code": "PM",
            "name": "圣皮埃尔和密克隆"
        }, {
            "code": "VC",
            "name": "圣文森特"
        }, {
            "code": "LK",
            "name": "斯里兰卡"
        }, {
            "code": "SK",
            "name": "斯洛伐克"
        }, {
            "code": "SI",
            "name": "斯洛文尼亚"
        }, {
            "code": "SJ",
            "name": "斯瓦尔巴"
        }, {
            "code": "SZ",
            "name": "斯威士兰"
        }, {
            "code": "SD",
            "name": "苏丹"
        }, {
            "code": "SR",
            "name": "苏里南"
        }, {
            "code": "SB",
            "name": "所罗门群岛"
        }, {
            "code": "SO",
            "name": "索马里"
        }, {
            "code": "TJ",
            "name": "塔吉克斯坦"
        }, {
            "code": "TW",
            "name": "台湾"
        }, {
            "code": "TH",
            "name": "泰国"
        }, {
            "code": "TZ",
            "name": "坦桑尼亚联合"
        }, {
            "code": "TO",
            "name": "汤加"
        }, {
            "code": "TC",
            "name": "特克斯"
        }, {
            "code": "TT",
            "name": "特立尼达"
        }, {
            "code": "TN",
            "name": "突尼斯"
        }, {
            "code": "TV",
            "name": "图瓦卢"
        }, {
            "code": "TR",
            "name": "土耳其"
        }, {
            "code": "TM",
            "name": "土库曼斯坦"
        }, {
            "code": "TK",
            "name": "托克劳"
        }, {
            "code": "WF",
            "name": "瓦利斯"
        }, {
            "code": "VU",
            "name": "瓦努阿图"
        }, {
            "code": "GT",
            "name": "危地马拉"
        }, {
            "code": "VE",
            "name": "委内瑞拉"
        }, {
            "code": "BN",
            "name": "文莱"
        }, {
            "code": "UG",
            "name": "乌干达"
        }, {
            "code": "UA",
            "name": "乌克兰"
        }, {
            "code": "UY",
            "name": "乌拉圭"
        }, {
            "code": "UZ",
            "name": "乌兹别克斯坦"
        }, {
            "code": "ES",
            "name": "西班牙"
        }, {
            "code": "EH",
            "name": "西撒哈拉"
        }, {
            "code": "GR",
            "name": "希腊"
        }, {
            "code": "HK",
            "name": "香港"
        }, {
            "code": "SG",
            "name": "新加坡"
        }, {
            "code": "NC",
            "name": "新喀里多尼亚"
        }, {
            "code": "NZ",
            "name": "新西兰"
        }, {
            "code": "HU",
            "name": "匈牙利"
        }, {
            "code": "JM",
            "name": "牙买加"
        }, {
            "code": "AM",
            "name": "亚美尼亚"
        }, {
            "code": "YE",
            "name": "也门"
        }, {
            "code": "IQ",
            "name": "伊拉克"
        }, {
            "code": "IR",
            "name": "伊朗伊斯兰"
        }, {
            "code": "IL",
            "name": "以色列"
        }, {
            "code": "IT",
            "name": "意大利"
        }, {
            "code": "IN",
            "name": "印度"
        }, {
            "code": "ID",
            "name": "印度尼西亚"
        }, {
            "code": "GB",
            "name": "英国"
        }, {
            "code": "VG",
            "name": "英属维尔京"
        }, {
            "code": "JO",
            "name": "约旦"
        }, {
            "code": "VN",
            "name": "越南"
        }, {
            "code": "ZM",
            "name": "赞比亚"
        }, {
            "code": "JE",
            "name": "泽西岛"
        }, {
            "code": "TD",
            "name": "乍得"
        }, {
            "code": "GI",
            "name": "直布罗陀"
        }, {
            "code": "CL",
            "name": "智利"
        }, {
            "code": "CF",
            "name": "中非"
        }]

        var countryname = country.map(i => i.name)
        Apollo.d.push({
            title: '““””' + getItem("country", "ip所在地").fontcolor("#FF00FF") + "的热门视频",
            url: $(countryname, 3).select((country) => {
                let index = country.findIndex(r => r.name == input);
                var code = country[index].code
                code = code.toLowerCase()
                setItem("country", input)
                //putMyVar("code", code)
                fetch("https://www.xvideos.com/change-country/" + code)
                refreshPage()
                return "hiker://empty"
            }, country),
            col_type: "text_1",
            extra: {
                lineVisible: false
            }
        })
    }
}
$.exports = Apollo