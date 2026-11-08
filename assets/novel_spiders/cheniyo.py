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

BASE = "https://cheniyo.cfd"

CATEGORIES = [
    ("1", "家庭乱伦"),
    ("2", "职场丽人"),
    ("3", "经验故事"),
    ("4", "都市激情"),
    ("5", "校园之恋"),
]

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"


def _fetch(url, data=None):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Referer": BASE + "/"})
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


def _clean_title(raw):
    text = re.sub(r"<img[^>]*>", "", raw)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&#155;", ">")
    return re.sub(r"\s+", " ", text).strip()


def _clean_text(raw):
    text = re.sub(r"<script[^>]*>.*?</script>", "", raw, flags=re.S)
    text = re.sub(r"</p\s*>", "\n", text, flags=re.I)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&#155;", ">")
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.split("\n")]
    lines = [ln for ln in lines if ln]
    return "\n".join(lines)


def _parse_list(page):
    items = []
    seen = set()
    for m in re.finditer(r'/artdetail-(\d+)\.html"\s+class="row">(.*?)</a>', page, flags=re.S):
        vid = m.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        block = m.group(2)
        parts = re.findall(r"<li[^>]*>(.*?)</li>", block, flags=re.S)
        title = _clean_title(parts[0]) if parts else ""
        remark = _clean_title(parts[-1]) if len(parts) >= 2 else ""
        if title:
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


class Spider(BaseSpider):
    def getName(self):
        return "🔞Cheniyo"

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
        page = _fetch(BASE + "/")
        return {"class": classes, "list": _parse_list(page), "filters": {}}

    def homeVideoContent(self):
        return self.homeContent(None)

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        tid = str(tid)
        pg = _to_int(pg, 1)
        page = _fetch(self._list_url(tid, pg))
        return {"page": pg, "pagecount": 9999, "limit": 40, "total": 999999, "list": _parse_list(page)}

    def _detail(self, vid):
        page = _fetch(BASE + "/artdetail-" + vid + ".html")
        title = ""
        m = re.search(r'<p class="other-title">(.*?)</p>', page, flags=re.S)
        if m:
            title = _clean_title(m.group(1)).rstrip(" -").strip()
        text = ""
        m = re.search(r'<div class="other-content introduction">(.*?)</div>\s*</div>', page, flags=re.S)
        if not m:
            m = re.search(r'<div class="other-content introduction">(.*)', page, flags=re.S)
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
        if vid.startswith("cheniyo:"):
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
