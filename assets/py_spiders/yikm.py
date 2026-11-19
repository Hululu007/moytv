try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

import gzip
import html
import http.client
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from urllib.parse import quote

HOST = "https://www.yikm.net"

UA = (
    "Mozilla/5.0 (Linux; Android 8.0; Pixel 2 Build/OPD3.170816.012) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 "
    "Mobile Safari/537.36"
)

TIMEOUT_PAGE = 6
TIMEOUT_API = 4

TTL_CAT = 300
TTL_SEARCH = 180

ACTION_HEADER = {
    'Upgrade-Insecure-Requests': '1',
    'User-Agent': UA,
}

PLATFORMS = [
    {"id": "/nes?tag=0&e=0&page=", "name": "FC", "flag": "[CFS]2-00-S"},
    {"id": "/nes?tag=&e=5&page=", "name": "SFC", "flag": "[CFS]2-00-S"},
    {"id": "/nes?tag=9&e=&page=", "name": "街机", "flag": "[CFS]2-00-S"},
    {"id": "/nes?tag=&e=2&page=", "name": "GBA", "flag": "[CFS]2-00-S"},
    {"id": "/nes?tag=&e=7&page=", "name": "NDS", "flag": "[CFS]2-00-S"},
    {"id": "/nes?tag=&e=3&page=", "name": "MD", "flag": "[CFS]2-00-S"},
    {"id": "/nes?tag=&e=6&page=", "name": "DOS", "flag": "[CFS]2-00-S"},
    {"id": "/nes?tag=&e=4&page=", "name": "FC高清", "flag": "[CFS]2-00-S"},
]

GAME_TYPES = [
    ("/nes?tag=2&e=0&page=", "动作冒险"),
    ("/nes?tag=3&e=0&page=", "飞行射击"),
    ("/nes?tag=4&e=0&page=", "格斗"),
    ("/nes?tag=5&e=0&page=", "棋牌"),
    ("/nes?tag=6&e=0&page=", "射击"),
    ("/nes?tag=7&e=0&page=", "运动比赛"),
    ("/nes?tag=8&e=0&page=", "小游戏"),
    ("/nes?tag=10&e=0&page=", "角色扮演"),
]

