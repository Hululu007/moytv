var AvJoy = {
    HOST: 'https://avjoy.me',
    UA: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    K: { tab: 'aj_tab', sort: 'aj_sort' },

    TABS: [
        { key: 'videos', name: '影片', color: '4ECDC4', icon: 'video' },
        { key: 'categories', name: '分類', color: '54A0FF', icon: 'grid' },
        { key: 'tags', name: '標籤', color: 'FF6B6B', icon: 'tag' }
    ],

    videoSorts: [
        { v: 'mr', name: '最新' },
        { v: 'mv', name: '最受歡迎' },
        { v: 'tr', name: '最高評分' },
        { v: 'tf', name: '最愛' }
    ],

    hdr: function () {
        return { 'User-Agent': this.UA, 'Referer': this.HOST + '/' };
    },

    abs: function (u) {
        if (!u) return '';
        if (/^https?:\/\//i.test(u)) return u;
        if (u.indexOf('/') === 0) return this.HOST + u;
        return this.HOST + '/' + u;
    },

    imgH: function (u) {
        if (!u) return '';
        u = this.abs(u);
        return u + '@Referer=' + this.HOST + '/';
    },

    text: function (t) {
        return String(t == null ? '' : t).replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
    },

    on: function (name, active, color) {
        if (!active) return String(name);
        color = String(color || 'FF6B6B').replace('#', '');
        return '‘‘’’<strong><font color=#' + color + '>' + name + '</font></strong>';
    },

    gap: function (d) {
        d.push({ title: '', url: 'hiker://empty', col_type: 'blank_block' });
    },

    videoUrl: function (sort, page) {
        if (page > 1) return this.HOST + '/?page=' + page;
        return this.HOST + '/';
    },

    parseVideos: function (html) {
        var items = [];
        if (!html) return items;
        var re = /<a href="(\/video\/[^"]+)"/g;
        var m, seen = {};
        while ((m = re.exec(html)) !== null) {
            var href = m[1];
            if (seen[href]) continue;
            seen[href] = 1;
            var slice = html.substring(m.index, m.index + 1500);
            var title = '';
            var tm = slice.match(/content-title">([^<]+)/);
            if (tm) title = this.text(tm[1]);
            if (!title) {
                var am = slice.match(/alt="([^"]+)"/);
                if (am) title = this.text(am[1]);
            }
            if (!title) {
                var tt = slice.match(/title="([^"]+)"/);
                if (tt) title = this.text(tt[1]);
            }
            if (!title) continue;

            var img = '';
            var im = slice.match(/<img[^>]+src="([^"]+)"/);
            if (im) img = im[1];
            var dur = '';
            var dm = slice.match(/class="duration">([\s\S]*?)<\/div>/);
            if (dm) dur = this.text(dm[1]).replace(/^HD\s*/i, '');
            var views = '';
            var vm = slice.match(/content-views">([\s\S]*?)<\/span>/);
            if (vm) views = this.text(vm[1]);
            items.push({
                title: title,
                img: this.imgH(img),
                desc: [dur, views].filter(Boolean).join(' · '),
                url: this.abs(href) + this.lazy,
                col_type: 'movie_2'
            });
        }
        return items;
    },

    parseCategories: function (html) {
        var items = [];
        if (!html) return items;
        var re = /<a href="(\/videos\/[a-z0-9\-]+)"[\s\S]*?<\/a>/gi;
        var m, seen = {};
        while ((m = re.exec(html)) !== null) {
            var href = m[1];
            var b = m[0];
            if (b.indexOf('title-truncate') < 0 && b.indexOf('category-title') < 0) continue;
            if (seen[href]) continue;
            seen[href] = 1;
            var name = '';
            var nm = b.match(/title-truncate">\s*([^<]+)/);
            if (nm) name = this.text(nm[1]);
            if (!name) {
                var alt = b.match(/alt="([^"]+)"/);
                if (alt) name = this.text(alt[1]);
            }
            if (!name) continue;
            var count = '';
            var cm = b.match(/float-right">\s*(\d+)/);
            if (cm) count = cm[1];
            var img = '';
            var im = b.match(/<img[^>]+src="([^"]+)"/);
            if (im) img = im[1];
            items.push({
                title: name + (count ? ' (' + count + ')' : ''),
                img: this.imgH(img),
                url: 'hiker://empty?page=fypage&cateUrl=' + encodeURIComponent(this.abs(href)) +
                     '@rule=js:$.require("AvJoy").categoryVideos()',
                col_type: 'movie_3'
            });
        }
        return items;
    },

    parseTags: function (html) {
        var items = [];
        if (!html) return items;
        var re = /href="(\/search\/videos\/[^"]+)"[^>]*title="([^"]*)"/g;
        var m, seen = {};
        while ((m = re.exec(html)) !== null) {
            var href = m[1];
            var name = this.text(m[2] || '');
            if (!href || !name) continue;
            if (seen[href]) continue;
            seen[href] = 1;
            var count = '';
            var slice = html.substring(Math.max(0, m.index - 120), m.index);
            var cm = slice.match(/tag-counter">(\d+)</);
            if (cm) count = cm[1];
            items.push({
                title: name + (count ? ' (' + count + ')' : ''),
                url: 'hiker://empty?page=fypage&tagUrl=' + encodeURIComponent(this.abs(href)) +
                     '@rule=js:$.require("AvJoy").tagSearch()',
                col_type: 'text_3'
            });
        }
        return items;
    },

    pushSearch: function (d) {
        d.push({
            title: '🔍 搜索影片',
            url: $.toString(function () {
                if (!input || !String(input).trim()) return 'toast://请输入关键词';
                return 'hiker://empty?page=fypage&kw=' + encodeURIComponent(String(input).trim()) +
                    '@rule=js:$.require("AvJoy").search()';
            }),
            col_type: 'input'
        });
    },

    pushTabs: function (d, cur) {
        for (var i = 0; i < this.TABS.length; i++) {
            var t = this.TABS[i];
            d.push({
                title: this.on(t.name, t.key === cur, t.color),
                img: 'https://img.icons8.com/ios-filled/100/' + t.color + '/' + t.icon + '.png',
                url: $('#noLoading#').lazyRule(function (k) {
                    var M = $.require('AvJoy');
                    putMyVar(M.K.tab, k);
                    putMyVar(M.K.sort, 'mr');
                    refreshPage(true);
                    return 'hiker://empty';
                }, t.key),
                col_type: 'icon_small_3'
            });
        }
    },

    pushVideoSort: function (d, cur) {
        for (var i = 0; i < this.videoSorts.length; i++) {
            var s = this.videoSorts[i];
            var on = String(s.v) === String(cur);
            d.push({
                title: this.on(s.name, on, on ? '54A0FF' : 'A29BFE'),
                url: $('#noLoading#').lazyRule(function (v) {
                    var M = $.require('AvJoy');
                    putMyVar(M.K.sort, String(v));
                    refreshPage(false);
                    return 'hiker://empty';
                }, s.v),
                col_type: 'scroll_button'
            });
        }
    },

    videoList: function () {
        var sort = getMyVar(this.K.sort, 'mr');
        var page = parseInt(MY_PAGE, 10) || 1;
        if (page < 1) page = 1;
        if (page === 1) {
            var head = [];
            this.pushSearch(head);
            this.pushTabs(head, 'videos');
            this.gap(head);
            setPreResult(head);
        }
        var html = '';
        try { html = fetch(this.videoUrl(sort, page), { headers: this.hdr(), timeout: 60000 }) || ''; } catch (e) {}
        var items = this.parseVideos(html);
        if (!items.length && page > 1) { setResult([]); return; }
        if (!items.length) {
            setResult([{ title: '暂无视频', url: 'hiker://empty', col_type: 'text_center_1' }]);
            return;
        }
        setResult(items);
    },

    categoryList: function () {
        var page = parseInt(MY_PAGE, 10) || 1;
        if (page < 1) page = 1;
        if (page > 1) { setResult([]); return; }
        var head = [];
        this.pushSearch(head);
        this.pushTabs(head, 'categories');
        this.gap(head);
        setPreResult(head);
        var html = '';
        try { html = fetch(this.HOST + '/categories', { headers: this.hdr(), timeout: 60000 }) || ''; } catch (e) {}
        var items = this.parseCategories(html);
        if (!items.length) {
            setResult([{ title: '暂无分类', url: 'hiker://empty', col_type: 'text_center_1' }]);
            return;
        }
        setResult(items);
    },

    tagList: function () {
        var page = parseInt(MY_PAGE, 10) || 1;
        if (page < 1) page = 1;
        if (page > 1) { setResult([]); return; }
        var head = [];
        this.pushSearch(head);
        this.pushTabs(head, 'tags');
        this.gap(head);
        setPreResult(head);
        var html = '';
        try { html = fetch(this.HOST + '/tags', { headers: this.hdr(), timeout: 60000 }) || ''; } catch (e) {}
        var items = this.parseTags(html);
        if (!items.length) {
            setResult([{ title: '暂无标签', url: 'hiker://empty', col_type: 'text_center_1' }]);
            return;
        }
        setResult(items);
    },

    categoryVideos: function () {
        var cateUrl = '';
        try {
            var m = String(MY_URL || '').match(/[?&]cateUrl=([^&]+)/);
            if (m) cateUrl = decodeURIComponent(m[1]);
        } catch (e) {}
        if (!cateUrl) {
            setResult([{ title: '无效分类', col_type: 'text_center_1' }]);
            return;
        }
        var page = parseInt(MY_PAGE, 10) || 1;
        if (page < 1) page = 1;
        var sort = getMyVar(this.K.sort, 'mr');
        var url = cateUrl;
        url += (url.indexOf('?') >= 0 ? '&' : '?') + 'o=' + encodeURIComponent(sort);
        if (page > 1) url += '&page=' + page;
        var body = [];
        if (page === 1) {
            this.pushVideoSort(body, sort);
            this.gap(body);
        }
        var html = '';
        try { html = fetch(url, { headers: this.hdr(), timeout: 60000 }) || ''; } catch (e) {}
        var items = this.parseVideos(html);
        if (!items.length && page > 1) { setResult([]); return; }
        if (!items.length) {
            body.push({ title: '该分类暂无视频', col_type: 'text_center_1' });
            setResult(body);
            return;
        }
        setResult(body.concat(items));
    },

    tagSearch: function () {
        var tagUrl = '';
        try {
            var m = String(MY_URL || '').match(/[?&]tagUrl=([^&]+)/);
            if (m) tagUrl = decodeURIComponent(m[1]);
        } catch (e) {}
        if (!tagUrl) {
            setResult([{ title: '无效标签', col_type: 'text_center_1' }]);
            return;
        }
        var page = parseInt(MY_PAGE, 10) || 1;
        if (page < 1) page = 1;
        var url = tagUrl;
        if (page > 1) url += (url.indexOf('?') >= 0 ? '&' : '?') + 'page=' + page;
        var html = '';
        try { html = fetch(url, { headers: this.hdr(), timeout: 60000 }) || ''; } catch (e) {}
        var items = this.parseVideos(html);
        if (!items.length && page > 1) { setResult([]); return; }
        if (!items.length) {
            setResult([{ title: '该标签暂无视频', col_type: 'text_center_1' }]);
            return;
        }
        setResult(items);
    },

    main: function () {
        var mu = String(MY_URL || '');
        if (/[?&]cateUrl=/.test(mu)) return this.categoryVideos();
        if (/[?&]tagUrl=/.test(mu)) return this.tagSearch();
        if (/[?&]detailUrl=/.test(mu)) return this.detail();
        var tab = getMyVar(this.K.tab, 'videos');
        if (tab === 'categories') return this.categoryList();
        if (tab === 'tags') return this.tagList();
        return this.videoList();
    },

    detail: function () {
        var url = '';
        try {
            var m = String(MY_URL || '').match(/[?&]detailUrl=([^&]+)/);
            if (m) url = decodeURIComponent(m[1]);
        } catch (e) {}
        if (!url) {
            setResult([{ title: '无效链接', col_type: 'text_center_1' }]);
            return;
        }
        var html = '';
        try { html = fetch(url, { headers: this.hdr(), timeout: 60000 }) || ''; } catch (e) {}
        if (!html) {
            setResult([{ title: '加载失败', col_type: 'text_center_1' }]);
            return;
        }
        var title = '';
        var tm = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
        if (tm) title = this.text(tm[1]);
        if (!title) {
            var t2 = html.match(/<title>([\s\S]*?)<\/title>/);
            if (t2) title = this.text(t2[1]);
        }
        var img = '';
        var im = html.match(/<img[^>]+src="([^"]+)"/);
        if (im) img = this.imgH(im[1]);
        var result = [];
        if (img) result.push({ col_type: 'movie_1_vertical_pic_blur', title: title || '详情', img: img });
        else result.push({ col_type: 'rich_text', title: '<b>' + (title || '详情') + '</b>' });
        setResult(result);
    },

    search: function () {
        var kw = '';
        try {
            var m = String(MY_URL || '').match(/[?&]kw=([^&]+)/);
            if (m) kw = decodeURIComponent(m[1]);
            else if (String(MY_URL || '').indexOf('##') >= 0) kw = String(MY_URL).split('##').pop();
        } catch (e) {}
        if (!kw) kw = getMyVar('aj_kw', '');
        putMyVar('aj_kw', kw);
        kw = String(kw || '').trim();
        if (!kw) {
            setResult([{ title: '请输入关键词', url: 'hiker://empty', col_type: 'text_center_1' }]);
            return;
        }
        var page = parseInt(MY_PAGE, 10) || 1;
        if (page < 1) page = 1;
        var url = this.HOST + '/search/videos/' + encodeURIComponent(kw);
        if (page > 1) url += '?page=' + page;
        var html = '';
        try { html = fetch(url, { headers: this.hdr(), timeout: 60000 }) || ''; } catch (e) {}
        var items = this.parseVideos(html);
        if (!items.length && page > 1) { setResult([]); return; }
        if (!items.length) {
            setResult([{ title: '没有搜到「' + kw + '」', url: 'hiker://empty', col_type: 'text_center_1' }]);
            return;
        }
        setResult(items);
    },

    lazy: $('').lazyRule(function () {
        var M = $.require('AvJoy');
        try {
            var pageUrl = String(input || '').split('#')[0];
            if (!pageUrl) return 'toast://缺少详情地址';
            var html = fetch(pageUrl, { headers: M.hdr(), timeout: 60000 }) || '';
            if (!html) return 'toast://详情为空';
            var play = '';
            var m = html.match(/<source[^>]+src=["']([^"']+\.(?:mp4|m3u8)[^"']*)["']/i);
            if (m) play = m[1];
            if (!play) {
                var m2 = html.match(/https?:\/\/[^"'\s]*media-cdn[^"'\s]*\.(?:mp4|m3u8)[^"'\s]*/i);
                if (m2) play = m2[0];
            }
            if (!play) return 'toast://未解析到播放地址';
            if (play.indexOf('http') !== 0) play = M.HOST + play;
            return JSON.stringify({
                urls: [play],
                names: ['播放'],
                headers: [{
                    Referer: M.HOST + '/',
                    'User-Agent': M.UA
                }]
            });
        } catch (e) {
            return 'toast://解析失败';
        }
    })
};
$.exports = AvJoy;