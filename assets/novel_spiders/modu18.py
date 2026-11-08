import base64
import hashlib
import json
import re
import urllib.parse
import urllib.request

try:
    from base import BaseSpider
except Exception:
    try:
        from spiders.base import BaseSpider
    except Exception:
        class BaseSpider:
            pass

API = 'https://api.modu18.vip'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
SITE = 'https://modu18.vip'
KEY = hashlib.sha256(b'MoDu18Comic2024!').hexdigest()[:32].encode()


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


def _norm_extend(extend):
    if isinstance(extend, dict):
        return extend
    if isinstance(extend, str) and extend.strip():
        try:
            return json.loads(extend)
        except Exception:
            return {}
    return {}


def _fetch(path):
    req = urllib.request.Request(
        API + path,
        headers={'User-Agent': UA, 'Accept': 'application/json', 'Referer': SITE + '/'},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode('utf-8', 'ignore')


def _api(path):
    try:
        raw = json.loads(_fetch(path))
    except Exception:
        return None
    if isinstance(raw, dict) and 'encrypted' in raw:
        try:
            part = raw['encrypted'].split('.', 1)[1]
            data = base64.b64decode(part)
            text = bytes(b ^ KEY[i % len(KEY)] for i, b in enumerate(data)).decode('utf-8')
            return json.loads(text)
        except Exception:
            return None
    return raw


def _cards(items):
    out = []
    seen = set()
    for it in items or []:
        aid = str(it.get('id', ''))
        if not aid or aid in seen:
            continue
        seen.add(aid)
        out.append({
            'vod_id': aid,
            'vod_name': it.get('name', ''),
            'vod_pic': '',
            'vod_remarks': (it.get('author') or '') if isinstance(it.get('author'), str) else '',
        })
    return out


class Spider(BaseSpider):

    def __init__(self):
        self._cats = None
        self._server = None

    def getName(self):
        return '🔞modu18'

    def getDependence(self):
        return []

    def init(self, extend=None):
        self._cats = None
        self._server = None

    def destroy(self):
        pass

    def _categories(self):
        if self._cats is not None:
            return self._cats
        cats = []
        try:
            data = _api('/api/categories')
            rows = ((data or {}).get('data') or {}).get('categories') or []
            for row in rows:
                cats.append({
                    'type_id': row.get('slug') or 'latest',
                    'type_name': row.get('name', ''),
                })
        except Exception:
            pass
        if not cats:
            cats = [{'type_id': 'latest', 'type_name': '最新A漫'}]
        self._cats = cats
        return cats

    def _img_server(self):
        if self._server:
            return self._server
        srv = 'https://cdn-msp.jmapinodeudzn.net'
        try:
            data = _api('/api/image-servers')
            servers = (data or {}).get('servers') or []
            if servers and servers[0].get('url'):
                srv = servers[0]['url']
        except Exception:
            pass
        self._server = srv
        return srv

    def _cover(self, aid):
        return self._img_server().rstrip('/') + '/media/albums/' + aid + '_3x4.jpg'

    def homeContent(self, filter=False):
        return {'class': self._categories(), 'filters': {}}

    def homeVideoContent(self):
        return self.categoryContent('latest', 1, False, {})

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        if tid in ('', 'latest'):
            path = '/api/latest?page=%d' % pg
        else:
            path = '/api/categories/filter?page=%d&o=latest&c=%s' % (pg, urllib.parse.quote(tid))
        data = _api(path)
        items = []
        if isinstance(data, dict):
            inner = data.get('data')
            if isinstance(inner, list):
                items = inner
            elif isinstance(inner, dict):
                items = inner.get('content') or inner.get('list') or []
        cards = _cards(items)
        for card in cards:
            card['vod_pic'] = self._cover(card['vod_id'])
        total = 0
        if isinstance(data, dict) and isinstance(data.get('data'), dict):
            try:
                total = int(data['data'].get('total') or 0)
            except Exception:
                total = 0
        pagecount = 0
        if total > 0:
            pagecount = (total + 79) // 80
        return {'list': cards, 'page': pg, 'pagecount': pagecount, 'total': total}

    def _album(self, aid):
        data = _api('/api/album?id=' + urllib.parse.quote(aid))
        if isinstance(data, dict):
            return data.get('data') or {}
        return {}

    def detailContent(self, ids):
        aid = _norm_id(ids)
        alb = self._album(aid)
        title = alb.get('name', '') or aid
        desc = alb.get('description', '') or ''
        series = alb.get('series') or []
        eps = []
        if isinstance(series, list) and series:
            for entry in series:
                if isinstance(entry, dict) and entry.get('id'):
                    label = entry.get('title') or entry.get('name') or '章节'
                    eps.append('%s$modu18:%s' % (label, entry['id']))
                elif isinstance(entry, str) and entry:
                    eps.append('%s$modu18:%s' % (entry, aid))
        if not eps:
            eps.append('全集$modu18:%s' % aid)
        return {'list': [{
            'vod_id': aid,
            'vod_name': title,
            'vod_pic': self._cover(aid),
            'vod_content': desc,
            'vod_play_from': '在线漫画',
            'vod_play_url': '#'.join(eps),
            'vod_tag': 'image',
            'vod_player': '画',
        }]}

    def searchContent(self, key, quick=False, pg=1):
        return {'list': [], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id)
        cid = ''
        if raw.startswith('modu18:'):
            segs = raw.split(':')
            if len(segs) >= 2:
                cid = segs[1]
        if not cid:
            return {'parse': 0, 'url': '', 'header': {'User-Agent': UA, 'Referer': SITE + '/'}}
        data = _api('/api/chapter?id=' + urllib.parse.quote(cid))
        imgs = []
        if isinstance(data, dict):
            inner = data.get('data') or {}
            imgs = inner.get('images') or []
        srv = self._img_server().rstrip('/')
        urls = [srv + '/media/photos/' + cid + '/' + fn for fn in imgs if fn]
        return {
            'parse': 0,
            'url': 'pics://' + '&&'.join(urls) if urls else '',
            'header': {'User-Agent': UA, 'Referer': SITE + '/'},
        }

    def localProxy(self, param):
        return [200, 'video/mp2t', b'', {}]

    def isVideoFormat(self, url):
        if url.startswith('pics://'):
            return False
        return bool(re.search(r'\.(m3u8|mp4|mkv|flv|avi|mov|webm)(\?|$)', url or '', re.I))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
