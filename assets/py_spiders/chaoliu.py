try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import gzip
import http.client
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request


FEED = "https://chaoliu-feed-8809814861.web.zaka.live"
WEB = "https://chaoliu-av-tk8m.web.zaka.live"
UA = "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36 ChaoliuApp/2.17"
LINES = ["/api/", "/api2/", "/api3/"]
JP_V = "20261005c"
PAGE = 24

CATS = [
    ("精品推荐", ((0, 20),)),
    ("国产色情", ((0, 22),)),
    ("主播直播", ((0, 23),)),
    ("亚洲无码", ((0, 24),)),
    ("亚洲有码", ((0, 25),)),
    ("中文字幕", ((0, 26), (1, 9))),
    ("巨乳美乳", ((0, 27), (1, 8))),
    ("人妻熟女", ((0, 28),)),
    ("强奸乱伦", ((0, 29), (1, 7))),
    ("欧美精品", ((0, 30),)),
    ("伦理三级", ((0, 32),)),
    ("成人动漫", ((0, 33),)),
    ("自拍偷拍", ((0, 34),)),
    ("制服丝袜", ((0, 35),)),
    ("口交颜射", ((0, 36),)),
    ("日本精品", ((0, 37),)),
    ("Cosplay", ((0, 38),)),
    ("素人自拍", ((0, 39),)),
    ("台湾辣妹", ((0, 40),)),
    ("韩国御姐", ((0, 41),)),
    ("唯美港姐", ((0, 42),)),
    ("东南亚AV", ((0, 43),)),
    ("欺辱凌辱", ((0, 44),)),
    ("剧情介绍", ((0, 45),)),
    ("多人多P", ((0, 46),)),
    ("91探花", ((0, 47),)),
    ("网红流出", ((0, 48),)),
    ("野外露出", ((0, 49),)),
    ("古装扮演", ((0, 50),)),
    ("女优系列", ((0, 51),)),
    ("可爱学生", ((0, 52),)),
    ("风情旗袍", ((0, 53),)),
    ("兽耳系列", ((0, 54),)),
    ("瑜伽裤", ((0, 55),)),
    ("闷骚护士", ((0, 56),)),
    ("过膝袜", ((0, 57),)),
    ("网曝门", ((0, 58),)),
    ("传媒出品", ((0, 59),)),
    ("女同性恋", ((0, 60), (1, 11))),
    ("男同性恋", ((0, 61),)),
    ("恋腿狂魔", ((0, 63),)),
    ("亚洲情色", ((1, 1),)),
    ("国产主播", ((1, 2),)),
    ("国产自拍", ((1, 3),)),
    ("无码专区", ((1, 4),)),
    ("欧美性爱", ((1, 5),)),
    ("熟女人妻", ((1, 6),)),
    ("制服诱惑", ((1, 10),)),
    ("卡通动画", ((1, 12),)),
    ("视频伦理", ((1, 13),)),
    ("重口色情", ((1, 15),)),
    ("人兽性交", ((1, 16),)),
    ("福利姬", ((1, 33),)),
    ("中文传媒", ((2, 20),)),
    ("国产", ((2, 21),)),
    ("欧美AV", ((2, 22),)),
    ("日本AV", ((2, 23),)),
    ("传媒-麻豆传媒", ((2, 24),)),
    ("传媒-精东影业", ((2, 25),)),
    ("传媒-蜜桃传媒", ((2, 26),)),
    ("传媒-果冻传媒", ((2, 27),)),
    ("传媒-星空无限传媒", ((2, 28),)),
    ("传媒-SA国际传媒", ((2, 29),)),
    ("传媒-性视界传媒", ((2, 30),)),
    ("国产-自拍", ((2, 31),)),
    ("国产-偷拍", ((2, 32),)),
    ("国产-探花", ((2, 33),)),
    ("国产-主播", ((2, 34),)),
    ("传媒-天美传媒", ((2, 35),)),
    ("欧美-高清无码", ((2, 36),)),
    ("欧美-高清有码", ((2, 37),)),
    ("日本-中文字幕", ((2, 38),)),
    ("日本-无码流出", ((2, 39),)),
    ("日本-高清有码", ((2, 40),)),
    ("传媒-皇家华人", ((2, 41),)),
    ("欧美-中文字幕", ((2, 42),)),
    ("明星网黄", ((2, 43),)),
    ("刘玥", ((2, 44),)),
    ("玩偶姐姐", ((2, 45),)),
    ("动漫", ((2, 46),)),
    ("台湾粉红兔", ((2, 47),)),
    ("吃瓜黑料", ((2, 48),)),
    ("变态暗网", ((2, 49),)),
    ("小众口味", ((2, 50),)),
    ("男同", ((2, 51),)),
    ("小众女同", ((2, 52),)),
    ("TS人妖", ((2, 53),)),
    ("传媒-扣扣传媒", ((2, 54),)),
    ("恐怖色情", ((2, 55),)),
    ("人兽杂交", ((2, 56),)),
    ("迷奸强奸", ((2, 57),)),
    ("重口味", ((2, 58),)),
    ("传媒-91传媒", ((2, 59),)),
    ("传媒-杏吧传媒", ((2, 60),)),
    ("传媒-起点传媒", ((2, 61),)),
    ("传媒-CCAV成人头条", ((2, 62),)),
    ("传媒-渡边传媒", ((2, 63),)),
    ("传媒-辣椒原创", ((2, 64),)),
    ("传媒-红斯灯影像", ((2, 65),)),
    ("传媒-情欲国潮", ((2, 66),)),
    ("传媒-糖心传媒", ((2, 67),)),
    ("传媒-乐播传媒", ((2, 68),)),
    ("传媒-葫芦影业", ((2, 69),)),
    ("传媒-其他传媒", ((2, 70),)),
    ("伦理道德", ((2, 71),)),
    ("热门大瓜", ((2, 72),)),
    ("学生校园", ((2, 73),)),
    ("领导官员", ((2, 74),)),
    ("裸贷黑料", ((2, 75),)),
    ("白虎萌妹", ((2, 76),)),
    ("国产-节目企划", ((2, 77),)),
    ("动漫-黄漫", ((2, 78),)),
    ("动漫-里番中字", ((2, 79),)),
    ("AV解说", ((2, 80),)),
    ("水果派", ((2, 81),)),
    ("短视频", ((2, 82),)),
    ("SM虐待", ((2, 83),)),
    ("NTR 绿帽", ((2, 84),)),
    ("国产-网红", ((2, 85),)),
    ("国产-户外", ((2, 86),)),
    ("国产-吃瓜", ((2, 87),)),
    ("AI换脸", ((2, 88),)),
    ("日本-东京热", ((2, 89),)),
    ("日本-一本道", ((2, 90),)),
    ("国产-台湾JVID", ((2, 91),)),
    ("韩国AV", ((2, 92),)),
    ("韩国-主播", ((2, 93),)),
    ("吃瓜资讯", ((2, 94),)),
    ("必看大瓜", ((2, 95),)),
    ("网红黑料", ((2, 96),)),
    ("海外吃瓜", ((2, 97),)),
    ("偷拍自拍", ((2, 98),)),
    ("道德伦理", ((2, 99),)),
    ("吃瓜新闻", ((2, 100),)),
    ("直播大秀", ((2, 101),)),
    ("日本-素人", ((2, 102),)),
    ("饼干姐姐", ((2, 103),)),
    ("台北娜娜", ((2, 104),)),
    ("柚子猫", ((2, 105),)),
    ("桥本香菜", ((2, 106),)),
    ("小欣奈", ((2, 107),)),
    ("御梦子", ((2, 108),)),
    ("捅主任", ((2, 109),)),
    ("水冰月", ((2, 110),)),
    ("黑椒盖饭", ((2, 111),)),
    ("冉冉学姐", ((2, 112),)),
    ("粉色情人", ((2, 113),)),
    ("鸡教练", ((2, 114),)),
    ("唐伯虎", ((2, 115),)),
    ("地雷系", ((2, 116),)),
    ("白菜妹妹", ((2, 117),)),
    ("小二先生", ((2, 118),)),
    ("AI制作", ((2, 119),)),
    ("AI漫剧", ((2, 120),)),
    ("AI短剧", ((2, 122),)),
    ("AI魔改", ((2, 123),)),
]

