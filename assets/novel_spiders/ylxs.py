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

BASE = "https://ylxs.net"

CATEGORIES = [
    ("new", "最新作品"),
    ("ranking", "完整榜单"),
    ("series", "最新更新的系列"),
    ("discovery", "发现"),
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
    text = re.sub(r"</p\s*>", "\n", raw, flags=re.I)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.split("\n")]
    lines = [ln for ln in lines if ln]
    return "\n".join(lines)


def _parse_cards(page):
    items = []
    seen = set()
    for block in re.findall(r'<article class="novel-card[^"]*"[^>]*>(.*?)</article>', page, flags=re.S):
        m = re.search(r'novel-card-title">\s*<a href="/novel/(show|series)/(\d+)">\s*([^<]+)</a>', block)
        if not m:
            continue
        kind, nid, title = m.group(1), m.group(2), _clean(m.group(3))
        vid = kind + ":" + nid
        if vid in seen or not title:
            continue
        seen.add(vid)
        remark = ""
        bm = re.search(r'<span class="card-badge">([^<]+)</span>', block)
        if bm:
            remark = _clean(bm.group(1))
        else:
            sm = re.search(r'novel-card-stats">\s*<span>([^<]+)</span>', block)
            if sm:
                remark = _clean(sm.group(1))
        items.append({"vod_id": vid, "vod_name": title, "vod_pic": "", "vod_remarks": remark})
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


def _show_text(page):
    m = re.search(r'<div class="novel-body"[^>]*>(.*?)</div>\s*<div class="novel-action-panel"', page, flags=re.S)
    if not m:
        m = re.search(r'<div class="novel-body"[^>]*>(.*)', page, flags=re.S)
    if not m:
        return ""
    return _clean_text(m.group(1))


def _show_title(page):
    m = re.search(r'"@type":"Book","name":"([^"]+)"', page)
    if m:
        return m.group(1)
    m = re.search(r'<title>(.*?)</title>', page, flags=re.S)
    if m:
        return _clean(m.group(1)).split(" - ")[0]
    return ""


class Spider(BaseSpider):
    def getName(self):
        return "🔞Ylxs"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _list_url(self, tid, pg):
        if tid == "new":
            return BASE + "/novel/new?p=" + str(pg)
        if tid == "ranking":
            return BASE + "/novel/ranking?p=" + str(pg)
        if tid == "series":
            return BASE + "/novel/series?p=" + str(pg)
        if tid == "discovery":
            return BASE + "/discovery?p=" + str(pg)
        return BASE + "/novel/new?p=" + str(pg)

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        return {"class": classes, "list": _parse_cards(_fetch(BASE + "/novel/new?p=1")), "filters": {}}

    def homeVideoContent(self):
        return self.homeContent(None)

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _to_int(pg, 1)
        if str(tid) == "ranking" and pg > 1:
            return {"page": pg, "pagecount": 1, "limit": 50, "total": 50, "list": []}
        return {"page": pg, "pagecount": 9999, "limit": 30, "total": 999999, "list": _parse_cards(_fetch(self._list_url(str(tid), pg)))}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        kind, nid = ("", vid)
        if ":" in vid:
            kind, nid = vid.split(":", 1)
        if kind == "series":
            page = _fetch(BASE + "/novel/series/" + nid + "?p=1")
            title = ""
            m = re.search(r'<title>(.*?)</title>', page, flags=re.S)
            if m:
                title = _clean(m.group(1)).split(" - ")[0]
            shows = _parse_cards(page)
            eps = []
            for item in shows:
                if item["vod_id"].startswith("show:"):
                    eps.append(item["vod_name"] + "$" + item["vod_id"])
            return {"list": [{"vod_id": vid, "vod_name": title or vid, "vod_pic": "", "vod_play_from": "小说", "vod_play_url": "#".join(eps), "vod_content": ""}]}
        page = _fetch(BASE + "/novel/show/" + nid)
        title = _show_title(page) or vid
        text = _show_text(page)
        play = ""
        if text:
            payload = json.dumps({"title": title, "content": text}, ensure_ascii=False)
            play = "阅读$novel://" + payload
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": "", "vod_play_from": "小说", "vod_play_url": play, "vod_content": text[:200]}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _to_int(pg, 1)
        q = urllib.parse.quote(str(key))
        page = _fetch(BASE + "/search/novels?q=" + q + "&p=" + str(pg))
        return {"list": _parse_cards(page)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id)
        if raw.startswith("novel://"):
            return {"parse": 0, "url": raw, "header": {}}
        kind, nid = ("show", raw)
        if ":" in raw:
            kind, nid = raw.split(":", 1)
        if kind != "show":
            return {"parse": 0, "url": "", "header": {}}
        page = _fetch(BASE + "/novel/show/" + nid)
        title = _show_title(page) or nid
        text = _show_text(page)
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
