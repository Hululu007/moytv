import hashlib
import json
import time
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


SIGN_KEY = "056a308c515e16b2fe5a5c631319339cbc60a8ee0e03d016"


class Spider(BaseSpider):
    def __init__(self):
        self.api = "https://api.mekui.com/ecmsapi/index.php"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
            "Referer": "https://m.shuyinfm.com/",
            "Origin": "https://m.shuyinfm.com",
            "Accept": "application/json, text/plain, */*",
        }
        self.classes = [
            ("28", "有声小说"),
            ("29", "广播剧"),
            ("30", "评书"),
            ("31", "百家讲坛"),
            ("34", "养生"),
            ("35", "娱乐"),
            ("59", "粤语"),
            ("66", "车载专区"),
            ("81", "戏曲"),
            ("91", "相声小品"),
            ("98", "音乐"),
            ("100", "儿童"),
        ]

    def getName(self):
        return "书音FM"

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def _get_json(self, url, timeout=25):
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
            videos.append({
                "vod_id": str(bid),
                "vod_name": b.get("title") or "",
                "vod_pic": b.get("titlepic") or "",
                "vod_remarks": b.get("player") or "",
                "vod_actor": b.get("playadmin") or "",
                "vod_content": b.get("moviesay") or "",
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
                "mod": "movie",
                "act": "list",
                "classid": str(tid),
                "page": str(page),
                "pagesize": "24",
                "sort": "onclick desc",
            })
            videos = self._rows(self._get_json(self.api + "?" + q))
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
            book_id = str(ids[0] if isinstance(ids, list) else ids)
            info = {}
            try:
                d = self._get_json(self.api + "?" + urllib.parse.urlencode({
                    "mod": "movie", "act": "detail", "id": book_id}))
                info = ((d.get("data") or {}).get("detail")) or {}
            except Exception:
                info = {}
            play_urls = []
            page = 1
            total_page = 1
            while page <= total_page and page <= 40:
                d = self._get_json(self.api + "?" + urllib.parse.urlencode({
                    "mod": "movie", "act": "movielist", "id": book_id,
                    "pagesize": "500", "page": str(page)}))
                data = d.get("data") or {}
                total_page = int(data.get("totalpage") or 1)
                for c in data.get("moielist") or []:
                    if not isinstance(c, dict):
                        continue
                    cid = c.get("id")
                    if cid is None:
                        continue
                    title = self._title(c.get("title") or "第" + str(len(play_urls) + 1) + "集")
                    locked = str(c.get("control")) != "0" or str(c.get("level")) != "0" or str(c.get("ofen")) != "0"
                    if locked:
                        title += "（受限）"
                    play_urls.append(title + "$" + book_id + "|" + str(cid))
                page += 1
            vod = {
                "vod_id": book_id,
                "vod_name": info.get("title") or "",
                "vod_pic": info.get("titlepic") or "",
                "type_name": "",
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": str(len(play_urls)) + "集",
                "vod_actor": info.get("playadmin") or "",
                "vod_director": "",
                "vod_content": info.get("moviesay") or "",
                "vod_play_from": "书音FM",
                "vod_play_url": "#".join(play_urls),
            }
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        try:
            page = int(pg) if pg else 1
            q = urllib.parse.urlencode({
                "mod": "movie",
                "act": "search",
                "keyword": str(key),
                "page": str(page),
                "pagesize": "20",
            })
            return {"list": self._rows(self._get_json(self.api + "?" + q)), "page": page}
        except Exception:
            return {"list": []}

    def playerContent(self, flag, id, vipFlags=None):
        try:
            raw = str(id).strip()
            bid, cid = raw.split("|", 1)
            t = str(int(time.time()))
            raw_sign = "act=wapseries&id=%s&mod=movie&movieId=%s&t=%s&token=%s" % (bid, cid, t, SIGN_KEY)
            token = hashlib.md5(raw_sign.encode("utf-8")).hexdigest()
            url = "%s?act=wapseries&mod=movie&id=%s&movieId=%s&t=%s&token=%s" % (
                self.api, bid, cid, t, token)
            data = self._get_json(url)
            d = data.get("data") or {}
            play_url = d.get("SeriesUrl") or ""
            if not play_url:
                signed = d.get("signed_urls") or []
                if signed:
                    play_url = signed[0]
            if not play_url:
                return {"parse": 0, "url": "", "playUrl": "", "header": {}}
            return {
                "parse": 0,
                "url": play_url,
                "playUrl": play_url,
                "header": {
                    "User-Agent": self.headers["User-Agent"],
                    "Referer": "https://m.shuyinfm.com/",
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