MJV = [
    ("new", "每日更新"),
    ("chinese", "中文字幕AV"),
    ("censored", "有碼AV"),
    ("uncensored", "無碼AV"),
    ("amateurjav", "素人AV"),
    ("reducing-mosaic", "無碼破解"),
    ("dt", "國產自拍"),
]

TUKU = [
    ("pondo", "一本道 · 最新", 5),
    ("phot", "一本道 · 热门", 5),
    ("musume", "素人自拍 · 最新", 5),
    ("mhot", "素人自拍 · 热门", 5),
    ("paco", "人妻偷拍 · 最新", 5),
    ("phot2", "人妻偷拍 · 热门", 5),
    ("aidol", "女优", 4),
]

PH = [
    ("cg", "寫真圖片"),
    ("cwp", "國產寫真"),
]

_CACHE = {}
_CODE_RE = re.compile(r"[A-Z]{2,6}[-_ ]?\d{2,5}")


_SSL_CTX = None


def _ssl_ctx():
    global _SSL_CTX
    if _SSL_CTX is None:
        _SSL_CTX = ssl.create_default_context()
    return _SSL_CTX


def _proxy_for(parsed):
    host = (parsed.hostname or "").lower()
    no_proxy = os.environ.get("no_proxy") or os.environ.get("NO_PROXY") or ""
    for item in no_proxy.replace(",", " ").split():
        item = item.strip().lower()
        if item and (host == item or host.endswith("." + item) or item == "*"):
            return None
    if parsed.scheme == "https":
        raw = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY") or ""
    else:
        raw = os.environ.get("http_proxy") or os.environ.get("HTTP_PROXY") or ""
    if not raw:
        return None
    p = urllib.parse.urlparse(raw if "://" in raw else "http://" + raw)
    if not p.hostname:
        return None
    return (p.hostname, p.port or 80)


