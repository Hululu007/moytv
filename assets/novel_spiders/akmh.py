import base64
import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests as _requests
except Exception:
    _requests = None

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

BASES = ["https://www.eemh.cc", "https://www.eemh.net"]
UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"

CATEGORIES = [
    ("hanman", "韩国漫画"),
    ("riman", "日文漫画"),
    ("3d", "3D漫画"),
    ("doujin", "同人誌"),
    ("single", "单行本"),
    ("short", "短篇"),
    ("cosplay", "Cosplay"),
    ("cg", "CG漫画"),
]

FLAG_WORDS = ["萝莉", "幼女", "幼齿", "小学生", "初中生", "未成年", "思春期", "loli", "ロリ"]

_ACTIVE_BASE = [BASES[0]]


def _clean(raw):
    text = re.sub(r"<[^>]+>", "", raw or "")
    text = text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'")
    return re.sub(r"\s+", " ", text).strip()


def _flagged(text):
    low = (text or "").lower()
    for word in FLAG_WORDS:
        if word in low:
            return True
    return False


def _norm_pg(value, default=1):
    try:
        pg = int(str(value).strip())
        return pg if pg > 0 else default
    except Exception:
        return default


def _norm_id(value):
    if isinstance(value, (list, tuple)):
        return str(value[0]) if value else ""
    text = str(value or "")
    return text.split(",")[0].strip()


def _http_get(url, referer=""):
    headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=25)
            if resp.status_code == 200 and resp.content:
                return resp.content.decode("utf-8", "ignore"), str(resp.url)
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=25) as resp:
            raw = resp.read()
            final = resp.geturl()
            try:
                return raw.decode("utf-8"), final
            except Exception:
                return raw.decode("utf-8", "ignore"), final
    except Exception:
        return "", url


def _http_bytes(url, referer=""):
    headers = {"User-Agent": UA}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=25)
            if resp.status_code == 200 and resp.content:
                return bytes(resp.content), resp.headers.get("Content-Type", "")
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=25) as resp:
            return resp.read(), resp.headers.get("Content-Type", "")
    except Exception:
        return b"", ""


def _fetch(path):
    bases = [_ACTIVE_BASE[0]] + [b for b in BASES if b != _ACTIVE_BASE[0]]
    for base in bases:
        url = base + path
        text, final = _http_get(url, referer=base + "/")
        if text and len(text) > 200:
            _ACTIVE_BASE[0] = base
            return text, final, base
    return "", bases[0] + path, bases[0]


def _abs_url(src, base):
    src = (src or "").strip()
    if src.startswith("//"):
        return "https:" + src
    if src.startswith("/"):
        return base + src
    return src


def _parse_list(html, base):
    items = []
    seen = set()
    if not html:
        return items
    blocks = html.split("home-truyendecu")[1:]
    for block in blocks:
        m = re.search(r'href="/novel(\d+)/"', block)
        if not m:
            continue
        vid = m.group(1)
        if vid in seen:
            continue
        tm = re.search(r'href="/novel' + vid + r'/"[^>]*title="([^"]+)"', block)
        name = _clean(tm.group(1)) if tm else ""
        if not name:
            hm = re.search(r"<h3[^>]*>([^<]+)</h3>", block)
            name = _clean(hm.group(1)) if hm else ""
        if not name or _flagged(name):
            continue
        pic = ""
        for src in re.findall(r'<img[^>]*src="([^"]+)"', block):
            if src.startswith("http") and "/novel/images/" not in src:
                pic = src
                break
        if not pic:
            for src in re.findall(r'data-original=["\']([^"\']+)["\']', block):
                if src.startswith("http"):
                    pic = src
                    break
        remarks = ""
        rm = re.search(r"(连载中|已完结|连载|完结)", block)
        if rm:
            remarks = rm.group(1)
        seen.add(vid)
        items.append({"vod_id": vid, "vod_name": name, "vod_pic": pic, "vod_remarks": remarks})
    return items


def _pagecount(html):
    nums = [int(n) for n in re.findall(r"index_(\d+)\.html", html or "")]
    if nums:
        return max(nums)
    return 1


def _meta(html, prop):
    m = re.search(r'<meta[^>]*property="og:' + re.escape(prop) + r'"[^>]*content="([^"]*)"', html or "")
    if m:
        return _clean(m.group(1))
    m = re.search(r'<meta[^>]*content="([^"]*)"[^>]*property="og:' + re.escape(prop) + r'"', html or "")
    return _clean(m.group(1)) if m else ""


