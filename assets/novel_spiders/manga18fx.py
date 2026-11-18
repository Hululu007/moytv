import base64
import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests as _requests
except Exception:
    _requests = None

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASE = "https://manga18fx.com"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

CATEGORIES = [
    ("action", "Action"),
    ("adventure", "Adventure"),
    ("comedy", "Comedy"),
    ("drama", "Drama"),
    ("ecchi", "Ecchi"),
    ("fantasy", "Fantasy"),
    ("harem", "Harem"),
    ("isekai", "Isekai"),
    ("manhua", "Manhua"),
    ("manhwa", "Manhwa"),
    ("mature", "Mature"),
    ("mystery", "Mystery"),
    ("psychological", "Psychological"),
    ("reincarnation", "Reincarnation"),
    ("romance", "Romance"),
    ("school-life", "School Life"),
    ("seinen", "Seinen"),
    ("shoujo", "Shoujo"),
    ("shounen", "Shounen"),
    ("supernatural", "Supernatural"),
    ("thriller", "Thriller"),
    ("tragedy", "Tragedy"),
    ("uncensored-manhwa", "Uncensored Manhwa"),
]

FLAG_WORDS = ["loli", "shota", "lolicon", "shotacon"]

_IMG_HOST_RE = re.compile(r"^https://img\d*\.manga18fx\.com/")


def _clean(raw):
    text = re.sub(r"<[^>]+>", "", raw or "")
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'").replace("&mdash;", "-")
    return re.sub(r"\s+", " ", text).strip()


def _flagged(text):
    low = (text or "").lower()
    for word in FLAG_WORDS:
        if word in low:
            return True
    return False


def _norm_pg(value, default=1):
    try:
        pg = int(str(value).strip())
        return pg if pg > 0 else default
    except Exception:
        return default


def _norm_id(value):
    if isinstance(value, (list, tuple)):
        return str(value[0]) if value else ""
    return str(value or "").split(",")[0].strip()


def _abs_url(src):
    src = _clean(src or "")
    if src.startswith("//"):
        return "https:" + src
    if src.startswith("/"):
        return BASE + src
    if src.startswith("http://"):
        return "https://" + src[len("http://"):]
    return src


def _http_get(url, referer=""):
    headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=45)
            if resp.status_code == 200 and resp.content:
                return resp.content.decode("utf-8", "ignore"), str(resp.url)
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=45) as resp:
            return resp.read().decode("utf-8", "ignore"), resp.geturl()
    except Exception:
        return "", url


def _http_bytes(url, referer=""):
    headers = {"User-Agent": UA}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=45)
            if resp.status_code == 200 and resp.content:
                return bytes(resp.content), resp.headers.get("Content-Type", "")
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=45) as resp:
            return resp.read(), resp.headers.get("Content-Type", "")
    except Exception:
        return b"", ""


def _fetch(path):
    text, final = _http_get(BASE + path, referer=BASE + "/")
    return text, final


def _parse_cards(html):
    items = []
    seen = set()
    if not html:
        return items
    blocks = re.split(r'<div[^>]*class="[^"]*bsx-item[^"]*"', html)[1:]
    for block in blocks:
        m = re.search(r'<a href="/manga/([a-z0-9\-]+)"[^>]*title="([^"]*)"', block)
        if not m:
            m = re.search(r'<a href="/manga/([a-z0-9\-]+)"[^>]*>\s*([^<]+?)\s*</a>', block)
            if not m:
                continue
        slug = m.group(1)
        name = _clean(m.group(2))
        if not slug or not name or slug in seen or _flagged(name) or _flagged(slug):
            continue
        seen.add(slug)
        pic = ""
        mi = re.search(r'<img[^>]*?(?:data-src|src)="([^"]+)"', block)
        if mi:
            pic = _abs_url(mi.group(1))
        remarks = ""
        mr = re.search(r'<a[^>]*class="[^"]*chapter[^"]*"[^>]*>([^<]+)</a>', block)
        if mr:
            remarks = _clean(mr.group(1))
        items.append({"vod_id": slug, "vod_name": name, "vod_pic": pic, "vod_remarks": remarks})
    return items


def _mime_of(data, ctype=""):
    if data[:2] == b"\xff\xd8":
        return "image/jpeg"
    if data[:4] == b"\x89PNG":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:3] == b"GIF":
        return "image/gif"
    if ctype:
        return ctype.split(";")[0].strip()
    return "application/octet-stream"