def _http_get_once(url, timeout, depth=0):
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    headers = {"User-Agent": UA, "Accept": "application/json", "Host": parsed.netloc}
    proxy = _proxy_for(parsed)
    if proxy:
        if parsed.scheme == "https":
            conn = http.client.HTTPSConnection(proxy[0], proxy[1], timeout=timeout, context=_ssl_ctx())
            conn.set_tunnel(host, port)
        else:
            conn = http.client.HTTPConnection(proxy[0], proxy[1], timeout=timeout)
            path = url
    elif parsed.scheme == "https":
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=_ssl_ctx())
    else:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        status = resp.status
        data = resp.read()
        headers_out = dict((k.lower(), v) for k, v in resp.getheaders())
        if status in (301, 302, 303, 307, 308) and depth < 2:
            loc = headers_out.get("location") or ""
            if loc:
                return _http_get_once(urllib.parse.urljoin(url, loc), timeout, depth + 1)
        if status != 200:
            raise ValueError("http %d" % status)
        if "gzip" in (headers_out.get("content-encoding") or "").lower():
            data = gzip.decompress(data)
        return data
    finally:
        try:
            conn.close()
        except Exception:
            pass


def _http_json(url, timeout=35):
    for attempt in range(4):
        try:
            raw = _http_get_once(url, timeout)
            text = raw.decode("utf-8", "ignore")
            if text.lstrip().startswith("<"):
                return None
            return json.loads(text)
        except Exception:
            time.sleep(0.6 * (attempt + 1))
    return None


