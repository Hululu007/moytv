import json
import urllib.error
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from spider import BaseSpider
    except Exception:
        class BaseSpider:
            pass


class Spider(BaseSpider):
    def getName(self):
        return "ASMR MOON"

    def getDependence(self):
        return []

    def init(self, extend=""):
        self._base = "https://asmrmoon.com"
        self._ua = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
        self._cats = [("/中文音声", "中文音声"), ("/日韩音声", "日韩音声"), ("/English", "English")]
        self._audio_ext = (".mp3", ".flac", ".m4a", ".wav", ".ogg", ".aac", ".opus", ".wma")
        self._video_ext = (".mp4", ".mkv", ".avi", ".mov", ".flv", ".ts", ".m4v", ".webm")

    def destroy(self):
        pass

    def _post(self, path, payload, timeout=30, retries=4):
        data = json.dumps(payload).encode("utf-8")
        headers = {"User-Agent": self._ua, "Content-Type": "application/json", "Accept": "application/json", "Connection": "close"}
        last = None
        for attempt in range(retries + 1):
            try:
                req = urllib.request.Request(self._base + path, data=data, headers=headers, method="POST")
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    raw = r.read()
                return json.loads(raw.decode("utf-8", "replace"))
            except Exception as e:
                partial = getattr(e, "partial", None)
                if partial:
                    try:
                        return json.loads(partial.decode("utf-8", "replace"))
                    except Exception:
                        pass
                last = e
                import time
                time.sleep(1 << attempt)
        raise last

    def _list_dir(self, path, pg=1, per_page=30):
        d = self._post("/api/fs/list", {"path": path, "page": int(pg), "per_page": per_page, "refresh": False})
        data = d.get("data") or {}
        return data.get("content") or [], data

    def _is_media(self, entry):
        name = (entry.get("name") or "").lower()
        if entry.get("is_dir"):
            return False
        if entry.get("type") in (2, 3):
            return True
        return name.endswith(self._audio_ext + self._video_ext)

    def _size_str(self, size):
        try:
            size = int(size or 0)
        except Exception:
            return ""
        if size <= 0:
            return ""
        if size >= 1073741824:
            return "%.1fGB" % (size / 1073741824.0)
        if size >= 1048576:
            return "%.1fMB" % (size / 1048576.0)
        if size >= 1024:
            return "%dKB" % (size // 1024)
        return "%dB" % size

    def _card(self, entry, parent):
        name = entry.get("name") or ""
        path = parent.rstrip("/") + "/" + name
        if entry.get("is_dir"):
            return {
                "vod_id": "dir:" + path,
                "vod_name": name,
                "vod_pic": "",
                "vod_remarks": "",
                "vod_tag": "folder",
            }
        return {
            "vod_id": "file:" + path,
            "vod_name": name,
            "vod_pic": "",
            "vod_remarks": self._size_str(entry.get("size")),
        }

    def homeContent(self, filter=False):
        cats = [{"type_id": tid, "type_name": name} for tid, name in self._cats]
        return {"class": cats, "filters": {}}

    def homeVideoContent(self):
        videos = []
        try:
            entries, _ = self._list_dir("/中文音声", 1, 12)
            for e in entries:
                if e.get("is_dir"):
                    videos.append(self._card(e, "/中文音声"))
        except Exception:
            videos = []
        return {"list": videos}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        if extend is None:
            extend = {}
        pg = int(pg or 1)
        path = str(tid or "")
        if path.startswith("dir:"):
            path = path[4:]
        if not path.startswith("/"):
            path = "/" + path
        entries, data = self._list_dir(path, pg, 30)
        videos = []
        for e in entries:
            if e.get("is_dir") or self._is_media(e):
                videos.append(self._card(e, path))
        try:
            pagecount = int(data.get("pages_total") or pg)
        except Exception:
            pagecount = pg
        if pagecount < pg:
            pagecount = pg
        return {"list": videos, "page": pg, "pagecount": pagecount, "limit": 30, "total": 999999}

    def _walk_files(self, path, depth=0, cap=200, out=None):
        if out is None:
            out = []
        if depth > 3 or len(out) >= cap:
            return out
        try:
            entries, _ = self._list_dir(path, 1, 200)
        except Exception:
            return out
        for e in entries:
            if len(out) >= cap:
                break
            name = e.get("name") or ""
            child = path.rstrip("/") + "/" + name
            if e.get("is_dir"):
                self._walk_files(child, depth + 1, cap, out)
            elif self._is_media(e):
                rel = child[len(path.rstrip("/")) + 1:]
                out.append((rel, child))
        return out

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            vid = str(ids[0]) if ids else ""
        else:
            vid = str(ids)
        if vid.startswith("file:"):
            path = vid[5:]
            name = path.rsplit("/", 1)[-1]
            vod = {
                "vod_id": vid,
                "vod_name": name,
                "vod_pic": "",
                "vod_remarks": "",
                "vod_content": path,
                "vod_play_from": "ASMR",
                "vod_play_url": "%s$%s" % (name, path),
            }
            return {"list": [vod]}
        if vid.startswith("dir:"):
            path = vid[4:]
        else:
            path = vid if vid.startswith("/") else "/" + vid
        name = path.rstrip("/").rsplit("/", 1)[-1] or path
        files = self._walk_files(path)
        eps = []
        for rel, child in files:
            ep_name = rel.replace("#", "_").replace("$", "_")
            eps.append("%s$%s" % (ep_name, child))
        vod = {
            "vod_id": "dir:" + path,
            "vod_name": name,
            "vod_pic": "",
            "vod_remarks": "%d首" % len(files) if files else "",
            "vod_content": path,
            "vod_play_from": "ASMR",
            "vod_play_url": "#".join(eps),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1):
        pg = int(pg or 1)
        d = self._post("/api/fs/search", {"parent": "/", "keywords": key, "scope": 0, "page": pg, "per_page": 30})
        items = (d.get("data") or {}).get("content") or []
        videos = []
        seen = set()
        for e in items:
            parent = e.get("parent") or ""
            name = e.get("name") or ""
            path = parent.rstrip("/") + "/" + name
            if path in seen:
                continue
            seen.add(path)
            if e.get("is_dir"):
                videos.append({
                    "vod_id": "dir:" + path,
                    "vod_name": name,
                    "vod_pic": "",
                    "vod_remarks": parent,
                    "vod_tag": "folder",
                })
            elif self._is_media(e):
                videos.append({
                    "vod_id": "file:" + path,
                    "vod_name": name,
                    "vod_pic": "",
                    "vod_remarks": self._size_str(e.get("size")),
                })
        pagecount = pg + 1 if len(items) >= 30 else pg
        return {"list": videos, "page": pg, "pagecount": pagecount, "limit": 30, "total": 999999}

    def playerContent(self, flag, id, vipFlags=None):
        if vipFlags is None:
            vipFlags = []
        path = str(id)
        if path.startswith("file:"):
            path = path[5:]
        d = self._post("/api/fs/get", {"path": path, "password": ""})
        data = d.get("data") or {}
        url = data.get("raw_url") or ""
        if not url:
            raise RuntimeError("no raw_url for %s" % path)
        return {
            "parse": 0,
            "url": url,
            "header": {"User-Agent": self._ua, "Referer": self._base + "/"},
        }

    def localProxy(self, param):
        if isinstance(param, dict):
            action = param.get("action", "")
            url = param.get("url", "")
        else:
            action = ""
            url = str(param or "")
        if action in ("", "proxy") and url:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": self._ua})
                with urllib.request.urlopen(req, timeout=30) as r:
                    body = r.read()
                    ctype = r.headers.get_content_type() or "application/octet-stream"
                    return [200, ctype, body, {}]
            except Exception as e:
                return [500, "text/plain", str(e).encode(), {}]
        if action == "play":
            return self.playerContent(param.get("flag", ""), param.get("id", ""))
        return [200, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        url = (url or "").lower().split("?")[0]
        return url.endswith(self._audio_ext + self._video_ext + (".m3u8",))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
