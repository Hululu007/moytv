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

BASES = ["https://www.webmota.com", "https://cn.webmota.com", "https://cn.baozimh.com", "https://www.baozimh.com"]
COVER_BASE = "https://static-tw.baozimh.com/cover/"
UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"

CATEGORIES = [
    ("all|all", "全部"),
    ("all|cn", "国漫"),
    ("all|jp", "日本"),
    ("all|kr", "韩国"),
    ("lianai|all", "恋爱"),
    ("rexie|all", "热血"),
    ("xuanhuan|all", "玄幻"),
    ("gaoxiao|all", "搞笑"),
    ("kehuan|all", "科幻"),
    ("xuanyi|all", "悬疑"),
    ("gufeng|all", "古风"),
]

FLAG_WORDS = ["萝莉", "幼女", "幼齿", "小学生", "初中生", "未成年", "思春期", "loli", "ロリ"]

_ACTIVE_BASE = [BASES[0]]

_CARD_RE = re.compile(r'<a href="/comic/([^"/]+)" title="([^"]*)"[^>]*class="comics-card__poster[^"]*"[^>]*>\s*<amp-img[^>]*src="([^"]+)"')
_CHAPTER_RE = re.compile(r"comic_id=[^&\"']+&amp;section_slot=(\d+)&amp;chapter_slot=(\d+)\"[^>]*>\s*<div[^>]*>\s*<span[^>]*>([^<]*)</span>")
_IMG_RE = re.compile(r'<amp-img[^>]*id="chapter-img-[^"]*"[^>]*>')


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
    return str(value or "").split(",")[0].strip()


def _http_get(url, referer=""):
    headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8"}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=45)
            if resp.status_code == 200 and resp.content:
                return resp.content.decode("utf-8", "ignore"), str(resp.url)
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=45) as resp:
            return resp.read().decode("utf-8", "ignore"), resp.geturl()
    except Exception:
        return "", url


def _http_bytes(url, referer=""):
    headers = {"User-Agent": UA}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=45)
            if resp.status_code == 200 and resp.content:
                return bytes(resp.content), resp.headers.get("Content-Type", "")
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=45) as resp:
            return resp.read(), resp.headers.get("Content-Type", "")
    except Exception:
        return b"", ""


def _fetch(path, referer=""):
    bases = [_ACTIVE_BASE[0]] + [b for b in BASES if b != _ACTIVE_BASE[0]]
    for base in bases:
        url = base + path
        text, final = _http_get(url, referer=referer or (base + "/"))
        if text and len(text) > 100 and "challenge_required" not in text:
            _ACTIVE_BASE[0] = base
            return text, final, base
    return "", bases[0] + path, bases[0]


def _abs_url(src, base):
    src = _clean(src or "")
    if src.startswith("//"):
        return "https:" + src
    if src.startswith("/"):
        return base + src
    return src


def _list_items(path):
    text, _final, _base = _fetch(path)
    items = []
    if not text:
        return items, False
    try:
        data = json.loads(text)
    except Exception:
        return items, False
    has_next = bool(data.get("next"))
    seen = set()
    for it in data.get("items") or []:
        cid = str(it.get("comic_id") or "").strip()
        name = _clean(it.get("name") or "")
        if not cid or not name or cid in seen or _flagged(name):
            continue
        seen.add(cid)
        topic = str(it.get("topic_img") or "").strip()
        pic = COVER_BASE + topic if topic else COVER_BASE + cid + ".jpg"
        remarks = _clean(it.get("region_name") or "")
        types = it.get("type_names") or []
        if isinstance(types, list) and types:
            extra = " ".join(str(t) for t in types[:3])
            remarks = (remarks + " " + extra).strip()
        items.append({"vod_id": cid, "vod_name": name, "vod_pic": pic, "vod_remarks": remarks})
    return items, has_next


