import gzip
import html as _html
import http.cookiejar
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
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False

BASE = 'https://javtiful.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CATS = [
    ('latest', 'Latest Videos', '/videos'),
    ('censored', 'Censored', '/censored'),
    ('uncensored', 'Uncensored', '/uncensored'),
    ('reducing-mosaic', 'Reducing Mosaic', '/reducing-mosaic'),
    ('popular-week', 'Popular This Week', '/videos?sort=popular_week'),
    ('most-viewed', 'Most Viewed', '/videos?sort=most_viewed'),
    ('most-liked', 'Most Liked', '/videos?sort=most_liked'),
    ('cat:female-investigator', 'Female Investigator', '/category/female-investigator'),
    ('cat:chinese-av', 'Chinese AV', '/category/chinese-av'),
    ('cat:female-boss', 'Female Boss', '/category/female-boss'),
    ('cat:mature-woman', 'Mature Woman', '/category/mature-woman'),
    ('cat:cosplay', 'Cosplay', '/category/cosplay'),
    ('cat:amateur', 'Amateur', '/category/amateur'),
    ('cat:housekeeper', 'Housekeeper', '/category/housekeeper'),
    ('cat:nurse', 'Nurse', '/category/nurse'),
    ('cat:female-student', 'Female Student', '/category/female-student'),
    ('cat:school-girls', 'School Girls', '/category/school-girls'),
    ('cat:office-lady', 'Office Lady', '/category/office-lady'),
    ('cat:sister-in-law', 'Sister-in-law', '/category/sister-in-law'),
    ('cat:hypnosis', 'Hypnosis', '/category/hypnosis'),
    ('cat:beautiful-girl', 'Beautiful Girl', '/category/beautiful-girl'),
    ('cat:bbw', 'BBW', '/category/bbw'),
    ('cat:drama', 'Drama', '/category/drama'),
    ('cat:married-woman', 'Married Woman', '/category/married-woman'),
    ('cat:milf', 'Milf', '/category/milf'),
    ('cat:female-teacher', 'Female Teacher', '/category/female-teacher'),
    ('cat:affair', 'Affair', '/category/affair'),
    ('cat:big-tits', 'Big Tits', '/category/big-tits'),
    ('actresses', 'Actresses', '/actresses'),
]
CAT_PATH = {tid: path for tid, _name, path in CATS}

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TIMEOUT = 30

CARD_RE = re.compile(r'<article class="video-card">(.*?)</article>', re.S)
CARD_HREF_RE = re.compile(r'<a[^>]+href="(/video/\d+/[^"]+)"')
CARD_TITLE_RE = re.compile(r'class="video-card__title"[^>]*title="([^"]+)"')
CARD_PIC_RE = re.compile(r'data-front-lazy-src="([^"]+)"')
CARD_SRC_RE = re.compile(r'<img[^>]+src="([^"]+)"')
CARD_DUR_RE = re.compile(r'class="video-card__details">(.*?)</span>', re.S)
CARD_META_RE = re.compile(r'class="video-card__meta">(.*?)</div>', re.S)
TAG_RE = re.compile(r'<[^>]+>')
PAGE_RE = re.compile(r'[?&]page=(\d+)')
ACTRESS_CARD_RE = re.compile(r'<article class="directory-card directory-card--actress">(.*?)</article>', re.S)
ACTRESS_HREF_RE = re.compile(r'href="(/actress/[^"]+)"')
ACTRESS_NAME_RE = re.compile(r'class="directory-card__name">([^<]+)</span>')
ACTRESS_COUNT_RE = re.compile(r'class="directory-card__count">([^<]+)</span>')
ACTRESS_PIC_RE = re.compile(r'<img[^>]+src="([^"]+)"')
TITLE_RE = re.compile(r'<meta property="og:title"[^>]*content="([^"]+)"')
COVER_RE = re.compile(r'<meta property="og:image"[^>]*content="([^"]+)"')
DESC_RE = re.compile(r'<meta name="description"[^>]*content="([^"]+)"')
ACTOR_RE = re.compile(r'href="/actress/[^"]*"[^>]*>.*?<span>([^<]+)</span>', re.S)
CATLINK_RE = re.compile(r'href="/category/[^"]*"[^>]*>([^<]+)<')
DUR_RE = re.compile(r'(\d+:\d+:\d+)')
DATE_RE = re.compile(r'<time datetime="(\d{4})-\d{2}-\d{2}')
VTYPE_RE = re.compile(r'<strong>Video Type</strong>\s*<span[^>]*>([^<]+)</span>')
PLAYBACK_RE = re.compile(r'playback":\{"endpoint":"([^"]+)","ticket":"([^"]+)"')


def _unescape(s):
    if not s:
        return ''
    return _html.unescape(s).strip()


def _strip_tags(s):
    if not s:
        return ''
    return _unescape(TAG_RE.sub('', s))