def _api(line, params):
    qs = urllib.parse.urlencode(params)
    return _http_json(FEED + LINES[line] + "?" + qs)


def _cached(key, loader):
    if key not in _CACHE:
        try:
            _CACHE[key] = loader()
        except Exception:
            _CACHE[key] = None
    return _CACHE[key]


def _roster():
    def load():
        d = _http_json(WEB + "/jp220/actors.json?v=" + JP_V, timeout=45)
        if isinstance(d, dict):
            return d.get("actors") or []
        return d or []
    return _cached("roster", load) or []


def _mjv_file(key):
    def load():
        d = _http_json(WEB + "/mjv220/" + key + ".json", timeout=45)
        if isinstance(d, dict):
            return d.get("items") or []
        return []
    return _cached("mjv:" + key, load) or []


def _pg_index():
    def load():
        d = _http_json(WEB + "/mjv220/pg_index.json", timeout=20)
        return d if isinstance(d, dict) else {}
    return _cached("pg_index", load) or {}


def _pg_chunk(key, chunk):
    def load():
        d = _http_json(WEB + "/mjv220/pg_" + key + "_" + str(chunk) + ".json", timeout=45)
        return d if isinstance(d, list) else []
    return _cached("pg:%s:%d" % (key, chunk), load) or []


def _src_bucket(bucket):
    def load():
        d = _http_json(WEB + "/jp220/src/" + str(bucket) + ".json?v=" + JP_V, timeout=20)
        return d if isinstance(d, dict) else {}
    return _cached("src:%d" % bucket, load) or {}


def _code_bucket(bucket):
    def load():
        d = _http_json(WEB + "/jp220/c/" + str(bucket) + ".json?v=" + JP_V, timeout=20)
        return d if isinstance(d, dict) else {}
    return _cached("code:%d" % bucket, load) or {}


def _norm_text(s):
    return re.sub(r"[^A-Z0-9]", "", (s or "").upper())


def _code_key(s):
    n = _norm_text(s)
    m = re.match(r"^([A-Z]+)0*(\d+)$", n)
    return (m.group(1) + m.group(2)) if m else n


def _code_of(name):
    m = _CODE_RE.search((name or "").upper())
    if not m:
        return ""
    return re.sub(r"[\s_]+", "-", m.group(0))


def _bucket(key):
    h = 0x811C9DC5
    for ch in key:
        h ^= ord(ch)
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h % 256


def _first_play_url(play_url):
    for part in (play_url or "").split("#"):
        j = part.rfind("$")
        u = (part[j + 1:] if j >= 0 else part).strip()
        if u.startswith("http"):
            return u
    return ""


def _src_lookup(code):
    k = _code_key(code)
    if not k:
        return ""
    v = _src_bucket(_bucket(k)).get(k)
    if isinstance(v, list) and len(v) > 1 and isinstance(v[1], list):
        for row in v[1]:
            if isinstance(row, list) and len(row) > 2 and str(row[2]).startswith("http"):
                return str(row[2])
    return ""


def _line_search_code(code):
    kn = _code_key(code)
    for line in range(3):
        d = _api(line, {"ac": "videolist", "pg": 1, "pagesize": 20, "wd": code})
        for v in ((d or {}).get("list") or []):
            if kn and kn not in _norm_text(v.get("vod_name") or ""):
                continue
            url = _first_play_url(v.get("vod_play_url") or "")
            if url:
                return url
    return ""


def _resolve_code(code):
    url = _src_lookup(code)
    if url:
        return url
    return _line_search_code(code)


def _photos(first, n):
    if not first:
        return []
    m = re.search(r"(\d+)(\.[A-Za-z]+)$", str(first))
    if not m or not n:
        return [first]
    pad = len(m.group(1))
    start = int(m.group(1))
    head = str(first)[:m.start()]
    ext = m.group(2)
    return [head + str(start + i).zfill(pad) + ext for i in range(int(n))]


