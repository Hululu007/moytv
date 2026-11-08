import re
import urllib.parse
import urllib.request

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        def __init__(self):
            self.extend = {}
        def getName(self):
            return ''
        def getDependence(self):
            return []
        def init(self, extend=''):
            pass
        def destroy(self):
            pass
        def isVideoFormat(self, url):
            return False
        def manualVideoCheck(self):
            return False
        def action(self, action):
            return None
        def localProxy(self, param):
            return [200, 'video/MP2T', action, '']

BASE = 'https://www.ho5ho.com'

CATEGORIES = [
    ('全彩', '全彩'),
    ('巨乳', '巨乳'),
    ('痴女', '痴女'),
    ('熟女', '熟女'),
    ('變態', '變態'),
    ('多p', '多P'),
    ('母狗', '母狗'),
    ('接吻', '接吻'),
    ('肉感', '肉感'),
    ('幻想', '幻想'),
    ('m女', 'M女'),
    ('可愛', '可愛'),
    ('學生', '學生'),
    ('深喉', '深喉'),
    ('強姦', '強姦'),
    ('亂倫', '亂倫'),
    ('ntr', 'NTR'),
    ('肛交', '肛交'),
    ('正太', '正太'),
    ('母子', '母子'),
    ('m男', 'M男'),
    ('催眠', '催眠'),
    ('懷孕', '懷孕'),
    ('姐姐', '姐姐'),
    ('貧乳', '貧乳'),
    ('女性向', '女性向'),
    ('同人', '同人'),
    ('聖水', '聖水'),
    ('女同', '女同'),
    ('韓漫', '韓漫'),
]

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'


def _get(url):
    req = urllib.request.Request(url, headers={
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-TW,zh;q=0.9',
        'Referer': BASE + '/',
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode('utf-8', 'ignore')
    except Exception:
        return ''


def _fetch_path(path):
    parts = urllib.parse.urlsplit(BASE + path)
    safe = urllib.parse.urlunsplit((parts.scheme, parts.netloc, urllib.parse.quote(parts.path), parts.query, parts.fragment))
    return _get(safe)


def _strip(s):
    s = re.sub(r'<[^>]+>', '', s)
    return re.sub(r'\s+', ' ', s).strip()


def _parse_cards(page):
    items = []
    seen = set()
    for block in re.findall(r'<article class="ho5ho-v2-card".*?</article>', page, flags=re.S):
        m = re.search(r'ho5ho-v2-card-cover" href="([^"]+)"', block)
        if not m:
            continue
        url = m.group(1)
        path = urllib.parse.urlsplit(url).path
        if path in seen:
            continue
        seen.add(path)
        pic = ''
        mi = re.search(r'<img[^>]*src="([^"]+)"', block)
        if mi:
            pic = mi.group(1)
        name = ''
        mt = re.search(r'ho5ho-v2-card-title"><a[^>]*>([^<]+)</a>', block)
        if mt:
            name = mt.group(1).strip()
        if not name:
            continue
        items.append({
            'vod_id': urllib.parse.unquote(path).strip('/'),
            'vod_name': name,
            'vod_pic': pic,
            'vod_remarks': '',
        })
    return items


def _norm_id(v):
    if isinstance(v, (list, tuple)):
        v = v[0] if v else ''
    return str(v)


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        return 1


def _norm_extend(extend):
    if isinstance(extend, dict):
        return extend
    if isinstance(extend, str) and extend:
        try:
            import json
            v = json.loads(extend)
            return v if isinstance(v, dict) else {}
        except Exception:
            return {}
    return {}


class Spider(BaseSpider):
    def getName(self):
        return '🔞Ho5ho'

    def getDependence(self):
        return []

    def init(self, extend=''):
        self.extend = _norm_extend(extend)

    def destroy(self):
        pass

    def homeContent(self, filter):
        classes = [{'type_id': slug, 'type_name': name} for slug, name in CATEGORIES]
        return {'class': classes, 'list': _parse_cards(_fetch_path('/'))}

    def homeVideoContent(self):
        return {'list': []}

    def categoryContent(self, tid, pg, filter, extend):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        slug = urllib.parse.quote(tid)
        path = '/h漫分類/%s/' % slug
        if pg > 1:
            path = '/h漫分類/%s/page/%d/' % (slug, pg)
        page = _fetch_path(path)
        return {'list': _parse_cards(page), 'page': pg, 'pagecount': 9999, 'limit': 16, 'total': 999999}

    def detailContent(self, ids):
        pid = _norm_id(ids)
        page = _fetch_path('/' + pid + '/')
        title = ''
        m = re.search(r'<h1 id="ho5ho-detail-title">([^<]+)</h1>', page)
        if m:
            title = m.group(1).strip()
        pic = ''
        m = re.search(r'ho5ho-v3-cover"[^>]*>\s*<img[^>]*src="([^"]+)"', page)
        if m:
            pic = m.group(1)
        chapters = []
        seen = set()
        for m in re.finditer(r'wp-manga-chapter[^>]*>\s*<a href="([^"]+)"[^>]*>\s*([^<]+?)\s*</a>', page):
            url, text = m.group(1), m.group(2).strip()
            chap = urllib.parse.urlsplit(url).path.strip('/').split('/')[-1]
            if chap in seen:
                continue
            seen.add(chap)
            chapters.append('%s$%s#%s' % (text, pid, chap))
        if not chapters:
            chapters = ['全集$%s#server-1' % pid]
        remarks = ''
        m = re.search(r'作品資料與分類.*?分類\s*(.*?)\s*標籤', page, flags=re.S)
        if m:
            remarks = _strip(m.group(1))[:60]
        return {'list': [{
            'vod_id': pid,
            'vod_name': title or pid,
            'vod_pic': pic,
            'vod_play_from': '在线漫画',
            'vod_play_url': '#'.join(chapters),
            'vod_remarks': remarks,
        }]}

    def searchContent(self, key, quick, pg=1):
        pg = _norm_pg(pg)
        path = '/?s=%s' % urllib.parse.quote(key)
        if pg > 1:
            path += '&paged=%d' % pg
        page = _fetch_path(path)
        return {'list': _parse_cards(page), 'page': pg, 'pagecount': 9999, 'limit': 16, 'total': 999999}

    def playerContent(self, flag, id, vipFlags=None):
        parts = str(id).split('#')
        pid = parts[0]
        chap = parts[1] if len(parts) > 1 else 'server-1'
        page = _fetch_path('/' + pid + '/' + chap + '/')
        page = page.replace('\\/', '/')
        found = {}
        for m in re.finditer(r'https?://[^"\\\s]+/(\d+)\.jpg', page):
            try:
                found[int(m.group(1))] = m.group(0).replace('\\/', '/')
            except Exception:
                pass
        imgs = [found[k] for k in sorted(found)]
        if not imgs:
            for block in re.findall(r'wp-manga-chapter-img"[^>]*>', page):
                m = re.search(r'(?:data-src|src)="([^"]+)"', block)
                if m and m.group(1) not in imgs:
                    imgs.append(m.group(1))
        return {'parse': 0, 'url': 'pics://' + '&&'.join(imgs), 'header': {'User-Agent': UA, 'Referer': BASE + '/'}}

    def localProxy(self, param):
        return [200, 'video/MP2T', action, '']

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
