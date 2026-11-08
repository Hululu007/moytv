import base64
import json
import re
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

try:
    import requests
except Exception:
    requests = None

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
SITE_NAME = "🔞H有声小说"
SITE_KEY = "hysxs"
HOSTS = [
    "62.hysxs.work",
    "62.hysxs.sbs",
    "62.hysxs.cc",
    "62.hysxs.biz",
    "62.hysxs.buzz",
    "62.hysxs.pro",
    "62.hysxs.xyz",
    "62.hysxs.lol",
    "62.hysxs.lat",
    "62.hysxs.site",
    "hysxs.work",
    "hysxs.sbs",
    "hysxs.cc",
    "hysxs.biz",
]
TYPES = {"1": "音声剧场", "2": "同人有声"}
DEF_KEY = b"Hz64QG3atyY7lx0e"
DEF_IV = b"mxuGOKmLNl2fHOl3"
MEDIA_EXTS = (".mp3", ".m4a", ".wav", ".ogg", ".webm", ".flac", ".aac", ".mp4", ".m3u8")

SBOX = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16]
INV_SBOX = [0] * 256
for _i, _v in enumerate(SBOX):
    INV_SBOX[_v] = _i
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]


def _xtime(a):
    a <<= 1
    if a & 0x100:
        a ^= 0x11b
    return a & 0xff


