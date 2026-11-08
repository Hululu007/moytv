import base64
import json
import re
import urllib.parse
import urllib.request

try:
    import requests
except Exception:
    requests = None

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider(object):
        pass

HOST = "https://evj1istu2k.hsvoice31.cfd"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
SITE_NAME = "🔞黄色有声小说"
CLASSES = [
    ("home", "首页"),
    ("author", "主播"),
    ("toplist", "榜单"),
    ("latest", "最新"),
]
PLAY_FROM = "在线播放"
MEDIA_EXTS = (".webm", ".mp3", ".m4a", ".wav", ".ogg", ".flac", ".aac",
              ".mp4", ".m3u8", ".mpd", ".mov", ".mkv")


def _b64decode(s):
    s = re.sub(r"\s+", "", str(s or ""))
    if not s:
        return b""
    return base64.b64decode(s + "=" * (-len(s) % 4))


def _dtext(s):
    try:
        return _b64decode(s).decode("utf-8", "ignore")
    except Exception:
        return ""


def _as_dict(extend):
    if isinstance(extend, dict):
        return extend
    if isinstance(extend, str) and extend.strip():
        try:
            v = json.loads(extend)
            return v if isinstance(v, dict) else {}
        except Exception:
            return {}
    return {}


def _as_int(v, default=1):
    try:
        return int(v)
    except Exception:
        return default


