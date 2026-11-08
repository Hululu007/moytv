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

BASE = 'https://nnhanman.xyz'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    ('all', '全部'),
    ('completed', '已完结'),
    ('serialized', '连载中'),
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
    for href, title, img in re.findall(
            r'<a class="ImgA" href="(/comic/[^"]+)"[^>]*title="([^"]*)"[^>]*><picture>.*?<img src="([^"]+)"',
            page, flags=re.S):
        if href in seen:
            continue
        seen.add(href)
        name = _clean_text(title)
        if not name:
            continue
        items.append({'vod_id': href.strip('/'), 'vod_name': name, 'vod_pic': img, 'vod_remarks': ''})
    return items


class Spider(BaseSpider):

    def getName(self):
        return '🔞nnhanman'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': slug, 'type_name': name} for slug, name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        return {'list': _parse_list(_fetch(BASE + '/comics/all/ob/time/st/all')), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        path = '/comics/all/ob/time/st/%s' % tid
        if pg > 1:
            path += '/page/%d' % pg
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        slug = vid.split('/')[-1].replace('.html', '') if '/' in vid else vid
        path = vid if vid.startswith('comic/') else 'comic/%s.html' % vid
        page = _fetch(BASE + '/' + path)
        if not page:
            return {'list': []}
        m_title = re.search(r'<h1[^>]*>(.*?)</h1>', page, flags=re.S)
        name = _clean_text(m_title.group(1)) if m_title else slug
        name = name.strip('《》')
        cover = ''
        for img in re.findall(r'<img[^>]*src="(https://[^"]+)"', page):
            if 'new.niaopic.com' in img:
                cover = img
                break
        if not cover:
            for img in re.findall(r'<img[^>]*src="(https://[^"]+)"', page):
                if 'niaopic.com' in img:
                    cover = img
                    break
        eps = []
        seen = set()
        for chref, label in re.findall(
                r'<a[^>]*href="/comic/[^/]+/chapter-(\d+)\.html"[^>]*>(.*?)</a>', page, flags=re.S):
            lab = _clean_text(label)
            if not lab or lab == '开始阅读':
                continue
            if chref in seen:
                continue
            seen.add(chref)
            eps.append((chref, lab))
        eps.reverse()
        if eps:
            play_url = '#'.join('%s$nnhanman:%s:%s' % (lab, slug, cid) for cid, lab in eps)
        else:
            play_url = ''
        return {'list': [{
            'vod_id': vid,
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
        path = '/search/%s' % q
        if pg > 1:
            path += '/page/%d' % pg
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        url = raw
        if '$' in raw:
            url = raw.split('$', 1)[1]
        if url.startswith('pics://'):
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'Referer': BASE + '/'}, 'vod_player': '画'}
        parts = url.split(':')
        if len(parts) >= 3 and parts[0] == 'nnhanman' and parts[2].isdigit():
            slug = parts[1]
            cid = parts[2]
            page = _fetch(BASE + '/comic/%s/chapter-%s.html' % (slug, cid))
            imgs = []
            seen = set()
            for img in re.findall(r'data-src="(https://img\.nnpic\.xyz[^"]+)"', page):
                if img not in seen:
                    seen.add(img)
                    imgs.append(img)
            if not imgs:
                for img in re.findall(r'<img[^>]*src="(https://img\.nnpic\.xyz[^"]+)"', page):
                    if img not in seen:
                        seen.add(img)
                        imgs.append(img)
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
