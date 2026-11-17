import gzip
import http.client
import json
import re
import ssl
import time
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

try:
    import requests as _requests
except Exception:
    _requests = None

BASE = 'https://aisee10w29.buzz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

FALLBACK_CATS = [
    ('25', 'AI成人短剧'),
    ('26', 'AI成人漫剧'),
]

FLAG_WORDS = [
    'loli', 'lolita', '幼女', '幼齿', '初中生', '小学生', '未成年',
    '未满', '萝莉', '童颜', '幼态', '处女', '小萝莉',
]


def _is_flagged(name):
    low = (name or '').lower()
    return any(w.lower() in low for w in FLAG_WORDS)


CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CACHE = {}
CATS_TTL = 3600
_CUR_BASE = [BASE]
_SESSION = [None]


def _get_session():
    if _SESSION[0] is None and _requests is not None:
        try:
            _SESSION[0] = _requests.Session()
        except Exception:
            _SESSION[0] = None
    return _SESSION[0]


def _now():
    return time.time()


def _http_via_client(url, hdr, timeout):
    proxies = urllib.request.getproxies()
    for _hop in range(6):
        parts = urllib.parse.urlsplit(url)
        scheme = (parts.scheme or 'https').lower()
        host = parts.hostname or ''
        if not host:
            return None
        port = parts.port or (443 if scheme == 'https' else 80)
        path = urllib.parse.urlunsplit(('', '', parts.path or '/', parts.query, ''))
        proxy = None
        try:
            if not urllib.request.proxy_bypass(host):
                proxy = proxies.get(scheme)
        except Exception:
            proxy = proxies.get(scheme)
        conn = None
        try:
            if proxy:
                pp = urllib.parse.urlsplit(proxy)
                phost = pp.hostname or ''
                pport = pp.port or 8080
                if not phost:
                    return None
                if scheme == 'https':
                    conn = http.client.HTTPSConnection(phost, pport, context=CTX, timeout=timeout)
                    conn.set_tunnel(host, port)
                else:
                    conn = http.client.HTTPConnection(phost, pport, timeout=timeout)
                    path = url
            elif scheme == 'https':
                conn = http.client.HTTPSConnection(host, port, context=CTX, timeout=timeout)
            else:
                conn = http.client.HTTPConnection(host, port, timeout=timeout)
            hdrs = dict(hdr)
            hdrs['Connection'] = 'keep-alive'
            conn.request('GET', path, headers=hdrs)
            resp = conn.getresponse()
            status = resp.status
            if status in (301, 302, 303, 307, 308):
                loc = resp.headers.get('Location')
                try:
                    resp.read()
                except Exception:
                    pass
                if not loc:
                    return None
                url = urllib.parse.urljoin(url, loc)
                continue
            if status != 200:
                try:
                    resp.read()
                except Exception:
                    pass
                return None
            data = resp.read()
            enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            return data.decode('utf-8', 'replace')
        except Exception:
            return None
        finally:
            try:
                if conn is not None:
                    conn.close()
            except Exception:
                pass
    return None


def _http_get(url, referer=None, timeout=25, extra_headers=None):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    if extra_headers:
        hdr.update(extra_headers)
    for attempt in range(3):
        text = None
        sess = _get_session()
        if sess is not None:
            try:
                resp = sess.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is None and _requests is not None:
            try:
                resp = _requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is None:
            try:
                text = _http_via_client(url, hdr, timeout)
            except Exception:
                text = None
        if text is None:
            try:
                req = urllib.request.Request(url, headers=hdr)
                with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                    if resp.status == 200:
                        data = resp.read()
                        enc = (resp.headers.get('Content-Encoding') or '').lower()
                        if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                            try:
                                data = gzip.decompress(data)
                            except Exception:
                                pass
                        text = data.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is not None:
            return text
        if attempt < 2:
            try:
                time.sleep(2)
            except Exception:
                pass
    return None


def _fetch(path, referer=None, extra_headers=None):
    base = _CUR_BASE[0]
    return _http_get(base + path, referer=referer or (base + '/network/'), extra_headers=extra_headers)


def _unescape(s):
    if not s:
        return ''
    return (s.replace('&nbsp;', ' ')
             .replace('&amp;', '&')
             .replace('&quot;', '"')
             .replace('&#39;', "'")
             .replace('&lt;', '<')
             .replace('&gt;', '>')
             .replace('\\/', '/'))


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return _CUR_BASE[0] + u
    return u


def _strip_tags(s):
    if not s:
        return ''
    s = re.sub(r'<[^>]+>', ' ', s)
    s = _unescape(s)
    s = re.sub(r'\s+', ' ', s)
    return s.strip()


