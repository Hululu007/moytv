import json
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
        self.api = "https://api.bookan.com.cn"
        self.search_api = "https://es.bookan.com.cn"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
            "Referer": "https://voicewk.bookan.com.cn/25303/index",
            "Origin": "https://voicewk.bookan.com.cn",
            "Accept": "application/json, text/plain, */*",
        }
        self.classes = [
            ("1314", "经典必读"),
            ("1320", "国学经典"),
            ("1306", "文学文艺"),
            ("1305", "少年读物"),
            ("1304", "儿童文学"),
            ("1310", "心理哲学"),
            ("1309", "育儿心经"),
            ("1311", "家庭健康"),
            ("1307", "青春励志"),
            ("1312", "历史小说"),
            ("1315", "商业财经"),
            ("1313", "科技科普"),
            ("1303", "故事会"),
            ("1316", "红色岁月"),
            ("1318", "社会观察"),
            ("1317", "音乐戏曲"),
            ("1319", "相声评书"),
        ]

    def getName(self):
        return "博看听书"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _get_json(self, url, timeout=75):
        last = None
        for _ in range(2):
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

    def _title(self, text):
        return str(text or "").replace("#", " ").replace("$", " ").strip()

    def _rows(self, data):
        rows = ((data.get("data") or {}).get("list")) or []
        videos = []
        for b in rows:
            if not isinstance(b, dict):
                continue
            bid = b.get("id")
            if bid is None:
                continue
            ex = b.get("extra") or {}
            total = b.get("total")
            videos.append({
                "vod_id": str(bid),
                "vod_name": b.get("name") or "",
                "vod_pic": b.get("cover") or "",
                "vod_remarks": (str(total) + "集") if total else (ex.get("narrator") or ""),
                "vod_actor": ex.get("author") or "",
                "vod_content": b.get("intro") or "",
            })
        return videos

    def homeContent(self, filter=False):
        return {
            "class": [{"type_id": tid, "type_name": name} for tid, name in self.classes],
            "filters": {},
            "list": [],
        }

    def homeVideoContent(self):
        try:
            return {"list": self.categoryContent(self.classes[0][0], 1)["list"]}
        except Exception:
            return {"list": []}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            page = int(pg) if pg else 1
            q = urllib.parse.urlencode({
                "instance_id": "25304",
                "page": str(page),
                "category_id": str(tid),
                "num": "24",
            })
            videos = self._rows(self._get_json(self.api + "/voice/book/list?" + q))
            return {
                "list": videos,
                "page": page,
                "pagecount": page + 1 if len(videos) >= 24 else page,
                "limit": 24,
                "total": (page + 1) * 24 if len(videos) >= 24 else page * 24,
            }
        except Exception:
            return {"list": [], "page": 1, "pagecount": 1, "limit": 24, "total": 0}

    def detailContent(self, ids):
        try:
            album_id = str(ids[0] if isinstance(ids, list) else ids)
            play_urls = []
            album_name = ""
            page = 1
            last_page = 1
            while page <= last_page and page <= 60:
                q = urllib.parse.urlencode({
                    "album_id": album_id,
                    "page": str(page),
                    "num": "200",
                    "order": "1",
                })
                data = self._get_json(self.api + "/voice/album/units?" + q)
                d = data.get("data") or {}
                if not album_name:
                    album_name = d.get("album_name") or d.get("name") or ""
                last_page = int(d.get("last_page") or 1)
                for c in d.get("list") or []:
                    if not isinstance(c, dict):
                        continue
                    f = str(c.get("file") or "")
                    if f.startswith("http://"):
                        f = "https://" + f[len("http://"):]
                    if not f.startswith("https://"):
                        continue
                    title = self._title(c.get("title") or "第" + str(len(play_urls) + 1) + "集")
                    play_urls.append(title + "$" + str(f))
                page += 1
            vod = {
                "vod_id": album_id if album_name else "",
                "vod_name": album_name,
                "vod_pic": "",
                "type_name": "",
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": str(len(play_urls)) + "集",
                "vod_actor": "",
                "vod_director": "",
                "vod_content": "",
                "vod_play_from": "博看听书",
                "vod_play_url": "#".join(play_urls),
            }
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        try:
            page = int(pg) if pg else 1
            q = urllib.parse.urlencode({
                "instanceId": "25304",
                "keyword": str(key),
                "pageNum": str(page),
                "limitNum": "20",
            })
            return {"list": self._rows(self._get_json(self.search_api + "/api/v3/voice/book?" + q)), "page": page}
        except Exception:
            return {"list": []}

    def playerContent(self, flag, id, vipFlags=None):
        url = str(id).strip()
        if not url.startswith("http"):
            return {"parse": 0, "url": "", "playUrl": "", "header": {}}
        return {
            "parse": 0,
            "url": url,
            "playUrl": url,
            "header": {
                "User-Agent": self.headers["User-Agent"],
                "Referer": "https://voicewk.bookan.com.cn/25303/index",
            },
        }

    def isVideoFormat(self, url):
        return True

    def manualVideoCheck(self):
        return False

    def localProxy(self, param):
        return [404, "text/plain", b"", {}]

    def action(self, action, params=None):
        return {"code": 0, "msg": "ok"}
