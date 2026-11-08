import json
import re
import time
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

BASE = "https://e5f6g7h8.cjg225.cc"

CATEGORIES = [
    ("30", "人妻"),
    ("20", "都市"),
    ("21", "校园"),
    ("22", "真实"),
    ("23", "武侠"),
    ("24", "乱伦"),
    ("25", "职场"),
    ("26", "经验"),
    ("27", "暴力"),
    ("28", "幻想"),
    ("29", "明星"),
]

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"


def _fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": BASE + "/"})
    start = time.monotonic()
    for _ in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                text = resp.read().decode("utf-8", "ignore")
            if text:
                return text
        except Exception:
            pass
        if time.monotonic() - start > 45:
            break
    return ""


def _clean(raw):
    text = re.sub(r"<[^>]+>", "", raw)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
    return re.sub(r"\s+", " ", text).strip()


def _clean_text(raw):
    text = re.sub(r"<script[^>]*>.*?</script>", "", raw, flags=re.S)
    text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.S)
    text = re.sub(r"</p\s*>", "\n", text, flags=re.I)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.split("\n")]
    lines = [ln for ln in lines if ln]
    return "\n".join(lines)


def _parse_list(page):
    items = []
    seen = set()
    for vid, title, date in re.findall(r'<a href="/artdetail-(\d+)\.html" class="list-group-item">([^<]+)<span class="article-date"[^>]*>([^<]+)</span>', page):
        if vid in seen:
            continue
        seen.add(vid)
        items.append({"vod_id": vid, "vod_name": _clean(title), "vod_pic": "", "vod_remarks": _clean(date)})
    return items


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
        return "🔞Cjg"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _list_url(self, tid, pg):
        if pg <= 1:
            return BASE + "/arttype/" + tid + ".html"
        return BASE + "/arttype/" + tid + "-" + str(pg) + ".html"

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        return {"class": classes, "list": _parse_list(_fetch(BASE + "/arttype/30.html")), "filters": {}}

    def homeVideoContent(self):
        return self.homeContent(None)

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _to_int(pg, 1)
        return {"page": pg, "pagecount": 9999, "limit": 30, "total": 999999, "list": _parse_list(_fetch(self._list_url(str(tid), pg)))}

    def _detail(self, vid):
        page = _fetch(BASE + "/artdetail-" + vid + ".html")
        title = ""
        m = re.search(r'<title>(.*?)</title>', page, flags=re.S)
        if m:
            title = _clean(m.group(1)).split(" - ")[0].strip()
        text = ""
        m = re.search(r'<div class="art-content"[^>]*>(.*?)</div>', page, flags=re.S)
        if m:
            text = _clean_text(m.group(1))
        return title, text

    def detailContent(self, ids):
        vid = _norm_id(ids)
        title, text = self._detail(vid)
        if not title:
            title = vid
        play = ""
        if text:
            payload = json.dumps({"title": title, "content": text}, ensure_ascii=False)
            play = "阅读$novel://" + payload
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": "", "vod_play_from": "小说", "vod_play_url": play, "vod_content": text[:200]}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _to_int(pg, 1)
        q = urllib.parse.quote(str(key))
        if pg <= 1:
            page = _fetch(BASE + "/artsearch/-------.html?wd=" + q)
        else:
            page = _fetch(BASE + "/artsearch/" + q + "------" + str(pg) + "-.html")
        return {"list": _parse_list(page)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id)
        if raw.startswith("novel://"):
            return {"parse": 0, "url": raw, "header": {}}
        vid = raw
        if vid.startswith("cjg:"):
            vid = vid.split(":", 1)[1]
        title, text = self._detail(vid)
        if not text:
            return {"parse": 0, "url": "", "header": {}}
        payload = json.dumps({"title": title, "content": text}, ensure_ascii=False)
        return {"parse": 0, "url": "novel://" + payload, "header": {}}

    def localProxy(self, param):
        return [200, "video/mp2t", None, ""]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self, *args, **kwargs):
        return False

    def action(self, *args, **kwargs):
        return None