class Spider(BaseSpider):

    def __init__(self):
        self.timeout = 15
        self.proxy = None
        self.cookie = ""
        self._sess = None

    def getName(self):
        return SITE_NAME

    def getDependence(self):
        return []

    def init(self, extend=""):
        ext = _as_dict(extend)
        self.cookie = str(ext.get("cookie") or "").strip()
        self.proxy = ext.get("proxy") or None
        try:
            self.timeout = max(5, min(60, int(ext.get("timeout") or 15)))
        except Exception:
            self.timeout = 15
        if requests is not None:
            try:
                s = requests.Session()
                s.headers.update({"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"})
                if self.cookie:
                    s.headers["Cookie"] = self.cookie
                if self.proxy:
                    s.proxies = {"http": self.proxy, "https": self.proxy}
                self._sess = s
            except Exception:
                self._sess = None
        return self

    def destroy(self):
        return None

    def _request(self, url):
        headers = {"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"}
        if self.cookie:
            headers["Cookie"] = self.cookie
        if self._sess is not None:
            try:
                r = self._sess.get(url, timeout=self.timeout)
                return r.text
            except Exception:
                pass
        req = urllib.request.Request(url, headers=headers)
        if self.proxy:
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({"http": self.proxy, "https": self.proxy}))
            return opener.open(req, timeout=self.timeout).read().decode("utf-8", "ignore")
        return urllib.request.urlopen(req, timeout=self.timeout).read().decode("utf-8", "ignore")

    def _fetch_page(self, path):
        url = HOST + urllib.parse.quote(path, safe="/:?&=%")
        shell = self._request(url)
        plain = shell.replace("\\", "")
        m = re.search(r"\w+\('(.+?)'\.split", plain, re.S)
        if not m:
            return shell
        try:
            layer2 = _b64decode(m.group(1)[::-1]).decode("utf-8", "ignore")
        except Exception:
            return shell
        m2 = re.search(r"/obfuscate/js/t/([0-9a-f]+)", layer2)
        if not m2:
            return layer2
        try:
            js = self._request(HOST + "/obfuscate/js/t/" + m2.group(1))
        except Exception:
            return layer2
        mh = re.search(r"var h\s*=\s*'([^']+)'", js)
        if not mh:
            return js
        try:
            return _b64decode(mh.group(1)).decode("utf-8", "ignore")
        except Exception:
            return js

    def _book_cards(self, html):
        out = []
        seen = set()
        for m in re.finditer(
                r'<a href="/play/(\d+)\.html" class="(?:book-card-link|update-item-link)">(.*?)</a>',
                html, re.S):
            bid = m.group(1)
            if bid in seen:
                continue
            seen.add(bid)
            parts = [_dtext(x) for x in re.findall(r"d\('([A-Za-z0-9+/=]+)'\)", m.group(2))]
            title = parts[0] if len(parts) > 0 else ""
            author = parts[1] if len(parts) > 1 else ""
            plays = parts[3] if len(parts) > 3 else ""
            if not title:
                continue
            out.append({
                "vod_id": bid,
                "vod_name": title,
                "vod_pic": "",
                "vod_actor": author,
                "vod_remarks": plays,
            })
        return out

    def _author_cards(self, html):
        out = []
        seen = set()
        for m in re.finditer(r'<a href="/author/([^"]+)\.html">(.*?)</a>', html, re.S):
            block = m.group(2)
            if "host-item" not in block:
                continue
            part = urllib.parse.unquote(m.group(1))
            if part in seen:
                continue
            seen.add(part)
            img = re.search(r'<img[^>]+src="([^"]+)"', block)
            parts = [_dtext(x) for x in re.findall(r"d\('([A-Za-z0-9+/=]+)'\)", block)]
            name = parts[0] if parts else part
            count = parts[1] if len(parts) > 1 else ""
            remarks = (count + "部作品") if count else ""
            out.append({
                "vod_id": "author:" + urllib.parse.quote(part, safe=""),
                "vod_name": name,
                "vod_pic": img.group(1) if img else "",
                "vod_tag": "folder",
                "vod_remarks": remarks,
            })
        return out

    def _home_books(self):
        return self._book_cards(self._fetch_page("/"))

    def _page_path(self, base, pg):
        if pg <= 1:
            return base
        return base + "?page=" + str(pg)

    def _author_books(self, part, pg):
        path = self._page_path("/author/" + part + ".html", pg)
        return self._book_cards(self._fetch_page(path))

    def homeContent(self, filter=None):
        classes = [{"type_id": cid, "type_name": name} for cid, name in CLASSES]
        try:
            lst = self._home_books()
        except Exception:
            lst = []
        return {"class": classes, "filters": {}, "list": lst}

    def homeVideoContent(self):
        try:
            lst = self._home_books()
        except Exception:
            lst = []
        return {"list": lst}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _as_int(pg, 1)
        if pg < 1:
            pg = 1
        ext = _as_dict(extend)
        tid = str(tid or "").strip()
        folder = ""
        for key in ("folderId", "folder", "folder_id", "id"):
            v = ext.get(key)
            if isinstance(v, str) and "author:" in v:
                folder = v
                break
        if tid.startswith("author:"):
            folder = tid
        try:
            if folder:
                part = urllib.parse.unquote(folder.split("author:", 1)[1])
                items = self._author_books(part, pg)
            elif tid == "home":
                items = self._home_books() if pg == 1 else []
            elif tid == "author":
                items = self._author_cards(self._fetch_page(self._page_path("/author.html", pg)))
            elif tid == "toplist":
                items = self._book_cards(self._fetch_page(self._page_path("/toplist.html", pg)))
            elif tid == "latest":
                items = self._book_cards(self._fetch_page(self._page_path("/latest.html", pg)))
            else:
                items = []
        except Exception:
            items = []
        pagecount = 999 if items else pg
        limit = len(items) if items else 15
        return {"page": pg, "pagecount": pagecount, "limit": limit,
                "total": pagecount * limit, "list": items}

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            bid = str(ids[0]) if ids else ""
        else:
            bid = str(ids or "").split(",")[0].strip()
        if not bid.isdigit():
            return {"list": []}
        try:
            html = self._fetch_page("/play/" + bid + ".html")
        except Exception:
            return {"list": []}
        m = re.search(r"<main class=\"play-page\">(.*?)</main>", html, re.S)
        block = m.group(1) if m else html
        title = ""
        hm = re.search(r"<h1[^>]*>.*?d\('([A-Za-z0-9+/=]+)'\)", block, re.S)
        if hm:
            title = _dtext(hm.group(1))
        am = re.search(r'href="/author/([^"]+)\.html"', block)
        apart = urllib.parse.unquote(am.group(1)) if am else ""
        params = [_dtext(x) for x in re.findall(r"d\('([A-Za-z0-9+/=]+)'\)", block)]
        author = ""
        date = ""
        plays = ""
        for i, p in enumerate(params):
            if p == "主播：" and i + 1 < len(params):
                author = params[i + 1]
            if re.match(r"^\d{4}-\d{2}-\d{2}$", p):
                date = p
            if re.match(r"^[\d.]+万$", p):
                plays = p
        if not author and apart:
            author = apart
        sm = re.search(r'<source src="([^"]+)"', block)
        audio = ""
        if sm:
            audio = sm.group(1)
            if audio.startswith("/"):
                audio = HOST + audio
        if not title or not audio:
            return {"list": []}
        meta = "主播：" + author
        if date:
            meta += " · " + date
        if plays:
            meta += " · " + plays + "播放"
        vod = {
            "vod_id": bid,
            "vod_name": title,
            "vod_pic": "",
            "vod_actor": author,
            "vod_remarks": plays,
            "vod_content": meta,
            "vod_play_from": PLAY_FROM,
            "vod_play_url": title + "$" + audio,
        }
        return {"list": [vod]}

    def searchContent(self, key, quick=False):
        kw = str(key or "").strip()
        if not kw:
            return {"list": []}
        k = base64.urlsafe_b64encode(kw.encode("utf-8")).rstrip(b"=").decode()
        try:
            html = self._fetch_page("/search.html?k=" + k)
            items = self._book_cards(html)
        except Exception:
            items = []
        return {"list": items}

    def playerContent(self, flag, did, vipFlags=None):
        did = str(did or "").strip()
        url = did
        if "$" in did:
            url = did.rsplit("$", 1)[1].strip()
        if url.isdigit():
            try:
                html = self._fetch_page("/play/" + url + ".html")
                sm = re.search(r'<source src="([^"]+)"', html)
                url = (HOST + sm.group(1)) if sm and sm.group(1).startswith("/") else (sm.group(1) if sm else "")
            except Exception:
                url = ""
        elif url.startswith("/"):
            url = HOST + url
        header = {"User-Agent": UA, "Referer": HOST + "/"}
        if not url:
            return {"parse": 0, "playUrl": "", "url": "", "header": header,
                    "msg": "未取到音频地址"}
        m = re.search(r"/static/downloads/(\d+)/", url)
        if m:
            header["Referer"] = HOST + "/play/" + m.group(1) + ".html"
        return {"parse": 0, "playUrl": "", "url": url, "header": header}

    def localProxy(self, param):
        url = ""
        if isinstance(param, dict):
            url = str(param.get("url") or param.get("src") or "")
        elif isinstance(param, str):
            m = re.search(r"https?://[^\s&\"']+", param)
            if m:
                url = m.group(0)
        if not url:
            return [404, "text/plain", b"", {}]
        try:
            if self._sess is not None:
                r = self._sess.get(url, timeout=self.timeout)
                return [r.status_code, r.headers.get("Content-Type", ""),
                        r.content, dict(r.headers)]
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return [r.status, r.headers.get("Content-Type", ""),
                        r.read(), dict(r.headers)]
        except Exception:
            return [404, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        u = str(url or "").lower().split("?")[0]
        return any(u.endswith(e) for e in MEDIA_EXTS)

    def manualVideoCheck(self):
        return False

    def action(self, act, *args, **kwargs):
        return {}
