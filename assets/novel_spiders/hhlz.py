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

BASES = ["https://www.hhby9.com", "https://www.f9rdkbh.top"]
UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
AES_KEY = b"saIZXc4yMvq0Iz56"
AES_IV = b"kbJYtBJUECT0oyjo"

CATEGORIES = [
    ("124", "长篇小说"),
    ("122", "短篇小说"),
    ("20", "武侠玄幻"),
    ("131", "灵异推理"),
    ("112", "网游小说"),
    ("151", "都市生活"),
    ("149", "现代情感"),
    ("150", "青春校园"),
    ("152", "人妻熟妇"),
    ("109", "古文艳情"),
    ("155", "現代情感"),
    ("133", "师生"),
    ("121", "办公室"),
    ("110", "人妻"),
    ("6", "重口"),
    ("144", "偷情"),
    ("142", "多人"),
    ("140", "凌辱"),
    ("138", "同人"),
    ("130", "乱伦"),
    ("129", "换妻"),
    ("128", "巨乳"),
    ("117", "淫男欲女"),
    ("116", "丝袜性趣"),
    ("4", "家庭乱伦"),
    ("113", "调教"),
]

FLAG_WORDS = ["萝莉", "幼女", "幼齿", "小学生", "初中生", "未成年", "loli"]

_ACTIVE_BASE = [BASES[0]]


def _gf_mul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def _gf_pow(a, n):
    r = 1
    while n:
        if n & 1:
            r = _gf_mul(r, a)
        a = _gf_mul(a, a)
        n >>= 1
    return r


def _build_sboxes():
    sbox = []
    for i in range(256):
        inv = 0 if i == 0 else _gf_pow(i, 254)
        s = inv
        for kk in (1, 2, 3, 4):
            s ^= ((inv << kk) | (inv >> (8 - kk))) & 0xFF
        sbox.append((s ^ 0x63) & 0xFF)
    inv_sbox = [0] * 256
    for i, v in enumerate(sbox):
        inv_sbox[v] = i
    return sbox, inv_sbox


_SBOX, _INV_SBOX = _build_sboxes()
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D]


def _expand_key(key):
    nk = len(key) // 4
    nr = nk + 6
    w = list(key)
    for i in range(nk, 4 * (nr + 1)):
        t = w[4 * (i - 1):4 * i]
        if i % nk == 0:
            t = [_SBOX[t[1]] ^ _RCON[i // nk - 1], _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        base = 4 * (i - nk)
        w += [w[base + j] ^ t[j] for j in range(4)]
    return w, nr


def _decrypt_block(block, rk, nr):
    s = [block[r + 4 * c] for c in range(4) for r in range(4)]

    def add_rk(rnd):
        for c in range(4):
            for r in range(4):
                s[r + 4 * c] ^= rk[16 * rnd + 4 * c + r]

    def inv_shift():
        old = s[:]
        for r in range(4):
            for c in range(4):
                s[r + 4 * c] = old[r + 4 * ((c - r) % 4)]

    def inv_sub():
        for i in range(16):
            s[i] = _INV_SBOX[s[i]]

    def inv_mix():
        for c in range(4):
            i = 4 * c
            a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
            s[i] = _gf_mul(a0, 14) ^ _gf_mul(a1, 11) ^ _gf_mul(a2, 13) ^ _gf_mul(a3, 9)
            s[i + 1] = _gf_mul(a0, 9) ^ _gf_mul(a1, 14) ^ _gf_mul(a2, 11) ^ _gf_mul(a3, 13)
            s[i + 2] = _gf_mul(a0, 13) ^ _gf_mul(a1, 9) ^ _gf_mul(a2, 14) ^ _gf_mul(a3, 11)
            s[i + 3] = _gf_mul(a0, 11) ^ _gf_mul(a1, 13) ^ _gf_mul(a2, 9) ^ _gf_mul(a3, 14)

    add_rk(nr)
    for rnd in range(nr - 1, 0, -1):
        inv_shift()
        inv_sub()
        add_rk(rnd)
        inv_mix()
    inv_shift()
    inv_sub()
    add_rk(0)
    return bytes(s[r + 4 * c] for c in range(4) for r in range(4))


def _aes_cbc_decrypt(ct, key, iv):
    try:
        from Crypto.Cipher import AES as _AES
        pt = _AES.new(key, _AES.MODE_CBC, iv).decrypt(ct)
    except Exception:
        rk, nr = _expand_key(key)
        out = bytearray()
        prev = iv
        for off in range(0, len(ct), 16):
            blk = ct[off:off + 16]
            if len(blk) < 16:
                break
            dec = _decrypt_block(list(blk), rk, nr)
            out += bytes(b ^ p for b, p in zip(dec, prev))
            prev = blk
        pt = bytes(out)
    if pt:
        n = pt[-1]
        if 1 <= n <= 16 and len(pt) >= n and pt[-n:] == bytes([n]) * n:
            pt = pt[:-n]
    return pt


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
    headers = {"User-Agent": UA, "Accept": "application/json, text/plain, */*"}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=25)
            if resp.status_code == 200 and resp.content:
                return resp.content.decode("utf-8", "ignore")
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=25) as resp:
            return resp.read().decode("utf-8", "ignore")
    except Exception:
        return ""