def _parse_cards(html):
    out = []
    if not html:
        return out
    card_re = re.compile(
        r'<a\s+href="/detail/(\d+)/"[^>]*?class="video-cover"[^>]*?>'
        r'\s*<img[^>]*?src="([^"]+)"[^>]*?alt="([^"]*)"',
        re.S)
    title_re = re.compile(
        r'<h4 class="video-title">\s*<a[^>]*>\s*([^<]+?)\s*</a>', re.S)
    view_re = re.compile(r'<div class="video-view">\s*([\d,]+)\s*浏览')
    seen = set()
    for m in card_re.finditer(html):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        seen.add(vid)
        tail = html[m.end():m.end() + 2000]
        tm = title_re.search(tail)
        title = _unescape(tm.group(1).strip()) if tm else _unescape(m.group(3).strip())
        if not title:
            continue
        vm = view_re.search(tail)
        remark = (vm.group(1).strip() + '浏览') if vm else ''
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(m.group(2)),
            'vod_remarks': remark,
        })
    return out


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
        return v[1]
    cats = []
    html = _fetch('/network/')
    if html:
        i = html.find('vod-category-menu')
        if i >= 0:
            rest = html[i:]
            end = rest.find('色色本')
            menu = rest[:end] if end > 0 else rest
            pat = re.compile(
                r'<a href="/aidj/(\d+)/"[^>]*>.*?</i>\s*([^<]+?)\s*</a>', re.S)
            seen = set()
            for m in pat.finditer(menu):
                cid = m.group(1).strip()
                name = _unescape(m.group(2).strip())
                if not name or cid in seen:
                    continue
                seen.add(cid)
                cats.append((cid, name))
    ttl = CATS_TTL
    if not cats:
        cats = list(FALLBACK_CATS)
        ttl = 300
    cats = [(cid, name) for cid, name in cats if not _is_flagged(name)]
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _parse_title(html):
    m = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
    if not m:
        return ''
    return _strip_tags(m.group(1))


def _parse_cover(html):
    m = re.search(r'<img[^>]*src="([^"]*?/upload/huangguo/[^"]+)"', html)
    if m:
        return _fix_url(m.group(1))
    return ''


def _parse_synopsis(html):
    m = re.search(r'<meta name="description" content="([^"]*)"', html)
    if not m:
        return ''
    return _unescape(m.group(1).strip())


def _parse_player_data(html):
    if not html:
        return '', ''
    m = re.search(r'player_data=\{.*?"url":"([^"]+)"', html, re.S)
    url = m.group(1).strip() if m else ''
    fm = re.search(r'"from":"([^"]+)"', html)
    frm = fm.group(1).strip() if fm else ''
    return url, frm


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids)


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        try:
            return int(str(pg).strip())
        except Exception:
            return 1


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
        'vod_name': '',
        'vod_pic': '',
        'vod_actor': '',
        'vod_director': '',
        'vod_remarks': '',
        'vod_year': '',
        'vod_area': '',
        'vod_content': '',
        'type_name': '',
        'vod_tag': '',
        'vod_play_from': '在线播放',
        'vod_play_url': '',
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return '🔞AI短剧AV'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': cid, 'type_name': name}
                for cid, name in _fetch_categories()]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/network/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        for cid, name in _fetch_categories():
            if cid == tid and _is_flagged(name):
                return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        if pg <= 1:
            path = '/aidj/%s/' % tid
        else:
            path = '/aidj/%s/page/%d/' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        html = _fetch('/detail/%s/' % nid)
        if not html:
            return _empty_detail(nid)
        title = _parse_title(html)
        if not title:
            return _empty_detail(nid)
        cover = _parse_cover(html)
        synopsis = _parse_synopsis(html)
        eps = sorted(set(re.findall(r'href="/play/%s-1-(\d+)/"' % nid, html)),
                     key=lambda x: int(x))
        if not eps:
            eps = ['1']
        plays = ['第%s集$aidj:%s-1-%s' % (ep, nid, ep) for ep in eps]
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': '',
            'vod_year': '',
            'vod_area': '',
            'vod_content': synopsis,
            'type_name': '',
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(plays),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        html = _fetch('/search/%s-------------/' % kw)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('aidj:'):
            raw = raw.split(':', 1)[1].strip()
        if raw.startswith('http'):
            header = {'User-Agent': UA, 'Referer': _CUR_BASE[0] + '/network/'}
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        parts = raw.split('-')
        if len(parts) != 3:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        vid, sid, ep = parts[0], parts[1], parts[2]
        if not vid.isdigit() or not ep.isdigit():
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        play_page = '/play/%s-%s-%s/' % (vid, sid, ep)
        page_url = _CUR_BASE[0] + play_page
        html = _fetch(play_page, referer=page_url)
        url, frm = _parse_player_data(html)
        header = {'User-Agent': UA, 'Referer': page_url}
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if '.m3u8' in url or '.mp4' in url:
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        if '|' not in url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        mid, mep = url.split('|', 1)
        mid = mid.strip()
        mep = mep.strip()
        if frm != 'huangguo' or not mid or not mep:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        api = '/huangguo.php?ac=play&id=%s&ep=%s' % (mid, mep)
        body = _fetch(api, referer=page_url, extra_headers={'X-Requested-With': 'XMLHttpRequest'})
        if not body:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        try:
            data = json.loads(body)
        except Exception:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if data.get('code') != 1:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        proxy = str(data.get('url') or '').strip()
        if not (proxy.startswith('/hgmedia.php?e=') or proxy.startswith('/huangguo.php?ac=media')):
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        full = _CUR_BASE[0] + proxy
        return {'parse': 0, 'playUrl': full, 'url': full, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
