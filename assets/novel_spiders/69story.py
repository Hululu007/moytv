import html as _html
import json
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

BASE = 'https://69story.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    ('wife', '人妻熟女'),
    ('school', '學生校園'),
    ('family', '家庭亂倫'),
    ('bdsm-abuse', '強暴虐待'),
    ('sex-in-the-city', '都市生活'),
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
    text = re.sub(r'<br\s*/?>', '\n', raw, flags=re.I)
    text = re.sub(r'</p\s*>', '\n', text, flags=re.I)
    text = re.sub(r'<[^>]+>', '', text)
    text = _html.unescape(text)
    text = text.replace('\xa0', ' ')
    lines = [ln.strip() for ln in text.split('\n')]
    return '\n'.join(ln for ln in lines if ln)


def _parse_list(page):
    m = re.search(r'<main[^>]*>(.*?)</main>', page, flags=re.S)
    area = m.group(1) if m else page
    items = []
    seen = set()
    for path, txt in re.findall(
            r'href=https://69story\.com/(article/\d+-[^\s>]+)[^>]*>(.*?)</a>', area):
        if path in seen:
            continue
        seen.add(path)
        name = _clean_text(txt).split(' / ')[0].strip()
        if not name:
            continue
        items.append({'vod_id': path, 'vod_name': name, 'vod_pic': '', 'vod_remarks': ''})
    return items


class Spider(BaseSpider):

    def getName(self):
        return '🔞69story'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': slug, 'type_name': name} for slug, name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        return {'list': _parse_list(_fetch(BASE + '/')), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        path = '/' + tid
        if pg > 1:
            path += '/page/%d' % pg
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if vid.startswith('article/'):
            url = BASE + '/' + vid
            num = re.search(r'article/(\d+)-', vid)
            num = num.group(1) if num else vid
        else:
            url = BASE + '/article/' + vid
            num = vid
        page = _fetch(url)
        if not page:
            return {'list': []}
        m_title = re.search(r'<h1[^>]*class="entry-title"[^>]*>(.*?)</h1>', page, flags=re.S)
        name = _clean_text(m_title.group(1)) if m_title else num
        m_text = re.search(r'<div class=entry-content>(.*?)</div>\s*<div', page, flags=re.S)
        if not m_text:
            m_text = re.search(r'<div class=entry-content>(.*)', page, flags=re.S)
        text = _clean_text(m_text.group(1)) if m_text else ''
        payload = json.dumps({'title': name, 'content': text}, ensure_ascii=False)
        return {'list': [{
            'vod_id': vid,
            'vod_name': name,
            'vod_pic': '',
            'vod_actor': '',
            'vod_remarks': '',
            'vod_content': text[:300],
            'vod_tag': 'text',
            'vod_player': '书',
            'vod_play_from': '小说',
            'vod_play_url': '阅读$novel://' + payload,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        return {'list': [], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        url = raw
        if '$' in raw:
            url = raw.split('$', 1)[1]
        if url.startswith('novel://'):
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {}, 'vod_player': '书'}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
