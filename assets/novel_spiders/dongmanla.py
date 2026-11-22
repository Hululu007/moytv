# -*- coding: utf-8 -*-
# 动漫啦（m.dongman.la）— 由真果鉴 Venera 源 dongmanla.js 移植（适配 2026-10 新版页面）
import base64
import gzip
import json
import re
import urllib.parse
import urllib.request
import zlib

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASE = "https://m.dongman.la"
UA = ("Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

CATEGORIES = [
    ("manhua/serial/", "最近更新"), ("manhua/japan/", "日本"), ("manhua/hongkongtaiwan/", "港台"),
    ("manhua/oumei/", "欧美"), ("manhua/guochan/", "国产"), ("manhua/hanguo/", "韩漫"),
    ("manhua/finish/", "已完结"), ("manhua/class/32/", "热血"), ("manhua/class/24/", "爱情"),
    ("manhua/class/18/", "校园"), ("manhua/class/16/", "格斗"), ("manhua/class/17/", "竞技"),
    ("manhua/class/19/", "恐怖"), ("manhua/class/20/", "悬疑"), ("manhua/class/21/", "奇幻"),
    ("manhua/class/22/", "魔法"), ("manhua/class/23/", "神鬼"), ("manhua/class/25/", "搞笑"),
    ("manhua/class/27/", "耽美"), ("manhua/class/29/", "历史"), ("manhua/class/30/", "战争"),
    ("manhua/class/33/", "后宫"), ("manhua/class/34/", "魔幻"), ("manhua/class/35/", "美食"),
    ("manhua/class/37/", "萌系"), ("manhua/class/38/", "百合"), ("manhua/class/42/", "治愈"),
    ("manhua/class/43/", "少女"), ("manhua/class/45/", "职场"), ("manhua/class/46/", "侦探"),
    ("manhua/class/47/", "机战"), ("manhua/class/48/", "青年"), ("manhua/class/49/", "少年"),
]

_COVER_RE = re.compile(r'<a[^>]*href="(/manhua/detail/[^"]+)"[^>]*title="([^"]*)"[^>]*>\s*'
                       r'(?:<div[^>]*>\s*)?<img[^>]*(?:data-cover|data-src|src)="([^"]+)"', re.S)
_BARE_RE = re.compile(r'<a[^>]*href="(/manhua/detail/[^"]+)"[^>]*title="([^"]*)"', re.S)


def _get(url, referer=""):
    headers = {
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept-Encoding": "gzip, deflate",
    }
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read()
        enc = (r.headers.get("Content-Encoding") or "").lower()
        if "gzip" in enc:
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        elif "deflate" in enc:
            try:
                raw = zlib.decompress(raw)
            except Exception:
                try:
                    raw = zlib.decompress(raw, -zlib.MAX_WBITS)
                except Exception:
                    pass
        return raw.decode("utf-8", "replace"), r.geturl()


def _abs(path):
    if not path:
        return ""
    if path.startswith("http"):
        return path
    if path.startswith("//"):
        return "https:" + path
    return BASE + (path if path.startswith("/") else "/" + path)


def _parse_list(html):
    items, seen = [], set()
    covers = {}
    for m in _COVER_RE.finditer(html):
        covers.setdefault(m.group(1), m.group(3))
    for m in _BARE_RE.finditer(html):
        href, title = m.group(1), re.sub(r'<[^>]+>', '', m.group(2)).strip()
        if not title or href in seen:
            continue
        seen.add(href)
        items.append({
            "vod_id": href,
            "vod_name": title,
            "vod_pic": _abs(covers.get(href, "")),
            "vod_remarks": "",
            "vod_content": "",
            "vod_tag": "image",
        })
    return items


class Spider(BaseSpider):
    def getName(self):
        return "动漫啦"

    def getDependence(self):
        return []

    def init(self, extend=None):
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        return {"class": [{"type_id": k, "type_name": n} for k, n in CATEGORIES], "filters": {}}

    def homeVideoContent(self, *args, **kwargs):
        return {"list": []}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = max(1, int(pg or 1))
        path = str(tid or "manhua/serial/").strip("/")
        url = "%s/%s/" % (BASE, path)
        if pg > 1:
            url += "?page=%d" % pg
        try:
            html, _ = _get(url)
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 24, "total": 0}
        items = _parse_list(html)
        return {"list": items, "page": pg, "pagecount": pg + 1 if items else pg, "limit": 24, "total": len(items)}

    def detailContent(self, ids):
        raw = ids if not isinstance(ids, (list, tuple)) else (ids[0] if ids else "")
        raw = str(raw or "").strip()
        if raw.startswith("dongmanla:"):
            raw = raw[len("dongmanla:"):]
        if not raw:
            return {"list": []}
        url = _abs(raw)
        try:
            html, final = _get(url)
        except Exception:
            return {"list": []}

        m = re.search(r'<h1[^>]*itemprop="name"[^>]*>(.*?)</h1>', html, re.S) or re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
        title = re.sub(r'<[^>]+>', '', m.group(1)).strip() if m else ""
        if not title:
            return {"list": []}

        cover = ""
        for mm in re.finditer(r'<img[^>]+>', html):
            tag = mm.group(0)
            if "封面" in tag:
                mc = re.search(r'(?:data-cover|data-src|src)="([^"]+)"', tag)
                if mc:
                    cover = mc.group(1)
                    break

        desc = ""
        m = re.search(r'<p[^>]*itemprop="description"[^>]*>(.*?)</p>', html, re.S)
        if m:
            desc = re.sub(r'<[^>]+>', '', m.group(1)).strip()

        author = ""
        m = re.search(r'itemprop="author"[^>]*>(.*?)<', html, re.S)
        if m:
            author = re.sub(r'<[^>]+>', '', m.group(1)).strip()

        chapters, seen = [], set()
        for m in re.finditer(r'<a[^>]*href="(/manhua/chapter/[^"]+)"[^>]*>(.*?)</a>', html, re.S):
            href = m.group(1)
            label = re.sub(r'<[^>]+>', '', m.group(2)).strip()
            if href in seen:
                continue
            seen.add(href)
            if not label or "开始阅读" in label or "阅读" == label:
                label = "第%d话" % (len(chapters) + 1)
            chapters.append((href, label))
        chapters.reverse()
        if not chapters:
            return {"list": []}

        play = "#".join("%s$dongmanla:%s" % (label.replace("$", " "), href) for href, label in chapters)
        return {"list": [{
            "vod_id": raw,
            "vod_name": title,
            "vod_pic": _abs(cover),
            "vod_actor": author,
            "vod_director": "",
            "vod_remarks": "",
            "vod_year": "",
            "vod_area": "",
            "vod_content": desc,
            "type_name": "",
            "vod_tag": "image",
            "vod_play_from": "漫画",
            "vod_play_url": play,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = max(1, int(pg or 1))
        url = "%s/manhua/so/%s/" % (BASE, urllib.parse.quote(str(key or "")))
        if pg > 1:
            url += "?page=%d" % pg
        try:
            html, _ = _get(url)
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 24, "total": 0}
        items = _parse_list(html)
        if not items:
            # 新版站搜索走 /manhua/search/
            try:
                html, _ = _get("%s/manhua/search/?key=%s" % (BASE, urllib.parse.quote(str(key or ""))))
                items = _parse_list(html)
            except Exception:
                items = []
        return {"list": items, "page": pg, "pagecount": pg + 1 if items else pg, "limit": 24, "total": len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "")
        if "$" in raw:
            raw = raw.split("$", 1)[1]
        if raw.startswith("dongmanla:"):
            raw = raw[len("dongmanla:"):]
        if raw.startswith("pics://"):
            header = {"User-Agent": UA, "Referer": BASE + "/"}
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        url = _abs(raw)
        header = {"User-Agent": UA, "Referer": BASE + "/"}
        imgs = []
        for suffix in ("all.html", ""):
            if raw.startswith("http"):
                page = raw + suffix if suffix else raw
            else:
                page = _abs(raw.rstrip("/") + "/" + suffix) if suffix else url
            try:
                html, final = _get(page, BASE + "/")
            except Exception:
                continue
            for tag in re.findall(r'<img[^>]+>', html):
                m = re.search(r'(?:data-src|src)="(https?://img\.dongman\.la/[^"]+)"', tag)
                if m and m.group(1) not in imgs:
                    imgs.append(m.group(1))
            if imgs:
                header["Referer"] = final or page
                break
        if not imgs:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        pics = "pics://" + "&&".join(imgs)
        return {"parse": 0, "playUrl": pics, "url": pics, "header": header}

    def localProxy(self, param):
        try:
            target, ref, want_b64 = "", "", False
            p = param
            if isinstance(p, str):
                text = p.strip()
                if text.startswith("{"):
                    try:
                        p = json.loads(text)
                    except Exception:
                        p = {}
                elif text.startswith("http"):
                    target = text
                else:
                    p = dict(urllib.parse.parse_qsl(text))
            if isinstance(p, dict):
                target = str(p.get("u") or p.get("url") or "")
                ref = str(p.get("r") or p.get("referer") or "")
                want_b64 = str(p.get("b64") or p.get("base64") or "") == "1"
            if not target:
                return [404, "text/plain", b"", {}]
            req = urllib.request.Request(target, headers={
                "User-Agent": UA,
                "Referer": ref or (BASE + "/"),
                "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            })
            with urllib.request.urlopen(req, timeout=20) as r:
                data = r.read()
                ctype = r.headers.get("Content-Type") or "image/jpeg"
            if not data:
                return [404, "text/plain", b"", {}]
            if want_b64:
                return [200, ctype, base64.b64encode(data).decode("ascii"), {}, 1]
            return [200, ctype, data, {}]
        except Exception:
            return [404, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self, *args, **kwargs):
        return False

    def action(self, *args, **kwargs):
        return {}
