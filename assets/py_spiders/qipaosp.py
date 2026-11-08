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
import html as _html
import http.client
import json
import re
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


BASES = [
    'https://qipaosp.devs.li',
    'https://www.qipaotv.com',
    'https://qipaosp.dpdns.org',
    'https://qipaosp2.devs.li',
    'https://www.qipaosp.kdns.fr',
    'https://www.qipaosp2.kdns.fr',
]
LINES = ['/api-jisu/', '/api-vv/', '/api-tiangou/', '/api-hs/', '/api-mkmb/']
LINE_NAMES = ['极速专线', '薇薇专线', '舔狗专线', '仓库专线', 'MB专线']
EXCLUDE = {
    0: ['智能换脸'],
    1: ['最新视频', '热门', '欧美', '动漫', 'AI换脸', '乱伦', '强奸', '女主播', '擦边短剧'],
    2: [],
    3: [],
    4: ['明星换脸', '黑料吃瓜'],
}
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

_STATE = {'base': '', 'tk': '', 'exp': 0}
_TIMEOUT = 90


def _parse_api(text):
    t = (text or '').strip()
    if not t:
        return {}
    if t.startswith('{') or t.startswith('['):
        try:
            return json.loads(t)
        except Exception:
            return {}
    try:
        return json.loads(base64.b64decode(t[::-1]).decode('utf-8'))
    except Exception:
        pass
    try:
        return json.loads(base64.b64decode(t).decode('utf-8'))
    except Exception:
        return {}


def _read_body(resp, raw):
    enc = ''
    try:
        enc = (resp.headers.get('Content-Encoding') or '').lower()
    except Exception:
        pass
    if enc == 'gzip' or raw[:2] == b'\x1f\x8b':
        try:
            raw = gzip.decompress(raw)
        except Exception:
            pass
    for cs in ('utf-8', 'gbk', 'gb18030'):
        try:
            return raw.decode(cs)
        except Exception:
            continue
    return raw.decode('utf-8', 'replace')


