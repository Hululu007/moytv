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

BASE = 'https://canovel.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    '亂倫小說',
    '人妻熟女',
    '強暴虐待',
    '校園師生',
    '同志小說',
    '古典武俠',
    '都市小品',
    '名人明星',
    '外國翻譯',
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


def _extract_paras(page):
    m_body = re.search(r'<div class="entry-inner"[^>]*>', page)
    if not m_body:
        return ''
    region = page[m_body.end():]
    depth = 1
    paras = []
    for t in re.finditer(r'<[^>]+>', region):
        tag = t.group(0)
        mm = re.match(r'</?([a-zA-Z0-9]+)', tag)
        if not mm:
            continue
        name = mm.group(1).lower()
        closing = tag.startswith('</')
        selfclose = tag.endswith('/>')
        if name == 'div' and not closing and not selfclose:
            depth += 1
        elif name == 'div' and closing:
            depth -= 1
            if depth <= 0:
                break
        if name == 'p' and not closing and depth >= 1:
            end = region.find('</p>', t.end())
            if end >= 0:
                txt = _clean_text(region[t.end():end])
                if txt:
                    paras.append(txt)
    return '\n'.join(paras)


def _parse_list(page):
    items = []
    seen = set()
    for pid, title in re.findall(
            r'<h2 class="post-title entry-title">\s*<a href="https://canovel\.com/article/(\d+)"[^>]*>(.*?)</a>',
            page):
        if pid in seen:
            continue
        seen.add(pid)
        name = _clean_text(title)
        if not name:
            continue
        items.append({'vod_id': pid, 'vod_name': name, 'vod_pic': '', 'vod_remarks': ''})
    return items


class Spider(BaseSpider):

    def getName(self):
        return '🔞canovel'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': name, 'type_name': name} for name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        return {'list': _parse_list(_fetch(BASE + '/')), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        path = '/article/category/' + urllib.parse.quote(tid)
        if pg > 1:
            path += '/page/%d' % pg
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        m = re.search(r'(\d+)', vid)
        if m:
            vid = m.group(1)
        page = _fetch(BASE + '/article/%s' % vid)
        if not page:
            return {'list': []}
        m_title = re.search(r'<h1[^>]*class="post-title entry-title"[^>]*>(.*?)</h1>', page, flags=re.S)
        name = _clean_text(m_title.group(1)) if m_title else vid
        text = _extract_paras(page)
        name = name.replace('#', '＃')
        text = text.replace('#', '＃')
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
        pg = _norm_pg(pg)
        q = urllib.parse.quote(str(key))
        if pg > 1:
            url = BASE + '/page/%d/?s=%s' % (pg, q)
        else:
            url = BASE + '/?s=%s' % q
        items = _parse_list(_fetch(url))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

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