def _http_bytes(url, referer=""):
    headers = {"User-Agent": UA}
    if referer:
        headers["Referer"] = referer
    if _requests is not None:
        try:
            resp = _requests.get(url, headers=headers, timeout=25)
            if resp.status_code == 200 and resp.content:
                return bytes(resp.content)
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=25) as resp:
            return resp.read()
    except Exception:
        return b""


def _api(path):
    bases = [_ACTIVE_BASE[0]] + [b for b in BASES if b != _ACTIVE_BASE[0]]
    for base in bases:
        text = _http_get(base + path, referer=base + "/")
        if not text:
            continue
        try:
            obj = json.loads(text)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("code") == 0 and "data" in obj:
            _ACTIVE_BASE[0] = base
            return obj["data"], base
    return None, bases[0]


def _cover_url(cover, base):
    src = (cover or "").strip()
    if not src:
        return ""
    if src.startswith("http"):
        return src
    return base + "/" + src.lstrip("/")


def _pic(cover, base):
    url = _cover_url(cover, base)
    if not url:
        return ""
    return "proxy://do=py&siteKey=hhlz&u=" + urllib.parse.quote(url, safe="")


def _parse_results(data, base):
    items = []
    seen = set()
    results = []
    if isinstance(data, dict):
        results = data.get("results") or []
    elif isinstance(data, list):
        results = data
    for it in results:
        if not isinstance(it, dict):
            continue
        vid = str(it.get("book_id") or "")
        if not vid or vid in seen:
            continue
        name = _clean(str(it.get("book_name") or it.get("name") or ""))
        if not name or _flagged(name):
            continue
        remarks = "连载中" if it.get("is_serializing") else "已完结"
        seen.add(vid)
        items.append({"vod_id": vid, "vod_name": name, "vod_pic": _pic(it.get("cover"), base), "vod_remarks": remarks})
    return items


def _pagecount(data, limit):
    if isinstance(data, dict):
        try:
            total = int(data.get("total") or 0)
        except Exception:
            total = 0
        if total > 0 and limit > 0:
            return (total + limit - 1) // limit
    return 1


def _mime_of(data):
    if data[:2] == b"\xff\xd8":
        return "image/jpeg"
    if data[:4] == b"\x89PNG":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:3] == b"GIF":
        return "image/gif"
    return ""


def _all_chapters(vid):
    chapters = []
    meta = {}
    limit = 100
    pg = 1
    while pg <= 20:
        data, _base = _api("/api/v2/novels/" + vid + "/chapters?page=" + str(pg) + "&limit=" + str(limit))
        if not isinstance(data, dict):
            break
        if pg == 1:
            meta = data
        got = data.get("chapters") or []
        if not got:
            break
        chapters.extend(got)
        try:
            total = int(data.get("total") or 0)
        except Exception:
            total = 0
        if total > 0 and len(chapters) >= total:
            break
        if len(got) < limit:
            break
        pg += 1
    chapters.sort(key=lambda c: c.get("display_order") or 0)
    return meta, chapters


