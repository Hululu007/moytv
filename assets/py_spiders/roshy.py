import gzip
import html as htmlmod
import json
import re
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

BASE = 'https://roshy.tv'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
TIMEOUT = 30
RETRY = 3

CLASSES = [
    {'type_id': 'home', 'type_name': '最新视频'},
    {'type_id': 'cat:english-sub-11', 'type_name': '英文字幕'},
    {'type_id': 'cat:decensored-6', 'type_name': '无码'},
    {'type_id': 'cats_index', 'type_name': '全部分类'},
    {'type_id': 'stars_index', 'type_name': '女优'},
]


def _dec(raw):
    for enc in ('utf-8', 'gb18030'):
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode('utf-8', 'ignore')


def _headers(referer=None):
    return {'User-Agent': UA, 'Referer': referer or BASE + '/'}


def _get_req(url, referer=None):
    r = _requests.get(url, headers=_headers(referer), timeout=TIMEOUT)
    if r.status_code >= 400:
        raise IOError('http %s' % r.status_code)
    return r.text


def _get_urllib(url, referer=None):
    req = urllib.request.Request(url)
    for k, v in _headers(referer).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        raw = r.read()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    return _dec(raw)


def http_get(url, referer=None):
    if not url.startswith('http'):
        url = BASE + url
    for attempt in range(RETRY):
        try:
            if _requests is not None:
                return _get_req(url, referer)
            break
        except Exception:
            time.sleep(0.5 * (attempt + 1))
    for attempt in range(RETRY):
        try:
            return _get_urllib(url, referer)
        except Exception:
            time.sleep(0.5 * (attempt + 1))
    return ''


def txt_of(s):
    s = re.sub(r'(?is)<(script|style)[^>]*>.*?</\1>', ' ', s or '')
    s = re.sub(r'(?s)<[^>]+>', ' ', s)
    return re.sub(r'\s+', ' ', htmlmod.unescape(s)).strip()


def _base36(n, b):
    digs = '0123456789abcdefghijklmnopqrstuvwxyz'
    if n == 0:
        return '0'
    s = ''
    while n:
        s = digs[n % b] + s
        n //= b
    return s


def _unpack_packed(html):
    m = re.search(r"eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)", html or '', re.S)
    if not m:
        return ''
    p, a, c, k = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4).split('|')
    out = p
    for i in range(c - 1, -1, -1):
        if i < len(k) and k[i]:
            word = k[i]
            out = re.sub(r'\b' + _base36(i, a) + r'\b', lambda mm: word, out)
    return out


def _embed_hls(embed_url):
    html = http_get(embed_url, BASE + '/')
    if not html:
        return ''
    unpacked = _unpack_packed(html)
    for src in (unpacked, html):
        lm = re.search(r'links=\{([^}]*)\}', src)
        if lm:
            body = lm.group(1)
            for key in ('hls2', 'hls4', 'hls3'):
                mm = re.search(r'"' + key + r'":"([^"]+)"', body)
                if mm:
                    u = mm.group(1)
                    if u.startswith('http'):
                        return u
                    if u.startswith('/'):
                        return urllib.parse.urljoin(embed_url, u)
    mm = re.search(r'(https?://[^\s"\'\\]+\.m3u8[^\s"\'\\]*)', unpacked or html)
    if mm:
        return mm.group(1)
    return ''


def parse_cards(html):
    out = []
    seen = set()
    for m in re.finditer(r'<article[^>]*vidmov_video[^>]*>(.*?)</article>', html or '', re.S):
        blk = m.group(1)
        lm = re.search(r'<a[^>]+data-post-type="vidmov_video"[^>]+href="(https://roshy\.tv/video/[^"]+)"', blk)
        if not lm:
            lm = re.search(r'<a[^>]+href="(https://roshy\.tv/video/[^"]+)"[^>]+class="blog-img-link', blk)
        if not lm:
            continue
        url = lm.group(1)
        if url in seen:
            continue
        seen.add(url)
        tm = re.search(r'title="([^"]+)"', blk)
        name = txt_of(tm.group(1)) if tm else url
        im = re.search(r'<img[^>]+src="(https://[^"]+)"', blk)
        pic = im.group(1) if im else ''
        tags = re.findall(r'class="beeteam368-duration[^"]*"[^>]*>([^<]+)<', blk)
        out.append({
            'vod_id': url,
            'vod_name': name,
            'vod_pic': pic,
            'vod_remarks': ' '.join(txt_of(t) for t in tags if txt_of(t)),
        })
    return out


