const Apollo = {
    version: "20260114",
    empty: 'hiker://empty',
    url: "https://www.tnaflix.com",
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
                putMyVar("page", "1");
                refreshPage();
                return "hiker://empty";
            }),
        }, {
            title: "上页",
            js: $.toString((page) => {
                if (page > 1) {
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
        var page = getMyVar("page", MY_PAGE + "")
        let categoryList = [{
            "title": "Home",
            "path": "/featured",
            "type": "video",
            "sub": []
        }, {
            "title": "Categories",
            "path": "/categories",
            "type": "avatar",
            "sub": []
        }, {
            "title": "Channels",
            "path": "/channels",
            "type": "channel",
            "sub": []
        }, {
            "title": "Pornstars",
            "path": "/pornstars",
            "type": "channel",
            "sub": []
        }, {
            "title": "Tags",
            "path": "/tags",
            "type": "tag",
            "sub": []
        }, {
            "title": "Kuzu_v0",
            "path": "/search?what=Kuzu_v0&page=1",
            "type": "video",
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
        url = url.replace(/(\/featured|\?page=\d+|\&page=\d+|$)/, (match) => {
            if (match.startsWith('/')) {
                return match.charAt(0) + 'featured/' + page;
            } else if (match.startsWith('?') || match.startsWith('&')) {
                return match.charAt(0) + 'page=' + page;
            } else {
                return (url.includes('?') ? '&page=' : '?page=') + page;
            }
        });
        Apollo.pageAdd(page)
        if (url.includes("search")) {
            type = "search"
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
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0)'
            }
        })
        //动态分类
        //Apollo.DynamicSort(html)
        //Apollo.ActorSort(url, html)
        //搜索
        if (MY_PAGE == 1) {
            Apollo.d.push({
                title: "🔍",
                url: $.toString((url) => {
                    if (input.trim() != "") {
                        putMyVar('keyword', input);
                        var searchUrl = getHome(url) + "/search?what=" + input
                        putMyVar("url", searchUrl);
                        refreshPage();
                        return "hiker://empty"
                    } else {
                        clearMyVar("url");
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

        switch (type) {
            case 'home':
                if (MY_PAGE == 1 && !/search/.test(url)) {
                    try {
                        Apollo.lunboType(html)
                    } catch {}
                    Apollo.homeType(html)
                }
                break
            case 'video':
                Apollo.videoType(html, page)
                break
            case 'avatar':
                Apollo.avatarType(html, page)
                break
            case 'channel':
                Apollo.channelType(html, page)
                break
            case 'tag':
                Apollo.tagType(html, page)
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
                    Apollo.d.push({
                        col_type: "blank_block"
                    })
                }
                Apollo.videoType(html, page)
                break
            default:
                Apollo.videoType(html, page)
        }
        setResult(Apollo.d)
    },

    //动态分类
    DynamicSort: (html) => {
        const 分类颜色 = Apollo.getRangeColors()
        const 大类定位 = "body&&.section-header&&.dropdown-menu"
        const 拼接分类 = ""
        const 小类定位 = "body&&a"
        const 分类标题 = "Text"
        const 分类链接 = "a&&href"
        Apollo.d.push({
            col_type: "blank_block"
        });
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
            var cate_temp_json = getMyVar("sort", JSON.stringify(init_cate))
        } else {
            var cate_temp_json = getMyVar("ysort", JSON.stringify(init_cate))
        }
        var cate_temp = JSON.parse(cate_temp_json)

        if (MY_PAGE == 1) {
            categories.forEach((category, index) => {
                let sub_categories = pdfa(category, 小类定位);
                sub_categories.forEach((item, key) => {
                    let title = pdfh(item, 分类标题)
                    if (typeof(排除) != 'undefined' && 排除 != '') {
                        title = title.replace(new RegExp(排除, "g"), "")
                    };
                    Apollo.d.push({
                        title: key.toString() === cate_temp[index] ? '““””' + title.fontcolor(分类颜色) : title,
                        url: $(pdfh(item, 分类链接) + '#noLoading#').lazyRule((params) => {
                            params.cate_temp[params.index] = params.key.toString()
                            if (getMyVar("MY_TYPE") == "主页") {
                                putMyVar('sort', JSON.stringify(params.cate_temp));
                                putMyVar("url", input);
                            } else {
                                putMyVar('ysort', JSON.stringify(params.cate_temp));
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
    //女优sort
    ActorSort: (url, html) => {
        const 分类颜色 = Apollo.getRangeColors()
        const 大类定位 = "body&&.gutter-20&&select"
        const 拼接分类 = ""
        const 小类定位 = "body&&option"
        const 分类标题 = "Text"
        const 分类链接 = "option&&value"
        Apollo.d.push({
            col_type: "blank_block"
        });
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
        var cate_temp_json = getMyVar("asort", JSON.stringify(init_cate))
        var cate_temp = JSON.parse(cate_temp_json)

        if (MY_PAGE == 1) {
            categories.forEach((category, index) => {
                let sub_categories = pdfa(category, 小类定位);
                sub_categories.forEach((item, key) => {
                    let title = pdfh(item, 分类标题)
                    if (typeof(排除) != 'undefined' && 排除 != '') {
                        title = title.replace(new RegExp(排除, "g"), "")
                    };
                    Apollo.d.push({
                        title: key.toString() === cate_temp[index] ? '““””' + title.fontcolor(分类颜色) : title,
                        url: $(pdfh(item, 分类链接) + '#noLoading#').lazyRule((url, params) => {
                            params.cate_temp[params.index] = params.key.toString()
                            if (params.index == 0) {
                                input = input ? ("&height=" + input) : ""
                                url = url.replace(/\&height=.*(\&.*)?/, "$1") + input
                            }
                            if (params.index == 1) {
                                input = input ? ("&cup=" + input) : ""
                                url = url.replace(/\&cup=.*(\&.*)?/, "$1") + input
                            }
                            if (params.index == 2) {
                                input = input ? ("&age=" + input) : ""
                                url = url.replace(/\&age=.*(\&.*)?/, "$1") + input
                            }
                            if (params.index == 3) {
                                input = input ? ("&debut=" + input) : ""
                                url = url.replace(/\&debut=.*(\&.*)?/, "$1") + input
                            }
                            putMyVar('asort', JSON.stringify(params.cate_temp));
                            putMyVar("url", url);
                            clearMyVar("page")
                            refreshPage(true)
                            return "hiker://empty"
                        }, url, {
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
    searchParse: () => {
        Apollo.videoType(getResCode());
        setResult(Apollo.d)
    },

    videoType: (html, page) => {
        /*try {
            var pages = pdfh(html, "body&&.form-control-text&&Text").replace(/\,/g, "").match(/\d+/)[0]
        } catch (e) {
            var pages = 1
        }*/
        const list = pdfa(html, ".video-list&&.col-xs-6")
        list.forEach(item => {
            var img = pdfh(item, 'img&&data-src');
            var url = Apollo.url + pdfh(item, 'a&&href');
            url = url.replace(/http.*?(http.*)/, "$1");
            Apollo.d.push({
                title: pdfh(item, "img&&alt"),
                url: url + $('').lazyRule(() => {
                    var html = fetch(input)
                    var id = pdfh(html, "#video-meta&&data-vid");
                    var ajax = "https://www.tnaflix.com/ajax/video-player/" + id;
                    var data = JSON.parse(fetch(ajax)).html
                    var list = pdfa(data, "body&&source")
                    var names = list.map(i => pdfh(i, "source&&size"))
                    var urls = list.map(i => pdfh(i, "source&&src"))
                    return {
                        names,
                        urls
                    }
                }),
                pic_url: img ? img : pdfh(item, 'img&&src'),
                desc: pdfh(item, ".max-quality&&Text") + " ⏰" + pdfh(item, ".video-duration&&Text"),
                col_type: 'movie_2',
                extra: page ? {
                    longClick: Apollo.pageMoveto(page)
                } : ""
            })
        })
    },

    //一级.简
    yijiParse: (url) => {
        putMyVar("MY_TYPE", "一级")
        var page = getMyVar("page", MY_PAGE + "")
        /*try {
            var pages = pdfh(html, "body&&.mt-6.justify-between&&form&&Text").match(/\d+/)[0]
        } catch {
            var pages = 1
        }*/
        addListener("onClose", $.toString(() => {
            clearMyVar("yurl");
            clearMyVar("ysort");
            clearMyVar("page")
        }));
        url = getMyVar("yurl", url)
        url = url.replace(/(\/featured|\?page=\d+|\&page=\d+|$)/, (match) => {
            if (match.startsWith('/')) {
                return match.charAt(0) + 'featured/' + page;
            } else if (match.startsWith('?') || match.startsWith('&')) {
                return match.charAt(0) + 'page=' + page;
            } else {
                return (url.includes('?') ? '&page=' : '?page=') + page;
            }
        });
        log(url)
        Apollo.pageAdd(page)
        const html = fetch(url, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0)'
            }
        })
        //Apollo.DynamicSort(html)
        Apollo.videoType(html, page)
    },

    articlesType: (html, page) => {
        try {
            var pages = pdfh(html, "body&&.mt-6.justify-between&&form&&Text").match(/\d+/)[0]
        } catch {
            var pages = 1
        }
        const list = pdfa(html, '.grid&&.rounded-lg')
        list.forEach(item => {
            Apollo.d.push({
                title: pdfh(item, 'img&&alt'),
                url: $(pdfh(item, 'a&&href') + '#noHistory#').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    const html = fetch(MY_URL, {
                        headers: {
                            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0)'
                        }
                    })
                    Apollo.d.push({
                        title: pdfh(html, 'article&&Html'),
                        col_type: 'rich_text'
                    })
                    setResult(Apollo.d)
                }),
                pic_url: pdfh(item, 'img&&data-src') + '@Referer=' + Apollo.url,
                col_type: 'movie_2',
                extra: page ? {
                    longClick: Apollo.pageMoveto(page, pages)
                } : ""
            })
        })
    },

    avatarType: (html, page) => {
        /* try {
             var pages = pdfh(html, "body&&.form-control-text&&Text").replace(/\,/g, "").match(/\d+/)[0]
         } catch {
             var pages = 1
         }*/
        const list = pdfa(html, "body&&.col-6")
        list.forEach(item => {
            var img = pdfh(item, 'img&&src');
            Apollo.d.push({
                title: pdfh(item, '.thumb-title&&Text'),
                desc: pdfh(item, 'span&&Text'),
                img: img,
                url: $(pdfh(item, 'a&&href') + '/featured#fypage#noHistory#').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    MY_URL = MY_URL.split("#")[0]
                    Apollo.yijiParse(MY_URL)
                    setResult(Apollo.d)
                }),
                col_type: "movie_3",
                extra: page ? {
                    longClick: Apollo.pageMoveto(page)
                } : ""
            })
        })
    },
    //频道
    channelType: (html, page) => {
        /* try {
             var pages = pdfh(html, "body&&.form-control-text&&Text").replace(/\,/g, "").match(/\d+/)[0]
         } catch {
             var pages = 1
         }*/
        const list = pdfa(html, "body&&.col-6:not(:has(h3))")
        list.forEach(item => {
            var img = pdfh(item, 'img&&src');
            var url = pdfh(item, 'a&&href');
            Apollo.d.push({
                title: pdfh(item, '.thumb-title&&Text'),
                desc: pdfh(item, 'span&&Text'),
                img: img,
                url: url + $('?page=fypage#noHistory#').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    //MY_URL = MY_URL.split("#")[0]
                    Apollo.yijiParse(MY_URL)
                    setResult(Apollo.d)
                }),
                col_type: url.includes("channel") ? "movie_2" : "movie_3",
                extra: page ? {
                    longClick: Apollo.pageMoveto(page)
                } : ""
            })
        })
    },
    //标签
    tagType: (html, page) => {
        /* try {
             var pages = pdfh(html, "body&&.form-control-text&&Text").replace(/\,/g, "").match(/\d+/)[0]
         } catch {
             var pages = 1
         }*/
        const list = pdfa(html, "body&&.col-sm-2")
        list.forEach(item => {
            //var img = pdfh(item, 'img&&src');
            var url = pdfh(item, 'a&&href');
            Apollo.d.push({
                title: pdfh(item, 'Text'),
                desc: pdfh(item, 'span&&Text'),
                //img: img,
                url: url + $('&page=fypage#noHistory#').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    //MY_URL = MY_URL.split("#")[0]
                    Apollo.yijiParse(MY_URL)
                    setResult(Apollo.d)
                }),
                col_type: "text_2",
                extra: page ? {
                    longClick: Apollo.pageMoveto(page)
                } : ""
            })
        })
    },
    //首页轮播
    lunboType: (html) => {
        var lundata = pdfa(html, "#top-carousel&&.box-item").map((x) => {
            var urll = Apollo.url + pdfh(x, "a&&href");
            return {
                title: pdfh(x, ".name&&Text"), //pdfh(x, ".name&&Text").split("").map(b => b.fontcolor(Apollo.getRangeColors()).small()).join(""),
                img: pdfh(x, "img&&src").replace("resize/s500", "images"),
                url: urll + $('#noHistory#').rule(() => {
                    const Apollo = $.require('hiker://page/Apollo')
                    Apollo.videoParse(MY_URL)
                    setResult(Apollo.d)
                }),
            }
        });

        function banner(title, start, arr, data, cfg) {
            let id = title + 'lunbo';
            var rnum = Math.floor(Math.random() * data.length);
            var item = data[rnum];
            putMyVar('rnum', rnum);
            let time = 5000;
            let col_type = 'pic_1_card';
            let color = "white";
            let desc = '';
            if (cfg != undefined) {
                time = cfg.time ? cfg.time : time;
                col_type = cfg.col_type ? cfg.col_type : col_type;
                desc = cfg.desc ? cfg.desc : desc;
            }

            arr.push({
                    col_type: col_type,
                    img: item.img,
                    desc: desc,
                    title: item.title,
                    url: item.url,
                    extra: {
                        id: id + 'bar',
                        img: item.img,
                    }
                },
                /*{
                               col_type: "avatar",
                               title: item.title,
                               img: "https://cdn-icons-png.flaticon.com/128/1384/1384060.png",
                               url: Apollo.empty,
                               extra: {
                                   id: id + 'title',
                                   title: item.title,
                                   lineVisible: false
                               }
                           }, {
                               col_type: "line_blank"
                           }*/
            )

            if (start == false || getMyVar('benstart', 'true') == 'false') {
                unRegisterTask(id)
                return
            }

            //log(data)

            let obj = {
                data: data,
            };

            registerTask(id, time, $.toString((obj, id) => {
                var data = obj.data;
                var rum = getMyVar('rnum');

                var i = Number(getMyVar('banneri', '0'));
                if (rum != '') {
                    i = Number(rum) + 1
                    clearMyVar('rnum')
                } else {
                    i = i + 1;
                }
                //log(i)
                //log(data.length)

                if (i > data.length - 1) {
                    i = 0
                }
                var item = data[i];
                //log(item)
                try {
                    updateItem(id + 'bar', {
                        title: item.title,
                        img: item.img,
                        url: item.url,
                        extra: {
                            title: item.title,
                            img: item.img,
                            //name: item.title.replace(/<[^>]+>/g, ''),
                            //sname: item.extra.sname,
                            //stype: item.extra.stype,
                            //surl: item.url,
                            //img:item.img,
                            //pageTitle: item.title.replace(/<[^>]+>/g, ''),
                        }
                    })
                    updateItem(id + 'title', {
                        title: item.title,
                        extra: {
                            title: item.title,
                            lineVisible: false
                        }
                    })
                } catch (e) {
                    log(e.message)
                    unRegisterTask(id)
                }
                putMyVar('banneri', i);

            }, obj, id))
        }
        banner(MY_RULE.title, true, Apollo.d, lundata, {
            time: 3333,
            col_type: "card_pic_1",
            desc: '0'
        })
    },

    //首页
    homeType: (html) => {
        var tabs = pdfa(html, "body&&section,1:")
        tabs.forEach(tag => {
            let list = pdfa(tag, "body&&.box-item")
            Apollo.d.push({
                title: pdfh(tag, "h2&&Text").fontcolor("#FF00FF"),
                url: "hiker://empty",
                col_type: "rich_text",
            })
            list.forEach(item => {
                let url = Apollo.url + pdfh(item, "a&&href")
                let title = pdfh(item, ".detail&&Text");
                Apollo.d.push({
                    title: title,
                    desc: pdfh(item, ".duration&&Text") + "\t" + pdfh(item, ".video-duration&&Text"),
                    img: pdfh(item, "img&&data-src").replace("resize/s360", "images"),
                    url: url + $('#noHistory#').rule(() => {
                        const Apollo = $.require('hiker://page/Apollo')
                        Apollo.videoParse(MY_URL)
                        setResult(Apollo.d)
                    }),
                    col_type: "movie_2",
                })
            })
            Apollo.d.push({
                col_type: "blank_block"
            })
        })
    }

}
$.exports = Apollo