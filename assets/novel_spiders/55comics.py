import html as _html
import re
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

BASE = 'https://www.55comics.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    ('hanman', '韩漫'),
    ('riman', '日漫'),
    ('danben', '单行本'),
    ('meiman', '美漫'),
]


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


def _fetch(url):
    import time
    for attempt in range(3):
        req = urllib.request.Request(url, headers={'User-Agent': UA, 'Referer': BASE + '/'})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read().decode('utf-8', 'ignore')
            if len(data) >= 10000 or attempt == 2:
                return data
        except Exception:
            if attempt == 2:
                return ''
        time.sleep(1)
    return ''


def _clean_text(raw):
    if not raw:
        return ''
    text = re.sub(r'<[^>]+>', '', raw)
    text = _html.unescape(text)
    text = text.replace('\xa0', ' ')
    return text.strip()


def _parse_list(page):
    items = []
    seen = set()
    for aid, cover, title in re.findall(
            r'<a href="/album/(\d+)\.html">\s*<img[^>]*data-original="([^"]+)"[^>]*title="([^"]*)"',
            page):
        if aid in seen:
            continue
        seen.add(aid)
        name = _clean_text(title)
        if not name:
            continue
        items.append({'vod_id': aid, 'vod_name': name, 'vod_pic': cover, 'vod_remarks': ''})
    return items


def _chapter_images(cid):
    first = _fetch(BASE + '/chapter/%s.html' % cid)
    if not first:
        return []
    pages = re.findall(r'/chapter/%s\.html\?p=(\d+)' % cid, first)
    total = max([int(p) for p in pages]) if pages else 1
    imgs = []
    seen = set()
    for n in range(1, total + 1):
        page = first if n == 1 else _fetch(BASE + '/chapter/%s.html?p=%d' % (cid, n))
        for img in re.findall(r'<img[^>]*data-original="([^"]+)"[^>]*class="[^"]*img-responsive-mw[^"]*"', page):
            if img not in seen:
                seen.add(img)
                imgs.append(img)
    return imgs


class Spider(BaseSpider):

    def getName(self):
        return '🔞55comics'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': slug, 'type_name': name} for slug, name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        return {'list': _parse_list(_fetch(BASE + '/lists/hanman.html')), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        path = '/lists/%s.html' % tid
        if pg > 1:
            path += '?p=%d' % pg
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        aid = _norm_id(ids)
        m = re.search(r'(\d+)', aid)
        if m:
            aid = m.group(1)
        page = _fetch(BASE + '/album/%s.html' % aid)
        if not page:
            return {'list': []}
        m_title = re.search(r'<h1[^>]*>(.*?)</h1>', page, flags=re.S)
        name = _clean_text(m_title.group(1)) if m_title else aid
        cover = ''
        m_cover = re.search(r'<img[^>]*data-original="(https://img\.manhua18h\.com/comic/[^"]+)"', page)
        if m_cover:
            cover = m_cover.group(1)
        chs = []
        seen = set()
        for cid, label in re.findall(r'<a[^>]*href="/chapter/(\d+)\.html"[^>]*>(.*?)</a>', page):
            if cid in seen:
                continue
            seen.add(cid)
            lab = _clean_text(label)
            chs.append((cid, lab))
        if len(chs) == 1:
            play_url = '全集$55comics:%s' % chs[0][0]
        else:
            play_url = '#'.join('%s$55comics:%s' % (lab if lab else '第%d话' % (i + 1), cid) for i, (cid, lab) in enumerate(chs))
        return {'list': [{
            'vod_id': aid,
            'vod_name': name,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_remarks': '',
            'vod_content': '',
            'vod_tag': 'image',
            'vod_player': '画',
            'vod_play_from': '漫画',
            'vod_play_url': play_url,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        q = urllib.parse.quote(str(key))
        path = '/search.html?keyword=%s' % q
        if pg > 1:
            path += '&p=%d' % pg
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        url = raw
        if '$' in raw:
            url = raw.split('$', 1)[1]
        if url.startswith('pics://'):
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'Referer': BASE + '/'}, 'vod_player': '画'}
        if url.startswith('55comics:'):
            cid = url.split(':', 1)[1]
            if not cid.isdigit():
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
            imgs = _chapter_images(cid)
            out = 'pics://' + '&&'.join(imgs)
            return {'parse': 0, 'playUrl': out, 'url': out, 'header': {'Referer': BASE + '/'}, 'vod_player': '画'}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
