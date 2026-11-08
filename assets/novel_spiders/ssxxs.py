import html as _html
import json
import re
import time

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

try:
    import requests
except Exception:
    requests = None

try:
    from urllib import request as _urlreq
    from urllib import parse as _urlparse
except Exception:
    _urlreq = None
    _urlparse = None

BASE = "https://e5f6g7h8.ssxxs014.cc"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
REFERER = "https://e5f6g7h8.ssxxs014.cc/"
CATEGORIES = [
    ("20", "都市激情"),
    ("21", "校园之恋"),
    ("22", "真实体验"),
    ("23", "武侠虚幻"),
    ("24", "家庭乱伦"),
    ("25", "职场丽人"),
    ("26", "经验故事"),
    ("27", "暴力虐待"),
    ("28", "科学幻想"),
    ("29", "明星偶像"),
    ("30", "人妻熟女"),
]
CAT_IDS = {tid for tid, _name in CATEGORIES}


def _fetch(url):
    headers = {"User-Agent": UA, "Referer": REFERER}
    start = time.monotonic()
    if requests is not None:
        try:
            r = requests.get(url, headers=headers, timeout=60)
            if r.status_code == 200:
                return r.text
        except Exception:
            pass
    if _urlreq is not None:
        try:
            left = 65 - (time.monotonic() - start)
            if left < 5:
                return None
            req = _urlreq.Request(url, headers=headers, method="GET")
            with _urlreq.urlopen(req, timeout=left) as resp:
                return resp.read().decode("utf-8", "ignore")
        except Exception:
            return None
    return None


def _clean(text):
    if not text:
        return ""
    text = re.sub(r"<[^>]+>", "", text)
    return _html.unescape(text).strip()


def _clean_text(raw):
    if not raw:
        return ""
    text = re.sub(r"<br[^>]*>", "\n", raw, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = _html.unescape(text)
    text = text.replace("\xa0", " ")
    lines = [ln.strip() for ln in text.splitlines()]
    lines = [ln for ln in lines if ln]
    return "\n".join(lines)


def _parse_list(page):
    out = []
    seen = set()
    for m in re.finditer(r'/artdetail-(\d+)\.html" title="([^"]+)"', page):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        tail = page[m.end():m.end() + 200]
        m_date = re.search(r'<span class="r">([^<]+)</span>', tail)
        out.append({
            "vod_id": vid,
            "vod_name": _clean(m.group(2)),
            "vod_pic": "",
            "vod_remarks": m_date.group(1).strip() if m_date else "",
        })
    return out


def _to_int(value, default=1):
    try:
        return int(value)
    except Exception:
        try:
            return int(float(value))
        except Exception:
            return default


def _norm_id(value):
    s = str(value)
    if "$" in s:
        tail = s.split("$", 1)[1]
        if tail:
            s = tail
    if "," in s:
        s = s.split(",")[0]
    return s.strip()


class Spider(BaseSpider):
    def getName(self):
        return "🔞Ssxxs"

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
        page = _fetch(self._list_url("20", 1))
        items = _parse_list(page) if page else []
        return {"class": classes, "list": items}

    def homeVideoContent(self):
        page = _fetch(self._list_url("20", 1))
        items = _parse_list(page) if page else []
        return {"list": items}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _to_int(pg, 1)
        if pg < 1:
            pg = 1
        tid = str(tid or "20")
        if tid not in CAT_IDS:
            tid = "20"
        page = _fetch(self._list_url(tid, pg))
        items = _parse_list(page) if page else []
        return {"list": items, "page": pg, "pagecount": pg + 1 if len(items) >= 30 else pg, "limit": 30, "total": 0}

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            raw = ids[0] if ids else ""
        else:
            raw = ids
        vid = _norm_id(raw)
        m = re.search(r"(\d+)", vid)
        if m:
            vid = m.group(1)
        page = _fetch(BASE + "/artdetail-" + vid + ".html")
        if not page:
            return {"list": []}
        m_title = re.search(r'<div class="article-title">\s*『(.*?)』\s*</div>', page, re.S)
        m_text = re.search(r'<div class="artcontent">(.*?)</div>', page, re.S)
        name = _clean(m_title.group(1)) if m_title else vid
        text = _clean_text(m_text.group(1)) if m_text else ""
        payload = json.dumps({"title": name, "content": text}, ensure_ascii=False)
        vod = {
            "vod_id": vid,
            "vod_name": name,
            "vod_pic": "",
            "vod_actor": "",
            "vod_remarks": "",
            "vod_content": text[:300],
            "vod_tag": "text",
            "vod_player": "书",
            "vod_play_from": "小说",
            "vod_play_url": "阅读$novel://" + payload,
        }
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _to_int(pg, 1)
        if pg < 1:
            pg = 1
        q = ""
        if _urlparse is not None:
            q = _urlparse.quote(str(key or ""))
        else:
            q = str(key or "")
        if pg > 1:
            page = _fetch(BASE + "/artsearch/" + q + "------" + str(pg) + "-.html")
        else:
            page = _fetch(BASE + "/artsearch/-------.html?wd=" + q)
        items = _parse_list(page) if page else []
        return {"list": items, "page": pg, "pagecount": pg + 1 if len(items) >= 30 else pg, "limit": 30, "total": 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "")
        url = raw
        if "$" in raw:
            url = raw.split("$", 1)[1]
        if url.startswith("novel://"):
            return {"parse": 0, "playUrl": url, "url": url, "header": {}, "vod_player": "书"}
        return {"parse": 0, "playUrl": url, "url": url, "header": {}}

    def localProxy(self, param):
        return [404, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        u = str(url or "").lower()
        return u.endswith(".m3u8") or u.endswith(".mp4") or ".m3u8?" in u or ".mp4?" in u

    def manualVideoCheck(self, *args, **kwargs):
        url = ""
        if args:
            url = str(args[0] or "")
        return self.isVideoFormat(url)

    def action(self, *args, **kwargs):
        return {}
