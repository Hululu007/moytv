import json
import re
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASE = "https://xn--uns.mhbl.buzz"
PREFIX = BASE + "/acg/index.php"

CATEGORIES = [
    ("50", "完本"),
    ("51", "同人志"),
    ("52", "韩漫"),
]

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"


def _fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": BASE + "/"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read().decode("utf-8", "ignore")
    except Exception:
        return ""


def _clean(raw):
    text = re.sub(r"<[^>]+>", "", raw)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
    return re.sub(r"\s+", " ", text).strip()


def _abs_pic(src):
    if src.startswith("//"):
        return "https:" + src
    if src.startswith("/"):
        return BASE + src
    return src


def _parse_list(page):
    items = []
    seen = set()
    for block in page.split('<div class="card h-100">')[1:]:
        m = re.search(r'href="/acg/index\.php/book/detail/id/(\d+)\.html"', block)
        if not m:
            continue
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        pm = re.search(r'data-bg="([^"]+)"', block)
        tm = re.search(r'<p class="card-text[^>]*>([^<]+)</p>', block)
        dm = re.search(r'<p class="card-subtitle[^>]*>([^<]+)</p>', block)
        items.append({"vod_id": vid, "vod_name": _clean(tm.group(1)) if tm else vid, "vod_pic": _abs_pic(pm.group(1)) if pm else "", "vod_remarks": _clean(dm.group(1)) if dm else ""})
    return items


def _parse_images(page):
    imgs = []
    seen = set()
    for src in re.findall(r'//img\.904174\.xyz/[^"\s<>]+', page):
        url = "https:" + src
        if "/t/" in url:
            continue
        if url not in seen:
            seen.add(url)
            imgs.append(url)
    return imgs


def _to_int(value, default=1):
    try:
        return int(value)
    except Exception:
        return default


def _norm_id(value):
    if isinstance(value, (list, tuple)):
        return str(value[0]) if value else ""
    return str(value).split(",")[0].strip()


class Spider(BaseSpider):
    def getName(self):
        return "🔞Mhbl"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _list_url(self, tid, pg):
        if pg <= 1:
            return PREFIX + "/book/type/id/" + tid + ".html"
        return PREFIX + "/book/type/id/" + tid + "/page/" + str(pg) + ".html"

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        return {"class": classes, "list": _parse_list(_fetch(PREFIX + "/book/home/page/1.html")), "filters": {}}

    def homeVideoContent(self):
        return self.homeContent(None)

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _to_int(pg, 1)
        return {"page": pg, "pagecount": 9999, "limit": 30, "total": 999999, "list": _parse_list(_fetch(self._list_url(str(tid), pg)))}

    def _detail(self, vid):
        page = _fetch(PREFIX + "/book/detail/id/" + vid + ".html")
        title = ""
        m = re.search(r'<div class="card-header[^>]*>([^<]+)</div>', page)
        if m:
            title = _clean(m.group(1))
        if not title:
            m = re.search(r"<title>(.*?)</title>", page, flags=re.S)
            if m:
                title = _clean(m.group(1)).split("-漫画部落")[0].strip()
        pic = ""
        m = re.search(r'data-bg="([^"]+)"', page)
        if m:
            pic = _abs_pic(m.group(1))
        parts = ["1"]
        for sid in re.findall(r"/book/detail/id/" + vid + r"/sid/(\d+)\.html", page):
            if sid not in parts:
                parts.append(sid)
        parts.sort(key=lambda x: int(x))
        return title, pic, parts

    def detailContent(self, ids):
        vid = _norm_id(ids)
        title, pic, parts = self._detail(vid)
        if not title:
            title = vid
        play = "#".join("第" + p + "部分$mhbl:" + vid + ":" + p for p in parts)
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": pic, "vod_play_from": "漫画", "vod_play_url": play, "vod_tag": "image", "vod_player": "画"}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _to_int(pg, 1)
        q = urllib.parse.quote(str(key))
        if pg <= 1:
            page = _fetch(PREFIX + "/book/search/wd/" + q + ".html")
        else:
            page = _fetch(PREFIX + "/book/search/wd/" + q + "/page/" + str(pg) + ".html")
        return {"list": _parse_list(page)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id)
        if raw.startswith("pics://"):
            return {"parse": 0, "url": raw, "header": {}}
        vid, part = raw, "1"
        if raw.startswith("mhbl:"):
            segs = raw.split(":")
            if len(segs) >= 3:
                vid, part = segs[1], segs[2]
        if part == "1":
            page = _fetch(PREFIX + "/book/detail/id/" + vid + ".html")
        else:
            page = _fetch(PREFIX + "/book/detail/id/" + vid + "/sid/" + part + ".html")
        imgs = _parse_images(page)
        if not imgs:
            return {"parse": 0, "url": "", "header": {}}
        return {"parse": 0, "url": "pics://" + "&&".join(imgs), "header": {}}

    def localProxy(self, param):
        return [200, "video/mp2t", None, ""]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self, *args, **kwargs):
        return False

    def action(self, *args, **kwargs):
        return None