class Spider(BaseSpider):
    def getName(self):
        return "🔞Manga18fx"

    def getDependence(self):
        return []

    def init(self, extend=None):
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        html, _final = _fetch("/")
        return {"class": classes, "list": _parse_cards(html), "filters": {}}

    def homeVideoContent(self, *args, **kwargs):
        html, _final = _fetch("/")
        return {"list": _parse_cards(html), "page": 1, "pagecount": 9999, "limit": 24, "total": 9999}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _norm_pg(pg, 1)
        tid = str(tid or "manhwa").strip()
        valid = [t for t, _n in CATEGORIES]
        if tid not in valid:
            tid = "manhwa"
        if pg <= 1:
            path = "/manga-genre/" + tid
        else:
            path = "/manga-genre/" + tid + "/" + str(pg)
        html, _final = _fetch(path)
        items = _parse_cards(html)
        nxt = bool(re.search(r'href="[^"]*/manga-genre/' + re.escape(tid) + r"/" + str(pg + 1) + r'"', html or ""))
        return {"page": pg, "pagecount": 9999 if nxt else pg, "limit": 24, "total": 9999, "list": items}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        html, _final = _fetch("/manga/" + urllib.parse.quote(vid))
        title = vid
        m = re.search(r"<h1[^>]*>(.*?)</h1>", html or "", flags=re.S)
        if m:
            title = _clean(m.group(1)) or vid
        pic = ""
        m = re.search(r'summary_image.*?<img[^>]*?(?:data-src|src)="([^"]+)"', html or "", flags=re.S)
        if m:
            pic = _abs_url(m.group(1))
        desc = ""
        m = re.search(r'class="dsct"[^>]*>(.*?)</div>', html or "", flags=re.S)
        if m:
            desc = _clean(m.group(1))
        author = ""
        m = re.search(r'class="author-content"[^>]*>.*?<a[^>]*>([^<]+)</a>', html or "", flags=re.S)
        if m:
            author = _clean(m.group(1))
        status = ""
        low = (html or "").lower()
        if "completed" in low:
            status = "completed"
        elif "ongoing" in low:
            status = "ongoing"
        genres = []
        m = re.search(r'class="genres-content"[^>]*>(.*?)</div>', html or "", flags=re.S)
        if m:
            for g in re.findall(r"<a[^>]*>([^<]+)</a>", m.group(1)):
                g = _clean(g)
                if g:
                    genres.append(g)
        chapters = []
        seen = set()
        for href, name in re.findall(r'<a[^>]*class="[^"]*chapter-name[^"]*"[^>]*href="([^"]+)"[^>]*>([^<]+)</a>', html or ""):
            cm = re.search(r"/manga/[^/]+/([^/?#]+)", href)
            if not cm:
                continue
            chap = cm.group(1)
            if chap in seen:
                continue
            seen.add(chap)
            chapters.append((chap, _clean(name) or chap))
        chapters.reverse()
        play = "#".join(name + "$manga18fx:" + vid + "/" + chap for chap, name in chapters)
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": pic, "vod_actor": author, "vod_director": "", "vod_remarks": status, "vod_year": "", "vod_area": "", "vod_content": desc, "type_name": " ".join(genres[:6]), "vod_tag": "image", "vod_play_from": "漫画", "vod_play_url": play}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg, 1)
        if pg > 1:
            return {"list": [], "page": pg, "pagecount": 1, "limit": 24, "total": 0}
        q = urllib.parse.quote(str(key or ""))
        html, _final = _fetch("/search?q=" + q)
        items = _parse_cards(html)
        return {"list": items, "page": pg, "pagecount": 1, "limit": 24, "total": len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if "$" in raw:
            raw = raw.split("$", 1)[1]
        header = {"User-Agent": UA, "Referer": BASE + "/"}
        if raw.startswith("pics://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        chap_path = ""
        if raw.startswith("manga18fx:"):
            chap_path = raw[len("manga18fx:"):]
        elif "/" in raw:
            chap_path = raw
        if not chap_path:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        html, final = _fetch("/manga/" + chap_path)
        header["Referer"] = final or (BASE + "/manga/" + chap_path)
        imgs = []
        seen = set()
        for src in re.findall(r'<img[^>]*?(?:data-src|src)="([^"]+)"', html or ""):
            url = _abs_url(src)
            if _IMG_HOST_RE.match(url) and url not in seen:
                seen.add(url)
                imgs.append(url)
        if not imgs:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        pics = "pics://" + "&&".join(imgs)
        return {"parse": 0, "playUrl": pics, "url": pics, "header": header}

    def localProxy(self, param):
        try:
            target = ""
            want_b64 = False
            p = param
            if isinstance(p, str):
                text = p.strip()
                if text.startswith("{"):
                    try:
                        p = json.loads(text)
                    except Exception:
                        p = {}
                elif text.startswith("http"):
                    target = text
                else:
                    p = dict(urllib.parse.parse_qsl(text))
            if isinstance(p, dict):
                target = str(p.get("u") or p.get("url") or "")
                want_b64 = str(p.get("b64") or p.get("base64") or "") == "1"
            if not target:
                return [404, "text/plain", b"", {}]
            data, ctype = _http_bytes(target, referer=BASE + "/")
            if not data:
                return [404, "text/plain", b"", {}]
            mime = _mime_of(data, ctype)
            if want_b64:
                return [200, mime, base64.b64encode(data).decode("ascii"), {}, 1]
            return [200, mime, data, {}]
        except Exception:
            return [404, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self, *args, **kwargs):
        return False

    def action(self, *args, **kwargs):
        return {}
