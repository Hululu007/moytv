import gzip
import json
import re
import ssl
import time
import unicodedata
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

BASE = 'https://11171224.2026aidj789.lol'
JUMP = 'https://2026.2026aidjtz.top/?yng'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

KNOWN_CATS = [
    ('2427808755', '国产自拍'),
    ('1821390968', 'AI短剧'),
    ('4211939055', '日本无码'),
    ('1335262090', '欧美'),
    ('3725810177', '主播'),
]

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
try:
    CTX.maximum_version = ssl.TLSVersion.TLSv1_2
    CTX.minimum_version = ssl.TLSVersion.TLSv1_2
except Exception:
    pass

CACHE = {}
CATS_TTL = 3600
_CUR_BASE = [BASE]


def _now():
    return time.time()


def _clean(s):
    if not s:
        return ''
    s = re.sub(r'<zq-h[^>]*>.*?</zq-h>', '', s, flags=re.S)
    s = re.sub(r'<[^>]+>', ' ', s)
    s = s.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&quot;', '"')
    s = s.replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>')
    out = []
    for ch in s:
        if ch == '\u034f' or unicodedata.category(ch) in ('Cf', 'Cc'):
            continue
        out.append(ch)
    return re.sub(r'\s+', ' ', ''.join(out)).strip()


def _http_get(url, referer=None, timeout=70):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                if resp.status != 200:
                    return None
                try:
                    data = resp.read()
                except Exception as e:
                    data = getattr(e, 'partial', b'') or b''
                enc = (resp.headers.get('Content-Encoding') or '').lower()
            if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            text = data.decode('utf-8', 'replace')
            return text if text.strip() else None
        except Exception:
            if attempt < 2:
                try:
                    time.sleep(1)
                except Exception:
                    pass
    return None


def _is_site_page(html):
    if not html:
        return False
    return '/shipin/' in html or 'window.ZQ' in html or '/list/' in html


def _resolve_base():
    raw = _http_get(JUMP, referer=None, timeout=60)
    if raw:
        m = re.search(r'fixedDomain\s*=\s*"([^"]+)"', raw)
        if m:
            dom = m.group(1).strip()
            if dom:
                return 'https://' + dom
    return None


def _fetch(path, referer=None):
    base = _CUR_BASE[0]
    html = _http_get(base + path, referer=referer or (base + '/'))
    if _is_site_page(html):
        return html
    new_base = _resolve_base()
    if new_base and new_base != base:
        _CUR_BASE[0] = new_base
        html = _http_get(new_base + path, referer=referer or (new_base + '/'))
        if _is_site_page(html):
            return html
    if html:
        return html
    return None


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return _CUR_BASE[0] + u
    return u


def _parse_cards(html):
    out = []
    if not html:
        return out
    anchors = list(re.finditer(
        r'<a class="card" href="/shipin/(\d+)" title="([^"]*)"', html))
    seen = set()
    for i, m in enumerate(anchors):
        vid = m.group(1).strip()
        if not vid or vid in seen:
            continue
        seen.add(vid)
        end = anchors[i + 1].start() if i + 1 < len(anchors) else min(m.start() + 3000, len(html))
        chunk = html[m.start():end]
        title = _clean(m.group(2))
        if not title:
            continue
        cover = ''
        imgs = re.findall(r'<img[^>]+src="([^"]+)"', chunk)
        for im in imgs:
            if '/upload/vod/' in im:
                cover = im
                break
        if not cover and imgs:
            cover = imgs[0]
        remark = ''
        rm = re.search(r'更新至\s*(\d+)\s*集', _clean(chunk))
        if rm:
            remark = '更新至%s集' % rm.group(1)
        elif 'NEW' in chunk:
            remark = 'NEW'
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': _fix_url(cover),
            'vod_remarks': remark,
        })
    return out


def _fetch_categories():
    v = CACHE.get('cats')
    if v and _now() - v[0] < v[2]:
        return v[1]
    known = dict(KNOWN_CATS)
    cats = []
    html = _fetch('/')
    if html:
        seen = set()
        for m in re.finditer(r'href="/list/(\d+)"', html):
            cid = m.group(1).strip()
            if cid in known and cid not in seen:
                seen.add(cid)
                cats.append((cid, known[cid]))
    ttl = CATS_TTL
    if not cats:
        cats = list(KNOWN_CATS)
        ttl = 300
    if len(CACHE) > 20:
        CACHE.clear()
    CACHE['cats'] = (_now(), cats, ttl)
    return cats


