try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


import base64
import gzip
import json
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


DOMAIN_LIST_URLS = [
    'https://api.dc-server.cc/sdk/getAvailableDomainList',
    'https://dcapi.dc-dev.cc/sdk/getAvailableDomainList',
]

BASES = [
    'https://sophia.aaq123.com/api/v1/',
    'https://ph.douyinweb.cc/api/v1/',
    'https://mia.sk7te.cc/api/v1/',
    'https://clara.rvr19.com/api/v1/',
    'https://34.150.66.94:17778/api/v1/',
    'https://134.122.129.17:17778/api/v1/',
]

UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36'

SKIP_NAME_KEYS = (
    '未成年', '幼女', '萝莉', '儿童', '小学生', '初中', '童',
    '赌', '博彩', '彩票', '棋牌', '捕鱼', '赌场',
)

PAGE_SIZE = 20


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        ids = ids[0] if ids else ''
    return str(ids or '').strip()


def _norm_pg(pg):
    try:
        pg = int(pg)
    except Exception:
        pg = 1
    return pg if pg >= 1 else 1


def _skip_name(name):
    n = (name or '').strip()
    for k in SKIP_NAME_KEYS:
        if k and k in n:
            return True
    return False


def _pick(d, keys, default=''):
    if not isinstance(d, dict):
        return default
    for k in keys:
        v = d.get(k)
        if v is not None and v != '':
            return v
    return default


def _num(v, default=0):
    try:
        return int(float(v))
    except Exception:
        return default


def _fmt_duration(sec):
    sec = _num(sec)
    if sec <= 0:
        return ''
    m, s = divmod(sec, 60)
    h, m = divmod(m, 60)
    if h:
        return '%d:%02d:%02d' % (h, m, s)
    return '%d:%02d' % (m, s)


def _fmt_count(n):
    n = _num(n)
    if n <= 0:
        return ''
    if n >= 10000:
        return '%.1f万' % (n / 10000.0)
    return str(n)