CUSTOM_GAMES = [
    {"name": "原神启动！", "url": "https://ys.mihoyo.com/cloud/m/",
     "pic": "https://pan.uvqzu.cn/f/4Z1ue/IMG_20260305_170950.jpg"},
    {"name": "星穹铁道", "url": "https://sr.mihoyo.com/cloud/m/#/",
     "pic": "https://pan.uvqzu.cn/f/Q6ktP/IMG_20260305_171855.jpg"},
    {"name": "好游快爆", "url": "https://m.3839.com/wap.html",
     "pic": "https://pan.uvqzu.cn/f/01jtP/m.baidu.com_1162231158.png"},
    {"name": "TapTap", "url": "https://www.taptap.cn/",
     "pic": "https://pan.uvqzu.cn/f/xpqhX/m.baidu.com_01172723iyvp.png"},
    {"name": "网易云游戏", "url": "https://cg.163.com/#/game/recommend?tab_id=66051b810d5fa1f0204c294f",
     "pic": "https://pan.uvqzu.cn/f/nAyHZ/IMG_20260305_175247.jpg"},
    {"name": "抖音", "url": "https://www.douyin.com/?is_from_mobile_home=1",
     "pic": "https://pan.uvqzu.cn/f/3lJuW/m.baidu.com_e2ecc9605e2f97e1135d87cab2ddcf08.jpeg"},
    {"name": "拼多多", "url": "https://mobile.yangkeduo.com/",
     "pic": "https://pan.uvqzu.cn/f/4ZrSe/IMG_20260305_183229.png"},
    {"name": "淘宝", "url": "https://main.m.taobao.com/",
     "pic": "https://pan.uvqzu.cn/f/Nw5HW/IMG_20260305_182200.jpg"},
    {"name": "京东", "url": "https://m.jd.com/",
     "pic": "https://pan.uvqzu.cn/f/janHj/IMG_20260305_181852.png"},
    {"name": "野草助手", "url": "https://www.yecao.net/",
     "pic": "https://pan.uvqzu.cn/f/JKPcD/m.baidu.com_20231207112652564.png"},
    {"name": "永劫无间", "url": "https://cloudgame.ds.163.com/yjwj",
     "pic": "https://pan.szfx.top/view.php/2c4445e75e023e2dd5b0439253957c77.jpg"},
    {"name": "梦幻西游", "url": "https://xyh5.163.com/game/?channel=netease",
     "pic": "https://pan.szfx.top/view.php/52902e10204e7b07dbc69f6e3fdec9ab.jpg"},
    {"name": "赛尔号", "url": "https://s.61.com/",
     "pic": "https://pan.szfx.top/view.php/f56ac1ae1dd1a49041199a6719fd9234.png"},
    {"name": "刘明野的工具箱", "url": "https://tools.liumingye.cn/",
     "pic": "https://pan.szfx.top/view.php/1dcefe9108bee4a51f0d8e59cffe7a04.png"},
    {"name": "4399小游戏", "url": "https://h.4399.com/",
     "pic": "https://pan.szfx.top/view.php/b5f614076f8a9df19e3cdd1d01bdf09a.png"},
    {"name": "一千个小游戏", "url": "https://fuun.fun/",
     "pic": "https://pan.szfx.top/view.php/8191c07bb1631cde242a61aa97d7fbe5.jpg"},
    {"name": "小霸王游戏机", "url": "https://www.yikm.net",
     "pic": "https://pan.szfx.top/view.php/4d88e211d22818b011d68073353f0d3d.jpg"},
    {"name": "红色警戒2", "url": "https://ra2web.com/",
     "pic": "https://pan.szfx.top/view.php/80ff902afb37581accc402666382a9fb.jpg"},
    {"name": "X的世界", "url": "https://bloxd.io",
     "pic": "https://pan.szfx.top/view.php/0f6ff96aa13b4bb6c3adba724df6e34d.png"},
    {"name": "贪吃蛇", "url": "http://slither.io/",
     "pic": "https://pan.szfx.top/view.php/8818a2e27a1c6fa9a6d702e579ad9d1b.jpg"},
    {"name": "斗地主(人机)", "url": "https://www.haiwaiqipai.com/games/doudizhus/index.html",
     "pic": "https://www.haiwaiqipai.com/img/DouDiZhu.jpg"},
    {"name": "五子棋", "url": "https://wuziqi.hongton.com",
     "pic": "https://wuziqi.hongton.com/img/stype/init-bg.png"},
    {"name": "俄罗斯方块", "url": "https://v2fy.com/game/tetris/",
     "pic": "https://i-1-uc129.zswxy.cn/2023/0223/5d809bdb026646478a97a938f7b3300c.png"},
    {"name": "魂斗罗(美版)", "url": "https://www.yikm.net/play?id=4137",
     "pic": "https://img.1990i.com/fcpic/sj/436a.png"},
    {"name": "冒险岛(日版)", "url": "https://www.yikm.net/play?id=3175",
     "pic": "https://img.1990i.com/fcpic/3175.png"},
    {"name": "拳皇97", "url": "https://www.yikm.net/play?id=5326",
     "pic": "https://img.1990i.com/arcadepic/kof97.png"},
]

ALL_CLASSES = (
    [{"type_id": "定制", "type_name": "定制", "type_flag": "2-00-S"}]
    + [{"type_id": p["id"], "type_name": p["name"], "type_flag": p["flag"]} for p in PLATFORMS]
)

_FILTER_VALUE = [{"n": "全部", "v": ""}] + [{"n": n, "v": t} for t, n in GAME_TYPES]
ALL_FILTERS = {}
for p in PLATFORMS:
    ALL_FILTERS[p["id"]] = [{"key": "class", "name": "类型", "value": _FILTER_VALUE}]

_CARD_SPLIT = re.compile(r'<div\s+class="col-md-3 col-xs-6">')
_H4_LINK = re.compile(r'<h4[^>]*>\s*<a\s+href="([^"]+)">([^<]+)</a>', re.S)
_ANY_LINK = re.compile(r'<a\s+href="([^"]+)"')
_IMG_SRC = re.compile(r'<img[^>]+src="([^"]+)"')