def _fix_url(raw):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('/'):
        return BASE + u
    return BASE + '/' + u


def _headers(referer=None):
    hdr = {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if referer:
        hdr['Referer'] = referer
    return hdr


def _http_get(url, referer=None):
    for _attempt in range(3):
        text = None
        if _HAS_REQ:
            try:
                resp = requests.get(url, headers=_headers(referer), timeout=TIMEOUT)
                if resp.status_code == 200:
                    text = resp.content.decode('utf-8', 'replace')
            except Exception:
                text = None
        if text is None:
            try:
                req = urllib.request.Request(url, headers=_headers(referer))
                with urllib.request.urlopen(req, timeout=TIMEOUT, context=CTX) as resp:
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
        time.sleep(2)
    return None


def _fetch(path, referer=None):
    if path.startswith('http'):
        return _http_get(path, referer=referer or (BASE + '/'))
    return _http_get(BASE + path, referer=referer or (BASE + '/'))


def _page_url(path, pg):
    if pg <= 1:
        return path
    sep = '&' if '?' in path else '?'
    return '%s%spage=%d' % (path, sep, pg)


def _pagecount(html):
    if not html:
        return 0
    pages = [int(n) for n in PAGE_RE.findall(html)]
    return max(pages) if pages else 0


def _parse_cards(html):
    out = []
    if not html:
        return out
    seen = set()
    for block in CARD_RE.findall(html):
        hm = CARD_HREF_RE.search(block)
        if not hm:
            continue
        vid = hm.group(1)
        if vid in seen:
            continue
        tm = CARD_TITLE_RE.search(block)
        title = _unescape(tm.group(1)) if tm else ''
        if not title:
            continue
        seen.add(vid)
        pic = ''
        pm = CARD_PIC_RE.search(block)
        if pm:
            pic = _fix_url(pm.group(1))
        if not pic:
            sm = CARD_SRC_RE.search(block)
            if sm and 'placeholder' not in sm.group(1):
                pic = _fix_url(sm.group(1))
        remark = ''
        dm = CARD_DUR_RE.search(block)
        if dm:
            remark = _strip_tags(dm.group(1))
        meta = ''
        mm = CARD_META_RE.search(block)
        if mm:
            meta = _strip_tags(mm.group(1))
        out.append({
            'vod_id': vid,
            'vod_name': title,
            'vod_pic': pic,
            'vod_remarks': remark,
            'vod_tag': meta,
        })
    return out


def _parse_actresses(html):
    out = []
    if not html:
        return out
    seen = set()
    for block in ACTRESS_CARD_RE.findall(html):
        hm = ACTRESS_HREF_RE.search(block)
        if not hm:
            continue
        slug = hm.group(1).rsplit('/', 1)[-1]
        if slug in seen:
            continue
        nm = ACTRESS_NAME_RE.search(block)
        name = _unescape(nm.group(1)) if nm else slug
        if not name:
            continue
        seen.add(slug)
        pic = ''
        pm = ACTRESS_PIC_RE.search(block)
        if pm:
            pic = _fix_url(pm.group(1))
        count = ''
        cm = ACTRESS_COUNT_RE.search(block)
        if cm:
            count = _unescape(cm.group(1))
        out.append({
            'vod_id': 'actress:' + slug,
            'vod_name': name,
            'vod_pic': pic,
            'vod_remarks': count,
            'vod_tag': 'folder',
        })
    return out


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


def _playback_url(page_url):
    if _HAS_REQ:
        try:
            sess = requests.Session()
            resp = sess.get(BASE + page_url, headers=_headers(), timeout=TIMEOUT)
            if resp.status_code != 200:
                return ''
            html = resp.content.decode('utf-8', 'replace')
            pm = PLAYBACK_RE.search(html)
            if not pm:
                return ''
            endpoint = pm.group(1)
            ticket = pm.group(2)
            if endpoint.startswith('/'):
                endpoint = BASE + endpoint
            for _attempt in range(2):
                hdr = _headers(BASE + page_url)
                hdr['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8'
                hdr['Accept'] = 'application/json'
                hdr['X-Requested-With'] = 'XMLHttpRequest'
                post = sess.post(endpoint, data={'ticket': ticket}, headers=hdr, timeout=TIMEOUT)
                if post.status_code != 200:
                    return ''
                try:
                    obj = json.loads(post.text)
                except Exception:
                    return ''
                if obj.get('renewTicket'):
                    ticket = str(obj.get('renewTicket'))
                    continue
                sources = obj.get('sources') or []
                for src in sources:
                    u = (src or {}).get('src') or ''
                    if u:
                        return _fix_url(u)
                return ''
            return ''
        except Exception:
            pass
    try:
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        req = urllib.request.Request(BASE + page_url, headers=_headers())
        with opener.open(req, timeout=TIMEOUT, context=CTX) as resp:
            if resp.status != 200:
                return ''
            html = resp.read().decode('utf-8', 'replace')
        pm = PLAYBACK_RE.search(html)
        if not pm:
            return ''
        endpoint = pm.group(1)
        ticket = pm.group(2)
        if endpoint.startswith('/'):
            endpoint = BASE + endpoint
        for _attempt in range(2):
            body = urllib.parse.urlencode({'ticket': ticket}).encode('utf-8')
            hdr = _headers(BASE + page_url)
            hdr['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8'
            hdr['Accept'] = 'application/json'
            hdr['X-Requested-With'] = 'XMLHttpRequest'
            req2 = urllib.request.Request(endpoint, data=body, headers=hdr, method='POST')
            with opener.open(req2, timeout=TIMEOUT, context=CTX) as resp:
                if resp.status != 200:
                    return ''
                data = resp.read().decode('utf-8', 'replace')
            try:
                obj = json.loads(data)
            except Exception:
                return ''
            if obj.get('renewTicket'):
                ticket = str(obj.get('renewTicket'))
                continue
            sources = obj.get('sources') or []
            for src in sources:
                u = (src or {}).get('src') or ''
                if u:
                    return _fix_url(u)
            return ''
    except Exception:
        return ''
    return ''


class Spider(BaseSpider):

    def getName(self):
        return '🔞Javtiful┃JAV视频'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        cats = [{'type_id': tid, 'type_name': name} for tid, name, _path in CATS]
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        html = _fetch('/videos')
        items = _parse_cards(html)
        return {'list': items, 'page': 1, 'pagecount': _pagecount(html), 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid).strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        if tid == 'actresses':
            html = _fetch(_page_url('/actresses', pg))
            items = _parse_actresses(html)
            return {'list': items, 'page': pg, 'pagecount': _pagecount(html), 'total': 0}
        if tid.startswith('actress:'):
            slug = tid.split(':', 1)[1]
            html = _fetch(_page_url('/actress/' + slug, pg))
            items = _parse_cards(html)
            return {'list': items, 'page': pg, 'pagecount': _pagecount(html), 'total': 0}
        path = CAT_PATH.get(tid)
        if not path:
            if tid.startswith('cat:'):
                path = '/category/' + tid[4:]
            elif tid.startswith('/'):
                path = tid
            else:
                path = '/videos'
        html = _fetch(_page_url(path, pg))
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': _pagecount(html), 'total': 0}

    def detailContent(self, ids):
        page_url = _norm_id(ids).strip()
        if not page_url or page_url.startswith('actress:'):
            return _empty_detail(page_url)
        if not page_url.startswith('/'):
            page_url = '/' + page_url
        html = _fetch(page_url)
        if not html:
            return _empty_detail(page_url)
        title = ''
        tm = TITLE_RE.search(html)
        if tm:
            title = _unescape(tm.group(1))
        if title.endswith(' | Javtiful'):
            title = title[:-len(' | Javtiful')].strip()
        if not title:
            return _empty_detail(page_url)
        cover = ''
        cm = COVER_RE.search(html)
        if cm:
            cover = _fix_url(cm.group(1))
        desc = ''
        dm = DESC_RE.search(html)
        if dm:
            desc = _unescape(dm.group(1))
        actors = []
        for m in ACTOR_RE.finditer(html):
            name = _unescape(m.group(1))
            if name and name not in actors:
                actors.append(name)
        cats = []
        for m in CATLINK_RE.finditer(html):
            name = _unescape(m.group(1))
            if name and name not in cats:
                cats.append(name)
        remark = ''
        dm2 = DUR_RE.search(html)
        if dm2:
            remark = dm2.group(1)
        vm = VTYPE_RE.search(html)
        if vm:
            vtype = _unescape(vm.group(1))
            if vtype:
                remark = (remark + ' ' + vtype).strip()
        year = ''
        ym = DATE_RE.search(html)
        if ym:
            year = ym.group(1)
        stills = [cover] if cover else []
        return {'list': [{
            'vod_id': page_url,
            'vod_name': title,
            'vod_pic': cover,
            'vod_actor': ' / '.join(actors),
            'vod_director': '',
            'vod_remarks': remark,
            'vod_year': year,
            'vod_area': '',
            'vod_content': desc,
            'type_name': ' / '.join(cats),
            'vod_tag': '',
            'vod_play_from': '在线播放',
            'vod_play_url': '播放$' + page_url,
            'stills': stills,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote_plus(str(key).strip())
        path = '/search?q=' + kw
        html = _fetch(_page_url(path, pg))
        items = _parse_cards(html)
        return {'list': items, 'page': pg, 'pagecount': _pagecount(html), 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        if '$' in raw:
            raw = raw.split('$', 1)[1]
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        page_url = raw if raw.startswith('/') else '/' + raw
        url = _playback_url(page_url)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        header['Referer'] = BASE + page_url
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
