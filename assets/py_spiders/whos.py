"""whos 内置源（2026-11-21 用户令：内置区的 whos 打不开，做成能过盾的内置源）。

whos.tv 直连被 Cloudflare 挑战挡住（403 Just a moment），本插件不硬碰：
取页走多通道兜底——validator.nu（W3C 校验器代取，第一页稳）→
validator.w3.org（另一入口，nu 504 时兜一把）→ 直连（手机 UA，CF
偶尔放行）。取回后解析服务端渲染的卡片：

    href="/videos/<code>" ... data-cover-src="<hex 密文>" ... alt="<标题>"

封面密文 16 进制解码后，末字节即 XOR 密钥，逐字节解出
https://v.hersav.me/images/av/<32位hash>.jpg；播放地址不用取详情，
直接 <base>/<hash>/<hash>.m3u8（实测 200，可直接播）。

分类：最新（/videos，可分页）、排行榜（/ranking/video，单页 50 条）。
"""
import json
import re
import ssl
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


BASE = "https://whos.tv"
IMG_BASE = "https://v.hersav.me"
UA_DESKTOP = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
UA_MOBILE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 "
    "Mobile/15E148 Safari/604.1"
)
UA_ANDROID = (
    "Mozilla/5.0 (Linux; Android 14; PGT-AN10) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
)

CARD_RE = re.compile(
    r'href="/videos/([a-z0-9-]+)"[^>]*>.*?data-cover-src="([0-9a-f]+)"'
    r'[^>]*alt="([^"]*)"',
    re.S,
)
HASH_RE = re.compile(r"/images/av/([0-9a-f]{32})\.jpg")

CATS = [
    {"type_id": "new", "type_name": "最新作品"},
    {"type_id": "rank", "type_name": "排行榜"},
]

# 分类/首页取过的卡片缓存：详情页直接用它，不再为每条取一次详情
#（validator 取详情页很慢，缓存住就不用等）。
_CACHE = {}


def _ssl_ctx():
    return ssl._create_unverified_context()


def _get(url, accept="text/html", ua=UA_DESKTOP, timeout=45):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": ua,
            "Accept": accept,
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout, context=_ssl_ctx()) as resp:
        raw = resp.read()
    return raw.decode("utf-8", "replace")


def _looks_real(html):
    return (
        bool(html)
        and len(html) > 10000
        and "data-cover-src" in html
        and "Just a moment" not in html
    )


def _fetch(target):
    """多通道取 whos 页面：任一通道取回真页面即返回。"""
    encoded = urllib.parse.quote(target, safe="")
    channels = [
        ("https://validator.nu/?doc=" + encoded + "&showsource=yes&out=json", True),
        (
            "https://validator.w3.org/nu/?doc="
            + encoded
            + "&showsource=yes&out=json",
            True,
        ),
        (target, False),
    ]
    uas = [UA_MOBILE, UA_ANDROID]
    for url, is_json in channels:
        for attempt in range(2):
            try:
                body = _get(
                    url,
                    accept="application/json" if is_json else "text/html",
                    ua=uas[attempt % len(uas)],
                )
                if is_json:
                    doc = json.loads(body)
                    source = doc.get("source") or {}
                    body = source.get("code") or ""
                if _looks_real(body):
                    return body
            except Exception:
                pass
    return ""


def _decode_cover(cipher):
    """封面密文 → (封面地址, hash)；解不出返回 (None, None)。"""
    cipher = (cipher or "").strip().lower()
    if len(cipher) < 4 or len(cipher) % 2:
        return None, None
    try:
        raw = bytes.fromhex(cipher)
    except Exception:
        return None, None
    key = raw[-1]
    plain = bytes(b ^ key for b in raw[:-1]).decode("utf-8", "replace")
    match = HASH_RE.search(plain)
    if not match:
        return None, None
    return plain, match.group(1)


def _cards(html):
    items = []
    for code, cipher, alt in CARD_RE.findall(html or ""):
        pic, digest = _decode_cover(cipher)
        if not digest:
            continue
        title = (alt or "").strip()
        _CACHE[code] = {
            "title": title,
            "pic": pic or "",
            "m3u8": IMG_BASE + "/" + digest + "/" + digest + ".m3u8",
        }
        items.append(
            {
                "vod_id": code,
                "vod_name": title,
                "vod_pic": pic or "",
                "vod_remarks": "高清",
                "vod_play_from": "whos",
                "vod_play_url": "正片$" + _CACHE[code]["m3u8"],
            }
        )
    return items


def _page_url(tid, pg):
    pg = int(pg or 1)
    if pg < 1:
        pg = 1
    if tid == "rank":
        return BASE + "/ranking/video"
    if pg <= 1:
        return BASE + "/videos"
    return BASE + "/videos/page-" + str(pg)


class Spider(BaseSpider):
    def getName(self):
        return "whos"

    def getDependence(self):
        return []

    def init(self, extend=""):
        return

    def destroy(self):
        return

    def homeContent(self, filter=""):
        html = _fetch(BASE + "/videos")
        return {"class": CATS, "list": _cards(html)}

    def homeVideoContent(self):
        html = _fetch(BASE + "/videos")
        items = _cards(html)
        return {"list": items, "page": 1, "pagecount": 9999, "total": len(items)}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            pg = int(pg or 1)
        except Exception:
            pg = 1
        url = _page_url(tid, pg)
        html = _fetch(url)
        items = _cards(html)
        return {
            "list": items,
            "page": pg,
            "pagecount": 9999 if items else pg,
            "total": len(items),
        }

    def detailContent(self, ids):
        code = str(ids[0] if isinstance(ids, (list, tuple)) else ids)
        code = code.strip()
        if code.startswith("whos:"):
            code = code[5:]
        if not code:
            return {"list": []}
        cached = _CACHE.get(code) or {}
        title = cached.get("title") or code
        pic = cached.get("pic") or ""
        m3u8 = cached.get("m3u8") or ""
        if not m3u8:
            # 缓存里没有（从搜索/历史直接进来）：取一次详情页补。
            html = _fetch(BASE + "/videos/" + code)
            for card in _cards(html):
                if card.get("vod_id") == code:
                    m3u8 = (card.get("vod_play_url") or "").split("$", 1)[-1]
                    title = card.get("vod_name") or title
                    pic = card.get("vod_pic") or pic
                    break
        if not m3u8:
            return {"list": []}
        play_url = "正片$" + m3u8
        return {
            "list": [
                {
                    "vod_id": code,
                    "vod_name": title,
                    "vod_pic": pic,
                    "vod_remarks": "高清",
                    "vod_content": "<p>whos · " + code + "</p>",
                    "vod_play_from": "whos",
                    "vod_play_url": play_url,
                    "stills": [],
                }
            ]
        }

    def searchContent(self, key, quick=False, pg=1):
        keyword = urllib.parse.quote((key or "").strip(), safe="")
        html = _fetch(BASE + "/result?q=" + keyword)
        items = _cards(html)
        if not items:
            html = _fetch(BASE + "/result?keyword=" + keyword)
            items = _cards(html)
        return {"list": items, "page": 1, "pagecount": 1, "total": len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "").strip()
        if raw.startswith("whos:"):
            raw = raw[5:]
        url = raw if raw.startswith("http") else (
            _CACHE.get(raw, {}).get("m3u8") or ""
        )
        if not url:
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        return {
            "parse": 0,
            "playUrl": url,
            "url": url,
            "header": {"User-Agent": UA_DESKTOP, "Referer": BASE + "/"},
        }

    def isVideoFormat(self, url):
        return ".m3u8" in str(url or "")

    def manualVideoCheck(self):
        return False