def _browser_vod(url, name, pic='', header=None):
    action = {
        "actionId": "browser",
        "type": "browser",
        "title": "小游戏",
        "url": url,
        "textZoom": 100,
        "header": header or ACTION_HEADER,
    }
    return {
        "vod_id": json.dumps(action, ensure_ascii=False),
        "vod_name": name,
        "vod_pic": pic,
        "vod_tag": "action",
    }


def _ssl_ctx():
    return ssl.create_default_context()


def _proxy_for(parsed):
    host = (parsed.hostname or "").lower()
    no_proxy = os.environ.get("no_proxy") or os.environ.get("NO_PROXY") or ""
    for item in no_proxy.replace(",", " ").split():
        item = item.strip().lower()
        if item and (host == item or host.endswith("." + item) or item == "*"):
            return None
    if parsed.scheme == "https":
        raw = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY") or ""
    else:
        raw = os.environ.get("http_proxy") or os.environ.get("HTTP_PROXY") or ""
    if not raw:
        return None
    p = urllib.parse.urlparse(raw if "://" in raw else "http://" + raw)
    if not p.hostname:
        return None
    return (p.hostname, p.port or 80)


def _decode_body(raw, encoding):
    enc = (encoding or "").lower()
    try:
        if "gzip" in enc:
            raw = gzip.decompress(raw)
        elif "deflate" in enc:
            try:
                raw = zlib.decompress(raw)
            except zlib.error:
                raw = zlib.decompress(raw, -zlib.MAX_WBITS)
    except Exception:
        pass
    return raw.decode("utf-8", errors="replace")


def _http_get_once(url, timeout, headers=None, depth=0):
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    req_headers = {"User-Agent": UA, "Host": parsed.netloc}
    if headers:
        req_headers.update(headers)
    proxy = _proxy_for(parsed)
    if proxy:
        if parsed.scheme == "https":
            conn = http.client.HTTPSConnection(proxy[0], proxy[1], timeout=timeout, context=_ssl_ctx())
            conn.set_tunnel(host, port)
        else:
            conn = http.client.HTTPConnection(proxy[0], proxy[1], timeout=timeout)
            path = url
    elif parsed.scheme == "https":
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=_ssl_ctx())
    else:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", path, headers=req_headers)
        resp = conn.getresponse()
        status = resp.status
        data = resp.read()
        headers_out = dict((k.lower(), v) for k, v in resp.getheaders())
        if status in (301, 302, 303, 307, 308) and depth < 2:
            loc = headers_out.get("location") or ""
            if loc:
                return _http_get_once(urllib.parse.urljoin(url, loc), timeout, headers, depth + 1)
        return status, _decode_body(data, headers_out.get("content-encoding"))
    finally:
        try:
            conn.close()
        except Exception:
            pass


