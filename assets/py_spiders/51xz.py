
import re
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
        self.host = "https://51xz.vip"
        self.ua = ("Mozilla/5.0 (Linux; Android 13; Pixel 7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/120.0.0.0 Mobile Safari/537.36")

        names = [
            "x视频", "真实自拍", "网红女神", "国产精品", "爱好男同-1",
            "短剧", "成年短剧", "情感剧场", "古装历史", "年代农村", "穿越重生",
            "x吃瓜", "今日吃瓜", "海外吃瓜", "娱乐吃瓜", "网红黑料",
            "x-av", "日本无码", "国产av", "欧美av", "动漫av",
        ]
        self.classes = [{"type_name": n, "type_id": n} for n in names]

        self.post_modules = {"x吃瓜", "今日吃瓜", "海外吃瓜", "娱乐吃瓜", "网红黑料"}
        self._pcache = {}
        self._ocache = {}
        self.pic_head = True


    def init(self, extend=""):
        try:
            ext = json.loads(extend) if extend else {}
        except Exception:
            ext = {}
        if isinstance(ext, dict) and ext.get("host"):
            self.host = str(ext["host"]).rstrip("/")
        if isinstance(ext, dict) and ext.get("pic_head") is not None:
            self.pic_head = bool(ext.get("pic_head"))

    def _pic(self, url):


        if not url:
            return ""
        if url.startswith("//"):
            url = "https:" + url
        if not self.pic_head or "@Referer=" in url:
            return url
        return "%s@Referer=%s/@User-Agent=%s" % (url, self.host + "/", self.ua)

    def getName(self):
        return "51X"

    def isVideoFormat(self, url):
        return ".m3u8" in url or ".mp4" in url

    def manualVideoCheck(self):
        return False

    def _fetch(self, url, referer=None):
        try:
            _p = urllib.parse.urlsplit(url)
            url = urllib.parse.urlunsplit((
                _p.scheme, _p.netloc,
                urllib.parse.quote(_p.path, safe="/%:@&+$,-_.!~*'()"),
                urllib.parse.quote(_p.query, safe="=&%+/:;@!$'()*,-_.~?"),
                _p.fragment))
        except Exception:
            pass
        headers = {
            "User-Agent": self.ua,
            "Referer": referer or (self.host + "/"),
            "Accept": "text/html,*/*",
        }
        last = None
        for _ in range(3):
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=30) as r:
                    return r.read().decode("utf-8", "ignore")
            except Exception as e:
                last = e
        if last:
            raise last
        return ""


    def _objects(self, page):
        chunks = []
        for m in re.finditer(r'self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)', page, re.S):
            try:
                chunks.append(json.loads(m.group(1)))
            except Exception:
                pass
        text = "\n".join(chunks) if chunks else page.replace('\\"', '"')
        decoder = json.JSONDecoder()
        objs = []
        seen = set()
        for m in re.finditer(r'\{"id":"', text):
            try:
                obj, _end = decoder.raw_decode(text, m.start())
            except Exception:
                continue
            if not isinstance(obj, dict) or "id" not in obj:
                continue
            kind = None
            if obj.get("cardKind") == "video":
                kind = "video"
            elif obj.get("kind") == "drama":
                kind = "drama"
            elif obj.get("kind") == "post":
                kind = "post"
            if not kind:
                continue
            key = (kind, obj["id"])
            if key in seen:
                continue
            seen.add(key)
            obj["_kind"] = kind
            objs.append(obj)
        return objs

    def _dur(self, sec):
        try:
            s = int(float(sec))
        except Exception:
            return ""
        if s >= 3600:
            return "%d:%02d:%02d" % (s // 3600, (s % 3600) // 60, s % 60)
        return "%d:%02d" % (s // 60, s % 60)

    def _card(self, obj):
        self._ocache[obj["id"]] = obj
        kind = obj["_kind"]
        path = "/" + kind + "/" + obj["id"] + "/" + (obj.get("slug") or "")
        if kind == "video":
            remarks = self._dur(obj.get("duration"))
        elif kind == "drama":
            cnt = obj.get("episodeCount") or obj.get("currentEpisode") or ""
            remarks = ("全 %s 集" % cnt) if cnt else "短剧"
        else:
            remarks = "有视频" if obj.get("hlsUrl") else "图文"
        return {
            "vod_id": path,
            "vod_name": (obj.get("titleZh") or obj.get("titleEn") or path).strip(),
            "vod_pic": self._pic(obj.get("coverUrl") or ""),
            "vod_remarks": remarks,
        }

    def _module_list(self, name, pg):
        url = self.host + "/m/" + name
        if pg > 1:
            url += "?page=" + str(pg)
        page = self._fetch(url)
        objs = self._objects(page)
        return [self._card(o) for o in objs]


    def homeContent(self, filter=''):
        result = {"class": self.classes}
        try:
            page = self._fetch(self.host + "/")
            vods = [self._card(o) for o in self._objects(page) if o["_kind"] == "video"]
            result["list"] = vods[:24]
        except Exception:
            result["list"] = []
        return result

    def homeVideoContent(self):
        try:
            page = self._fetch(self.host + "/")
            vods = [self._card(o) for o in self._objects(page) if o["_kind"] == "video"]
            return {"list": vods[:24]}
        except Exception:
            return {"list": []}

    def _post_agg(self, name, pg):

        if name not in self._pcache:
            cards = []
            seen = set()
            for sp in range(1, 9):
                try:
                    url = self.host + "/m/" + name + ("?page=" + str(sp) if sp > 1 else "")
                    objs = [o for o in self._objects(self._fetch(url)) if o["_kind"] == "post"]
                except Exception:
                    break
                for o in objs:
                    if o.get("hlsUrl") and o["id"] not in seen:
                        seen.add(o["id"])
                        cards.append(self._card(o))
                if len(objs) < 24:
                    break
            self._pcache[name] = cards
        all_cards = self._pcache[name]
        pagecount = max(1, (len(all_cards) + 23) // 24)
        return all_cards[(pg - 1) * 24: pg * 24], pagecount

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = int(pg) if str(pg).isdigit() else 1
        if tid in self.post_modules:
            vods, total = self._post_agg(tid, pg)
            return {
                "list": vods,
                "page": pg,
                "pagecount": total,
                "limit": max(len(vods), 1),
                "total": len(self._pcache.get(tid, [])),
            }
        vods = self._module_list(tid, pg)
        total = pg + 1 if len(vods) >= 24 else pg
        return {
            "list": vods,
            "page": pg,
            "pagecount": total,
            "limit": max(len(vods), 1),
            "total": total * max(len(vods), 1),
        }

    def _find_obj(self, page, vid):
        target = vid.split("/")[2] if vid.startswith("/") and len(vid.split("/")) > 2 else ""
        for o in self._objects(page):
            if o.get("id") == target:
                return o
        objs = self._objects(page)
        return objs[0] if objs else None

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            vid = ids[0] if ids else ""
        else:
            vid = str(ids).split(",")[0]
        target = vid.split("/")[2] if vid.startswith("/") and len(vid.split("/")) > 2 else ""
        obj = self._ocache.get(target)

        if obj is not None and obj["_kind"] == "drama" and not obj.get("episodes"):
            obj = None
        if obj is None:
            url = self.host + vid if vid.startswith("/") else self.host + "/" + vid
            page = self._fetch(url)
            obj = self._find_obj(page, vid)
        if obj is None:
            return {"list": []}
        kind = obj["_kind"]
        creator = obj.get("creator") or {}
        category = obj.get("category") or {}
        tags = ",".join(t.get("nameZh", "") for t in (obj.get("tags") or []) if t.get("nameZh"))
        pub = (obj.get("publishedAt") or "")[:10]
        vod = {
            "vod_id": vid,
            "vod_name": (obj.get("titleZh") or obj.get("titleEn") or vid).strip(),
            "vod_pic": self._pic(obj.get("coverUrl") or ""),
            "vod_year": pub[:4],
            "vod_area": "",
            "vod_actor": creator.get("name", ""),
            "vod_director": "",
            "vod_type": category.get("nameZh", ""),
            "vod_tag": tags,
            "vod_content": (obj.get("descriptionZh") or obj.get("seoDescription") or "")[:600],
        }
        if kind == "video":
            vod["vod_remarks"] = self._dur(obj.get("duration"))
            vod["vod_play_from"] = "51X"
            vod["vod_play_url"] = "正片$" + (obj.get("hlsUrl") or "")
        elif kind == "drama":
            eps = sorted(obj.get("episodes") or [], key=lambda e: e.get("sort") or 0)
            lines = []
            for e in eps:
                if e.get("hlsUrl"):
                    lines.append("第%s集$%s" % (e.get("sort") or (len(lines) + 1), e["hlsUrl"]))
            cnt = obj.get("episodeCount") or len(lines)
            vod["vod_remarks"] = "全 %s 集" % cnt
            vod["vod_play_from"] = "51X"
            vod["vod_play_url"] = "#".join(lines)
        else:
            vod["vod_remarks"] = "有视频" if obj.get("hlsUrl") else "图文帖"
            if obj.get("hlsUrl"):
                vod["vod_play_from"] = "51X"
                vod["vod_play_url"] = "视频$" + obj["hlsUrl"]
            else:
                vod["vod_play_from"] = ""
                vod["vod_play_url"] = ""
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1):

        url = self.host + "/search?q=" + urllib.parse.quote_plus(key)
        try:
            page = self._fetch(url)
            vods = [self._card(o) for o in self._objects(page)]
        except Exception:
            vods = []
        return {
            "list": vods,
            "page": 1,
            "pagecount": 1,
            "limit": max(len(vods), 1),
            "total": max(len(vods), 1),
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


        import urllib.parse as _up
        import urllib.request as _ur
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(_up.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get("url") or p.get("u") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = _up.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            _o = _up.urlparse(target)
            _req = _ur.Request(target, headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                "Referer": "%s://%s/" % (_o.scheme, _o.netloc)})
            with _ur.urlopen(_req, timeout=20) as _r:
                return [_r.status, _r.headers.get("Content-Type") or "application/octet-stream", _r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]



    def getDependence(self):
        return []

    def destroy(self):
        return None

    def action(self, action=None):
        return {}