def _pagecount(html, pg):
    nums = [int(n) for n in re.findall(r'/page/(\d+)/', html or '')]
    nums += [int(n) for n in re.findall(r'class="[^"]*current[^"]*"[^>]*>\s*(\d+)', html or '')]
    pc = max(nums) if nums else int(pg)
    return max(pc, int(pg))


def _listing(html, pg, limit=30):
    pc = _pagecount(html, pg)
    return {'page': int(pg), 'pagecount': pc,
            'limit': limit, 'total': pc * limit,
            'list': parse_cards(html)}


def _cats_index():
    html = http_get(BASE + '/categories/')
    out = []
    seen = set()
    if html:
        body = html
        best = {}
        for mm in re.finditer(r'<a[^>]+href="https://roshy\.tv/category/([^"/]+)/"[^>]*>(.*?)</a>', body, re.S):
            slug = mm.group(1)
            t = txt_of(mm.group(2))
            has_count = bool(re.search(r'\d[\d,]*\s*videos?$', t) or re.search(r'\s\d{3}[\d,]*$', t))
            t = re.sub(r'\s*(?:\d[\d,]*\s*videos?|\d{3}[\d,]*)$', '', t).strip()
            if not t:
                continue
            if slug not in best or (has_count and not best[slug][1]):
                best[slug] = (t, has_count)
        for slug, (t, _c) in best.items():
            out.append({
                'vod_id': 'cat:' + slug,
                'vod_name': t,
                'vod_pic': '',
                'vod_remarks': '',
                'vod_tag': 'folder',
            })
    return out


def _stars_index(pg):
    url = BASE + '/stars/'
    if int(pg) > 1:
        url = BASE + '/stars/page/%d/' % int(pg)
    html = http_get(url)
    out = []
    seen = set()
    if html:
        for m in re.finditer(r'<article[^>]*vidmov_cast[^>]*>(.*?)</article>', html, re.S):
            blk = m.group(1)
            lm = re.search(r'<a[^>]+data-post-type="vidmov_cast"[^>]+href="(https://roshy\.tv/stars/[^"]+)"[^>]*title="([^"]+)"', blk)
            if not lm:
                continue
            link, name = lm.group(1), txt_of(lm.group(2))
            slug = link.rstrip('/').rsplit('/', 1)[-1]
            if slug in seen:
                continue
            seen.add(slug)
            im = re.search(r'<img[^>]+src="(https://[^"]+)"', blk)
            out.append({
                'vod_id': 'star:' + slug,
                'vod_name': name,
                'vod_pic': im.group(1) if im else '',
                'vod_remarks': '',
                'vod_tag': 'folder',
            })
    return out, html