def _parse_episodes(html, nid):
    eps = []
    if not html:
        return eps
    blk = ''
    m = re.search(r'<div class="ep-list">(.*?)</div>', html, re.S)
    if m:
        blk = m.group(1)
    seen = set()
    for am in re.finditer(r'href="/shipin/(\d+)(\?j=(\d+))?"[^>]*>(.*?)</a>', blk, re.S):
        vid = am.group(1).strip()
        jnum = am.group(3)
        label = _clean(am.group(4))
        if not label:
            label = '第%s集' % (jnum or '1')
        key = vid + ':' + (jnum or '1')
        if key in seen:
            continue
        seen.add(key)
        if jnum and jnum != '1':
            eps.append((int(jnum), '%s$ai2026:%s?j=%s' % (label, vid, jnum)))
        else:
            eps.append((1, '%s$ai2026:%s' % (label, vid)))
    eps.sort(key=lambda x: x[0])
    return [e[1] for e in eps]


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
        return '🔞2026短剧AI'

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
        html = _fetch('/')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if pg <= 1:
            path = '/list/%s' % tid
        else:
            path = '/list/%s/%d' % (tid, pg)
        html = _fetch(path)
        items = _parse_cards(html)
        pagecount = pg
        if html:
            nums = [int(n) for n in re.findall(
                r'/list/%s/(\d+)' % re.escape(tid), html)]
            if nums:
                pagecount = max(max(nums), pg)
        return {'list': items, 'page': pg, 'pagecount': pagecount, 'total': 0}

    def detailContent(self, ids):
        raw = _norm_id(ids)
        nid = ''.join([ch for ch in raw.split('?')[0] if ch.isdigit()])
        if not nid:
            return _empty_detail(raw)
        html = _fetch('/shipin/%s' % nid)
        if not html:
            return _empty_detail(nid)
        title = ''
        hm = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
        if hm:
            h1 = re.sub(r'<small[^>]*>.*?</small>', '', hm.group(1), flags=re.S)
            title = _clean(h1)
        if not title:
            tm = re.search(r'<title[^>]*>(.*?)</title>', html, re.S)
            if tm:
                title = _clean(tm.group(1))
                for suf in (' - 2026AI短剧',):
                    if title.endswith(suf):
                        title = title[:-len(suf)].strip()
                title = re.sub(r'\s*第\d+集\s*$', '', title).strip()
        if not title:
            return _empty_detail(nid)
        cover = ''
        om = re.search(r'<meta property="og:image"[^>]*content="([^"]+)"', html)
        if om:
            cover = _fix_url(om.group(1))
        if not cover:
            pm = re.search(r'<video[^>]*poster="([^"]+)"', html)
            if pm:
                cover = _fix_url(pm.group(1))
        tags = []
        for tm in re.finditer(r'<a class="chip"[^>]*>(.*?)</a>', html, re.S):
            t = _clean(tm.group(1))
            if t and t not in tags:
                tags.append(t)
        remark = ''
        um = re.search(r'更新至\s*(\d+)\s*集', _clean(html))
        if um:
            remark = '更新至%s集' % um.group(1)
        dm = re.search(r'(\d{4}-\d{2}-\d{2})\s*更新', _clean(html))
        if dm:
            remark = (remark + ' ' + dm.group(1)).strip()
        eps = _parse_episodes(html, nid)
        if not eps:
            eps = ['正片$ai2026:%s' % nid]
        parts = []
        if tags:
            parts.append('标签：' + '、'.join(tags))
        if remark:
            parts.append(remark)
        return {'list': [{
            'vod_id': nid,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_director': '',
            'vod_remarks': remark,
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': ' / '.join(tags[:3]),
            'vod_tag': '、'.join(tags),
            'vod_play_from': '在线播放',
            'vod_play_url': '#'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        path = '/seek?wd=%s' % kw
        if pg > 1:
            path += '&page=%d' % pg
        html = _fetch(path)
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        if raw.startswith('ai2026:'):
            raw = raw.split(':', 1)[1].strip()
        base = _CUR_BASE[0]
        header = {'User-Agent': UA, 'Referer': base + '/'}
        if raw.startswith('http') and '.m3u8' in raw:
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        m = re.match(r'(\d+)(\?j=(\d+))?$', raw.strip())
        if not m:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        path = '/shipin/%s' % m.group(1)
        if m.group(3):
            path += '?j=%s' % m.group(3)
        page_url = base + path
        html = _fetch(path, referer=page_url)
        url = ''
        if html:
            dm = re.search(r'data-src="([^"]+\.m3u8[^"]*)"', html)
            if dm:
                url = _clean(dm.group(1))
            if not url:
                um = re.search(r'(https?://[^\s"\']+\.m3u8[^\s"\']*)', html)
                if um:
                    url = _clean(um.group(1))
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        header = {'User-Agent': UA, 'Referer': page_url}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
