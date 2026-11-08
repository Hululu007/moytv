try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

import base64
import html as htmlmod
import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests
except Exception:
    requests = None

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
BASE = 'http://1mx8i3.www.jywx2.quest'

CATEGORIES = [
    ('DCCCCD', '恋情'),
    ('LCCCCD', '武侠'),
    ('RCCCCD', '淫想'),
    ('XCCCCD', '伦理'),
    ('bCCCCD', '人妻'),
    ('mCCCCD', '校园'),
    ('uCCCCD', '都市'),
    ('VCCCCD', '经验'),
    ('TCCCCD', '真实'),
    ('vCCCCD', '另类'),
    ('0CCCCD', '笑话'),
]
CAT_IDS = set([c[0] for c in CATEGORIES])


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    if pg < 1:
        pg = 1
    return pg


def _fu_decode(page):
    m = re.search(r'FU1\("([^"]+)"\)', page)
    if not m:
        return page
    try:
        raw = base64.b64decode(m.group(1)).decode('utf-8')
    except Exception:
        return page
    try:
        return json.loads(raw)
    except Exception:
        return raw


def _fetch(url):
    headers = {'User-Agent': UA, 'Referer': BASE + '/'}
    if requests is not None:
        try:
            r = requests.get(url, headers=headers, timeout=20)
            if r.status_code == 200:
                return _fu_decode(r.text)
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as resp:
            return _fu_decode(resp.read().decode('utf-8', 'replace'))
    except Exception:
        return ''


def _clean_text(raw):
    text = re.sub(r'<[^>]+>', '', raw)
    text = htmlmod.unescape(text)
    text = text.replace('\xa0', ' ')
    text = re.sub(r'\s+', ' ', text).strip()
    text = text.replace('#', '＃').replace('$', '＄')
    return text


def _parse_rows(page):
    rows = []
    for m in re.finditer(r'<a href="/artdetail-([^"]+)/" class="art-item-row">(.*?)</a>', page, flags=re.S):
        inner = m.group(2)
        name = re.search(r'col-name">([^<]*)', inner)
        author = re.search(r'col-author">([^<]*)', inner)
        time = re.search(r'col-time">([^<]*)', inner)
        rows.append({
            'vod_id': m.group(1),
            'vod_name': name.group(1).strip() if name else '',
            'vod_pic': '',
            'vod_actor': author.group(1).strip() if author else '',
            'vod_remarks': time.group(1).strip() if time else '',
        })
    return rows


def _detail(token):
    page = _fetch(BASE + '/artdetail-' + token + '/')
    if not page:
        return '', ''
    title = re.search(r'<h1 class="read-title">(.*?)</h1>', page, flags=re.S)
    body = re.search(r'<div id="read-content">(.*?)</div>\s*<div', page, flags=re.S)
    if body is None:
        body = re.search(r'<div id="read-content">(.*)', page, flags=re.S)
    title = _clean_text(title.group(1)) if title else ''
    text = _clean_text(body.group(1)) if body else ''
    return title, text


def _home_items():
    page = _fetch(BASE + '/')
    items = []
    seen = set()
    for m in re.finditer(r'<a href="/artdetail-([^"]+)/">([^<]+)</a>', page):
        token = m.group(1)
        if token in seen:
            continue
        seen.add(token)
        items.append({
            'vod_id': token,
            'vod_name': m.group(2).strip(),
            'vod_pic': '',
            'vod_remarks': '',
        })
    return items


class Spider(BaseSpider):
    def getName(self):
        return '🔞jywx2'

    def getDependence(self):
        return []

    def init(self, extend=''):
        return {'code': 0, 'msg': 'ok'}

    def destroy(self):
        return {'code': 0, 'msg': 'ok'}

    def homeContent(self, filter=None):
        classes = [{'type_id': tid, 'type_name': name} for tid, name in CATEGORIES]
        items = _home_items()
        return {'class': classes, 'filters': {}, 'list': items}

    def homeVideoContent(self):
        items = _home_items()
        return {'page': 1, 'pagecount': 1, 'limit': len(items), 'total': len(items), 'list': items}

    def categoryContent(self, tid, pg=1, filter=None, extend=None):
        pg = _norm_pg(pg)
        tid = str(tid).strip()
        if tid not in CAT_IDS:
            return {'page': pg, 'pagecount': 1, 'limit': 20, 'total': 0, 'list': []}
        if pg <= 1:
            url = BASE + '/arttype/' + tid + '/'
        else:
            url = BASE + '/arttype/' + tid + '-' + str(pg) + '/'
        rows = _parse_rows(_fetch(url))
        pagecount = pg if len(rows) < 20 else pg + 1
        return {'page': pg, 'pagecount': pagecount, 'limit': 20, 'total': 0, 'list': rows}

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            raw = ids
        elif isinstance(ids, str):
            raw = ids.split(',')
        else:
            raw = [str(ids)]
        out = []
        for one in raw:
            token = str(one).strip().split('$')[-1].strip()
            if not token:
                continue
            title, text = _detail(token)
            if not title:
                continue
            out.append({
                'vod_id': token,
                'vod_name': title,
                'vod_pic': '',
                'vod_actor': '',
                'vod_remarks': '全文',
                'vod_content': text[:150],
                'vod_play_from': '小说',
                'vod_play_url': '全文$' + BASE + '/artdetail-' + token + '/',
                'vod_tag': 'text',
                'vod_player': '书',
            })
        return {'list': out}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = str(key).strip()
        if not key:
            return {'page': pg, 'pagecount': 1, 'limit': 20, 'total': 0, 'list': []}
        q = urllib.parse.quote(key, safe='')
        if pg <= 1:
            url = BASE + '/artsearch/-------/?wd=' + q
        else:
            url = BASE + '/artsearch/' + q + '------' + str(pg) + '-/'
        rows = _parse_rows(_fetch(url))
        pagecount = pg if len(rows) < 20 else pg + 1
        return {'page': pg, 'pagecount': pagecount, 'limit': 20, 'total': 0, 'list': rows}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id).strip()
        m = re.search(r'artdetail-([^/]+)/?', raw)
        if m:
            token = m.group(1)
        else:
            token = raw.split('$')[-1].strip()
        header = {'User-Agent': UA, 'Referer': BASE + '/'}
        if not token:
            return {'parse': 0, 'url': '', 'playUrl': '', 'header': header}
        title, text = _detail(token)
        if not text:
            return {'parse': 0, 'url': '', 'playUrl': '', 'header': header}
        payload = json.dumps({'title': title, 'content': text}, ensure_ascii=False)
        url = 'novel://' + payload
        return {
            'parse': 0,
            'url': url,
            'playUrl': url,
            'header': header,
            'vod_tag': 'text',
            'vod_player': '书',
        }

    def localProxy(self, params=None):
        return [404, 'text/plain', '', {}]

    def isVideoFormat(self, url):
        u = str(url).lower()
        for ext in ('.mp4', '.m3u8', '.flv', '.mkv', '.webm', '.mov', '.avi', '.mpd'):
            if ext in u:
                return True
        return False

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return {}
