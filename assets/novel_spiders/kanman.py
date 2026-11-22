# -*- coding: utf-8 -*-
# 看漫画（m.kanman.com）— 由真果鉴 Venera 源 kanman.js 移植
import base64
import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASE = "https://m.kanman.com"
UA = ("Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

CATEGORIES = [
    ("rexue", "热血"), ("xuanhuan", "玄幻"), ("lianai", "恋爱"), ("gufeng", "古风"),
    ("gaoxiao", "搞笑"), ("chuanyue", "穿越"), ("xiuzhen", "修真"), ("dushi", "都市"),
    ("maoxian", "冒险"), ("shenghuo", "生活"), ("mangai", "漫改"), ("bazong", "霸总"),
    ("shenmo", "神魔"), ("wuxia", "武侠"), ("kehuan", "科幻"), ("youxi", "游戏"),
    ("dongzuo", "动作"), ("xuanyi", "悬疑"), ("zhanzhen", "战争"), ("lishi", "历史"),
    ("lianzai", "连载"), ("wanjie", "完结"), ("jingpin", "精品"),
]

_IMG_LIST_RE = re.compile(r"chapter_img_list\s*:\s*\[(.*?)\]", re.S)
_STR_RE = re.compile(r'"([^"]+)"')


def _get(url, referer=""):
    headers = {
        "User-Agent": UA,
        "Accept": "application/json, text/html, */*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "X-Requested-With": "XMLHttpRequest",
    }
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read()
        return raw.decode("utf-8", "replace"), r.geturl()


def _cover(cid, given=""):
    if given and given.startswith("http"):
        return given.replace("http://", "https://", 1)
    return "https://image.yqmh.com/mh/%s.jpg-300x400.jpg" % cid


def _item(entry):
    cid = str(entry.get("comic_id") or "")
    if not cid:
        return None
    tags = []
    for part in str(entry.get("comic_type") or "").split("|"):
        seg = part.split(",")
        name = (seg[1] if len(seg) > 1 else seg[0]).strip()
        if name and name not in tags:
            tags.append(name)
    return {
        "vod_id": cid,
        "vod_name": str(entry.get("comic_name") or "") .strip(),
        "vod_pic": _cover(cid, str(entry.get("cover_img") or "")),
        "vod_remarks": str(entry.get("last_chapter_name") or "")[:40],
        "vod_content": str(entry.get("cartoon_desc") or "").strip(),
        "vod_actor": str(entry.get("comic_author") or ""),
        "type_name": " ".join(tags[:3]),
        "vod_tag": "image",
    }


def _list_from_api(body):
    try:
        data = json.loads(body)
    except Exception:
        return []
    rows = ((data or {}).get("data") or {}).get("data") or []
    out = []
    for entry in rows:
        if isinstance(entry, dict):
            it = _item(entry)
            if it:
                out.append(it)
    return out


class Spider(BaseSpider):
    def getName(self):
        return "看漫画"

    def getDependence(self):
        return []

    def init(self, extend=None):
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        return {
            "class": [{"type_id": k, "type_name": n} for k, n in CATEGORIES],
            "filters": {},
        }

    def homeVideoContent(self, *args, **kwargs):
        return {"list": []}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = max(1, int(pg or 1))
        url = ("%s/api/getsortlist/?orderby=click&search_key=&comic_sort=%s&size=30&page=%d"
               % (BASE, urllib.parse.quote(str(tid or "")), pg))
        try:
            body, _ = _get(url, BASE + "/")
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 30, "total": 0}
        items = _list_from_api(body)
        return {
            "list": items,
            "page": pg,
            "pagecount": pg + 1 if items else pg,
            "limit": 30,
            "total": len(items),
        }

    def detailContent(self, ids):
        cid = re.sub(r"\D", "", str(ids if not isinstance(ids, (list, tuple)) else (ids[0] if ids else "")))
        if not cid:
            return {"list": []}
        url = "%s/%s/" % (BASE, cid)
        try:
            html, final = _get(url)
        except Exception:
            return {"list": []}

        title = ""
        m = re.search(r'id="js_comic_id"[^>]*>([^<]+)<', html)
        if m:
            title = m.group(1).strip()
        if not title:
            m = re.search(r'<h1[^>]*class="[^"]*comic-title[^"]*"[^>]*>(.*?)</h1>', html, re.S)
            if m:
                title = re.sub(r"<[^>]+>", "", m.group(1)).strip()
        if not title:
            return {"list": []}

        pic = ""
        m = re.search(r'class="comic-detail-cover[^"]*".*?<img[^>]+>', html, re.S)
        if m:
            mm = re.search(r'data-src="([^"]+)"', m.group(0)) or re.search(r'src="([^"]+)"', m.group(0))
            if mm:
                pic = mm.group(1)

        desc = ""
        m = re.search(r'id="js_desc_content"[^>]*>(.*?)</', html, re.S)
        if m:
            desc = re.sub(r"<[^>]+>", "", m.group(1)).strip()

        authors = []
        m = re.search(r'<ul[^>]*class="[^"]*comic-figure[^"]*"[^>]*>(.*?)</ul>', html, re.S)
        if m:
            for name in re.findall(r'class="[^"]*figcaption-title[^"]*"[^>]*>.*?<a[^>]*>([^<]+)<', m.group(1), re.S):
                name = name.strip()
                if name and name not in authors:
                    authors.append(name)

        tags = []
        for t in re.findall(r'class="comic-tags".*?</ul>', html, re.S):
            for name in re.findall(r'>([^<>]{2,12})</a>', t):
                name = name.strip()
                if name and name not in tags:
                    tags.append(name)

        chapters = []
        for li in re.findall(r'<li[^>]*class="[^"]*item[^"]*"[^>]*data-index="(\d+)"[^>]*>(.*?)</li>', html, re.S):
            idx, block = li
            a = re.search(r'<a[^>]*href="([^"]+)"[^>]*>', block)
            if not a:
                continue
            href = a.group(1)
            nm = re.search(r'title="([^"]+)"', a.group(0))
            label = nm.group(1).strip() if nm else re.sub(r"<[^>]+>", "", block).strip()
            if not href or not label:
                continue
            if not href.startswith("http") and not href.startswith("/"):
                href = "/%s/%s" % (cid, href)
            chapters.append((int(idx), href, label))
        # 有些页面 li 没带 data-index，退回文档顺序
        if not chapters:
            for a in re.findall(r'<a[^>]*class="[^"]*chapter-name[^"]*"[^>]*>', html):
                href = (re.search(r'href="([^"]+)"', a) or [None, ""])[1] if re.search(r'href="([^"]+)"', a) else ""
                label = (re.search(r'title="([^"]+)"', a).group(1) if re.search(r'title="([^"]+)"', a) else "").strip()
                if href and label:
                    chapters.append((len(chapters) + 1, href if href.startswith("/") else "/%s/%s" % (cid, href), label))
        chapters.sort(key=lambda x: x[0])
        if not chapters:
            return {"list": []}

        play = "#".join("%s$kanman:%s" % (label.replace("$", " "), href) for _, href, label in chapters)
        return {"list": [{
            "vod_id": cid,
            "vod_name": title,
            "vod_pic": _cover(cid, pic),
            "vod_actor": "/".join(authors),
            "vod_director": "",
            "vod_remarks": "",
            "vod_year": "",
            "vod_area": "",
            "vod_content": desc,
            "type_name": " ".join(tags[:4]),
            "vod_tag": "image",
            "vod_play_from": "漫画",
            "vod_play_url": play,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = max(1, int(pg or 1))
        url = ("%s/api/getsortlist/?orderby=click&search_key=%s&size=30&page=%d"
               % (BASE, urllib.parse.quote(str(key or "")), pg))
        try:
            body, _ = _get(url, BASE + "/")
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 30, "total": 0}
        items = _list_from_api(body)
        return {
            "list": items,
            "page": pg,
            "pagecount": pg + 1 if items else pg,
            "limit": 30,
            "total": len(items),
        }

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "")
        if "$" in raw:
            raw = raw.split("$", 1)[1]
        if raw.startswith("kanman:"):
            raw = raw[len("kanman:"):]
        header = {"User-Agent": UA, "Referer": BASE + "/"}
        if raw.startswith("pics://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        url = raw if raw.startswith("http") else BASE + (raw if raw.startswith("/") else "/" + raw)
        try:
            html, final = _get(url, BASE + "/")
        except Exception:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        m = _IMG_LIST_RE.search(html)
        imgs = []
        if m:
            for u in _STR_RE.findall(m.group(1)):
                u = u.replace("\\/", "/").strip()
                if u.startswith("http") and u not in imgs:
                    imgs.append(u)
        if not imgs:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        pics = "pics://" + "&&".join(imgs)
        return {"parse": 0, "playUrl": pics, "url": pics, "header": header}

    def localProxy(self, param):
        try:
            target = ""
            want_b64 = False
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
                want_b64 = str(p.get("b64") or p.get("base64") or "") == "1"
            if not target:
                return [404, "text/plain", b"", {}]
            req = urllib.request.Request(target, headers={
                "User-Agent": UA,
                "Referer": BASE + "/",
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