def _vod_item(line, v):
    return {
        "vod_id": "v%d_%s" % (line, v.get("vod_id")),
        "vod_name": v.get("vod_name") or "",
        "vod_pic": v.get("vod_pic") or "",
        "vod_remarks": v.get("vod_remarks") or v.get("type_name") or "",
    }


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg > 0 else 1


def _norm_ids(ids):
    if isinstance(ids, str):
        return [ids]
    if isinstance(ids, (list, tuple)):
        return [str(x) for x in ids]
    return [str(ids)]


def _play_header():
    return {"User-Agent": UA, "Referer": WEB + "/"}


class Spider(BaseSpider):
    def getName(self):
        return "潮流AV"

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=""):
        classes = [{"type_id": "c%d" % i, "type_name": name} for i, (name, _) in enumerate(CATS)]
        for key, name in MJV:
            classes.append({"type_id": "mjv_" + key, "type_name": name})
        classes.append({"type_id": "jp", "type_name": "女优库"})
        for key, name, _mp in TUKU:
            classes.append({"type_id": "tk_" + key, "type_name": name})
        for key, name in PH:
            classes.append({"type_id": "ph_" + key, "type_name": name})
        return {"class": classes, "list": [], "filters": {}}

    def homeVideoContent(self):
        d = _api(0, {"ac": "videolist", "pg": 1, "pagesize": PAGE})
        items = [_vod_item(0, v) for v in ((d or {}).get("list") or [])]
        return {"list": items}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = str(tid or "")
        if tid.startswith("mjv_"):
            return self._cat_mjv(tid[4:], pg)
        if tid == "jp":
            return self._cat_jp(pg)
        if tid.startswith("tk_"):
            return self._cat_tuku(tid[3:], pg)
        if tid.startswith("ph_"):
            return self._cat_ph(tid[3:], pg)
        if tid.startswith("c"):
            try:
                idx = int(tid[1:])
            except Exception:
                return {"list": [], "page": pg, "pagecount": 1, "limit": PAGE, "total": 0}
            if 0 <= idx < len(CATS):
                _name, targets = CATS[idx]
                items = []
                seen = set()
                pagecount = 1
                total = 0
                for line, type_id in targets:
                    d = _api(line, {"ac": "videolist", "t": type_id, "pg": pg, "pagesize": PAGE})
                    if not d:
                        continue
                    try:
                        pagecount = max(pagecount, int(d.get("pagecount") or 1))
                    except Exception:
                        pass
                    try:
                        total = max(total, int(d.get("total") or 0))
                    except Exception:
                        pass
                    for v in d.get("list") or []:
                        vid = "v%d_%s" % (line, v.get("vod_id"))
                        if vid in seen:
                            continue
                        seen.add(vid)
                        items.append(_vod_item(line, v))
                return {"list": items, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}
        return {"list": [], "page": pg, "pagecount": 1, "limit": PAGE, "total": 0}

    def _cat_mjv(self, key, pg):
        items_all = _mjv_file(key)
        total = len(items_all)
        start = (pg - 1) * PAGE
        out = []
        for it in items_all[start:start + PAGE]:
            out.append({
                "vod_id": "mjv_%s_%s" % (key, it.get("n")),
                "vod_name": it.get("t") or "",
                "vod_pic": it.get("p") or "",
                "vod_remarks": it.get("s") or "",
            })
        pagecount = (total + PAGE - 1) // PAGE if total else 1
        return {"list": out, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}

    def _cat_jp(self, pg):
        roster = _roster()
        total = len(roster)
        out = []
        for a in roster[(pg - 1) * PAGE:pg * PAGE]:
            aid = str(a.get("id") or "")
            pic = a.get("a") or (WEB + "/jp/av/" + aid + ".jpg")
            out.append({
                "vod_id": "jp_" + aid,
                "vod_name": a.get("n") or "",
                "vod_pic": pic,
                "vod_remarks": "作品 %s 部" % (a.get("t") or 0),
            })
        pagecount = (total + PAGE - 1) // PAGE if total else 1
        return {"list": out, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}

    def _cat_tuku(self, key, pg):
        max_page = 5
        for k, _n, mp in TUKU:
            if k == key:
                max_page = mp
                break
        d = _http_json(WEB + "/data220/%s_%d.json?v=4" % (key, pg), timeout=35)
        items = (d or {}).get("items") or []
        out = []
        for v in items:
            imgs = v.get("imgs") or []
            out.append({
                "vod_id": "tk_%s_%d_%s" % (key, pg, v.get("id")),
                "vod_name": (v.get("title") or "").strip(),
                "vod_pic": WEB + "/" + str(v.get("thumb") or "").lstrip("/"),
                "vod_remarks": "%s %s 共 %d 张" % ((v.get("actress") or "").strip(), (v.get("date") or "").strip(), len(imgs)),
            })
        total = 0
        try:
            total = int((d or {}).get("total") or 0)
        except Exception:
            pass
        return {"list": out, "page": pg, "pagecount": max_page, "limit": len(out), "total": total}

    def _cat_ph(self, key, pg):
        info = _pg_index().get(key) or {}
        total = int(info.get("n") or 0)
        chunk_size = 500
        start = (pg - 1) * PAGE
        end = min(start + PAGE, total)
        out = []
        if total and start < total:
            c1 = start // chunk_size + 1
            c2 = (end - 1) // chunk_size + 1
            for c in range(c1, c2 + 1):
                arr = _pg_chunk(key, c)
                base = (c - 1) * chunk_size
                for i in range(max(start, base), min(end, base + len(arr))):
                    v = arr[i - base]
                    out.append({
                        "vod_id": "ph_%s_%d_%s" % (key, c, v[0]),
                        "vod_name": v[1] or "",
                        "vod_pic": v[2] or "",
                        "vod_remarks": "%s 图" % (v[4] or 0),
                    })
        pagecount = (total + PAGE - 1) // PAGE if total else 1
        return {"list": out, "page": pg, "pagecount": pagecount, "limit": PAGE, "total": total}

    def detailContent(self, ids):
        ids = _norm_ids(ids)
        vid = (ids[0] if ids else "").strip()
        if vid.startswith("mjv_"):
            return self._detail_mjv(vid)
        if vid.startswith("jp_"):
            return self._detail_jp(vid[3:])
        if vid.startswith("tk_"):
            return self._detail_tuku(vid)
        if vid.startswith("ph_"):
            return self._detail_ph(vid)
        if vid.startswith("code_"):
            code = vid[5:]
            return {"list": [{
                "vod_id": vid,
                "vod_name": code,
                "vod_pic": "",
                "vod_content": code,
                "vod_play_from": "番号解析",
                "vod_play_url": "正片$jpcode:" + code,
            }]}
        m = re.match(r"^v(\d)_(\d+)$", vid)
        if m:
            return self._detail_line(int(m.group(1)), m.group(2), vid)
        return {"list": []}

    def _detail_line(self, line, oid, vid):
        d = _api(line, {"ac": "detail", "ids": oid})
        items = (d or {}).get("list") or []
        if not items:
            return {"list": []}
        v = items[0]
        play_from = []
        play_urls = []
        main = v.get("vod_play_url") or ""
        if main:
            play_from.append("线路%d" % (line + 1))
            play_urls.append(main)
        code = _code_of(v.get("vod_name") or "")
        if code:
            kn = _code_key(code)
            for other in range(3):
                if other == line:
                    continue
                d2 = _api(other, {"ac": "videolist", "pg": 1, "pagesize": 20, "wd": code})
                for v2 in ((d2 or {}).get("list") or []):
                    if kn and kn not in _norm_text(v2.get("vod_name") or ""):
                        continue
                    u = _first_play_url(v2.get("vod_play_url") or "")
                    if u and u not in main:
                        play_from.append("线路%d" % (other + 1))
                        play_urls.append("正片$" + u)
                        break
        vod = {
            "vod_id": vid,
            "vod_name": v.get("vod_name") or "",
            "vod_pic": v.get("vod_pic") or "",
            "vod_actor": v.get("vod_actor") or "",
            "vod_director": v.get("vod_director") or "",
            "vod_area": v.get("vod_area") or "",
            "vod_year": v.get("vod_year") or "",
            "vod_remarks": v.get("vod_remarks") or "",
            "vod_content": (v.get("vod_content") or v.get("vod_name") or "").strip(),
            "vod_play_from": "$$$".join(play_from),
            "vod_play_url": "$$$".join(play_urls),
        }
        return {"list": [vod]}

    def _detail_mjv(self, vid):
        m = re.match(r"^mjv_([A-Za-z\-]+)_(\d+)$", vid)
        if not m:
            return {"list": []}
        key = m.group(1)
        num = m.group(2)
        for it in _mjv_file(key):
            if str(it.get("n")) == num:
                code = it.get("s") or ""
                return {"list": [{
                    "vod_id": vid,
                    "vod_name": it.get("t") or "",
                    "vod_pic": it.get("p") or "",
                    "vod_remarks": code,
                    "vod_content": it.get("t") or "",
                    "vod_play_from": "番号解析",
                    "vod_play_url": "正片$jpcode:" + code,
                }]}
        return {"list": []}

    def _detail_jp(self, aid):
        roster = _roster()
        actor = None
        for a in roster:
            if str(a.get("id")) == aid:
                actor = a
                break
        name = (actor or {}).get("n") or aid
        pic = (actor or {}).get("a") or (WEB + "/jp/av/" + aid + ".jpg")
        films = _http_json(WEB + "/jp220/f/" + urllib.parse.quote(aid) + ".json?v=" + JP_V, timeout=45)
        eps = []
        if isinstance(films, list):
            for f in films[:200]:
                if not isinstance(f, list) or len(f) < 2:
                    continue
                code = str(f[1] or "")
                date = str(f[2] or "") if len(f) > 2 else ""
                if code:
                    eps.append("%s %s$jpcode:%s" % (code, date, code))
        total = (actor or {}).get("t") or len(eps)
        return {"list": [{
            "vod_id": "jp_" + aid,
            "vod_name": name,
            "vod_pic": pic,
            "vod_actor": name,
            "vod_remarks": "作品 %s 部" % total,
            "vod_content": "%s，作品 %s 部" % (name, total),
            "vod_play_from": "女优作品",
            "vod_play_url": "#".join(eps),
        }]}

    def _detail_tuku(self, vid):
        m = re.match(r"^tk_([A-Za-z0-9]+)_(\d+)_(.+)$", vid)
        if not m:
            return {"list": []}
        key = m.group(1)
        pg = m.group(2)
        art_id = m.group(3)
        d = _http_json(WEB + "/data220/%s_%s.json?v=4" % (key, pg), timeout=35)
        for v in ((d or {}).get("items") or []):
            if str(v.get("id")) == art_id:
                imgs = [WEB + "/" + str(x).lstrip("/") for x in (v.get("imgs") or [])]
                return {"list": [{
                    "vod_id": vid,
                    "vod_name": (v.get("title") or "").strip(),
                    "vod_pic": WEB + "/" + str(v.get("thumb") or "").lstrip("/"),
                    "vod_actor": (v.get("actress") or "").strip(),
                    "vod_remarks": (v.get("date") or "").strip(),
                    "vod_content": (v.get("title") or "").strip(),
                    "vod_tag": "image",
                    "vod_play_from": "图片",
                    "vod_play_url": "查看$pics://" + "&&".join(imgs),
                }]}
        return {"list": []}

    def _detail_ph(self, vid):
        m = re.match(r"^ph_([A-Za-z]+)_(\d+)_(\d+)$", vid)
        if not m:
            return {"list": []}
        key = m.group(1)
        chunk = int(m.group(2))
        num = m.group(3)
        for v in _pg_chunk(key, chunk):
            if str(v[0]) == num:
                photos = _photos(v[3], v[4])
                return {"list": [{
                    "vod_id": vid,
                    "vod_name": v[1] or "",
                    "vod_pic": v[2] or "",
                    "vod_remarks": "%s 图" % (v[4] or 0),
                    "vod_content": v[1] or "",
                    "vod_tag": "image",
                    "vod_play_from": "图片",
                    "vod_play_url": "查看$pics://" + "&&".join(photos),
                }]}
        return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or "").strip()
        if not key:
            return {"list": []}
        items = []
        seen = set()
        for line in range(3):
            d = _api(line, {"ac": "videolist", "wd": key, "pg": pg, "pagesize": 20})
            for v in ((d or {}).get("list") or []):
                vid = "v%d_%s" % (line, v.get("vod_id"))
                if vid in seen:
                    continue
                seen.add(vid)
                items.append(_vod_item(line, v))
        if pg == 1:
            k = _code_key(key)
            if len(k) >= 3 and any(c.isdigit() for c in k):
                hits = self._code_hits(k)
                for code, mid, date in hits[:20]:
                    vid = "code_" + code
                    if vid in seen:
                        continue
                    seen.add(vid)
                    pic = ""
                    if mid:
                        pic = "https://c0.jdbstatic.com/covers/" + str(mid)[:2].lower() + "/" + str(mid) + ".jpg"
                    items.append({
                        "vod_id": vid,
                        "vod_name": code,
                        "vod_pic": pic,
                        "vod_remarks": "番号命中 %s" % date,
                    })
        return {"list": items}

    def _code_hits(self, k):
        out = []
        seen = set()
        exact = _code_bucket(_bucket(k)).get(k) or []
        for r in exact:
            if isinstance(r, list) and len(r) >= 4:
                code = str(r[3] or k)
                if code not in seen:
                    seen.add(code)
                    out.append((code, str(r[0] or ""), str(r[2] or "")))
        if not out:
            group = _code_bucket(_bucket(k + "~")).get(k + "~") or []
            for r in group:
                if isinstance(r, list) and len(r) >= 4:
                    code = str(r[0] or "")
                    if code and code not in seen:
                        seen.add(code)
                        out.append((code, str(r[1] or ""), str(r[3] or "")))
        return out

    def playerContent(self, flag, id, vipFlags=None):
        ids = _norm_ids(id)
        raw = (ids[0] if ids else "").strip()
        if raw.startswith("jpcode:"):
            url = _resolve_code(raw[len("jpcode:"):])
            return {"parse": 0, "playUrl": url, "url": url, "header": _play_header()}
        if raw.startswith("pics://") or raw.startswith("novel://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": {}}
        return {"parse": 0, "playUrl": raw, "url": raw, "header": _play_header()}

    def localProxy(self, param=None):
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get("url") or p.get("u") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = urllib.parse.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            parsed = urllib.parse.urlparse(target)
            headers = {"User-Agent": UA, "Referer": "%s://%s/" % (parsed.scheme, parsed.netloc)}
            req = urllib.request.Request(target, headers=headers)
            last_err = None
            for _ in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=20) as resp:
                        ctype = resp.headers.get("Content-Type") or "application/octet-stream"
                        return [resp.status, ctype, resp.read(), {}]
                except urllib.error.HTTPError as e:
                    try:
                        body = e.read()
                    except Exception:
                        body = b""
                    return [e.code, e.headers.get("Content-Type") or "text/plain", body, {}]
                except Exception as e:
                    last_err = e
                    time.sleep(0.5)
            raise last_err
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def isVideoFormat(self, url):
        url = (url or "").lower()
        return any(k in url for k in (".m3u8", ".mp4", ".m4s", ".ts"))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