def _http_get(url, headers=None, timeout=_TIMEOUT):
    hdr = {
        'User-Agent': UA,
        'Accept': 'application/json, text/html, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
    }
    if headers:
        hdr.update(headers)
    for _ in range(2):
        if _HAS_REQ:
            try:
                resp = requests.get(url, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    return resp.text
                if resp.status_code in (401, 403, 404):
                    return None
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                if resp.status != 200:
                    return None
                return _read_body(resp, resp.read())
        except http.client.IncompleteRead as e:
            part = e.partial or b''
            if part:
                try:
                    return part.decode('utf-8', 'replace')
                except Exception:
                    pass
        except Exception:
            pass
    return None


def _http_post_json(url, payload, timeout=_TIMEOUT):
    body = json.dumps(payload).encode('utf-8')
    hdr = {
        'User-Agent': UA,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
    }
    for _ in range(2):
        if _HAS_REQ:
            try:
                resp = requests.post(url, data=body, headers=hdr, timeout=timeout)
                if resp.status_code == 200:
                    return resp.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, data=body, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
                if resp.status != 200:
                    return None
                return _read_body(resp, resp.read())
        except http.client.IncompleteRead as e:
            part = e.partial or b''
            if part:
                try:
                    return part.decode('utf-8', 'replace')
                except Exception:
                    pass
        except Exception:
            pass
    return None


def _ensure_base():
    if _STATE.get('base'):
        return _STATE['base']
    bucket = int(time.time() // 1800)
    for base in BASES:
        text = _http_get('%s/api/public-config?_v=%d' % (base, bucket))
        if not text:
            continue
        data = _parse_api(text)
        if isinstance(data, dict) and data.get('code') == 1:
            _STATE['base'] = base
            return base
    _STATE['base'] = BASES[0]
    return BASES[0]


def _ensure_token(base):
    now = int(time.time() * 1000)
    if _STATE.get('tk') and _STATE.get('base') == base:
        exp = _STATE.get('exp') or 0
        if exp - now > 1800000:
            return _STATE['tk']
    text = _http_post_json(base + '/api-verify', {'token': 'refresh'})
    if text:
        data = _parse_api(text)
        tk = data.get('tk') if isinstance(data, dict) else None
        if tk and isinstance(tk, str) and '.' in tk:
            try:
                _STATE['exp'] = int(tk.split('.')[0])
            except Exception:
                _STATE['exp'] = 0
            _STATE['tk'] = tk
            _STATE['base'] = base
            return tk
    return _STATE.get('tk') or ''


def _api(path, params, line=0, with_token=True):
    bases = [b for b in [_STATE.get('base') or '', BASES[0]] if b]
    for base in BASES:
        if base not in bases:
            bases.append(base)
    last = None
    for base in bases:
        tk = _ensure_token(base) if with_token else ''
        hdr = {'x-app-token': tk} if tk else {}
        qs = urllib.parse.urlencode(params)
        url = base + path + ('?' + qs if qs else '')
        text = _http_get(url, headers=hdr)
        if text is None:
            continue
        data = _parse_api(text)
        if isinstance(data, dict) and data:
            _STATE['base'] = base
            return data
        last = data
    return last or {}


def _fix_url(raw, base):
    u = (raw or '').strip()
    if not u:
        return ''
    if u.startswith('//'):
        return 'https:' + u
    if u.startswith('http://') or u.startswith('https://'):
        return u
    if u.startswith('/'):
        return base.rstrip('/') + u
    return base.rstrip('/') + '/' + u


def _is_excluded(name, cat, line):
    words = EXCLUDE.get(line) or []
    if not words:
        return False
    hay = ((name or '') + ' ' + (cat or '')).lower()
    for w in words:
        if w.lower() in hay:
            return True
    return False


def _to_item(v, line):
    base = _STATE.get('base') or BASES[0]
    raw_id = str(v.get('vod_id') if v.get('vod_id') is not None else '')
    if not raw_id:
        return None
    try:
        raw_id = urllib.parse.unquote(raw_id)
    except Exception:
        pass
    name = _html.unescape(str(v.get('vod_name') or '')).strip()
    if not name:
        return None
    cat = str(v.get('type_name') or v.get('cat') or '')
    if _is_excluded(name, cat, line):
        return None
    pic = _fix_url(str(v.get('vod_pic') or v.get('pic') or ''), base)
    return {
        'vod_id': '%d:%s' % (line, raw_id),
        'vod_name': name,
        'vod_pic': pic,
        'vod_remarks': str(v.get('vod_remarks') or v.get('rem') or ''),
        'vod_year': str(v.get('vod_time') or '')[:4],
        'vod_area': '',
        'vod_actor': str(v.get('vod_actor') or ''),
        'vod_director': '',
        'vod_content': '',
        'type_name': cat,
    }


def _parse_lines(v, line):
    base = _STATE.get('base') or BASES[0]
    froms = str(v.get('vod_play_from') or '').split('$$$')
    groups = str(v.get('vod_play_url') or '').split('$$$')
    lines = []
    for idx, group in enumerate(groups):
        raw_name = (froms[idx] if idx < len(froms) else '').strip()
        ep_strs = [s.strip() for s in re.split(r'[\r\n#]+', group) if s.strip()]
        eps = []
        for pos, s in enumerate(ep_strs):
            ep_name = ''
            play_url = ''
            if '$' in s:
                parts = s.split('$')
                ep_name = parts[0].strip()
                play_url = '$'.join(parts[1:]).strip()
            elif s.startswith('http') or s.startswith('/'):
                ep_name = '第%d集' % (pos + 1)
                play_url = s
            if not play_url:
                continue
            if play_url.startswith('http://') and base.startswith('https://'):
                play_url = play_url.replace('http://', 'https://', 1)
            eps.append({'name': ep_name or ('第%d集' % (pos + 1)), 'url': play_url})
        if eps:
            lines.append({'name': raw_name or ('线路 %d' % (idx + 1)), 'eps': eps})
    m3u8_lines = []
    for ln in lines:
        name = ln['name'].lower()
        if 'yun' in name or '云播' in ln['name']:
            continue
        if 'm3u8' in name or any('.m3u8' in e['url'] for e in ln['eps']):
            m3u8_lines.append(ln)
    picked = m3u8_lines if m3u8_lines else [ln for ln in lines if 'yun' not in ln['name'].lower() and '云播' not in ln['name']]
    if not picked:
        picked = lines
    picked.sort(key=lambda ln: 3 if ('m3u8' in ln['name'].lower() or (ln['eps'] and '.m3u8' in ln['eps'][0]['url'])) else 1, reverse=True)
    return picked


def _split_vod_id(vod_id):
    s = str(vod_id or '').strip()
    try:
        s = urllib.parse.unquote(s)
    except Exception:
        pass
    m = re.match(r'^([0-7]):(.*)$', s, re.S)
    if m:
        return int(m.group(1)), m.group(2)
    return 0, s


def _split_play_id(play_id):
    s = str(play_id or '').strip()
    m = re.match(r'^([0-7]):(.+):(\d+):(\d+)$', s, re.S)
    if m:
        return int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4))
    m = re.match(r'^([0-7]):(.+)$', s, re.S)
    if m:
        return int(m.group(1)), m.group(2), 0, 0
    return 0, s, 0, 0