def _gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _expand_key(key):
    w = [list(key[i * 4:(i + 1) * 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = [SBOX[t[1]] ^ RCON[i // 4 - 1], SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return w


def _aes_block_decrypt(block, w):
    st = [[block[4 * c + r] for c in range(4)] for r in range(4)]

    def _addrk(rnd):
        for c in range(4):
            for r in range(4):
                st[r][c] ^= w[rnd * 4 + c][r]

    def _inv_shift():
        for r in range(1, 4):
            st[r] = st[r][-r:] + st[r][:-r]

    def _inv_sub():
        for r in range(4):
            for c in range(4):
                st[r][c] = INV_SBOX[st[r][c]]

    def _inv_mix():
        for c in range(4):
            a0, a1, a2, a3 = st[0][c], st[1][c], st[2][c], st[3][c]
            st[0][c] = _gmul(a0, 14) ^ _gmul(a1, 11) ^ _gmul(a2, 13) ^ _gmul(a3, 9)
            st[1][c] = _gmul(a0, 9) ^ _gmul(a1, 14) ^ _gmul(a2, 11) ^ _gmul(a3, 13)
            st[2][c] = _gmul(a0, 13) ^ _gmul(a1, 9) ^ _gmul(a2, 14) ^ _gmul(a3, 11)
            st[3][c] = _gmul(a0, 11) ^ _gmul(a1, 13) ^ _gmul(a2, 9) ^ _gmul(a3, 14)

    _addrk(10)
    for rnd in range(9, 0, -1):
        _inv_shift()
        _inv_sub()
        _addrk(rnd)
        _inv_mix()
    _inv_shift()
    _inv_sub()
    _addrk(0)
    return bytes(st[r][c] for c in range(4) for r in range(4))


def _aes_cbc_decrypt(data, key, iv):
    w = _expand_key(key)
    out = bytearray()
    prev = iv
    for off in range(0, len(data) - len(data) % 16, 16):
        blk = data[off:off + 16]
        dec = _aes_block_decrypt(blk, w)
        out += bytes(dec[i] ^ prev[i] for i in range(16))
        prev = blk
    if out:
        pad = out[-1]
        if 1 <= pad <= 16 and out[-pad:] == bytes([pad]) * pad:
            out = out[:-pad]
    return bytes(out)


def _as_dict(extend):
    if isinstance(extend, dict):
        return extend
    if isinstance(extend, str) and extend.strip():
        try:
            v = json.loads(extend)
            if isinstance(v, dict):
                return v
        except Exception:
            pass
    return {}


def _as_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ""
    s = str(ids or "")
    if "," in s:
        s = s.split(",")[0]
    return s.strip()


def _as_int(pg, default=1):
    try:
        return max(1, int(pg))
    except Exception:
        return default


def _clean(s):
    return re.sub(r"\s+", " ", str(s or "")).strip()


class Spider(BaseSpider):
    def __init__(self):
        self.cookie = ""
        self.proxy = None
        self.timeout = 15
        self.host = None
        self.pin_host = None
        self._sess = None

    def getName(self):
        return SITE_NAME

    def getDependence(self):
        return []

    def init(self, extend=""):
        ext = _as_dict(extend)
        self.cookie = str(ext.get("cookie") or "").strip()
        self.proxy = ext.get("proxy") or None
        try:
            self.timeout = max(5, min(60, int(ext.get("timeout") or 15)))
        except Exception:
            self.timeout = 15
        pin = str(ext.get("host") or "").strip()
        if pin:
            self.pin_host = pin
            self.host = pin
        if requests is not None:
            try:
                s = requests.Session()
                s.headers.update({"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"})
                if self.cookie:
                    s.headers["Cookie"] = self.cookie
                if self.proxy:
                    s.proxies = {"http": self.proxy, "https": self.proxy}
                self._sess = s
            except Exception:
                self._sess = None
        return self

    def destroy(self):
        return None

    def _request(self, url):
        headers = {"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"}
        if self.cookie:
            headers["Cookie"] = self.cookie
        if self._sess is not None:
            try:
                r = self._sess.get(url, timeout=self.timeout)
                return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.read().decode("utf-8", "ignore")
        except Exception as e:
            part = getattr(e, "partial", None)
            if part:
                try:
                    return part.decode("utf-8", "ignore")
                except Exception:
                    return ""
            return ""

    def _alive(self, html):
        return bool(html) and "book/detail/id/" in html and "H有声小说" in html

    def _resolve_host(self):
        cands = []
        if self.pin_host:
            cands.append(self.pin_host)
        for h in HOSTS:
            if h not in cands:
                cands.append(h)
        for h in cands:
            try:
                html = self._request("https://" + h + "/ting/index.php")
            except Exception:
                continue
            if self._alive(html):
                self.host = h
                return h
        return None

    def _fetch(self, path):
        if not self.host:
            if not self._resolve_host():
                return ""
        html = self._request("https://" + self.host + path)
        if self._alive(html) or (html and path.startswith("/ting/index.php/book/detail/")):
            return html
        if self.pin_host:
            return html
        old = self.host
        self.host = None
        if self._resolve_host() and self.host != old:
            return self._request("https://" + self.host + path)
        return html

    def _cards(self, html):
        out = []
        seen = set()
        pat = re.compile(
            r"/ting/index\.php/book/detail/id/(\d+)\.html\"[^>]*class=\"hover-zoom[^>]*>.*?"
            r"class=\"text-primary[^>]*>(.*?)</span>.*?"
            r"class=\"text-jade[^>]*>(.*?)</small>.*?"
            r"class=\"col-md-2[^>]*>\s*([\d:]+)\s*</div>",
            re.S)
        for m in pat.finditer(html or ""):
            bid = m.group(1)
            title = _clean(re.sub(r"<[^>]+>", "", m.group(2)))
            author = _clean(re.sub(r"<[^>]+>", "", m.group(3)))
            dur = m.group(4).strip()
            if bid in seen:
                continue
            seen.add(bid)
            out.append({"vod_id": bid, "vod_name": title, "vod_pic": "",
                        "vod_actor": author, "vod_remarks": dur})
        if not out:
            ids = re.findall(r"/ting/index\.php/book/detail/id/(\d+)\.html", html or "")
            titles = re.findall(r"class=\"text-primary[^>]*>(.*?)</span>", html or "", re.S)
            for bid, title in zip(ids, titles):
                if bid in seen:
                    continue
                seen.add(bid)
                out.append({"vod_id": bid, "vod_name": _clean(re.sub(r"<[^>]+>", "", title)),
                            "vod_pic": "", "vod_actor": "", "vod_remarks": ""})
        return out

    def _pagecount(self, html, cards):
        nums = [int(x) for x in re.findall(r"/page/(\d+)\.html", html or "")]
        if nums:
            return max(nums)
        return 1 if cards else 0

    def _list_result(self, cards, pg, pagecount):
        return {"list": cards, "page": pg, "pagecount": pagecount,
                "limit": 20, "total": pagecount * 20}

    def homeContent(self, filter=None):
        html = self._fetch("/ting/index.php/book/type/id/1/page/1.html")
        cards = self._cards(html)
        return {"class": [{"type_id": k, "type_name": v} for k, v in TYPES.items()],
                "filters": {}, "list": cards}

    def homeVideoContent(self):
        html = self._fetch("/ting/index.php/book/type/id/1/page/1.html")
        cards = self._cards(html)
        return self._list_result(cards, 1, self._pagecount(html, cards))

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        tid = str(tid or "").strip()
        if tid not in TYPES:
            return self._list_result([], _as_int(pg), 0)
        pg = _as_int(pg)
        html = self._fetch("/ting/index.php/book/type/id/%s/page/%d.html" % (tid, pg))
        cards = self._cards(html)
        return self._list_result(cards, pg, self._pagecount(html, cards))

    def _detail(self, bid):
        html = self._fetch("/ting/index.php/book/detail/id/%s.html" % bid)
        if not html:
            return None
        m = re.search(r"<title>(.*?)</title>", html, re.S)
        title = ""
        if m:
            title = _clean(m.group(1))
            title = re.sub(r"-H有声小说\s*$", "", title).strip()
        if not title:
            m = re.search(r"class=\"main-title\">([^<]+)<", html)
            title = _clean(m.group(1)) if m else bid
        tm = re.search(r"var sstypeid\s*=\s*'(\d+)'", html)
        typename = TYPES.get(tm.group(1), "") if tm else ""
        km = re.search(r"var key\s*=\s*CryptoJS\.enc\.Utf8\.parse\(\"([^\"]+)\"\)", html)
        vm = re.search(r"var iv\s*=\s*CryptoJS\.enc\.Utf8\.parse\(\"([^\"]+)\"\)", html)
        key = km.group(1).encode("utf-8") if km else DEF_KEY
        iv = vm.group(1).encode("utf-8") if vm else DEF_IV
        tracks = []
        tm2 = re.search(r"const tracks\s*=\s*\[(.*?)\];", html, re.S)
        if tm2:
            for t in re.finditer(r"title:\s*\"([^\"]+)\",\s*url:\s*\"([^\"]+)\"", tm2.group(1)):
                try:
                    raw = base64.b64decode(t.group(2))
                    url = _aes_cbc_decrypt(raw, key, iv).decode("utf-8", "ignore")
                except Exception:
                    url = ""
                if url.startswith("http"):
                    tracks.append((t.group(1), url))
        return {"title": title, "typename": typename, "tracks": tracks, "html": html}

    def detailContent(self, ids, **kwargs):
        bid = _as_id(ids)
        bid = re.sub(r"\D", "", bid)
        if not bid:
            return {"list": []}
        d = self._detail(bid)
        if d is None:
            return {"list": []}
        tracks = d["tracks"]
        play = "#".join("%s$%s" % (t, u) for t, u in tracks)
        vod = {"vod_id": bid, "vod_name": d["title"], "vod_pic": "",
               "vod_actor": "", "vod_type": d["typename"],
               "vod_remarks": "%d集" % len(tracks),
               "vod_content": "分类：%s · 共%d集" % (d["typename"] or "有声", len(tracks)),
               "vod_play_from": "在线播放", "vod_play_url": play}
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg=1, **kwargs):
        wd = str(key or "").strip()
        if not wd:
            return self._list_result([], 1, 0)
        pg = _as_int(pg)
        q = urllib.parse.quote(wd)
        html = self._fetch("/ting/index.php/book/search/wd/%s/page/%d.html" % (q, pg))
        cards = self._cards(html)
        return self._list_result(cards, pg, self._pagecount(html, cards))

    def playerContent(self, flag=None, id=None, vipFlags=None, **kwargs):
        pid = _as_id(id)
        if "$" in pid and not pid.startswith("http"):
            pid = pid.split("$", 1)[1]
        if "#" in pid:
            pid = pid.split("#")[0]
        url = ""
        if pid.startswith("http"):
            url = pid
        elif pid.startswith(SITE_KEY + ":"):
            parts = pid.split(":")
            if len(parts) == 3:
                try:
                    idx = int(parts[2])
                except Exception:
                    idx = -1
                d = self._detail(parts[1])
                if d is not None and 0 <= idx < len(d["tracks"]):
                    url = d["tracks"][idx][1]
        host = self.host or HOSTS[0]
        header = {"User-Agent": UA, "Referer": "https://" + host + "/ting/index.php"}
        return {"parse": 0, "playUrl": "", "url": url, "header": header}

    def localProxy(self, param):
        url = ""
        if isinstance(param, dict):
            url = str(param.get("url") or param.get("src") or "")
        elif isinstance(param, str):
            m = re.search(r"https?://[^\s&\"']+", param)
            if m:
                url = m.group(0)
        if not url:
            return [404, "text/plain", b"", {}]
        try:
            if self._sess is not None:
                r = self._sess.get(url, timeout=self.timeout)
                return [r.status_code, r.headers.get("Content-Type", ""),
                        r.content, dict(r.headers)]
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return [r.status, r.headers.get("Content-Type", ""),
                        r.read(), dict(r.headers)]
        except Exception:
            return [404, "text/plain", b"", {}]

    def isVideoFormat(self, url):
        u = str(url or "").lower().split("?")[0]
        return any(u.endswith(e) for e in MEDIA_EXTS)

    def manualVideoCheck(self):
        return False

    def action(self, act, *args, **kwargs):
        return {}
