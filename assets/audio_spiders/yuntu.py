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
        self.seg = "wechat:07955551-706c-4259-9aa0-db4627dfca57"
        self.base = "https://open-service.yuntuys.com/api/w_ys/book"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
            "Referer": "https://yuntuwechat.yuntuys.com/",
            "Origin": "https://yuntuwechat.yuntuys.com",
            "Accept": "application/json, text/plain, */*",
        }
        self.classes = [
            ("124", "听见真知"),
            ("125", "豆瓣高分"),
            ("126", "广播剧"),
            ("127", "影视同期"),
            ("131", "世界名著"),
            ("132", "中国文学"),
            ("142", "悬疑推理"),
            ("152", "儿童文学"),
            ("165", "古代历史"),
            ("148", "创业学院"),
            ("181", "养生保健"),
            ("585", "四史专栏"),
            ("571", "远读重洋"),
        ]

    def getName(self):
        return "云图听书"

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
            bid = b.get("bookId")
            if bid is None:
                continue
            chapters = b.get("chapters")
            videos.append({
                "vod_id": str(bid),
                "vod_name": b.get("bookName") or "",
                "vod_pic": b.get("cover") or "",
                "vod_remarks": (str(chapters) + "章") if chapters else (b.get("anchorName") or ""),
                "vod_actor": b.get("authorName") or "",
                "vod_content": b.get("summary") or "",
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
            url = "%s/getBookListByType/%s/%s?pageNum=%d&pageSize=20" % (self.base, self.seg, tid, page)
            videos = self._rows(self._get_json(url))
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
            book_id = ids[0] if isinstance(ids, list) else ids
            play_urls = []
            page = 1
            total_page = 1
            while page <= total_page and page <= 60:
                url = "%s/getChapters/%s/%s/true/asc?pageSize=200&pageNum=%d" % (
                    self.base, self.seg, book_id, page)
                data = self._get_json(url)
                pq = ((data.get("data") or {}).get("pageQuery")) or {}
                total_page = int(pq.get("totalPage") or 1)
                for c in pq.get("list") or []:
                    if not isinstance(c, dict):
                        continue
                    u = c.get("audioUrl") or ""
                    if not u and c.get("audio"):
                        u = "https://qiniustorage.yuntuys.com/" + str(c.get("audio")).lstrip("/")
                    if not u:
                        continue
                    title = self._title(c.get("name") or "第" + str(len(play_urls) + 1) + "章")
                    play_urls.append(title + "$" + u)
                page += 1
            vod = {
                "vod_id": "",
                "vod_name": "",
                "vod_pic": "",
                "type_name": "",
                "vod_year": "",
                "vod_area": "",
                "vod_remarks": str(len(play_urls)) + "章",
                "vod_actor": "",
                "vod_director": "",
                "vod_content": "",
                "vod_play_from": "云图听书",
                "vod_play_url": "#".join(play_urls),
            }
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick=False, pg=1):
        try:
            page = int(pg) if pg else 1
            url = "%s/search/%s/%s?pageSize=20&pageNum=%d" % (
                self.base, self.seg, urllib.parse.quote(str(key)), page)
            return {"list": self._rows(self._get_json(url)), "page": page}
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
                "Referer": "https://yuntuwechat.yuntuys.com/",
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