def _fetch_detail(line, raw_id):
    data = _api(LINES[line], {'ac': 'detail', 'ids': raw_id}, line=line)
    items = data.get('list') or []
    if not items:
        return None
    got = str(items[0].get('vod_id') if items[0].get('vod_id') is not None else '')
    try:
        got = urllib.parse.unquote(got)
    except Exception:
        pass
    if got != raw_id:
        return None
    return items[0]


def _norm_id(ids):
    if isinstance(ids, (list, tuple)):
        return str(ids[0]) if ids else ''
    return str(ids or '')


def _norm_pg(pg):
    try:
        return int(pg)
    except Exception:
        try:
            return int(str(pg).strip())
        except Exception:
            return 1


def _empty_detail(vod_id):
    return {'list': [{
        'vod_id': vod_id,
        'vod_name': '',
        'vod_pic': '',
        'vod_actor': '',
        'vod_director': '',
        'vod_remarks': '',
        'vod_year': '',
        'vod_area': '',
        'vod_content': '',
        'type_name': '',
        'vod_tag': '',
        'vod_play_from': '在线播放',
        'vod_play_url': '',
        'stills': [],
    }]}


class Spider(BaseSpider):

    def getName(self):
        return '🔞气泡视频'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        _ensure_base()
        data = _api(LINES[0], {'ac': 'list'}, line=0)
        cats = []
        for c in data.get('class') or []:
            cid = str(c.get('type_id') if c.get('type_id') is not None else '')
            name = str(c.get('type_name') or '').strip()
            if not cid or not name:
                continue
            if _is_excluded(name, '', 0):
                continue
            if not any(x['type_id'] == cid for x in cats):
                cats.append({'type_id': cid, 'type_name': name})
        return {'class': cats, 'filters': {}}

    def homeVideoContent(self):
        _ensure_base()
        data = _api(LINES[0], {'ac': 'videolist', 'pg': 1}, line=0)
        items = []
        for v in data.get('list') or []:
            it = _to_item(v, 0)
            if it:
                items.append(it)
        return {
            'list': items,
            'page': 1,
            'pagecount': int(data.get('pagecount') or 0),
            'total': int(data.get('total') or 0),
        }

    def categoryContent(self, tid, pg, filter=False, extend=None):
        _ensure_base()
        tid = str(tid or '').strip()
        pg = _norm_pg(pg)
        if pg < 1:
            pg = 1
        params = {'ac': 'videolist', 'pg': pg}
        if tid and tid != 'all':
            params['t'] = tid
        data = _api(LINES[0], params, line=0)
        items = []
        for v in data.get('list') or []:
            it = _to_item(v, 0)
            if it:
                items.append(it)
        return {
            'list': items,
            'page': pg,
            'pagecount': int(data.get('pagecount') or 0),
            'total': int(data.get('total') or 0),
        }

    def detailContent(self, ids):
        vod_id = _norm_id(ids).strip()
        if not vod_id:
            return _empty_detail(vod_id)
        line, raw_id = _split_vod_id(vod_id)
        v = _fetch_detail(line, raw_id)
        if not v:
            for alt in range(len(LINES)):
                if alt == line:
                    continue
                v = _fetch_detail(alt, raw_id)
                if v:
                    line = alt
                    break
        if not v:
            return _empty_detail(vod_id)
        base = _STATE.get('base') or BASES[0]
        title = _html.unescape(str(v.get('vod_name') or '')).strip()
        if not title:
            return _empty_detail(vod_id)
        pic = _fix_url(str(v.get('vod_pic') or ''), base)
        desc = _html.unescape(str(v.get('vod_content') or v.get('vod_blurb') or '')).strip()
        parsed = _parse_lines(v, line)
        play_from = []
        play_url = []
        for li, ln in enumerate(parsed):
            play_from.append(ln['name'])
            eps = []
            for ei, ep in enumerate(ln['eps']):
                pid = '%d:%s:%d:%d' % (line, raw_id, li, ei)
                eps.append('%s$%s' % (ep['name'], pid))
            play_url.append('#'.join(eps))
        if not play_from:
            play_from = ['在线播放']
            play_url = ['正片$%d:%s' % (line, raw_id)]
        return {'list': [{
            'vod_id': '%d:%s' % (line, raw_id),
            'vod_name': title,
            'vod_pic': pic,
            'vod_actor': str(v.get('vod_actor') or ''),
            'vod_director': '',
            'vod_remarks': str(v.get('vod_remarks') or ''),
            'vod_year': str(v.get('vod_time') or '')[:4],
            'vod_area': str(v.get('vod_area') or ''),
            'vod_content': desc,
            'type_name': str(v.get('type_name') or ''),
            'vod_tag': '',
            'vod_play_from': '$$$'.join(play_from),
            'vod_play_url': '$$$'.join(play_url),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        _ensure_base()
        kw = str(key or '').strip()
        if not kw:
            return {'list': [], 'page': 1, 'pagecount': 0, 'total': 0}
        base = _STATE.get('base') or BASES[0]
        tk = _ensure_token(base)
        hdr = {'x-app-token': tk} if tk else {}
        url = base + '/api-search?wd=' + urllib.parse.quote(kw)
        text = _http_get(url, headers=hdr)
        data = _parse_api(text) if text else {}
        items = []
        for v in data.get('list') or []:
            try:
                line = int(v.get('line_idx'))
            except Exception:
                line = 0
            if line < 0 or line >= len(LINES):
                line = 0
            it = _to_item(v, line)
            if it:
                items.append(it)
        return {'list': items, 'page': 1, 'pagecount': 1, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '').strip()
        if '$' in raw:
            raw = raw.split('$', 1)[1].strip()
        base = _ensure_base()
        header = {'User-Agent': UA, 'Referer': base + '/'}
        if not raw:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if raw.startswith('http://') or raw.startswith('https://'):
            url = raw
            if url.startswith('http://') and base.startswith('https://'):
                url = url.replace('http://', 'https://', 1)
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        if raw.startswith('/'):
            url = base.rstrip('/') + raw
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}
        line, raw_id, li, ei = _split_play_id(raw)
        v = _fetch_detail(line, raw_id)
        if not v:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        parsed = _parse_lines(v, line)
        if not parsed:
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
        if li < 0 or li >= len(parsed):
            li = 0
        eps = parsed[li]['eps']
        if ei < 0 or ei >= len(eps):
            ei = 0
        url = eps[ei]['url']
        if url.startswith('/'):
            url = base.rstrip('/') + url
        elif url.startswith('http://') and base.startswith('https://'):
            url = url.replace('http://', 'https://', 1)
        return {'parse': 0, 'playUrl': url, 'url': url, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', b'', {}]

    def isVideoFormat(self, url):
        u = str(url or '').lower().split('?')[0]
        return u.endswith(('.m3u8', '.mp4', '.mkv', '.webm', '.flv', '.ts'))

    def manualVideoCheck(self):
        return True

    def action(self, action, params=None):
        return {'code': 0, 'msg': 'ok'}
