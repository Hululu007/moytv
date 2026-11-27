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
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


class Spider(BaseSpider):
    def __init__(self):
        self.host = "https://api.bilibili.com"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Referer": "https://www.bilibili.com/",
            "Origin": "https://www.bilibili.com",
            "Cookie": "buvid3=7A75A498-7E2F-45B9-8684-4A8D9CFEE322infoc",
            "Accept": "application/json, text/plain, */*",
        }
        self.classes = ["有声小说", "广播剧", "评书", "相声", "英文有声书", "同人音声"]

    def getName(self):
        return "哔哩哔哩听书"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _get_json(self, url, timeout=20):
        last = None
        for _ in range(3):
            try:
                if requests is not None:
                    resp = requests.get(url, headers=self.headers, timeout=timeout)
                    resp.raise_for_status()
                    return resp.json()
                req = urllib.request.Request(url, headers=self.headers, method="GET")
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    return json.loads(resp.read().decode("utf-8", "ignore"))
            except Exception as e:
                last = e
        raise last

    def _clean(self, text):
        return re.sub(r"<[^>]+>", "", str(text or "")).strip()

    def _title(self, text):
        return self._clean(text).replace("#", " ").replace("$", " ").strip()

    def _list(self, keyword, page):
        q = urllib.parse.urlencode({
            "search_type": "video",
            "keyword": keyword,
            "page": str(page),
        })
        data = self._get_json(self.host + "/x/web-interface/search/type?" + q)
        rows = ((data.get("data") or {}).get("result")) or []
        videos = []
        for r in rows:
            if not isinstance(r, dict):
                continue
            bvid = r.get("bvid") or ""
            if not bvid:
                continue
            pic = r.get("pic") or ""
            if pic.startswith("//"):
                pic = "https:" + pic
            videos.append({
                "vod_id": bvid,
                "vod_name": self._clean(r.get("title")),
                "vod_pic": pic,
                "vod_remarks": str(r.get("duration") or ""),
                "vod_actor": r.get("author") or "",
                "vod_content": self._clean(r.get("description")),
            })
        return videos

    def homeContent(self, filter=False):
        return {
            "class": [{"type_id": c, "type_name": c} for c in self.classes],
            "filters": {},
            "list": [],
        }

    def homeVideoContent(self):
        try:
            return {"list": self._list(self.classes[0], 1)}
        except Exception:
            return {"list": []}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            page = int(pg) if pg else 1
            videos = self._list(tid or self.classes[0], page)
            return {
                "list": videos,
                "page": page,
                "pagecount": page + 1 if len(videos) >= 20 else page,
                "limit": 20,
                "total": (page + 1) * 20 if len(videos) >= 20 else page * 20,
            }
        except Exception:
            return {"list": [], "page": 1, "pagecount": 1, "limit": 20, "total": 0}

    def detailContent(self, ids):
        try:
            bvid = ids[0] if isinstance(ids, list) else ids
            data = self._get_json(self.host + "/x/web-interface/view?bvid=" + urllib.parse.quote(str(bvid)))
            d = data.get("data") or {}
            pages = d.get("pages") or []
            play_urls = []
            for p in pages:
                cid = p.get("cid")
                if cid is None:
                    continue
                title = self._title(p.get("part") or "第" + str(len(play_urls) + 1) + "集")
                play_urls.append(title + "$" + str(bvid) + "|" + str(cid))
            vod = {
                "vod_id": str(bvid),
                "vod_name": self._clean(d.get("title")),
                "vod_pic": d.get("pic") or "",
                "type_name": "",
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": str(len(pages)) + "集",
                "vod_actor": ((d.get("owner") or {}).get("name")) or "",
                "vod_director": "",
                "vod_content": self._clean(d.get("desc")),
                "vod_play_from": "哔哩哔哩听书",
                "vod_play_url": "#".join(play_urls),
            }
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        try:
            page = int(pg) if pg else 1
            return {"list": self._list(key, page), "page": page}
        except Exception:
            return {"list": []}

    def playerContent(self, flag, id, vipFlags=None):
        try:
            raw = str(id).strip()
            bvid, cid = raw.split("|", 1)
            q = urllib.parse.urlencode({
                "bvid": bvid,
                "cid": cid,
                "fnval": "16",
                "fourk": "0",
                "otype": "json",
            })
            data = self._get_json(self.host + "/x/player/playurl?" + q)
            d = data.get("data") or {}
            url = ""
            dash = d.get("dash") or {}
            audios = dash.get("audio") or []
            if audios:
                url = audios[0].get("baseUrl") or audios[0].get("base_url") or ""
            if not url:
                durl = d.get("durl") or []
                if durl:
                    url = durl[0].get("url") or ""
            if not url:
                return {"parse": 0, "url": "", "playUrl": "", "header": {}}
            return {
                "parse": 0,
                "url": url,
                "playUrl": url,
                "header": {
                    "User-Agent": self.headers["User-Agent"],
                    "Referer": "https://www.bilibili.com/",
                },
            }
        except Exception:
            return {"parse": 0, "url": "", "playUrl": "", "header": {}}

    def isVideoFormat(self, url):
        return True

    def manualVideoCheck(self):
        return False

    def localProxy(self, param):
        return [404, "text/plain", b"", {}]

    def action(self, action, params=None):
        return {"code": 0, "msg": "ok"}
