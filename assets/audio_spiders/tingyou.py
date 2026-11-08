import http.client
import json
import urllib.parse
import urllib.request
import uuid

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
        self.host = "https://appp.fdhtbz.cn"
        self.site = "https://tingyou.fm"
        self.session = str(uuid.uuid4())
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "x-listening-session": self.session,
            "x-listening-timezone": "UTC",
            "Origin": self.site,
            "Referer": self.site + "/",
            "Content-Type": "application/json",
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
        try:
            self._get("/api/h5/listening/rank", {"section": "latest", "page": "1"})
        except Exception:
            pass

    def destroy(self):
        pass

    def _fetch(self, req):
        if requests is not None:
            last = None
            for _ in range(3):
                try:
                    resp = requests.request(
                        req.get_method(),
                        req.full_url,
                        data=req.data,
                        headers=dict(req.header_items()),
                        timeout=15,
                    )
                    resp.raise_for_status()
                    return resp.json()
                except Exception as e:
                    last = e
            raise last
        last = None
        for _ in range(3):
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    try:
                        raw = resp.read()
                    except http.client.IncompleteRead as e:
                        raw = e.partial
                    return json.loads(raw.decode("utf-8", "ignore"))
            except http.client.IncompleteRead as e:
                if e.partial:
                    try:
                        return json.loads(e.partial.decode("utf-8", "ignore"))
                    except Exception:
                        last = e
                else:
                    last = e
            except Exception as e:
                last = e
        raise last

    def _get(self, path, params=None):
        url = self.host + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers=self.headers, method="GET")
        return self._fetch(req)

    def _post(self, path, data):
        url = self.host + path
        body = json.dumps(data).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers=self.headers, method="POST")
        return self._fetch(req)

    def homeContent(self, filter=False):
        classes = []
        for s in self.sections:
            classes.append({"type_id": s["key"], "type_name": s["name"]})
        return {
            "class": classes,
            "filters": {},
            "list": []
        }

    def homeVideoContent(self):
        try:
            data = self._get("/api/h5/listening/rank", {"section": "latest", "page": "1", "cache_meta": "1"})
            items = data.get("data", {}).get("items", [])
            videos = []
            for it in items[:20]:
                videos.append({
                    "vod_id": str(it.get("id", "")),
                    "vod_name": it.get("title", ""),
                    "vod_pic": it.get("cover_url", ""),
                    "vod_remarks": f"{it.get('count', 0)}集 · {it.get('teller', '')}",
                    "vod_year": "",
                    "vod_area": "",
                    "type_name": it.get("type", "") or it.get("cat", ""),
                })
            return {"list": videos}
        except Exception:
            return {"list": []}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            page = int(pg) if pg else 1
            data = self._get("/api/h5/listening/rank", {
                "section": tid or "latest",
                "page": str(page),
                "cache_meta": "1"
            })
            d = data.get("data", {})
            items = d.get("items", [])
            videos = []
            for it in items:
                videos.append({
                    "vod_id": str(it.get("id", "")),
                    "vod_name": it.get("title", ""),
                    "vod_pic": it.get("cover_url", ""),
                    "vod_remarks": f"{it.get('count', 0)}集 · {it.get('teller', '')}",
                    "vod_year": "",
                    "type_name": it.get("type", "") or it.get("cat", ""),
                })
            has_more = d.get("has_more", False)
            total = page * 20 + (20 if has_more else 0)
            return {
                "list": videos,
                "page": page,
                "pagecount": page + 1 if has_more else page,
                "limit": 20,
                "total": total
            }
        except Exception:
            return {"list": [], "page": 1, "pagecount": 1, "limit": 20, "total": 0}

    def detailContent(self, ids):
        try:
            vod_id = ids[0] if isinstance(ids, list) else ids
            album = self._get(f"/api/h5/listening/album/{vod_id}", {"cache_meta": "1"})
            a = album.get("data", {})
            chapters_data = self._get(f"/api/h5/listening/chapters/{vod_id}", {"cache_meta": "1"})
            chapters = chapters_data.get("data", {}).get("chapters", [])

            play_from = "听友听书"
            play_urls = []
            for ch in chapters:
                idx = ch.get("index", 0)
                title = ch.get("title") or f"第{idx}集"
                title = title.replace("#", " ").replace("$", " ").strip()
                play_urls.append(f"{title}${vod_id}|{idx}")

            vod = {
                "vod_id": str(a.get("id", vod_id)),
                "vod_name": a.get("title", ""),
                "vod_pic": a.get("cover_url", ""),
                "type_name": a.get("type", "") or a.get("cat", ""),
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": f"{a.get('count', 0)}集",
                "vod_actor": a.get("teller", ""),
                "vod_director": a.get("author", ""),
                "vod_content": a.get("synopsis", "") or a.get("intro", ""),
                "vod_play_from": play_from,
                "vod_play_url": "#".join(play_urls) if play_urls else "",
            }
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        try:
            page = int(pg) if pg else 1
            data = self._get("/api/h5/listening/rank", {
                "section": "latest",
                "page": str(page),
                "cache_meta": "1"
            })
            items = data.get("data", {}).get("items", [])
            videos = []
            key_lower = key.lower()
            for it in items:
                title = it.get("title", "")
                if key_lower in title.lower() or key_lower in (it.get("author", "") or "").lower() or key_lower in (it.get("teller", "") or "").lower():
                    videos.append({
                        "vod_id": str(it.get("id", "")),
                        "vod_name": title,
                        "vod_pic": it.get("cover_url", ""),
                        "vod_remarks": f"{it.get('count', 0)}集 · {it.get('teller', '')}",
                    })
            return {"list": videos, "page": page}
        except Exception:
            return {"list": []}

    def playerContent(self, flag, id, vipFlags=None):
        try:
            raw = str(id).strip()
            if "|" in raw:
                album_id, idx_str = raw.split("|", 1)
                chapter_idx = int(idx_str)
            elif "$" in raw:
                parts = raw.split("$")
                album_id = parts[0]
                chapter_idx = int(parts[1]) if len(parts) > 1 else 1
            else:
                return {"parse": 0, "url": "", "playUrl": "", "header": {}}

            data = self._post("/api/h5/listening/play", {
                "album_id": str(album_id),
                "chapter_idx": chapter_idx
            })
            play_url = data.get("play_url", "")
            if not play_url:
                return {"parse": 0, "url": "", "playUrl": "", "header": {}}

            return {
                "parse": 0,
                "url": play_url,
                "playUrl": play_url,
                "header": {
                    "User-Agent": self.headers["User-Agent"],
                    "Referer": self.site + "/",
                }
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