class Spider(BaseSpider):
    siteUrl = HOST
    headers = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Encoding': 'gzip, deflate',
        'Referer': HOST + '/',
    }

    def __init__(self):
        self._cat_cache = {}
        self._search_cache = {}

    def getName(self):
        return "小霸王游戏"

    def getDependence(self):
        return []

    def init(self, extend=""):
        self.extend = extend or ""

    def destroy(self):
        pass

    def close(self):
        self.destroy()

    def _get_text(self, url, referer='', timeout=TIMEOUT_PAGE):
        headers = dict(self.headers)
        headers['Connection'] = 'keep-alive'
        if referer:
            headers['Referer'] = referer
        for attempt in range(2):
            try:
                status, text = _http_get_once(url, timeout, headers)
                if status == 429:
                    time.sleep(2.0)
                    continue
                if status != 200:
                    raise ValueError("http %d" % status)
                return text
            except Exception:
                if attempt == 0:
                    time.sleep(0.2)
                else:
                    return ""
        return ""

    @staticmethod
    def _cache_get(cache, key, ttl):
        item = cache.get(key)
        if item and time.time() - item[0] < ttl:
            return item[1]
        return None

    @staticmethod
    def _cache_set(cache, key, value, ttl):
        if len(cache) > 512:
            cache.clear()
        cache[key] = (time.time(), value, ttl)

    @staticmethod
    def _abs(u):
        u = (u or '').strip()
        if not u:
            return ''
        if u.startswith('//'):
            return 'https:' + u
        if u.startswith('/'):
            return HOST + u
        if not u.startswith('http'):
            return HOST + '/' + u
        return u

    def _parse_cards(self, html_text, limit=40):
        if not html_text:
            return []
        out = []
        chunks = _CARD_SPLIT.split(html_text)
        for chunk in chunks[1:]:
            m = _H4_LINK.search(chunk)
            if m:
                url = self._abs(m.group(1))
                name = html.unescape(m.group(2)).strip()
            else:
                a = _ANY_LINK.search(chunk)
                if a is None:
                    continue
                url = self._abs(a.group(1))
                name = ""
                nm = re.search(r'<a\s+href="[^"]+">([^<]+)</a>', chunk)
                if nm:
                    name = html.unescape(nm.group(1)).strip()
            if not name or not url or 'javascript' in url:
                continue
            pic = ''
            img = _IMG_SRC.search(chunk)
            if img is not None:
                pic = self._abs(img.group(1))
            out.append(_browser_vod(url, name, pic))
            if len(out) >= limit:
                break
        return out

    def homeContent(self, filter=""):
        return {
            "class": ALL_CLASSES,
            "filters": ALL_FILTERS,
            "list": [],
        }

    def homeVideoContent(self):
        return {"list": [_browser_vod(g["url"], g["name"], g.get("pic", "")) for g in CUSTOM_GAMES[:20]]}

    def _empty_category(self, page=1):
        return {"list": [], "page": page, "pagecount": 1, "limit": 40, "total": 0}

    def _custom_list(self, pg):
        if pg and int(pg) > 1:
            return {"list": []}
        return {"list": [_browser_vod(g["url"], g["name"], g.get("pic", "")) for g in CUSTOM_GAMES]}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        page = 1
        try:
            page = max(1, int(pg or 1))
            ext = {}
            if extend:
                if isinstance(extend, dict):
                    ext = extend
                elif isinstance(extend, str):
                    try:
                        ext = json.loads(extend)
                    except Exception:
                        ext = {}

            if str(tid).strip() == '定制':
                return self._custom_list(page)

            if ext.get('custom'):
                return self.searchContent(str(ext['custom']), quick=True, pg=page)

            type_path = (ext.get('class') or '').strip()
            if type_path:
                url = HOST + type_path + str(page)
            else:
                raw_tid = str(tid).strip()
                if not raw_tid.startswith('/nes?'):
                    for tpl, _name in GAME_TYPES:
                        if tpl.startswith('/nes?tag=' + raw_tid + '&') or raw_tid == tpl:
                            url = HOST + tpl + str(page)
                            break
                    else:
                        url = HOST + raw_tid + str(page)
                else:
                    url = HOST + raw_tid + str(page)

            ckey = "%s|%d|%s" % (url, page, type_path)
            cached = self._cache_get(self._cat_cache, ckey, TTL_CAT)
            if cached is not None:
                return cached

            html_text = self._get_text(url)
            if not html_text:
                return self._empty_category(page)

            vod_list = self._parse_cards(html_text)
            vod_list.append(_browser_vod("https://www.crazygames.com", "crazygames", ''))
            vod_list.append(_browser_vod("https://poki.com/zh", "poki", ''))

            result = {
                "list": vod_list,
                "page": page,
                "pagecount": 10,
                "limit": 40,
                "total": 400,
            }
            self._cache_set(self._cat_cache, ckey, result, TTL_CAT)
            return result
        except Exception:
            return self._empty_category(page)

    def detailContent(self, ids):
        if isinstance(ids, str):
            ids = [ids]
        vid = str(ids[0]) if ids else ''
        try:
            action = json.loads(vid)
            url = action.get("url") or ""
            name = action.get("title") or "小游戏"
        except Exception:
            url = vid
            name = vid
        if not url:
            return {"list": []}
        detail = {
            "vod_id": vid,
            "vod_name": name,
            "vod_pic": '',
            "type_name": "小游戏",
            "vod_remarks": "点开即玩",
            "vod_year": '',
            "vod_area": '',
            "vod_lang": '',
            "vod_director": '',
            "vod_actor": '',
            "vod_content": "%s 点开即用浏览器打开游玩" % name,
            "vod_play_from": "在线玩",
            "vod_play_url": "在线玩$%s" % url,
        }
        return {"list": [detail]}

    def playerContent(self, flag, id, vipFlags=None):
        if not id:
            return {"parse": 0, "playUrl": "", "url": ""}
        url = str(id)
        if url.startswith('http'):
            return {
                "parse": 1,
                "playUrl": "",
                "url": url,
                "header": ACTION_HEADER,
            }
        return {"parse": 0, "playUrl": "", "url": url, "header": ACTION_HEADER}

    def searchContent(self, keyword, quick=False, pg=1):
        kw = quote((keyword or '').strip())
        if not kw:
            return {"list": [], "msg": "请输入搜索关键词"}

        page = int(pg or 1)
        ckey = "%s|%s" % (page, (keyword or '').strip().lower())
        cached = self._cache_get(self._search_cache, ckey, TTL_SEARCH)
        if cached is not None:
            return cached

        url = "%s/search?name=%s" % (HOST, kw)
        html_text = self._get_text(url, referer=HOST + '/', timeout=TIMEOUT_API)
        if html_text:
            vod_list = self._parse_cards(html_text)
            if vod_list:
                result = {"list": vod_list, "page": page}
                self._cache_set(self._search_cache, ckey, result, TTL_SEARCH)
                return result

        result = {"list": [], "msg": "未找到相关游戏，请尝试其他关键词或通过分类浏览", "page": page}
        self._cache_set(self._search_cache, ckey, result, TTL_SEARCH)
        return result

    def localProxy(self, param=None):
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get("url") or p.get("u") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = urllib.parse.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            parsed = urllib.parse.urlparse(target)
            headers = {"User-Agent": UA, "Referer": "%s://%s/" % (parsed.scheme, parsed.netloc)}
            req = urllib.request.Request(target, headers=headers)
            last_err = None
            for _ in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=20, context=_ssl_ctx()) as resp:
                        ctype = resp.headers.get("Content-Type") or "application/octet-stream"
                        return [resp.status, ctype, resp.read(), {}]
                except urllib.error.HTTPError as e:
                    try:
                        body = e.read()
                    except Exception:
                        body = b""
                    return [e.code, e.headers.get("Content-Type") or "text/plain", body, {}]
                except Exception as e:
                    last_err = e
                    time.sleep(0.5)
            raise last_err
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def isVideoFormat(self, url):
        url = (url or "").lower()
        return any(k in url for k in (".m3u8", ".mp4", ".m4s", ".ts"))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None


