# -*- coding: utf-8 -*-
# 知音漫客（m.zymk.cn）— 由真果鉴 Venera 源 zymk.js 移植
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

BASE = "https://m.zymk.cn"
COVER_ROOT = "https://chapter-cover.yyhao.com/file/cover"
PIC_HOST = "https://mhpic.yyhao.com/comic/"
UA = ("Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

CATEGORIES = [
    ("all", "全部"), ("5", "热血"), ("6", "搞笑"), ("7", "玄幻"), ("8", "生活"),
    ("9", "恋爱"), ("10", "动作"), ("12", "战争"), ("16", "历史"), ("17", "穿越"),
    ("18", "后宫"), ("20", "都市"), ("22", "漫改"), ("23", "连载"), ("24", "完结"),
    ("25", "少男"), ("26", "少女"), ("27", "青年"), ("53", "修真"), ("62", "霸总"),
    ("63", "古风"), ("64", "游戏"), ("66", "武侠"),
]


def _get(url, referer=""):
    headers = {
        "User-Agent": UA,
        "Accept": "application/json, text/html, */*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept-Encoding": "gzip, deflate",
        "X-Requested-With": "XMLHttpRequest",
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


def _cover(cid):
    s = str(cid)
    s = s.zfill(9)
    return "%s/%s/%s/%s.jpg-300x400" % (COVER_ROOT, s[:3], s[3:6], s[6:9])


def _items_from_json(body):
    try:
        data = json.loads(body)
    except Exception:
        return []
    rows = (((data or {}).get("data") or {}).get("page") or {}).get("comic_list") or []
    out = []
    for it in rows:
        cid = str(it.get("comic_id") or "")
        if not cid:
            continue
        last = (it.get("last_chapter") or {}).get("name") or ""
        out.append({
            "vod_id": cid,
            "vod_name": str(it.get("comic_name") or "").strip(),
            "vod_pic": _cover(cid),
            "vod_remarks": ("更新至 " + last)[:40] if last else "",
            "vod_content": str(it.get("comic_feature") or "").strip(),
            "vod_tag": "image",
        })
    return out


class Spider(BaseSpider):
    def getName(self):
        return "知音漫客"

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
        url = "%s/apinew/getsortlist_new?type=%s&sort=click&page=%d&client-type=wap" % (
            BASE, urllib.parse.quote(str(tid or "all")), pg)
        try:
            body, _ = _get(url, BASE + "/")
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 30, "total": 0}
        items = _items_from_json(body)
        return {"list": items, "page": pg, "pagecount": pg + 1 if items else pg, "limit": 30, "total": len(items)}

    def detailContent(self, ids):
        raw = ids if not isinstance(ids, (list, tuple)) else (ids[0] if ids else "")
        cid = re.sub(r"\D", "", str(raw or ""))
        if not cid:
            return {"list": []}
        url = "%s/%s/" % (BASE, cid)
        try:
            html, final = _get(url)
        except Exception:
            return {"list": []}

        m = re.search(r'<h1[^>]*class="[^"]*name[^"]*"[^>]*>(.*?)</h1>', html, re.S)
        title = re.sub(r'<[^>]+>', '', m.group(1)).strip() if m else ""
        if not title:
            return {"list": []}

        cover = ""
        m = re.search(r'class="[^"]*comic-info[^"]*"[^>]*>(.*?)</div>', html, re.S)
        if m:
            mc = re.search(r'<img[^>]*(?:data-src|src)="([^"]+)"', m.group(1))
            if mc:
                cover = mc.group(1)

        if not cover or cover.endswith('.gif'):
            cover = _cover(cid)

        author = ""
        m = re.search(r'<span[^>]*class="[^"]*author[^"]*"[^>]*>(.*?)</span>', html, re.S)
        if m:
            author = re.sub(r'<[^>]+>', '', m.group(1)).strip()

        desc = ""
        m = re.search(r'class="[^"]*comic-detail[^"]*".*?<p[^>]*class="[^"]*content[^"]*"[^>]*>(.*?)</p>', html, re.S)
        if m:
            desc = re.sub(r'<[^>]+>', '', m.group(1)).strip()

        tags = []
        m = re.search(r'class="[^"]*tags-box[^"]*"(.*?)</ul>', html, re.S)
        if m:
            for t in re.findall(r'<a[^>]*>([^<]+)</a>', m.group(1)):
                t = t.strip()
                if t and t not in tags:
                    tags.append(t)

        chapters = []
        for m in re.finditer(r'<a[^>]*class="[^"]*chapterBtn[^"]*"[^>]*href="([^"]+)"[^>]*title="([^"]*)"', html):
            href, label = m.group(1), m.group(2).strip()
            if not href:
                continue
            if href.startswith("./"):
                href = href[2:]
            if not href.startswith("http") and not href.startswith("/"):
                href = "/%s/%s" % (cid, href)
            chapters.append((href, label or "第%d话" % (len(chapters) + 1)))
        chapters.reverse()
        if not chapters:
            return {"list": []}

        play = "#".join("%s$zymk:%s" % (label.replace("$", " "), href) for href, label in chapters)
        return {"list": [{
            "vod_id": cid,
            "vod_name": title,
            "vod_pic": cover or _cover(cid),
            "vod_actor": author,
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
        url = "%s/apinew/getsortlist_new?key=%s&page=%d&client-type=wap" % (
            BASE, urllib.parse.quote(str(key or "")), pg)
        try:
            body, _ = _get(url, BASE + "/")
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 30, "total": 0}
        items = _items_from_json(body)
        return {"list": items, "page": pg, "pagecount": pg + 1 if items else pg, "limit": 30, "total": len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "")
        if "$" in raw:
            raw = raw.split("$", 1)[1]
        if raw.startswith("zymk:"):
            raw = raw[len("zymk:"):]
        if raw.startswith("pics://"):
            header = {"User-Agent": UA, "Referer": BASE + "/"}
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        url = raw if raw.startswith("http") else BASE + (raw if raw.startswith("/") else "/" + raw)
        header = {"User-Agent": UA, "Referer": BASE + "/"}
        try:
            html, final = _get(url, BASE + "/")
        except Exception:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}

        m = re.search(r'start_var\s*:\s*(\d+)\s*,\s*end_var\s*:\s*(\d+)', html)
        if not m:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        start, end = int(m.group(1)), int(m.group(2))
        if end < start:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}

        host = PIC_HOST
        dm = re.search(r'domain\s*:\s*"([^"]+)"', html)
        if dm and dm.group(1):
            host = "https://mhpic." + dm.group(1) + "/comic/"

        addr, suffix = "", ""
        am = re.search(r'chapter_addr_original\s*:\s*"([^"]*)"', html)
        if am and am.group(1):
            addr = am.group(1)
            sm = re.search(r'image_suffix\s*:\s*"([^"]*)"', html)
            cm = re.search(r'comic_size\s*:\s*"([^"]*)"', html)
            suffix = (sm.group(1) if sm and sm.group(1) else ".jpg") + (cm.group(1) if cm and cm.group(1) else "-zymk.middle")
        else:
            tm = re.search(r'chapter_image\s*:\s*\{[^}]*?middle\s*:\s*"([^"]+)"', html)
            if tm and tm.group(1):
                tpl = tm.group(1)
                p = tpl.find("$$")
                if p >= 0:
                    addr = tpl[:p]
                    suffix = re.sub(r'\.webp$', '', tpl[p + 2:], flags=re.I)
        if not addr or not suffix:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}

        addr_q = urllib.parse.quote(addr, safe="/")
        imgs = [host + addr_q + str(n) + suffix for n in range(start, end + 1)]
        pics = "pics://" + "&&".join(imgs)
        header["Referer"] = final or url
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