class Spider(BaseSpider):
    def getName(self):
        return '🔞Roshy┃日系无码'

    def init(self, extend=''):
        pass

    def homeContent(self, filter=False):
        html = http_get(BASE + '/')
        return {'class': CLASSES, 'list': parse_cards(html)}

    def homeVideoContent(self):
        html = http_get(BASE + '/')
        return {'list': parse_cards(html)}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = int(pg or 1)
        if tid == 'home':
            url = BASE + '/'
            if pg > 1:
                url = BASE + '/page/%d/' % pg
            return _listing(http_get(url), pg)
        if tid == 'cats_index':
            lst = _cats_index()
            return {'page': 1, 'pagecount': 1, 'limit': len(lst) or 30,
                    'total': len(lst), 'list': lst}
        if tid == 'stars_index':
            lst, html = _stars_index(pg)
            pc = _pagecount(html, pg)
            return {'page': pg, 'pagecount': pc, 'limit': 30,
                    'total': pc * 30, 'list': lst}
        if tid.startswith('star:'):
            slug = tid[5:]
            url = BASE + '/stars/' + slug + '/'
            if pg > 1:
                url = BASE + '/stars/' + slug + '/page/%d/' % pg
            return _listing(http_get(url), pg)
        if tid.startswith('cat:'):
            slug = tid[4:]
            url = BASE + '/category/' + slug + '/'
            if pg > 1:
                url = BASE + '/category/' + slug + '/page/%d/' % pg
            return _listing(http_get(url), pg)
        path = tid if tid.startswith('/') else '/' + tid
        url = BASE + path
        if pg > 1:
            url = url.rstrip('/') + '/page/%d/' % pg
        return _listing(http_get(url), pg)

    def detailContent(self, ids):
        vid = ids[0] if ids else ''
        if isinstance(vid, (list, tuple)):
            vid = vid[0] if vid else ''
        vid = str(vid)
        if vid.startswith('http'):
            url = vid
        else:
            url = BASE + (vid if vid.startswith('/') else '/' + vid.strip('/') + '/')
        html = http_get(url)
        if not html:
            return {'list': []}
        vod = {'vod_id': url, 'vod_name': '', 'vod_pic': '', 'vod_content': '',
               'vod_actor': '', 'vod_director': '', 'vod_area': '',
               'vod_lang': '', 'vod_year': '', 'vod_remarks': '', 'type_name': ''}
        om = re.search(r'property="og:title" content="([^"]+)"', html)
        name = txt_of(om.group(1)) if om else ''
        name = re.sub(r'\s*-\s*ROSHY\.TV\s*$', '', name)
        vod['vod_name'] = name or url
        im = re.search(r'property="og:image" content="([^"]+)"', html)
        if im:
            vod['vod_pic'] = im.group(1)
        dm = re.search(r'property="og:description" content="([^"]+)"', html)
        if dm:
            vod['vod_content'] = txt_of(dm.group(1))
        actors = []
        for m in re.finditer(r'<a[^>]+href="https://roshy\.tv/stars/[^"]+"[^>]*title="([^"]+)"', html):
            t = txt_of(m.group(1))
            if t and t not in actors:
                actors.append(t)
        vod['vod_actor'] = ', '.join(actors)
        cats = []
        for m in re.finditer(r'href="https://roshy\.tv/category/([^"/]+)/"', html):
            if m.group(1) not in cats:
                cats.append(m.group(1))
        dm2 = re.search(r'duration.{0,8}?([\d.]+)', html)
        if dm2:
            try:
                secs = float(dm2.group(1))
                if secs > 60:
                    vod['vod_remarks'] = '%d分钟' % int(secs // 60)
            except Exception:
                pass
        ym = re.search(r'"datePublished":"(\d{4})-\d{2}-\d{2}', html)
        if ym:
            vod['vod_year'] = ym.group(1)
        vod['type_name'] = ', '.join(cats)
        embeds = []
        for m in re.finditer(r'video_url":"<iframe src=\\"([^\\]+)\\"', html):
            u = m.group(1).replace('\\/', '/')
            if u.startswith('http') and u not in embeds:
                embeds.append(u)
        if not embeds:
            em = re.search(r'"embedUrl":"([^"]+)"', html)
            if em:
                u = em.group(1).replace('\\/', '/')
                if u.startswith('http'):
                    embeds.append(u)
        if embeds:
            parts = []
            for i, u in enumerate(embeds):
                label = '正片' if len(embeds) == 1 else '第%d集' % (i + 1)
                parts.append('%s$%s' % (label, u))
            vod['vod_play_from'] = '在线播放'
            vod['vod_play_url'] = '#'.join(parts)
        vod['stills'] = [vod['vod_pic']] if vod['vod_pic'] else []
        return {'list': [vod]}

    def playerContent(self, flag, id, vipFlags=None):
        embed_url = str(id or '').strip()
        if not embed_url.startswith('http'):
            embed_url = BASE + (embed_url if embed_url.startswith('/') else '/' + embed_url)
        url = _embed_hls(embed_url)
        if url:
            return {'parse': 0, 'playUrl': '', 'url': url,
                    'header': {'Referer': embed_url, 'User-Agent': UA}}
        return {'parse': 1, 'playUrl': '', 'url': embed_url,
                'header': {'Referer': BASE + '/', 'User-Agent': UA}}

    def searchContent(self, key, quick=False, pg=1):
        pg = int(pg or 1)
        kw = urllib.parse.quote(str(key))
        if pg > 1:
            url = '%s/page/%d/?s=%s' % (BASE, pg, kw)
        else:
            url = '%s/?s=%s' % (BASE, kw)
        return _listing(http_get(url), pg)

    def localProxy(self, params=None):
        try:
            p = params
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get('url') or p.get('u') or ''
            if isinstance(target, list):
                target = target[0] if target else ''
            target = urllib.parse.unquote(str(target or '').strip())
            if not target.startswith('http'):
                return [404, 'text/plain', b'bad url', {}]
            _o = urllib.parse.urlparse(target)
            _req = urllib.request.Request(target, headers={
                'User-Agent': UA,
                'Referer': '%s://%s/' % (_o.scheme, _o.netloc)})
            with urllib.request.urlopen(_req, timeout=20) as _r:
                return [_r.status, _r.headers.get('Content-Type') or 'application/octet-stream', _r.read(), {}]
        except Exception:
            return [502, 'text/plain', b'proxy error', {}]

    def getDependence(self):
        return []

    def destroy(self):
        return None

    def isVideoFormat(self, url=None):
        u = str(url or '').lower()
        return ('.m3u8' in u) or ('.mp4' in u) or ('.flv' in u)

    def manualVideoCheck(self):
        return False

    def action(self, action=None):
        return {}
