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

BASE = 'https://1000novel.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    '亂倫小說',
    '暴力虐待',
    '人妻小說',
    '武俠色情',
    '教師學生',
    '都市生活',
    '名人明星',
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
    items = []
    seen = set()
    for path, title in re.findall(
            r'<h2 class="entry-title"><a href="https://1000novel\.com/(\d{4}/\d{2}/\d{2}/[^"/]+/)"[^>]*>(.*?)</a></h2>',
            page):
        if path in seen:
            continue
        seen.add(path)
        name = _clean_text(title)
        if not name:
            continue
        items.append({'vod_id': path, 'vod_name': name, 'vod_pic': '', 'vod_remarks': ''})
    return items


def _entry_text(page):
    i = page.find('entry-content')
    if i < 0:
        return ''
    seg = page[i:]
    paras = []
    for raw in re.findall(r'<p[^>]*>(.*?)</p>', seg, flags=re.S):
        txt = _clean_text(raw)
        if txt:
            paras.append(txt)
    return '\n'.join(paras)


def _page_count(path, page):
    nums = re.findall(re.escape(path) + r'(\d+)/', page)
    if not nums:
        return 1
    try:
        return max(int(n) for n in nums)
    except Exception:
        return 1


class Spider(BaseSpider):

    def getName(self):
        return '🔞1000novel'

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
        path = '/category/' + urllib.parse.quote(tid) + '/'
        if pg > 1:
            path += 'page/%d/' % pg
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        path = _norm_id(ids)
        page = _fetch(BASE + '/' + path)
        if not page:
            return {'list': []}
        m_title = re.search(r'<h1[^>]*>(.*?)</h1>', page, flags=re.S)
        name = _clean_text(m_title.group(1)) if m_title else path
        total = _page_count(path, page)
        if total <= 1:
            play_url = '全集$1000novel:%s:1' % path
        else:
            parts = []
            for n in range(1, total + 1):
                parts.append('第%d页$1000novel:%s:%d' % (n, path, n))
            play_url = '#'.join(parts)
        first_text = _entry_text(page)
        return {'list': [{
            'vod_id': path,
            'vod_name': name,
            'vod_pic': '',
            'vod_actor': '',
            'vod_remarks': '',
            'vod_content': first_text[:300],
            'vod_tag': 'text',
            'vod_player': '书',
            'vod_play_from': '小说',
            'vod_play_url': play_url,
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
        parts = url.split(':')
        if len(parts) >= 3 and parts[0] == '1000novel' and parts[2].isdigit():
            path = parts[1]
            n = int(parts[2])
            fetch_url = BASE + '/' + path
            if n > 1:
                fetch_url += '%d/' % n
            page = _fetch(fetch_url)
            m_title = re.search(r'<h1[^>]*>(.*?)</h1>', page, flags=re.S)
            name = _clean_text(m_title.group(1)) if m_title else path
            text = _entry_text(page)
            name = name.replace('#', '＃')
            text = text.replace('#', '＃')
            payload = json.dumps({'title': name, 'content': text}, ensure_ascii=False)
            out = 'novel://' + payload
            return {'parse': 0, 'playUrl': out, 'url': out, 'header': {}, 'vod_player': '书'}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': {}}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
