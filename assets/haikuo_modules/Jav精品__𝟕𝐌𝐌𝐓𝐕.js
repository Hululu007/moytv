// === zaAes: 自包含 AES-128-CBC/PKCS7 解密（不依赖外部加密库） ===
// AES-128-CBC/PKCS7 解密的最小实现（自包含，不依赖外部库）
var ZaAes = (function () {
  var sbox = new Array(256), rsbox = new Array(256);
  (function () {
    var p = 1, q = 1;
    do {
      p = p ^ ((p << 1) & 0xff) ^ (p & 0x80 ? 0x1b : 0);
      q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xff;
      if (q & 0x80) q ^= 0x09;
      var x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4));
      sbox[p] = (x ^ 0x63) & 0xff;
    } while (p !== 1);
    sbox[0] = 0x63;
    for (var i = 0; i < 256; i++) rsbox[sbox[i]] = i;
  })();
  function xtime(a) { return ((a << 1) ^ (a & 0x80 ? 0x1b : 0)) & 0xff; }
  function mul(a, b) {
    var r = 0;
    while (b) { if (b & 1) r ^= a; a = xtime(a); b >>= 1; }
    return r;
  }
  function expandKey(key) {
    var w = [], nk = key.length / 4, nr = nk + 6;
    for (var i = 0; i < nk; i++) w[i] = [key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]];
    var rcon = 1;
    for (var i = nk; i < 4 * (nr + 1); i++) {
      var t = w[i - 1].slice();
      if (i % nk === 0) {
        t = [sbox[t[1]] ^ rcon, sbox[t[2]], sbox[t[3]], sbox[t[0]]];
        rcon = xtime(rcon);
        if (rcon === 0) rcon = 1;
      } else if (nk > 6 && i % nk === 4) {
        t = [sbox[t[0]], sbox[t[1]], sbox[t[2]], sbox[t[3]]];
      }
      w[i] = [w[i - nk][0] ^ t[0], w[i - nk][1] ^ t[1], w[i - nk][2] ^ t[2], w[i - nk][3] ^ t[3]];
    }
    return { w: w, nr: nr };
  }
  function decryptBlock(ks, input) {
    var s = input.slice(), nr = ks.nr, w = ks.w;
    function addRoundKey(r) {
      for (var c = 0; c < 4; c++) for (var row = 0; row < 4; row++) s[c * 4 + row] ^= w[r * 4 + c][row];
    }
    addRoundKey(nr);
    for (var round = nr - 1; round >= 0; round--) {
      for (var i = 0; i < 16; i++) s[i] = rsbox[s[i]];
      // inv shift rows
      var t = s.slice();
      for (var row = 1; row < 4; row++) for (var c = 0; c < 4; c++) s[((c + row) % 4) * 4 + row] = t[c * 4 + row];
      addRoundKey(round);
      if (round !== 0) {
        for (var c = 0; c < 4; c++) {
          var a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3];
          s[c * 4]     = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9);
          s[c * 4 + 1] = mul(a0, 9)  ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13);
          s[c * 4 + 2] = mul(a0, 13) ^ mul(a1, 9)  ^ mul(a2, 14) ^ mul(a3, 11);
          s[c * 4 + 3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9)  ^ mul(a3, 14);
        }
      }
    }
    return s;
  }
  function utf8ToBytes(str) {
    var out = [], i, c;
    for (i = 0; i < str.length; i++) {
      c = str.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
      else if (c < 0xd800 || c >= 0xe000) { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
      else {
        i++; var c2 = 0x10000 + (((c & 0x3ff) << 10) | (str.charCodeAt(i) & 0x3ff));
        out.push(0xf0 | (c2 >> 18), 0x80 | ((c2 >> 12) & 0x3f), 0x80 | ((c2 >> 6) & 0x3f), 0x80 | (c2 & 0x3f));
      }
    }
    return out;
  }
  function bytesToUtf8(b) {
    var out = '', i = 0;
    while (i < b.length) {
      var c = b[i++];
      if (c < 0x80) out += String.fromCharCode(c);
      else if (c < 0xe0) out += String.fromCharCode(((c & 0x1f) << 6) | (b[i++] & 0x3f));
      else if (c < 0xf0) out += String.fromCharCode(((c & 0x0f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f));
      else {
        var cp = ((c & 0x07) << 18) | ((b[i++] & 0x3f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      }
    }
    return out;
  }
  function hexToBytes(h) {
    var out = [];
    for (var i = 0; i < h.length; i += 2) out.push(parseInt(h.substr(i, 2), 16));
    return out;
  }
  function base64ToBytes(b64) {
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var out = [], buf = 0, bits = 0;
    for (var i = 0; i < b64.length; i++) {
      var v = chars.indexOf(b64[i]);
      if (v < 0) continue;
      buf = (buf << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 0xff); }
    }
    return out;
  }
  return {
    utf8ToBytes: utf8ToBytes,
    bytesToUtf8: bytesToUtf8,
    hexToBytes: hexToBytes,
    base64ToBytes: base64ToBytes,
    decryptCBC: function (dataBytes, keyStr, ivStr) {
      var key = utf8ToBytes(keyStr), iv = utf8ToBytes(ivStr);
      var ks = expandKey(key), prev = iv.slice(), out = [];
      for (var off = 0; off < dataBytes.length; off += 16) {
        var block = dataBytes.slice(off, off + 16);
        if (block.length < 16) break;
        var dec = decryptBlock(ks, block);
        for (var i = 0; i < 16; i++) out.push(dec[i] ^ prev[i]);
        prev = block;
      }
      // PKCS7 去填充
      if (out.length) {
        var pad = out[out.length - 1];
        if (pad > 0 && pad <= 16) {
          var ok = true;
          for (var i = out.length - pad; i < out.length; i++) if (out[i] !== pad) { ok = false; break; }
          if (ok) out = out.slice(0, out.length - pad);
        }
      }
      return bytesToUtf8(out);
    }
  };
})();


// === end zaAes ===
var Apollo = {
    version: "20250425",
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
            var pgNext = "";
            var pgLinks = pdfa(html, "body&&.pagination-row&&a");
            for (var pgi = 0; pgi < pgLinks.length; pgi++) {
                if (pdfh(pgLinks[pgi], "a&&Text").trim() === ">") { pgNext = pdfh(pgLinks[pgi], "a&&href"); break; }
            }
            if (pgNext) { putMyVar("nextPage", pgNext); } else { clearMyVar("nextPage"); }
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
                        const Apollo = $.require('hiker://page/Apollo')
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
                const Apollo = $.require('hiker://page/Apollo?rule=𝟕𝐌𝐌𝐓𝐕')
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
        var list = pdfa(html, "body&&.video,.comics");
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
            var pgNext = "";
            var pgLinks = pdfa(html, "body&&.pagination-row&&a");
            for (var pgi = 0; pgi < pgLinks.length; pgi++) {
                if (pdfh(pgLinks[pgi], "a&&Text").trim() === ">") { pgNext = pdfh(pgLinks[pgi], "a&&href"); break; }
            }
            if (pgNext) { putMyVar("nextPage1", pgNext); } else { clearMyVar("nextPage1"); }
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
                const Apollo = $.require('hiker://page/Apollo?rule=𝟕𝐌𝐌𝐓𝐕')
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
            Apollo.d.push({
                title: "<a style='text-decoration: none;fontcolor:red;' href='" + lazypic + "'>預覽和介紹</a>：" + (content != "" ? content : "曾经沧海难为水，除却巫山不是云。取次花丛懒回顾，半缘修道半缘君。\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t------元稹").fontcolor("grey").small(),
                url: Apollo.empty,
                col_type: "rich_text",
                extra: {
                    lineVisible: false
                }
            })
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
        let list = [];
        // 解析最简单的 JS 数组/字符串字面量（站点把播放器参数塞在 mvarr 里，逐条解比整段 eval 稳）
        var parseArr = function zaParseArr(src) {
        var i = 0, n = src.length;
        function ws() { while (i < n && /\s/.test(src.charAt(i))) i++; }
        function val() {
            ws();
            var c = src.charAt(i);
            if (c === '[') {
                i++; var arr = [];
                while (true) {
                    ws();
                    if (src.charAt(i) === ']') { i++; return arr; }
                    arr.push(val()); ws();
                    var t = src.charAt(i);
                    if (t === ',') { i++; continue; }
                    if (t === ']') { i++; return arr; }
                    throw new Error('bad array at ' + i);
                }
            }
            if (c === "'" || c === '"') {
                var q = c; i++; var out = '';
                while (i < n) {
                    var ch = src.charAt(i++);
                    if (ch === '\\') {
                        var e = src.charAt(i++);
                        if (e === 'n') out += '\n';
                        else if (e === 't') out += '\t';
                        else if (e === 'r') out += '\r';
                        else out += e;
                    } else if (ch === q) break;
                    else out += ch;
                }
                return out;
            }
            var st = i;
            while (i < n && !/[,\]\s]/.test(src.charAt(i))) i++;
            var raw = src.slice(st, i);
            if (/^-?\d+$/.test(raw)) return parseInt(raw, 10);
            if (raw === 'true') return true;
            if (raw === 'false') return false;
            if (raw === 'null') return null;
            return raw;
        }
        return val();
        };

        // 站点每次访问都会换 key/iv，还会放近似名的诱饵变量，必须带词边界精确取
        var hcM = html.match(/\bhcdeedg252\s*=\s*(\d+)/);
        var haM = html.match(/\bhadeedg252\s*=\s*(\d+)/);
        var keyM = html.match(/\bargdeqweqweqwe\s*=\s*'([^']*)'/);
        var ivM = html.match(/\bhdddedg252\s*=\s*'([^']*)'/);
        var hc = hcM ? parseInt(hcM[1], 10) : 0;
        var ha = haM ? parseInt(haM[1], 10) : 0;
        var keyStr = keyM ? keyM[1] : '';
        var ivStr = ivM ? ivM[1] : '';

        var okParams = !!(hc && !isNaN(ha) && keyStr && ivStr);

        function zaDecode(enc) {
            var sep = String.fromCharCode(hc + 97);
            var toks = String(enc).split(sep);
            var s1 = '';
            for (var i = 0; i < toks.length; i++) {
                var v = parseInt(toks[i], hc);
                if (!isNaN(v) && v >= 0) s1 += String.fromCharCode(v ^ ha);
            }
            var bytes;
            if (/^[0-9a-fA-F]+$/.test(s1) && s1.length % 2 === 0) bytes = ZaAes.hexToBytes(s1);
            else bytes = ZaAes.base64ToBytes(s1);
            return ZaAes.decryptCBC(bytes, keyStr, ivStr);
        }

        var lineName = (tag) => tag
            .replace("28", "DO").replace("29", "🔥ST").replace("37", "🔥SW")
            .replace("38", "🔥VH").replace("39", "EM").replace("40", "🔥TV")
            .replace("41", "US").replace("42", "SP");

        var re = /mvarr\['(\d+_\d+)'\]\s*=/g;
        var mm, got = 0;
        while ((mm = re.exec(html)) !== null) {
            var tag = mm[1], arr;
            var seg = html.slice(mm.index + mm[0].length);
            try { arr = parseArr(seg); } catch (e) { arr = null; }
            if (!arr || !arr.length) continue;
            for (var k = 0; k < arr.length; k++) {
                var it = arr[k];
                if (!it || it.length < 4) continue;
                var enc = it[1], pre = it[3] || '', mid = it[4] || '';
                var dec = '';
                if (okParams) {
                    try { dec = zaDecode(enc); } catch (e) { dec = ''; }
                }
                if (!dec) continue;
                var full = pre + dec + mid;
                if (full.indexOf('//') === 0) full = 'https:' + full;
                else full = full.replace(/http.*?(http.*)/, '$1');
                list.push({ 'title': lineName(tag), 'url': full });
                got++;
            }
        }
        if (!got && typeof log === 'function') log('7mmtv: 未解出播放线路, params=' + okParams + ' hc=' + hc + ' keys=' + !!keyStr);

        var lazy = $('').lazyRule(() => {
            // 定义一个解析分辨率的函数
            function getResolution(name) {
                var match = name.match(/(\d+)/); // 提取降级分辨率
                return match ? parseInt(match[1], 10) : 0; // 如果没有匹配则返回0
            }
            let videoUrl = '';
            var html = fetch(input)
            //log(html)
            if (input.indexOf("7mmtv.sx/assets") != -1 || input.indexOf("7mmtv") != -1 && html.indexOf("videoSources") != -1) {
                //SP线路42：播放页里是 const videoSources = [{src,type,size},...]
                var srcList = [];
                var vm = html.match(/videoSources\s*=\s*(\[[\s\S]*?\])\s*;/);
                if (vm) {
                    try { srcList = eval('(' + vm[1] + ')') } catch (e) { srcList = [] }
                }
                var urls = [];
                for (var i = 0; i < srcList.length; i++) {
                    var it = srcList[i];
                    if (!it || !it.src) continue;
                    if (it.type && String(it.type).indexOf('mpegURL') === -1 && String(it.src).indexOf('.m3u8') === -1) continue;
                    urls.push({ name: String(it.size || (urls.length + 1)), url: it.src });
                }
                // 兜底：结构变了就直接从整页抓 m3u8 直链
                if (!urls.length) {
                    var raw = html.match(/https?:\/\/[^'"\s\\]+?\.m3u8[^'"\s\\]*/g) || [];
                    for (var j = 0; j < raw.length; j++) {
                        if (raw[j].indexOf('//') === 0) continue;
                        urls.push({ name: String(raw.length - j), url: raw[j] });
                    }
                }
                urls.sort(function (a, b) { return (parseInt(b.name) || 0) - (parseInt(a.name) || 0) });
                if (!urls.length) return 'toast://没取到播放地址，换个线路试试';
                return JSON.stringify({
                    names: urls.map(function (x) { return x.name }),
                    urls: urls.map(function (x) { return x.url }),
                    headers: new Array(urls.length).fill({ Referer: "https://7mmtv.sx/" })
                });
            } else if (input.indexOf("7mmtv.sx") != -1) {
                //TV线路40               
                var s = html.match(/src.?=[^\>]+/)[0];
                eval(s)
                var request = fetch(src);
                let playUrl = request.match(/https.*?m3u8/)[0];
                var group_quality = fetch(playUrl, {
                    headers: {
                        'Referer': input
                    }
                });
                //log(group_quality)
                hghest_quality = group_quality.match(/^[^#\s]+$/gm).map(v => v.includes("http") ? v + "#isVideo=true#" : playUrl.replace(/[^\/]+$/, v))
                //log(hghest_quality)
                name_quality = group_quality.match(/RESOLUTION=.*?\,/gm).map(n => n.replace(/RESOLUTION=|\,/g, ""))

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
                var script = html.match(/eval(.*\))/)[1]
                playUrl = eval(script).match(/(https?.*?)"/)[1]
                var group_quality = fetch(playUrl, {
                    headers: {
                        'Referer': input
                    }
                });
                group_quality = group_quality.split("\n\n")[0]
                // log(group_quality)
                hghest_quality = group_quality.match(/^[^#\s]+$/gm).map(v => v.includes("http") ? v + "#isVideo=true#" : playUrl.replace(/[^\/]+$/, v + "#.m3u8"))
                //log(hghest_quality)
                name_quality = group_quality.match(/RESOLUTION=.*?\,/gm).map(n => n.replace(/RESOLUTION=|\,/g, ""))

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
        var codelazy = fetch('hiker://files/rules/Apollo/CodeLazy.js') || "";
        if (!codelazy || codelazy == 'null' || codelazy == 'undefined') {
            Apollo.d.push({
                title: '““””<font color="#FF0000">本地 CodeLazy.js 不存在</font>',
                desc: '请把统一维护的 CodeLazy.js 放到 hiker://files/rules/Apollo/CodeLazy.js；本规则不会远程下载或覆盖。',
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
    }

}

$.exports = Apollo