import json
import urllib.request
import urllib.parse
import urllib.error

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        def init(self, extend=""):
            pass


class Spider(BaseSpider):
    def __init__(self):
        self.host = "https://sexaix.top"
        self.img = "https://img.mfantasy.net"
        self.ua = ("Mozilla/5.0 (Linux; Android 13; Pixel 7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/120.0.0.0 Mobile Safari/537.36")
        self.lang = "zh-CN"
        self._cats = None
        self._lists = {}

    def init(self, extend=""):
        try:
            ext = json.loads(extend) if extend else {}
        except Exception:
            ext = {}
        if isinstance(ext, dict) and ext.get("host"):
            self.host = str(ext["host"]).rstrip("/")
        if isinstance(ext, dict) and ext.get("img"):
            self.img = str(ext["img"]).rstrip("/")

    def getName(self):
        return "幻影AI"

    def isVideoFormat(self, url):
        return ".m3u8" in url or ".mp4" in url

    def manualVideoCheck(self):
        return False

    def _fetch(self, url, accept="application/json"):
        headers = {
            "User-Agent": self.ua,
            "Referer": self.host + "/",
            "Accept": accept,
            "Accept-Language": self.lang,
        }
        last = None
        for _ in range(2):
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=60) as r:
                    return r.read().decode("utf-8", "ignore")
            except Exception as e:
                last = e
        if last:
            raise last
        return ""

    def _api(self, path):
        text = self._fetch(self.host + path)
        data = json.loads(text)
        if isinstance(data, dict) and data.get("code") == 0:
            return data.get("data")
        if isinstance(data, list):
            return data
        return data

    def _abs(self, url):
        if not url:
            return ""
        if url.startswith("http"):
            return url
        if url.startswith("/api/"):
            return self.host + url
        return self.img + url

    def _pic(self, url):
        u = self._abs(url)
        if not u:
            return ""
        return "%s@Referer=%s/@User-Agent=%s" % (u, self.host + "/", self.ua)

    def _cats_list(self):
        if self._cats is None:
            data = self._api("/api/dramas/categories?language=" + self.lang)
            cats = []
            if isinstance(data, list):
                for c in data:
                    cats.append({"type_name": c.get("name", ""), "type_id": str(c.get("id", ""))})
            self._cats = cats
        return self._cats

    def _drama_list(self, tid):
        if tid not in self._lists:
            if tid == "all":
                data = self._api("/api/dramas?language=" + self.lang)
            else:
                data = self._api("/api/dramas?language=" + self.lang + "&categoryId=" + urllib.parse.quote(str(tid)))
            self._lists[tid] = data if isinstance(data, list) else []
        return self._lists[tid]

    def _card(self, d):
        total = d.get("totalEpisodes") or ""
        free = d.get("unlockedCount")
        if total and free is not None:
            remarks = "全%s集·免费%s集" % (total, free)
        elif total:
            remarks = "全%s集" % total
        else:
            remarks = d.get("categoryName", "")
        return {
            "vod_id": str(d.get("id", "")),
            "vod_name": (d.get("title") or "").strip(),
            "vod_pic": self._pic(d.get("coverUrl") or ""),
            "vod_remarks": remarks,
        }

    def homeContent(self, filter=''):
        try:
            classes = [{"type_name": "全部", "type_id": "all"}] + self._cats_list()
        except Exception:
            classes = [{"type_name": "全部", "type_id": "all"}]
        try:
            vods = [self._card(d) for d in self._drama_list("all")[:24]]
        except Exception:
            vods = []
        return {"class": classes, "list": vods}

    def homeVideoContent(self):
        try:
            vods = [self._card(d) for d in self._drama_list("all")[:24]]
        except Exception:
            vods = []
        return {"list": vods}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = int(pg) if str(pg).isdigit() else 1
        items = self._drama_list(str(tid))
        per = 24
        total = len(items)
        pagecount = max(1, (total + per - 1) // per)
        page_items = items[(pg - 1) * per: pg * per]
        return {
            "list": [self._card(d) for d in page_items],
            "page": pg,
            "pagecount": pagecount,
            "limit": max(len(page_items), 1),
            "total": total,
        }

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            vid = ids[0] if ids else ""
        else:
            vid = str(ids).split(",")[0]
        try:
            d = self._api("/api/dramas/" + urllib.parse.quote(str(vid)) + "?language=" + self.lang)
        except Exception:
            return {"list": []}
        if not isinstance(d, dict) or not d.get("id"):
            return {"list": []}
        eps = d.get("episodes") or []
        total = d.get("totalEpisodes") or len(eps)
        free_eps = [e for e in eps if e.get("isUnlocked") and e.get("videoUrl")]
        lines = []
        for e in sorted(free_eps, key=lambda x: x.get("episodeNo") or 0):
            lines.append("%s$%s" % (e.get("title") or ("第%s集" % e.get("episodeNo")), self._abs(e.get("videoUrl"))))
        created = str(d.get("createdAt") or "")
        vod = {
            "vod_id": str(d.get("id")),
            "vod_name": (d.get("title") or "").strip(),
            "vod_pic": self._pic(d.get("coverUrl") or ""),
            "vod_year": created[:4],
            "vod_area": "",
            "vod_actor": "",
            "vod_director": "",
            "vod_type": d.get("categoryName", ""),
            "vod_tag": "",
            "vod_content": (d.get("intro") or d.get("shareDesc") or "")[:600],
            "vod_remarks": "全%s集·免费%s集" % (total, len(free_eps)),
            "vod_play_from": "幻影AI",
            "vod_play_url": "#".join(lines),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1):
        try:
            items = self._drama_list("all")
        except Exception:
            items = []
        kw = str(key).lower()
        hits = [d for d in items if kw in str(d.get("title", "")).lower()]
        return {
            "list": [self._card(d) for d in hits],
            "page": 1,
            "pagecount": 1,
            "limit": max(len(hits), 1),
            "total": max(len(hits), 1),
        }

    def playerContent(self, flag, id, vipFlags=None):
        if isinstance(id, str) and "$" in id:
            id = id.split("$", 1)[1]
        return {
            "parse": 0,
            "playUrl": "",
            "url": id,
            "header": {
                "User-Agent": self.ua,
                "Referer": self.host + "/",
            },
        }

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
            o = urllib.parse.urlparse(target)
            req = urllib.request.Request(target, headers={
                "User-Agent": self.ua,
                "Referer": "%s://%s/" % (o.scheme, o.netloc)})
            with urllib.request.urlopen(req, timeout=30) as r:
                return [r.status, r.headers.get("Content-Type") or "application/octet-stream", r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def getDependence(self):
        return []

    def destroy(self):
        return None

    def action(self, action=None):
        return {}