class Spider(BaseSpider):
    def getName(self):
        return "🔞嘿嘿连载"

    def getDependence(self):
        return []

    def init(self, extend=None):
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATEGORIES]
        data, base = _api("/api/v2/novels?page=1&limit=20")
        items = _parse_results(data, base)
        if not items:
            data, base = _api("/api/v2/novels?category_id=124&page=1&limit=20")
            items = _parse_results(data, base)
        return {"class": classes, "list": items, "filters": {}}

    def homeVideoContent(self, *args, **kwargs):
        data, base = _api("/api/v2/novels?page=1&limit=20")
        items = _parse_results(data, base)
        return {"list": items, "page": 1, "pagecount": _pagecount(data, 20), "limit": 20, "total": 9999}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _norm_pg(pg, 1)
        tid = str(tid or "124").strip()
        valid = [t for t, _n in CATEGORIES]
        if tid not in valid:
            tid = "124"
        limit = 20
        data, base = _api("/api/v2/novels?category_id=" + tid + "&page=" + str(pg) + "&limit=" + str(limit))
        items = _parse_results(data, base)
        return {"page": pg, "pagecount": _pagecount(data, limit), "limit": limit, "total": 9999, "list": items}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        meta, chapters = _all_chapters(vid)
        title = ""
        author = ""
        pic = ""
        desc = ""
        remarks = ""
        if isinstance(meta, dict) and meta:
            title = _clean(str(meta.get("book_name") or meta.get("name") or ""))
            author = _clean(str(meta.get("author") or ""))
            desc = _clean(str(meta.get("description") or ""))
            pic = _pic(meta.get("cover"), _ACTIVE_BASE[0])
            remarks = "连载中" if meta.get("is_serializing") else "已完结"
        if not title:
            data, base = _api("/api/v2/novels/" + vid)
            if isinstance(data, dict):
                title = _clean(str(data.get("name") or data.get("book_name") or ""))
                author = _clean(str(data.get("author") or ""))
                pic = _pic(data.get("cover"), base)
                remarks = "连载中" if data.get("is_serializing") else "已完结"
        if not title:
            title = vid
        play = "#".join(_clean(str(c.get("title") or "")) + "$hhlz:" + vid + ":" + str(c.get("id")) for c in chapters if c.get("id"))
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": pic, "vod_actor": author, "vod_director": "", "vod_remarks": remarks, "vod_year": "", "vod_area": "", "vod_content": desc, "type_name": "", "vod_tag": "text", "vod_play_from": "小说", "vod_play_url": play}]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg, 1)
        limit = 20
        q = urllib.parse.quote(str(key or ""))
        data, base = _api("/api/v2/novels?keyword=" + q + "&page=" + str(pg) + "&limit=" + str(limit))
        items = _parse_results(data, base)
        return {"list": items, "page": pg, "pagecount": _pagecount(data, limit), "limit": limit, "total": 9999}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if "$" in raw:
            raw = raw.split("$", 1)[1]
        header = {"User-Agent": UA, "Referer": _ACTIVE_BASE[0] + "/"}
        if raw.startswith("novel://"):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        vid = ""
        chap = ""
        if raw.startswith("hhlz:"):
            parts = raw.split(":")
            if len(parts) >= 3:
                vid, chap = parts[1], parts[2]
        elif re.match(r"^\d+[:/]\d+$", raw):
            vid, chap = re.split(r"[:/]", raw)
        if not vid or not chap:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        data, _base = _api("/api/v2/novels/chapters/" + vid + "/" + chap)
        if not isinstance(data, dict):
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        text = str(data.get("content") or "")
        if not text.strip():
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        title = _clean(str(data.get("chapter_title") or ""))
        payload = json.dumps({"title": title, "content": text}, ensure_ascii=False)
        url = "novel://" + payload
        return {"parse": 0, "playUrl": url, "url": url, "header": header}

    def localProxy(self, param):
        try:
            target = ""
            p = param
            if isinstance(p, str):
                text = p.strip()
                if text.startswith("proxy://"):
                    text = text[len("proxy://"):]
                    if "?" in text:
                        text = text.split("?", 1)[1]
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
            if "%" in target:
                target = urllib.parse.unquote(target)
            if not target:
                return [404, "text/plain", b"", {}]
            data = _http_bytes(target, referer=_ACTIVE_BASE[0] + "/")
            if not data:
                return [404, "text/plain", b"", {}]
            mime = _mime_of(data)
            if not mime:
                data = _aes_cbc_decrypt(data, AES_KEY, AES_IV)
                mime = _mime_of(data)
            if not mime or not data:
                return [404, "text/plain", b"", {}]
            return [200, mime, base64.b64encode(data).decode("ascii"), {}, 1]
        except Exception:
            return [404, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self, *args, **kwargs):
        return False

    def action(self, *args, **kwargs):
        return {}