if __name__ == '__main__':
    s = Spider()
    action = sys.argv[1] if len(sys.argv) > 1 else 'home'
    if action == 'home':
        print(json.dumps(s.homeContent(), ensure_ascii=False)[:600])
    elif action == 'category':
        tid = sys.argv[2] if len(sys.argv) > 2 else '定制'
        pg = sys.argv[3] if len(sys.argv) > 3 else '1'
        cl = sys.argv[4] if len(sys.argv) > 4 else ''
        r = s.categoryContent(tid, pg, False, {'class': cl} if cl else {})
        print("list=%d" % len(r.get('list', [])))
        for it in r.get('list', [])[:5]:
            try:
                act = json.loads(it['vod_id'])
                print(" -", it['vod_name'], "|", act.get('url', '')[:60], "| tag:", it.get('vod_tag'))
            except Exception:
                print(" -", it['vod_name'], "|", it['vod_id'][:60])
    elif action == 'search':
        kw = sys.argv[2] if len(sys.argv) > 2 else '魂斗罗'
        r = s.searchContent(kw)
        print("list=%d" % len(r.get('list', [])))
        for it in r.get('list', [])[:5]:
            try:
                act = json.loads(it['vod_id'])
                print(" -", it['vod_name'], "|", act.get('url', '')[:60])
            except Exception:
                print(" -", it['vod_name'])
    elif action == 'detail':
        vid = sys.argv[2] if len(sys.argv) > 2 else '{"actionId":"browser","type":"browser","title":"小游戏","url":"https://www.yikm.net/play?id=4137","header":{"User-Agent":"x"}}'
        print(json.dumps(s.detailContent(vid), ensure_ascii=False)[:500])
    s.close()