class Spider(BaseSpider):
    def getName(self):
        return '黑颜禁播'

    def getDependence(self):
        return []

    def init(self, extend=''):
        self._base = ''
        self._bases = list(BASES)
        self._discovered = False

    def destroy(self):
        pass

    def _http(self, url, method='GET', data=None, timeout=25):
        headers = {
            'User-Agent': UA,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            'Accept-Encoding': 'gzip, deflate',
        }
        body = None
        if data is not None:
            body = json.dumps(data).encode('utf-8')
            headers['Content-Type'] = 'application/json'
        if _HAS_REQ:
            try:
                if method == 'POST':
                    r = requests.post(url, headers=headers, data=body, timeout=timeout)
                else:
                    r = requests.get(url, headers=headers, timeout=timeout)
                if r.status_code == 200 and r.content:
                    return r.content
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=body, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return raw
        except urllib.error.HTTPError as e:
            try:
                return e.read()
            except Exception:
                return b''
        except Exception:
            return b''

    def _json(self, raw):
        if not raw:
            return None
        try:
            if isinstance(raw, bytes):
                raw = raw.decode('utf-8', 'replace')
            return json.loads(raw)
        except Exception:
            return None

    def _discover(self):
        if self._discovered:
            return
        self._discovered = True
        found = []
        for u in DOMAIN_LIST_URLS:
            obj = self._json(self._http(u, timeout=20))
            if obj is None:
                continue
            domains = self._extract_domains(obj)
            for d in domains:
                d = (d or '').strip().rstrip('/')
                if d and d not in found:
                    found.append(d)
            if found:
                break
        bases = []
        for d in found:
            if d.startswith('http'):
                b = d if d.endswith('/') else d + '/'
                if not b.endswith('api/v1/'):
                    b += 'api/v1/'
                bases.append(b)
        if bases:
            self._bases = bases + [b for b in self._bases if b not in bases]

    def _extract_domains(self, obj):
        out = []
        if isinstance(obj, list):
            for it in obj:
                if isinstance(it, str):
                    out.append(it)
                elif isinstance(it, dict):
                    for k in ('domain', 'url', 'host', 'apiUrl', 'baseUrl'):
                        if it.get(k):
                            out.append(str(it[k]))
        elif isinstance(obj, dict):
            for k in ('data', 'domains', 'list', 'records', 'result'):
                v = obj.get(k)
                if v is not None:
                    out.extend(self._extract_domains(v))
            for k in ('domain', 'url', 'host', 'apiUrl', 'baseUrl'):
                if obj.get(k):
                    out.append(str(obj[k]))
        return out

    def _api(self, path, params=None, method='GET'):
        self._discover()
        params = params or {}
        tried_post = False
        for base in list(self._bases):
            url = base.rstrip('/') + '/' + path.lstrip('/')
            raw = None
            if method == 'GET' and params:
                url = url + '?' + urllib.parse.urlencode(params)
                raw = self._http(url, method='GET')
            elif method == 'POST':
                raw = self._http(url, method='POST', data=params)
            else:
                raw = self._http(url, method='GET')
            obj = self._json(raw)
            if obj is None:
                continue
            if self._is_ok(obj):
                self._base = base
                return obj
            if not tried_post and method == 'GET':
                tried_post = True
                raw2 = self._http(url, method='POST', data=params)
                obj2 = self._json(raw2)
                if obj2 is not None and self._is_ok(obj2):
                    self._base = base
                    return obj2
        return None

    def _is_ok(self, obj):
        if obj is None:
            return False
        if isinstance(obj, list):
            return True
        if isinstance(obj, dict):
            code = obj.get('errorCode')
            if code is None:
                code = obj.get('error_code')
            if code is None:
                code = obj.get('code')
            if code is None:
                return True
            try:
                return int(code) == 0
            except Exception:
                return str(code) in ('0', '200', 'success', 'SUCCESS')
        return False

    def _unwrap_list(self, obj):
        if obj is None:
            return [], 0
        if isinstance(obj, list):
            return obj, 0
        if isinstance(obj, dict):
            data = obj.get('data')
            if data is None:
                data = obj
            total = _num(obj.get('total', 0)) or _num((data if isinstance(data, dict) else {}).get('total', 0))
            if isinstance(data, list):
                return data, total
            if isinstance(data, dict):
                for k in ('list', 'records', 'rows', 'items', 'result', 'dataList', 'videos'):
                    v = data.get(k)
                    if isinstance(v, list):
                        return v, total or _num(data.get('total', 0))
                return [], total
            for k in ('list', 'records', 'rows', 'items', 'result', 'dataList', 'videos'):
                v = obj.get(k)
                if isinstance(v, list):
                    return v, total
            return [], total
        return [], 0

    def _item(self, d):
        if not isinstance(d, dict):
            return None
        vid = _pick(d, ('videoId', 'id', 'vid'))
        vid = str(vid or '').strip()
        if not vid:
            return None
        name = _pick(d, ('videoTitle', 'title', 'name', 'videoName'))
        name = str(name or '').strip()
        if not name:
            return None
        pic = _pick(d, ('coverUrl', 'verticalCoverURL', 'coverURL', 'cover', 'poster', 'pic'))
        pic = str(pic or '').strip()
        if pic.startswith('//'):
            pic = 'https:' + pic
        remarks = _fmt_duration(_pick(d, ('duration', 'videoDuration', 'length')))
        cnt = _fmt_count(_pick(d, ('playCount', 'viewCount', 'playNum')))
        if cnt and not remarks:
            remarks = cnt + '次播放'
        elif cnt:
            remarks = remarks + ' · ' + cnt + '次播放'
        return {
            'vod_id': vid,
            'vod_name': name,
            'vod_pic': pic,
            'vod_remarks': remarks,
            'vod_year': str(_pick(d, ('year', 'createYear')) or ''),
            'vod_area': '',
            'vod_actor': ', '.join([str(x) for x in d.get('actressNameList', []) if x]) if isinstance(d.get('actressNameList'), list) else str(_pick(d, ('actressName', 'actor')) or ''),
            'vod_director': '',
            'vod_content': str(_pick(d, ('description', 'content', 'intro', 'remark')) or ''),
            'type_name': str(_pick(d, ('categoryName', 'typeName')) or ''),
            'vod_tag': '',
        }

    def _items(self, obj):
        lst, total = self._unwrap_list(obj)
        out = []
        seen = set()
        for d in lst:
            it = self._item(d)
            if it and it['vod_id'] not in seen:
                seen.add(it['vod_id'])
                out.append(it)
        return out, total

    def _categories(self):
        obj = self._api('categories/all/getCates')
        cats = []
        if obj is not None:
            lst, _ = self._unwrap_list(obj)
            for d in lst:
                if not isinstance(d, dict):
                    continue
                cid = _pick(d, ('categoryId', 'id', 'cateId', 'typeId'))
                name = _pick(d, ('categoryName', 'name', 'cateName', 'typeName'))
                cid = str(cid or '').strip()
                name = str(name or '').strip()
                if not cid or not name:
                    continue
                if _skip_name(name):
                    continue
                cats.append({'type_id': cid, 'type_name': name})
        if not cats:
            obj = self._api('categories/dark/top')
            if obj is not None:
                lst, _ = self._unwrap_list(obj)
                for d in lst:
                    if not isinstance(d, dict):
                        continue
                    cid = _pick(d, ('categoryId', 'id', 'cateId', 'typeId'))
                    name = _pick(d, ('categoryName', 'name', 'cateName', 'typeName'))
                    cid = str(cid or '').strip()
                    name = str(name or '').strip()
                    if not cid or not name:
                        continue
                    if _skip_name(name):
                        continue
                    cats.append({'type_id': cid, 'type_name': name})
        return cats

    def _video_raw(self, vid):
        obj = self._api('videos/getVideoDetail', {'videoId': vid})
        if obj is not None:
            lst, _ = self._unwrap_list(obj)
            if lst and isinstance(lst[0], dict):
                return lst[0]
            if isinstance(obj, dict):
                data = obj.get('data')
                if isinstance(data, dict) and (data.get('videoId') or data.get('id')):
                    return data
        obj = self._api('videos/filter', {'videoId': vid, 'page': 1, 'pageSize': 1})
        if obj is not None:
            lst, _ = self._unwrap_list(obj)
            if lst and isinstance(lst[0], dict):
                return lst[0]
        return None

    def _play_url_of(self, d):
        if not isinstance(d, dict):
            return ''
        for k in ('m3u8URL', 'm3u8Url', 'playURL', 'playUrl', 'videoUrl'):
            v = str(d.get(k) or '').strip()
            if v.startswith('http'):
                return v
        return ''

    def homeContent(self, filter=''):
        cats = self._categories()
        items = []
        if cats:
            items, _ = self._items(self._api('videos/filter', {'categoryId': cats[0]['type_id'], 'page': 1, 'pageSize': PAGE_SIZE}))
        if not items:
            items, _ = self._items(self._api('videos/recommendPool', {'page': 1, 'pageSize': PAGE_SIZE}))
        return {
            'class': cats,
            'list': items,
            'filters': {},
        }

    def homeVideoContent(self):
        items, total = self._items(self._api('videos/recommendPool', {'page': 1, 'pageSize': PAGE_SIZE}))
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': total}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        tid = str(tid or '').strip()
        items = []
        total = 0
        if tid == 'short':
            items, total = self._items(self._api('videos/short', {'page': pg, 'pageSize': PAGE_SIZE}))
        elif tid == 'recommend':
            items, total = self._items(self._api('videos/recommendPool', {'page': pg, 'pageSize': PAGE_SIZE}))
        else:
            params = {'categoryId': tid, 'page': pg, 'pageSize': PAGE_SIZE}
            if isinstance(extend, dict):
                st = extend.get('sortType') or extend.get('sort')
                if st:
                    params['sortType'] = st
            items, total = self._items(self._api('videos/filter', params))
        pagecount = 0
        if total > 0:
            pagecount = (total + PAGE_SIZE - 1) // PAGE_SIZE
        return {'list': items, 'page': pg, 'pagecount': pagecount, 'total': total}

    def detailContent(self, ids):
        vid = _norm_id(ids)
        if not vid:
            return {'list': []}
        d = self._video_raw(vid)
        if not d:
            return {'list': []}
        it = self._item(d)
        if not it:
            return {'list': []}
        eps = []
        episodes = d.get('episodes')
        if isinstance(episodes, list) and episodes:
            for i, ep in enumerate(episodes):
                if isinstance(ep, dict):
                    u = self._play_url_of(ep) or str(_pick(ep, ('videoId', 'id')) or '')
                    nm = str(_pick(ep, ('name', 'title', 'episodeName')) or '') or ('第%d集' % (i + 1))
                else:
                    u = str(ep or '')
                    nm = '第%d集' % (i + 1)
                if not u:
                    u = vid
                eps.append('%s$heiyan:%s' % (nm, u))
        if not eps:
            u = self._play_url_of(d) or vid
            eps = ['正片$heiyan:%s' % u]
        it['vod_play_from'] = '在线播放'
        it['vod_play_url'] = '#'.join(eps)
        it['stills'] = []
        return {'list': [it]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        key = (key or '').strip()
        if not key:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        obj = self._api('search_short_video', {'keyword': key, 'page': pg, 'pageSize': PAGE_SIZE})
        items, total = self._items(obj)
        if not items:
            obj = self._api('tag/newSearchVideos', {'keyword': key, 'page': pg, 'pageSize': PAGE_SIZE})
            items, total = self._items(obj)
        pagecount = 0
        if total > 0:
            pagecount = (total + PAGE_SIZE - 1) // PAGE_SIZE
        return {'list': items, 'page': pg, 'pagecount': pagecount, 'total': total}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('heiyan:'):
            raw = raw[len('heiyan:'):]
        header = {'User-Agent': UA, 'Referer': (self._base or BASES[0])}
        if raw.startswith('http'):
            return {'parse': 0, 'playUrl': raw, 'url': raw, 'header': header}
        url = ''
        if raw:
            obj = self._api('videos/getPlayVideoInfo', {'videoId': raw})
            if obj is not None:
                lst, _ = self._unwrap_list(obj)
                if lst and isinstance(lst[0], dict):
                    url = self._play_url_of(lst[0])
                elif isinstance(obj, dict):
                    data = obj.get('data')
                    if isinstance(data, dict):
                        url = self._play_url_of(data)
            if not url:
                d = self._video_raw(raw)
                url = self._play_url_of(d)
        if not url:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': header, 'msg': 'no play url'}
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param=None):
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(urllib.parse.parse_qsl(p))
            if isinstance(p, bytes):
                try:
                    p = json.loads(p.decode('utf-8', 'replace'))
                except Exception:
                    p = {}
            if not isinstance(p, dict):
                p = {}
            target = p.get('url') or p.get('u') or ''
            if isinstance(target, list):
                target = target[0] if target else ''
            target = urllib.parse.unquote(str(target or '').strip())
            if target.startswith('heiyan:'):
                target = target[len('heiyan:'):]
            if not target.startswith('http'):
                return [404, 'text/plain', '', {}]
            xtype = str(p.get('type') or '').strip().lower()
            if xtype == 'img' or xtype == 'image':
                raw = self._http(target, timeout=20)
                if not raw:
                    return [404, 'text/plain', '', {}]
                ct = 'image/jpeg'
                if raw.startswith(b'\x89PNG'):
                    ct = 'image/png'
                elif raw.startswith(b'GIF8'):
                    ct = 'image/gif'
                elif raw.startswith(b'RIFF') and b'WEBP' in raw[:16]:
                    ct = 'image/webp'
                return [200, ct, base64.b64encode(raw).decode('ascii'), {}, 1]
            raw = self._http(target, timeout=20)
            if not raw:
                return [404, 'text/plain', '', {}]
            if xtype == 'm3u8':
                try:
                    text = raw.decode('utf-8', 'replace')
                except Exception:
                    text = ''
                return [200, 'application/vnd.apple.mpegurl', text, {}]
            ct = 'application/octet-stream'
            if raw[:6] == b'#EXTM3U':
                ct = 'application/vnd.apple.mpegurl'
                return [200, ct, raw.decode('utf-8', 'replace'), {}]
            return [200, ct, raw, {}]
        except Exception:
            return [404, 'text/plain', '', {}]

    def isVideoFormat(self, url):
        path = (url or '').split('?')[0].lower()
        return path.endswith(('.m3u8', '.mp4', '.flv', '.mkv', '.mov', '.ts', '.avi', '.m4v'))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return {}