def _parse_detail(html, vid, base):
    title = _meta(html, "novel:book_name")
    if not title:
        m = re.search(r"<title>(.*?)</title>", html or "", flags=re.S)
        if m:
            title = _clean(m.group(1)).split("_")[0].strip()
    pic = _meta(html, "image")
    author = _meta(html, "novel:author")
    category = _meta(html, "novel:category")
    status = _meta(html, "novel:status")
    desc = ""
    m = re.search(r'<meta[^>]*name="description"[^>]*content="([^"]*)"', html or "")
    if m:
        desc = _clean(m.group(1))
    chapters = {}
    pat = re.compile(r'href="/novel' + re.escape(vid) + r'/chapter(\d+)\.html"[^>]*>(?:\s*<span class="chapter-text">([^<]+)</span>|[^<]*?title="([^"]*)")', re.S)
    for m in pat.finditer(html or ""):
        num = m.group(1)
        name = _clean(m.group(2) or m.group(3) or "")
        if num not in chapters:
            chapters[num] = name or ("第" + str(int(num) + 1) + "话")
    if not chapters:
        for num in re.findall(r'href="/novel' + re.escape(vid) + r'/chapter(\d+)\.html"', html or ""):
            if num not in chapters:
                chapters[num] = "第" + str(int(num) + 1) + "话"
    ordered = sorted(chapters.items(), key=lambda kv: int(kv[0]))
    return title, pic, author, category, status, desc, ordered


def _chapter_images(html):
    imgs = []
    seen = set()
    for src in re.findall(r"data-original=['\"]([^'\"]+)['\"]", html or ""):
        src = src.strip()
        if src.startswith("http") and src not in seen:
            seen.add(src)
            imgs.append(src)
    if not imgs:
        for src in re.findall(r'<img[^>]*class=[\'"][^\'"]*comic_img[^\'"]*[\'"][^>]*src=["\']([^"\']+)["\']', html or ""):
            if src.startswith("http") and src not in seen:
                seen.add(src)
                imgs.append(src)
    return imgs


def _mime_of(data, ctype=""):
    if data[:2] == b"\xff\xd8":
        return "image/jpeg"
    if data[:4] == b"\x89PNG":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:3] == b"GIF":
        return "image/gif"
    if ctype:
        return ctype.split(";")[0].strip()
    return "application/octet-stream"


class Spider(BaseSpider):
    def getName(self):
        return "🔞爱看漫画"

    def getDependence(self):
        return []

    def init(self, extend=None):
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        html, _final, base = _fetch("/latest/")
        items = _parse_list(html, base)
        if not items:
            html, _final, base = _fetch("/hanman/")
            items = _parse_list(html, base)
        return {"class": classes, "list": items, "filters": {}}

    def homeVideoContent(self, *args, **kwargs):
        html, _final, base = _fetch("/latest/")
        items = _parse_list(html, base)
        return {"list": items, "page": 1, "pagecount": _pagecount(html), "limit": 24, "total": 9999}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _norm_pg(pg, 1)
        tid = str(tid or "hanman").strip()
        valid = [t for t, _n in CATEGORIES] + ["latest"]
        if tid not in valid:
            tid = "hanman"
        if pg <= 1:
            path = "/" + tid + "/"
        else:
            path = "/" + tid + "/index_" + str(pg) + ".html"
        html, _final, base = _fetch(path)
        items = _parse_list(html, base)
        return {"page": pg, "pagecount": _pagecount(html), "limit": 24, "total": 9999, "list": items}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        html, _final, base = _fetch("/novel" + vid + "/")
        title, pic, author, category, status, desc, ordered = _parse_detail(html, vid, base)
        if not title:
            title = vid
        play = "#".join(name + "$akmh:" + vid + ":" + num for num, name in ordered)
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": pic, "vod_actor": author, "vod_director": "", "vod_remarks": status, "vod_year": "", "vod_area": "", "vod_content": desc, "type_name": category, "vod_tag": "image", "vod_play_from": "漫画", "vod_play_url": play}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg, 1)
        q = urllib.parse.quote(str(key or ""))
        html, final, base = _fetch("/e/search/?searchget=1&keyboard=" + q + "&show=title")
        if pg > 1:
            m = re.search(r"searchid=(\d+)", final or "")
            if m:
                html, _f2, base = _fetch("/e/search/result/index.php?page=" + str(pg) + "&searchid=" + m.group(1))
        items = _parse_list(html, base)
        return {"list": items, "page": pg, "pagecount": 9999, "limit": 24, "total": 9999}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if "$" in raw:
            raw = raw.split("$", 1)[1]
        header = {"User-Agent": UA, "Referer": _ACTIVE_BASE[0] + "/"}
        if raw.startswith("pics://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        vid = ""
        chap = ""
        if raw.startswith("akmh:"):
            parts = raw.split(":")
            if len(parts) >= 3:
                vid, chap = parts[1], parts[2]
        elif re.match(r"^\d+[:/]\d+$", raw):
            vid, chap = re.split(r"[:/]", raw)
        if not vid or not chap:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        html, _final, base = _fetch("/novel" + vid + "/chapter" + chap + ".html")
        header["Referer"] = base + "/novel" + vid + "/chapter" + chap + ".html"
        imgs = _chapter_images(html)
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
            data, ctype = _http_bytes(target, referer=_ACTIVE_BASE[0] + "/")
            if not data:
                return [404, "text/plain", b"", {}]
            mime = _mime_of(data, ctype)
            if want_b64:
                return [200, mime, base64.b64encode(data).decode("ascii"), {}, 1]
            return [200, mime, data, {}]
        except Exception:
            return [404, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self, *args, **kwargs):
        return False

    def action(self, *args, **kwargs):
        return {}
