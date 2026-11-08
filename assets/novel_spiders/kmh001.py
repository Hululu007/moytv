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

BASE = 'https://kmh001.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    ('all', '最新'),
    ('ongoing', '连载中'),
    ('complete', '已完结'),
]

STATUS_LABEL = {'ongoing': '连载中', 'complete': '已完结', 'broken': '休刊中'}


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
            if len(data) >= 1000 or attempt == 2:
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


def _api_list(status, pg):
    url = BASE + '/api/comic?tag=&status=%s&current=%d' % (status, pg)
    data = _fetch(url)
    items = []
    try:
        obj = json.loads(data)
    except Exception:
        return items
    for rec in obj.get('records', []) if isinstance(obj, dict) else []:
        cid = str(rec.get('_id', ''))
        name = rec.get('name', '')
        cover = rec.get('cover', '')
        if not cover.startswith('http'):
            cover = ''
        last = rec.get('lastChapter', {}) or {}
        remarks = ''
        if last.get('subtitle'):
            remarks = last.get('subtitle', '')
        if cid and name:
            items.append({'vod_id': cid, 'vod_name': name, 'vod_pic': cover, 'vod_remarks': remarks})
    return items


def _parse_ssr_cards(page):
    items = []
    seen = set()
    for cid, cover, title in re.findall(
            r'\\"href\\":\\"/comic/([0-9a-f]{24})\\".{0,800}?\\"src\\":\\"(https://[^\\"]+)\\".{0,800}?\\"h3\\"[^}]*?\\"children\\":\\"([^\\"]+)\\"',
            page):
        if cid in seen:
            continue
        seen.add(cid)
        name = _clean_text(title)
        if name:
            items.append({'vod_id': cid, 'vod_name': name, 'vod_pic': cover, 'vod_remarks': ''})
    return items


class Spider(BaseSpider):

    def getName(self):
        return '🔞kmh001'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': tid, 'type_name': name} for tid, name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        return {'list': _api_list('', 1), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        status = '' if tid == 'all' else tid
        items = _api_list(status, pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        cid = _norm_id(ids)
        m = re.search(r'([0-9a-f]{24})', cid)
        if m:
            cid = m.group(1)
        page = _fetch(BASE + '/comic/%s' % cid)
        if not page:
            return {'list': []}
        m_title = re.search(r'og:title\\"[^}]*?content\\":\\"([^\\"]+)', page)
        name = _clean_text(m_title.group(1)).split(' | ')[0] if m_title else cid
        m_desc = re.search(r'og:description\\"[^}]*?content\\":\\"([^\\"]+)', page)
        desc = _clean_text(m_desc.group(1)) if m_desc else ''
        m_cover = re.search(r'og:image\\"[^}]*?content\\":\\"([^\\"]+)', page)
        cover = m_cover.group(1) if m_cover else ''
        m_author = re.search(r'作者：([^\\"]+)', page)
        author = _clean_text(m_author.group(1)) if m_author else ''
        eps = []
        for block in re.findall(r'\{\\"\_id\\":\\"([0-9a-f]{24})\\"(.*?)\}', page):
            body = block[1]
            m_sub = re.search(r'\\"subtitle\\":\\"([^\\"]+)\\"', body)
            m_ord = re.search(r'\\"ordinal\\":(\d+)', body)
            sub = m_sub.group(1) if m_sub else ''
            ordinal = int(m_ord.group(1)) if m_ord else 9999
            if sub:
                eps.append((ordinal, '%s$kmh001:%s:%s' % (sub, cid, block[0])))
        eps.sort(key=lambda x: x[0])
        play_url = '#'.join(e for _, e in eps)
        return {'list': [{
            'vod_id': cid,
            'vod_name': name,
            'vod_pic': cover,
            'vod_actor': author,
            'vod_remarks': '',
            'vod_content': desc,
            'vod_tag': 'image',
            'vod_player': '画',
            'vod_play_from': '漫画',
            'vod_play_url': play_url,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg > 1:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        q = urllib.parse.quote(str(key))
        items = _parse_ssr_cards(_fetch(BASE + '/search?key=%s' % q))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        url = raw
        if '$' in raw:
            url = raw.split('$', 1)[1]
        if url.startswith('pics://'):
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'Referer': BASE + '/'}, 'vod_player': '画'}
        parts = url.split(':')
        if len(parts) >= 3 and parts[0] == 'kmh001':
            chapter_id = parts[2]
            page = _fetch(BASE + '/chapter/%s' % chapter_id)
            groups = {}
            order = []
            for sid, img_url, sort_idx in re.findall(
                    r'\\"sourceID\\":\\"([0-9a-f]{24})\\",\\"sourceName\\":\\"[^\\"]+\\",\\"url\\":\\"([^\\"]+)\\",\\"sortIndex\\":(\d+)',
                    page):
                if sid not in groups:
                    groups[sid] = []
                    order.append(sid)
                groups[sid].append((int(sort_idx), img_url))
            best = None
            for sid in order:
                lst = sorted(groups[sid], key=lambda x: x[0])
                if best is None or len(lst) > len(best):
                    best = lst
            imgs = [u for _, u in best] if best else []
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
