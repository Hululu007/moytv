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

BASE = "https://bass-23023-bug.buliangxiaoshuowang2.cc"

CATEGORIES = [
    ("5036", "都市激情"),
    ("5037", "校园情事"),
    ("5038", "人妻縱情"),
    ("5039", "風俗倫理"),
    ("5040", "另类小说"),
    ("5041", "武侠古典"),
    ("5042", "长篇连载"),
    ("5043", "成人笑话"),
    ("1000", "小说"),
    ("5035", "短篇小说"),
    ("1005", "仙侠武侠"),
    ("1003", "淫乱乱伦"),
    ("1001", "人妻熟女"),
    ("1002", "故事"),
    ("1004", "学生"),
    ("5003", "其它"),
    ("5004", "暴力"),
    ("5005", "现代"),
    ("5033", "年度最佳"),
    ("5034", "世界着名"),
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
    for block in page.split('<div class="art-item">')[1:]:
        m = re.search(r'href="/article/(\d+)/"[^>]*>([^<]+)</a>', block)
        if not m:
            continue
        vid, title = m.group(1), _clean(m.group(2))
        if vid in seen:
            continue
        seen.add(vid)
        dm = re.search(r'<div class="art-item-foot">.*?<span>([^<]+)</span>', block, flags=re.S)
        items.append({"vod_id": vid, "vod_name": title, "vod_pic": "", "vod_remarks": _clean(dm.group(1)) if dm else ""})
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
        return "🔞Buliang"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _list_url(self, tid, pg):
        if pg <= 1:
            return BASE + "/arttype/" + tid + "/"
        return BASE + "/arttype/" + tid + "-" + str(pg) + "/"

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        return {"class": classes, "list": _parse_list(_fetch(BASE + "/artis")), "filters": {}}

    def homeVideoContent(self):
        return self.homeContent(None)

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _to_int(pg, 1)
        return {"page": pg, "pagecount": 9999, "limit": 30, "total": 999999, "list": _parse_list(_fetch(self._list_url(str(tid), pg)))}

    def _detail(self, vid):
        page = _fetch(BASE + "/article/" + vid + "/")
        title = ""
        m = re.search(r"<title>(.*?)</title>", page, flags=re.S)
        if m:
            title = _clean(m.group(1)).split(" | ")[0].strip()
        text = ""
        m = re.search(r'<article class="article">(.*?)</article>', page, flags=re.S)
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
            page = _fetch(BASE + "/artsearch/-------/?wd=" + q)
        else:
            page = _fetch(BASE + "/artsearch/" + q + "------" + str(pg) + "-/")
        return {"list": _parse_list(page)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id)
        if raw.startswith("novel://"):
            return {"parse": 0, "url": raw, "header": {}}
        vid = raw
        if vid.startswith("buliang:"):
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
