# -*- coding: utf-8 -*-
# 极速漫画（m.1kkk.com）— 由真果鉴 Venera 源 jisu_1kkk.js 移植
import base64
import gzip
import json
import re
import zlib
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

BASE = "http://m.1kkk.com"
UA = ("Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

CATEGORIES = [
    ("manhua-list", "全部"), ("manhua-updated", "最近更新"), ("manhua-original", "原创"),
    ("manhua-jpkr", "日漫"), ("manhua-completed", "完结"), ("manhua-rexue", "热血"),
    ("manhua-aiqing", "恋爱"), ("manhua-xiaoyuan", "校园"), ("manhua-maoxian", "冒险"),
    ("manhua-kehuan", "科幻"), ("manhua-gaoxiao", "搞笑"), ("manhua-qihuan", "奇幻"),
    ("manhua-kongbu", "恐怖"), ("manhua-xuanyi", "悬疑"), ("manhua-zhiyu", "治愈"),
    ("manhua-hougong", "后宫"), ("manhua-baihe", "百合"), ("manhua-danmei", "耽美"),
    ("manhua-zhichang", "职场"), ("manhua-lishi", "历史"), ("manhua-meishi", "美食"),
    ("manhua-tongren", "同人"), ("manhua-jingji", "运动"), ("manhua-jizhan", "机甲"),
    ("manhua-zhentan", "侦探"), ("manhua-zhanzheng", "战争"),
]


# ---------------- packer 解包 ----------------
def _b36(n):
    chars = '0123456789abcdefghijklmnopqrstuvwxyz'
    if n == 0:
        return '0'
    out = ''
    while n:
        out = chars[n % 36] + out
        n //= 36
    return out


def _ch(d):
    return chr(d + 29) if d > 35 else _b36(d)


def _enc(c, a):
    if c < a:
        return _ch(c)
    return _enc(c // a, a) + _ch(c % a)


def _find_packer(html):
    i = html.find('eval(function(p,a,c,k,e,d)')
    if i < 0:
        return ''
    body = html[i + len('eval('):]
    depth, end = 0, -1
    for j, ch in enumerate(body):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth < 0:
                end = j
                break
    return body[:end] if end > 0 else ''


def _unpack(expr):
    m = re.search(r"\('((?:[^'\\]|\\.)*)',\s*(\d+),\s*(\d+),\s*'((?:[^'\\]|\\.)*)'\.split\('\|'\)", expr, re.S)
    if not m:
        return ''
    payload, a, c, kw = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
    kws = kw.split('|')
    table = {}
    for i in range(c - 1, -1, -1):
        key = _enc(i, a)
        table[key] = kws[i] if i < len(kws) and kws[i] else key
    out = re.sub(r'\b\w+\b', lambda mm: table.get(mm.group(0), mm.group(0)), payload)
    return out.replace('\\/', '/')


def _images_from_html(html):
    out = _unpack(_find_packer(html))
    if not out:
        return []
    m = re.search(r'newImgs\s*=\s*(\[[\s\S]*?\])', out)
    if not m:
        return []
    urls = []
    for u in re.findall(r"'([^']+)'", m.group(1)):
        u = u.replace('\\/', '/').strip()
        if u.startswith('http') and u not in urls:
            urls.append(u)
    return urls


# ---------------- 网络 ----------------
def _get(url, referer=""):
    headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
               "Accept-Language": "zh-CN,zh;q=0.9"}
    if referer:
        headers["Referer"] = referer
    headers["Accept-Encoding"] = "gzip, deflate"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read()
        enc = (r.headers.get("Content-Encoding") or "").lower()
        if "gzip" in enc:
            raw = gzip.decompress(raw)
        elif "deflate" in enc:
            try:
                raw = zlib.decompress(raw)
            except Exception:
                raw = zlib.decompress(raw, -zlib.MAX_WBITS)
        return raw.decode('utf-8', 'replace'), r.geturl()


def _abs(path):
    if not path:
        return ''
    if path.startswith('http'):
        return path
    if path.startswith('//'):
        return 'https:' + path
    return BASE + (path if path.startswith('/') else '/' + path)


def _clean_id(raw):
    raw = str(raw or '').strip()
    if not raw:
        return ''
    if raw.startswith('jisu:'):
        raw = raw[len('jisu:'):]
    return raw.split('?')[0]


def _parse_list(html):
    items = []
    for li in re.findall(r'<li[^>]*>(.*?)</li>', html, re.S):
        m = re.search(r'class="[^"]*(?:book-list-info-title|manga-list-2-title|rank-list-info-right-title)[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', li, re.S)
        if not m:
            # 搜索页：<a href="/manhua432/"><p class="book-list-info-title">名字</p>
            m2 = re.search(r'<a[^>]*href="(/manhua[^"]*)"[^>]*>\s*<p[^>]*class="[^"]*(?:book-list-info-title|manga-list-2-title)[^"]*"[^>]*>(.*?)</p>', li, re.S)
            m = m2
        if not m:
            continue
        href, title = m.group(1), re.sub(r'<[^>]+>', '', m.group(2)).strip()
        if '/manhua' not in href or not title:
            continue
        cover = ''
        mc = re.search(r'class="[^"]*(?:book-list-cover-img|manga-list-2-cover-img|rank-list-cover-img)[^"]*"[^>]*src="([^"]+)"', li)
        if mc:
            cover = mc.group(1)
        tip = ''
        mt = re.search(r'class="[^"]*(?:manga-list-2-tip|book-list-info-bottom-right-font)[^"]*"[^>]*>(.*?)</', li, re.S)
        if mt:
            tip = re.sub(r'<[^>]+>', '', mt.group(1)).strip()
        items.append({
            "vod_id": href,
            "vod_name": title,
            "vod_pic": _abs(cover),
            "vod_remarks": tip[:40],
            "vod_content": "",
            "vod_tag": "image",
        })
    return items


class Spider(BaseSpider):
    def getName(self):
        return "极速漫画"

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
        path = str(tid or 'manhua-list')
        url = "%s/%s/" % (BASE, path) if pg == 1 else "%s/%s-p%d/" % (BASE, path, pg)
        try:
            html, _ = _get(url)
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 20, "total": 0}
        items = _parse_list(html)
        return {"list": items, "page": pg, "pagecount": pg + 1 if items else pg, "limit": 20, "total": len(items)}

    def detailContent(self, ids):
        raw = ids if not isinstance(ids, (list, tuple)) else (ids[0] if ids else "")
        path = _clean_id(raw)
        if not path:
            return {"list": []}
        url = _abs(path)
        try:
            html, final = _get(url)
        except Exception:
            return {"list": []}

        m = re.search(r'class="[^"]*detail-main-info-title[^"]*"[^>]*>(.*?)</', html, re.S)
        title = re.sub(r'<[^>]+>', '', m.group(1)).strip() if m else ''
        if not title:
            return {"list": []}

        cover = ''
        m = re.search(r'class="[^"]*detail-main-cover[^"]*"[^>]*>(.*?)</div>', html, re.S)
        if m:
            mc = re.search(r'<img[^>]*src="([^"]+)"', m.group(1))
            if mc:
                cover = mc.group(1)

        desc = ''
        m = re.search(r'class="[^"]*detail-desc[^"]*"[^>]*>(.*?)</', html, re.S)
        if m:
            desc = re.sub(r'<[^>]+>', '', m.group(1)).strip()

        author = ''
        m = re.search(r'class="[^"]*detail-main-info-author[^"]*"[^>]*>(.*?)</', html, re.S)
        if m:
            author = re.sub(r'^作者[：:]', '', re.sub(r'<[^>]+>', '', m.group(1))).strip()

        tags = []
        m = re.search(r'class="[^"]*detail-main-info-class[^"]*"[^>]*>(.*?)</', html, re.S)
        if m:
            for t in re.findall(r'<a[^>]*>([^<]+)</a>', m.group(1)):
                t = t.strip()
                if t and t not in tags:
                    tags.append(t)

        chapters = []
        for a in re.findall(r'<a[^>]*class="[^"]*chapteritem[^"]*"[^>]*>', html):
            mh = re.search(r'href="([^"]+)"', a)
            mt = re.search(r'title="([^"]*)"', a)
            if mh:
                label = (mt.group(1).strip() if mt and mt.group(1).strip() else '')
                chapters.append((mh.group(1), label))
        # 站点是倒序，反转成正序
        chapters.reverse()
        out_ch = []
        for idx, (href, label) in enumerate(chapters):
            mname = re.search(r'<a[^>]*class="[^"]*chapteritem[^"]*"[^>]*>([^<]*)</a>', html)
            out_ch.append("%s$jisu:%s" % ((label or ("第%d话" % (idx + 1))).replace("$", " "), href))
        if not out_ch:
            return {"list": []}

        return {"list": [{
            "vod_id": path,
            "vod_name": title,
            "vod_pic": _abs(cover),
            "vod_actor": author,
            "vod_director": "",
            "vod_remarks": "",
            "vod_year": "",
            "vod_area": "",
            "vod_content": desc,
            "type_name": " ".join(tags[:4]),
            "vod_tag": "image",
            "vod_play_from": "漫画",
            "vod_play_url": "#".join(out_ch),
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = max(1, int(pg or 1))
        url = "%s/search?title=%s&language=1&page=%d" % (BASE, urllib.parse.quote(str(key or '')), pg)
        try:
            html, _ = _get(url)
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 20, "total": 0}
        items = _parse_list(html)
        return {"list": items, "page": pg, "pagecount": pg + 1 if items else pg, "limit": 20, "total": len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('jisu:'):
            raw = raw[len('jisu:'):]
        url = _abs(raw.split('?')[0] if not raw.startswith('http') else raw)
        header = {"User-Agent": UA, "Referer": url}
        if raw.startswith('pics://'):
            return {"parse": 0, "playUrl": raw, "url": raw, "header": header}
        try:
            html, final = _get(url)
        except Exception:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        imgs = _images_from_html(html)
        if not imgs:
            return {"parse": 0, "playUrl": "", "url": "", "header": header}
        pics = "pics://" + "&&".join(imgs)
        header["Referer"] = final or url
        return {"parse": 0, "playUrl": pics, "url": pics, "header": header}

    def localProxy(self, param):
        try:
            target, ref, want_b64 = "", "", False
            p = param
            if isinstance(p, str):
                text = p.strip()
                if text.startswith('{'):
                    try:
                        p = json.loads(text)
                    except Exception:
                        p = {}
                elif text.startswith('http'):
                    target = text
                else:
                    p = dict(urllib.parse.parse_qsl(text))
            if isinstance(p, dict):
                target = str(p.get('u') or p.get('url') or '')
                ref = str(p.get('r') or p.get('referer') or '')
                want_b64 = str(p.get('b64') or p.get('base64') or '') == '1'
            if not target:
                return [404, "text/plain", b"", {}]
            req = urllib.request.Request(target, headers={
                "User-Agent": UA,
                "Referer": ref or "https://m.1kkk.com/",
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
