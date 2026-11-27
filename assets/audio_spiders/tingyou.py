import json
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
        self.base = "https://tingyou.fm/listening-api"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Origin": "https://tingyou.fm",
            "Referer": "https://tingyou.fm/listening",
        }
        self.sections = [
            {"key": "latest", "name": "最新"},
            {"key": "hot", "name": "热门"},
            {"key": "recommend", "name": "推荐"},
            {"key": "serial", "name": "连载"},
            {"key": "storytelling", "name": "评书"},
        ]

    def getName(self):
        return "听友听书"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _request(self, method, url, payload=None, timeout=25):
        last = None
        body = None
        headers = dict(self.headers)
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        for _ in range(3):
            try:
                if requests is not None:
                    resp = requests.request(method, url, data=body, headers=headers, timeout=timeout)
                    resp.raise_for_status()
                    return resp.json()
                req = urllib.request.Request(url, data=body, headers=headers, method=method)
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    return json.loads(resp.read().decode("utf-8", "ignore"))
            except Exception as e:
                last = e
        raise last

    def _title(self, text):
        return str(text or "").replace("#", " ").replace("$", " ").strip()

    def _rows(self, items):
        videos = []
        for it in items or []:
            if not isinstance(it, dict):
                continue
            bid = it.get("id")
            if bid is None:
                continue
            count = it.get("count")
            videos.append({
                "vod_id": str(bid),
                "vod_name": it.get("title") or "",
                "vod_pic": it.get("cover_url") or "",
                "vod_remarks": (str(count) + "集") if count else (it.get("teller") or ""),
                "vod_actor": it.get("author") or "",
                "vod_content": it.get("description") or it.get("intro") or it.get("synopsis") or "",
            })
        return videos

    def homeContent(self, filter=False):
        return {
            "class": [{"type_id": s["key"], "type_name": s["name"]} for s in self.sections],
            "filters": {},
            "list": [],
        }

    def homeVideoContent(self):
        try:
            return {"list": self.categoryContent("latest", 1)["list"]}
        except Exception:
            return {"list": []}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            page = int(pg) if pg else 1
            data = self._request("GET", "%s/rank?section=%s&page=%d" % (self.base, tid or "latest", page))
            items = data.get("items") or []
            videos = self._rows(items)
            has_more = bool(data.get("has_more")) if isinstance(data, dict) else False
            return {
                "list": videos,
                "page": page,
                "pagecount": page + 1 if (has_more or len(videos) >= 20) else page,
                "limit": 20,
                "total": (page + 1) * 20 if (has_more or len(videos) >= 20) else page * 20,
            }
        except Exception:
            return {"list": [], "page": 1, "pagecount": 1, "limit": 20, "total": 0}

    def detailContent(self, ids):
        try:
            album_id = str(ids[0] if isinstance(ids, list) else ids)
            album = self._request("GET", "%s/album/%s" % (self.base, album_id))
            chapters_data = self._request("GET", "%s/chapters/%s" % (self.base, album_id))
            chapters = chapters_data.get("chapters") or []
            play_urls = []
            for c in chapters:
                if not isinstance(c, dict):
                    continue
                idx = c.get("index")
                if idx is None:
                    continue
                title = self._title(c.get("title") or "第" + str(len(play_urls) + 1) + "集")
                play_urls.append(title + "$" + album_id + "|" + str(idx))
            vod = {
                "vod_id": album_id,
                "vod_name": album.get("title") or "",
                "vod_pic": album.get("cover_url") or "",
                "type_name": album.get("type") or album.get("cat") or "",
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": str(len(play_urls)) + "集",
                "vod_actor": album.get("author") or "",
                "vod_director": album.get("teller") or "",
                "vod_content": album.get("synopsis") or album.get("intro") or "",
                "vod_play_from": "听友听书",
                "vod_play_url": "#".join(play_urls),
            }
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        try:
            page = int(pg) if pg else 1
            data = self._request("POST", self.base + "/search", {"keyword": str(key), "page": page})
            return {"list": self._rows(data.get("results") or []), "page": page}
        except Exception:
            return {"list": []}

    def playerContent(self, flag, id, vipFlags=None):
        try:
            raw = str(id).strip()
            album_id, idx = raw.split("|", 1)
            data = self._request("POST", self.base + "/play", {
                "album_id": str(album_id),
                "chapter_idx": int(idx),
            })
            play_url = data.get("play_url") or ""
            if not play_url:
                return {"parse": 0, "url": "", "playUrl": "", "header": {}}
            return {
                "parse": 0,
                "url": play_url,
                "playUrl": play_url,
                "header": {
                    "User-Agent": self.headers["User-Agent"],
                    "Referer": "https://tingyou.fm/",
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