def _search_items(html, base):
    items = []
    seen = set()
    for cid, title, pic in _CARD_RE.findall(html or ""):
        name = _clean(title)
        if not cid or not name or cid in seen or _flagged(name):
            continue
        seen.add(cid)
        items.append({"vod_id": cid, "vod_name": name, "vod_pic": _abs_url(pic, base), "vod_remarks": ""})
    return items


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
        return "包子漫画"

    def getDependence(self):
        return []

    def init(self, extend=None):
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        items, _has_next = _list_items("/api/bzmhq/amp_comic_list?type=all&region=all&state=all&filter=*&page=1&limit=36&language=cn")
        return {"class": classes, "list": items, "filters": {}}

    def homeVideoContent(self, *args, **kwargs):
        items, has_next = _list_items("/api/bzmhq/amp_comic_list?type=all&region=all&state=all&filter=*&page=1&limit=36&language=cn")
        return {"list": items, "page": 1, "pagecount": 9999 if has_next else 1, "limit": 36, "total": 9999}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _norm_pg(pg, 1)
        tid = str(tid or "all|all").strip()
        valid = [t for t, _n in CATEGORIES]
        if tid not in valid:
            tid = "all|all"
        ctype, region = tid.split("|")
        path = "/api/bzmhq/amp_comic_list?type=" + urllib.parse.quote(ctype) + "&region=" + urllib.parse.quote(region) + "&state=all&filter=*&page=" + str(pg) + "&limit=36&language=cn"
        items, has_next = _list_items(path)
        return {"page": pg, "pagecount": 9999 if has_next else pg, "limit": 36, "total": 9999, "list": items}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        html, _final, base = _fetch("/comic/" + urllib.parse.quote(vid))
        title = vid
        m = re.search(r"<title>(.*?)</title>", html or "", flags=re.S)
        if m:
            title = _clean(m.group(1))
            title = re.sub(r"^[^\w\u4e00-\u9fff]+", "", title)
            title = re.sub(r"\s*[-–—]\s*包子漫畫.*$", "", title).strip() or title
        pic = COVER_BASE + vid + ".jpg"
        m = re.search(r'<meta[^>]*property="og:image"[^>]*content="([^"]+)"', html or "")
        if m and m.group(1).strip():
            pic = _abs_url(m.group(1), base)
        desc = ""
        m = re.search(r'<meta[^>]*name="description"[^>]*content="([^"]*)"', html or "")
        if m:
            desc = _clean(m.group(1))
        if len(desc) < 20:
            for m in re.finditer(r'<div[^>]*class="[^"]*comics-detail__desc[^"]*"[^>]*>(.*?)</p>', html or "", flags=re.S):
                cand = _clean(m.group(1))
                if cand and "{" not in cand and len(cand) > 5:
                    desc = cand
                    break
        tags = []
        m = re.search(r'<div class="tag-list"[^>]*>(.*?)</div>', html or "", flags=re.S)
        if m:
            for tag in re.findall(r"<span[^>]*>([^<]+)</span>", m.group(1)):
                tag = _clean(tag)
                if tag:
                    tags.append(tag)
        author = ""
        m = re.search(r'comics-detail__author[^>]*>(.*?)</', html or "", flags=re.S)
        if m:
            author = _clean(m.group(1))
        chapters = {}
        for section, slot, name in _CHAPTER_RE.findall(html or ""):
            key = (int(section), int(slot))
            label = _clean(name) or ("第" + slot + "话")
            if key not in chapters:
                chapters[key] = label
        ordered = sorted(chapters.items())
        play = "#".join(label + "$baozi:" + vid + ":" + str(s) + "_" + str(c) for (s, c), label in ordered)
        remarks = tags[0] if tags else ""
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": pic, "vod_actor": author, "vod_director": "", "vod_remarks": remarks, "vod_year": "", "vod_area": "", "vod_content": desc, "type_name": " ".join(tags[1:4]), "vod_tag": "image", "vod_play_from": "漫画", "vod_play_url": play}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg, 1)
        if pg > 1:
            return {"list": [], "page": pg, "pagecount": 1, "limit": 36, "total": 0}
        q = urllib.parse.quote(str(key or ""))
        html, _final, base = _fetch("/search?q=" + q)
        items = _search_items(html, base)
        return {"list": items, "page": pg, "pagecount": 1, "limit": 36, "total": len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if "$" in raw:
            raw = raw.split("$", 1)[1]
        header = {"User-Agent": UA, "Referer": _ACTIVE_BASE[0] + "/"}
        if raw.startswith("pics://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        vid = ""
        slot = ""
        if raw.startswith("baozi:"):
            rest = raw[len("baozi:"):]
            if ":" in rest:
                vid, slot = rest.split(":", 1)
        if not vid or not slot:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        path = "/comic/chapter/" + urllib.parse.quote(vid) + "/" + slot + ".html"
        html, final, base = _fetch(path)
        header["Referer"] = final or (base + path)
        imgs = []
        seen = set()
        for tag in _IMG_RE.findall(html or ""):
            m = re.search(r'data-src="([^"]+)"', tag) or re.search(r'src="([^"]+)"', tag)
            if m:
                src = _abs_url(m.group(1), base)
                if src.startswith("http") and src not in seen:
                    seen.add(src)
                    imgs.append(src)
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
