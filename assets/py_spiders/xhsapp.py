import base64
import hashlib
import json
import random
import ssl
import string
import time
import urllib.error
import urllib.request
from urllib.parse import quote, unquote, parse_qs

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider:
        def getCache(self, key):
            return ''

        def setCache(self, key, value):
            return None

        def getProxyUrl(self):
            return ''

try:
    import requests
except Exception:
    requests = None

try:
    from Crypto.Cipher import AES as _CryptoAES
    from Crypto.Util.Padding import unpad as _crypto_unpad
except Exception:
    _CryptoAES = None
    _crypto_unpad = None


DEFAULT_HOSTS = ['bpbbmplfxc', 'rggwiyhqtg', 'fhoumpjjih', 'dyfcbkggxn']

UA = ('Mozilla/5.0 (Linux; Android 11; M2012K10C Build/RP1A.200720.011; wv) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/87.0.4280.141 '
      'Mobile Safari/537.36;SuiRui/xhs/ver=1.2.6')

AES_KEY = base64.b64decode('SmhiR2NpT2lKSVV6STFOaQ==')
IMG_XOR_KEY = b'2020-zq3-888'

PIXEL = base64.b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/wFMaF0AAAAASUVORK5CYII=')

SEARCH_PATHS = [
    '/api/short/video/getShortVideos?videoMark=4&keyword=%s&page=%s&pageSize=%s',
    '/api/short/video/search?keyword=%s&page=%s&pageSize=%s',
    '/api/short/video/getShortVideos?classifyId=0&videoMark=4&keyword=%s&page=%s&pageSize=%s',
    '/api/video/search?keyword=%s&page=%s&pageSize=%s',
    '/api/short/video/queryShortVideos?keyword=%s&page=%s&pageSize=%s',
]

FLAG_WORDS = ['loli', 'lolita', '幼女', '幼齿', '初中生', '小学生', '未成年', '未满', '萝莉', '童颜', '幼态', '处女']

_SBOX = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]

_INV_SBOX = [
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
]

_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]


def _xtime(a):
    a <<= 1
    if a & 0x100:
        a ^= 0x11b
    return a & 0xff


def _gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _aes_expand_key(key16):
    w = [list(key16[i * 4:(i + 1) * 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[x] for x in t]
            t[0] ^= _RCON[i // 4 - 1]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return w


def _aes_decrypt_block(block16, w):
    s = [[block16[4 * c + r] for c in range(4)] for r in range(4)]

    def _ark(rnd):
        for c in range(4):
            for r in range(4):
                s[r][c] ^= w[rnd * 4 + c][r]

    def _inv_shift_rows():
        for r in range(1, 4):
            s[r] = s[r][-r:] + s[r][:-r]

    def _inv_sub_bytes():
        for r in range(4):
            for c in range(4):
                s[r][c] = _INV_SBOX[s[r][c]]

    def _inv_mix_columns():
        for c in range(4):
            a = [s[r][c] for r in range(4)]
            s[0][c] = _gmul(a[0], 14) ^ _gmul(a[1], 11) ^ _gmul(a[2], 13) ^ _gmul(a[3], 9)
            s[1][c] = _gmul(a[0], 9) ^ _gmul(a[1], 14) ^ _gmul(a[2], 11) ^ _gmul(a[3], 13)
            s[2][c] = _gmul(a[0], 13) ^ _gmul(a[1], 9) ^ _gmul(a[2], 14) ^ _gmul(a[3], 11)
            s[3][c] = _gmul(a[0], 11) ^ _gmul(a[1], 13) ^ _gmul(a[2], 9) ^ _gmul(a[3], 14)

    _ark(10)
    for rnd in range(9, 0, -1):
        _inv_shift_rows()
        _inv_sub_bytes()
        _ark(rnd)
        _inv_mix_columns()
    _inv_shift_rows()
    _inv_sub_bytes()
    _ark(0)
    out = bytearray(16)
    for c in range(4):
        for r in range(4):
            out[4 * c + r] = s[r][c]
    return bytes(out)


def _aes_cbc_decrypt_py(key16, iv16, data):
    if len(data) % 16:
        raise ValueError('bad length')
    w = _aes_expand_key(key16)
    out = bytearray()
    prev = iv16
    for i in range(0, len(data), 16):
        dec = _aes_decrypt_block(data[i:i + 16], w)
        out += bytes(dec[j] ^ prev[j] for j in range(16))
        prev = data[i:i + 16]
    if not out:
        raise ValueError('empty')
    pad = out[-1]
    if pad < 1 or pad > 16 or out[-pad:] != bytes([pad]) * pad:
        raise ValueError('bad padding')
    return bytes(out[:-pad])


class Spider(BaseSpider):

    def getName(self):
        return '小红薯APP'

    def getDependence(self):
        return []

    def init(self, extend=""):
        self.cfg = self._cfg(extend)
        self.ua = UA
        self.did = self._did()
        self.session = None
        if requests is not None:
            try:
                self.session = requests.Session()
            except Exception:
                self.session = None
        self.api_cache = {}
        self.img_cache = {}
        self.class_cache = []
        self.token = ''
        self.phost = ''
        self.auth_cdn = ''
        self.host = ''
        self.dead = {}
        self._connect(force=True)

    def destroy(self):
        try:
            if self.session is not None:
                self.session.close()
        except Exception:
            pass
        self.session = None
        self.api_cache = {}
        self.img_cache = {}
        self.token = ''
        self.host = ''

    def action(self, *args, **kwargs):
        return {}

    def homeContent(self, filter=None):
        classes = self._classes()
        res = {'class': classes, 'filters': {}}
        first = classes[0]['type_id'] if classes else '0'
        res['list'] = self.categoryContent(first, '1', False, {}).get('list', [])
        return res

    def homeVideoContent(self):
        tid = self.class_cache[0]['type_id'] if self.class_cache else '0'
        return {'list': self.categoryContent(tid, '1', False, {}).get('list', [])}

    def categoryContent(self, tid, pg, filter=None, extend=None):
        pg = str(pg or '1')
        tid = str(tid if tid is not None else '0')
        size = int(self.cfg.get('page_size') or 20)
        if tid in ('0', '', 'None'):
            paths = [
                '/api/short/video/getShortVideos?classifyId=0&videoMark=4&page=%s&pageSize=%s' % (pg, size),
                '/api/short/video/getShortVideos?videoMark=4&page=%s&pageSize=%s' % (pg, size),
            ]
        else:
            paths = [
                '/api/short/video/getShortVideos?classifyId=%s&videoMark=4&page=%s&pageSize=%s' % (tid, pg, size),
                '/api/video/queryVideoList?classifyId=%s&page=%s&pageSize=%s' % (tid, pg, size),
            ]
        items = []
        for p in paths:
            data = self._api(p)
            if not isinstance(data, dict):
                continue
            arr = self._as_list(data.get('data')) or self._as_list(data.get('list'))
            if arr:
                items = self._items(arr)
                break
        if not items and pg == '1':
            self._connect(force=True)
            for p in paths:
                data = self._api(p, refresh=False)
                arr = self._as_list(data.get('data')) if isinstance(data, dict) else []
                if arr:
                    items = self._items(arr)
                    break
        return {
            'list': items,
            'page': int(pg),
            'pagecount': 9999 if items else int(pg),
            'limit': size,
            'total': 999999 if items else 0,
        }

    def detailContent(self, ids):
        if isinstance(ids, (list, tuple)):
            vid = str(ids[0]) if ids else ''
        else:
            vid = str(ids or '')
        data = self._api('/api/video/getVideoById?videoId=%s' % quote(vid, safe=''))
        if isinstance(data, dict) and isinstance(data.get('data'), dict):
            data = data['data']
        if not isinstance(data, dict) or not data:
            return {'list': [{'vod_id': vid, 'vod_name': vid,
                              'vod_play_from': '小红书官方', 'vod_play_url': '正片$'}]}
        name = data.get('title') or data.get('vod_name') or data.get('name') or vid
        auth = str(data.get('authKey') or data.get('auth') or '')
        path = data.get('videoUrl') or data.get('playPath') or data.get('url') or ''
        play = self._play_url(auth, path)
        tag = data.get('tagTitles', '')
        if isinstance(tag, list):
            tag = ' '.join([str(x) for x in tag])
        if not tag:
            tag = data.get('classifyTitle') or ''
        vod = {
            'vod_id': vid,
            'vod_name': str(name),
            'vod_pic': self._pic(data.get('coverImg') or data.get('cover') or data.get('img') or ''),
            'type_name': str(tag or ''),
            'vod_year': str(data.get('year') or ''),
            'vod_area': str(data.get('area') or ''),
            'vod_remarks': self._time(data.get('playTime')),
            'vod_content': str(data.get('desc') or data.get('intro') or ''),
            'vod_play_from': str(data.get('nickName') or '小红书官方'),
            'vod_play_url': str(name) + '$' + play,
        }
        return {'list': [vod]}

    def searchContent(self, key, quick=False, pg='1'):
        pg = str(pg or '1')
        key = str(key or '').strip()
        if not key:
            return {'list': [], 'page': int(pg), 'pagecount': 1, 'limit': 20, 'total': 0}
        size = int(self.cfg.get('page_size') or 20)
        k = quote(key, safe='')
        for tpl in SEARCH_PATHS:
            data = self._api(tpl % (k, pg, size))
            arr = self._as_list(data.get('data')) if isinstance(data, dict) else []
            if not arr:
                arr = self._as_list(data.get('list')) if isinstance(data, dict) else []
            items = self._items(arr)
            if items:
                return {'list': items, 'page': int(pg), 'pagecount': 9999, 'limit': size, 'total': 999999}
        items = self._local_search(key)
        return {'list': items, 'page': int(pg), 'pagecount': 1, 'limit': size, 'total': len(items)}

    def playerContent(self, flag, id, vipFlags):
        h = self._headers()
        if 'aut' in h:
            h['Authorization'] = h['aut']
        url = str(id or '').strip()
        if url.startswith('http'):
            return {'parse': 0, 'playUrl': '', 'url': url, 'header': h}
        if url.startswith('auth_key='):
            base = self.host or self._ensure_host()
            if base:
                return {'parse': 0, 'playUrl': '',
                        'url': base + '/api/m3u8/decode/authPath?' + url, 'header': h}
            return {'parse': 0, 'playUrl': '', 'url': '', 'header': h}
        if url and self.host:
            return {'parse': 0, 'playUrl': '',
                    'url': self.host + '/' + url.lstrip('/'), 'header': h}
        return {'parse': 0, 'playUrl': '', 'url': url, 'header': h}

    def localProxy(self, param):
        tp, u = self._proxy_param(param)
        if not u:
            return [200, 'image/png', PIXEL]
        ct, body = self._img_asset(u)
        if not body:
            return [200, 'image/png', PIXEL]
        return [200, ct or 'image/jpeg', body]

    def isVideoFormat(self, url):
        u = str(url or '').lower()
        return any(x in u for x in ('.m3u8', '.mp4', '.flv', '.ts'))

    def manualVideoCheck(self):
        return False

    def _cfg(self, extend):
        cfg = {
            'hosts': [],
            'remote': '',
            'chCode': 'dafe13',
            'tt': 'U',
            'code': '',
            'page_size': 20,
            'inline_pic': 0,
            'img_max': 200,
            'refresh': 0,
            'timeout': 12,
        }
        s = extend if isinstance(extend, str) else (str(extend) if extend else '')
        s = s.strip()
        if not s:
            return cfg
        if s.startswith('{'):
            try:
                j = json.loads(s)
                if isinstance(j, dict):
                    for k in list(cfg.keys()):
                        if k in j and j[k] not in (None, ''):
                            cfg[k] = j[k]
                    if not cfg['hosts'] and (j.get('host') or j.get('domain')):
                        cfg['hosts'] = [j.get('host') or j.get('domain')]
                return cfg
            except Exception:
                pass
        cfg['hosts'] = [x for x in s.replace(',', '|').split('|') if x.strip()]
        return cfg

    def _ensure_host(self):
        if not self.host:
            self._connect(force=True)
        return self.host

    def _host_candidates(self):
        raw = list(self.cfg.get('hosts') or [])
        remote = str(self.cfg.get('remote') or '').strip()
        if remote:
            raw += self._remote_hosts(remote)
        raw += list(DEFAULT_HOSTS)
        cached = self._cache_get('xhs_host')
        if cached and cached not in raw:
            raw.insert(0, cached)
        out, seen = [], set()
        for x in raw:
            x = str(x or '').strip().strip('/')
            if not x:
                continue
            if x.startswith('https://'):
                x = x[8:]
            elif x.startswith('http://'):
                x = x[7:]
            x = x.split('/')[0]
            if not x or x in seen:
                continue
            seen.add(x)
            if '.' in x:
                out.append('https://' + x)
            else:
                for _ in range(3):
                    out.append('https://%s.%s.work' % (self._rand(8), x))
                out.append('https://' + x)
        return out

    def _remote_hosts(self, url):
        key = 'xhs_remote'
        now = time.time()
        cached = self._cache_get(key)
        if isinstance(cached, dict) and now - cached.get('t', 0) < 1800:
            return cached.get('v', [])
        val = []
        try:
            status, body, _ = self._http('GET', url, {'User-Agent': self.ua}, None, 6)
            txt = body.decode('utf-8', 'ignore').strip() if body else ''
            if txt.startswith('[') or txt.startswith('{'):
                j = json.loads(txt)
                val = j if isinstance(j, list) else list(j.get('hosts') or j.get('data') or [])
            else:
                val = [ln.strip() for ln in txt.splitlines() if ln.strip()]
        except Exception:
            val = []
        self._cache_set(key, {'t': now, 'v': val})
        return [str(x) for x in val]

    def _rand(self, n):
        return ''.join(random.choices(string.ascii_lowercase + string.digits, k=n))

    def _connect(self, force=False):
        if self.host and self.token and not force:
            return True
        now = time.time()
        cands = [c for c in self._host_candidates()
                 if now - float(self.dead.get(c) or 0) > 60]
        for host in cands:
            got = self._traveler(host)
            if got:
                self.token, self.phost, self.auth_cdn = got
                self.host = host
                self._cache_set('xhs_host', self.host)
                self.api_cache.clear()
                return True
            self.dead[host] = time.time()
        self.host = self.token = self.phost = self.auth_cdn = ''
        return False

    def _traveler(self, host):
        try:
            sign, t = self._sign()
            hd = {'User-Agent': self.ua, 'deviceid': self.did, 't': t, 's': sign,
                  'Content-Type': 'application/json; charset=utf-8'}
            body = {'deviceId': self.did, 'tt': self.cfg.get('tt') or 'U',
                    'code': self.cfg.get('code') or '',
                    'chCode': self.cfg.get('chCode') or 'dafe13'}
            status, raw, _ = self._http('POST', host + '/api/user/traveler', hd,
                                        json.dumps(body).encode('utf-8'), 6)
            if status != 200 or not raw:
                return None
            j = json.loads(raw.decode('utf-8', 'ignore'))
            if not isinstance(j, dict):
                return None
            d = j.get('data') or {}
            if isinstance(d, dict) and d.get('token'):
                return (str(d.get('token') or ''),
                        str(d.get('imgDomain') or ''),
                        str(d.get('authImageCdn') or ''))
        except Exception:
            return None
        return None

    def _refresh_token(self):
        if not self.host:
            return False
        got = self._traveler(self.host)
        if got:
            self.token, self.phost, self.auth_cdn = got
            self.api_cache.clear()
            return True
        return False

    def _api(self, path, refresh=True):
        if not self.host or not self.token:
            self._connect(force=True)
        if not self.host:
            return {}
        url = self.host + path if path.startswith('/') else path
        if url in self.api_cache:
            return self.api_cache[url]
        data, expired = self._fetch(url)
        if expired and refresh:
            if self._refresh_token():
                url = self.host + path if path.startswith('/') else path
                data, expired = self._fetch(url)
            if expired:
                self.dead.pop(self.host, None)
                if self._connect(force=True):
                    url = self.host + path if path.startswith('/') else path
                    data, _ = self._fetch(url)
        if data:
            if len(self.api_cache) > 80:
                self.api_cache.clear()
            self.api_cache[url] = data
        return data

    def _fetch(self, url):
        try:
            status, raw, _ = self._http('GET', url, self._headers(),
                                        None, int(self.cfg.get('timeout') or 12))
            if status == 301:
                return {}, True
            if status != 200 or not raw:
                return {}, False
            j = json.loads(raw.decode('utf-8', 'ignore'))
            if isinstance(j, dict) and j.get('code') == 301:
                return {}, True
            if isinstance(j, dict) and j.get('encData'):
                return self._aes(j.get('encData')), False
            return j if isinstance(j, (dict, list)) else {}, False
        except Exception:
            return {}, False

    def _http(self, method, url, headers, data, timeout):
        headers = dict(headers or {})
        headers.setdefault('Accept-Encoding', 'identity')
        if self.session is not None:
            try:
                if method == 'POST':
                    r = self.session.post(url, data=data, headers=headers,
                                          timeout=timeout, verify=False)
                else:
                    r = self.session.get(url, headers=headers,
                                         timeout=timeout, verify=False)
                return r.status_code, r.content, dict(r.headers or {})
            except Exception:
                pass
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        ctx = ssl._create_unverified_context()
        try:
            resp = urllib.request.urlopen(req, timeout=timeout, context=ctx)
            return resp.getcode(), resp.read(), dict(resp.headers or {})
        except urllib.error.HTTPError as e:
            try:
                return e.code, e.read(), dict(e.headers or {})
            except Exception:
                return e.code, b'', {}
        except Exception:
            return 0, b'', {}

    def _headers(self):
        sign, t = self._sign()
        h = {'User-Agent': self.ua, 'deviceid': self.did, 't': t, 's': sign}
        if self.token:
            h['aut'] = self.token
        return h

    def _sign(self):
        t = str(int(time.time() * 1000))
        return self._md5(t[3:8]), t

    def _aes(self, word):
        try:
            raw = base64.b64decode(word)
            if _CryptoAES is not None:
                dec = _crypto_unpad(
                    _CryptoAES.new(AES_KEY, _CryptoAES.MODE_CBC, AES_KEY).decrypt(raw),
                    _CryptoAES.block_size)
            else:
                dec = _aes_cbc_decrypt_py(AES_KEY, AES_KEY, raw)
            return json.loads(dec.decode('utf-8'))
        except Exception:
            return {}

    def _classes(self):
        data = self._api('/api/video/queryClassifyList?mark=4')
        rows = []
        if isinstance(data, dict):
            rows = (self._as_list(data.get('data'))
                    or self._as_list(data.get('classifyList'))
                    or self._as_list(data.get('list')))
            if not rows and isinstance(data.get('data'), list):
                rows = data['data']
        elif isinstance(data, list):
            rows = self._as_list(data)
        classes, seen = [], set()
        for k in rows:
            if not isinstance(k, dict):
                continue
            tid = str(k.get('classifyId') or k.get('id') or k.get('classId') or '')
            name = k.get('classifyTitle') or k.get('title') or k.get('name') or ''
            if tid and name and tid not in seen and not self._flagged(str(name)):
                seen.add(tid)
                classes.append({'type_name': str(name), 'type_id': tid})
        if not classes:
            classes = [{'type_name': '推荐', 'type_id': '0'}]
        else:
            classes.insert(0, {'type_name': '推荐', 'type_id': '0'})
        self.class_cache = classes
        return classes

    def _flagged(self, name):
        low = name.lower()
        return any(w in low for w in FLAG_WORDS)

    def _as_list(self, v):
        if isinstance(v, list):
            return v
        if isinstance(v, dict):
            for k in ('list', 'data', 'rows', 'items', 'result', 'videos', 'records', 'content'):
                if isinstance(v.get(k), list):
                    return v[k]
        return []

    def _items(self, arr):
        res, seen = [], set()
        for k in arr or []:
            if not isinstance(k, dict):
                continue
            vid = str(k.get('videoId') or k.get('id') or k.get('vid') or '')
            if not vid or vid in seen:
                continue
            seen.add(vid)
            title = k.get('title') or k.get('vod_name') or k.get('name') or vid
            cover = (k.get('coverImg') or k.get('cover') or k.get('img')
                     or k.get('pic') or k.get('verticalImg') or '')
            res.append({
                'vod_id': vid,
                'vod_name': str(title),
                'vod_pic': self._pic(cover),
                'vod_remarks': self._time(k.get('playTime') or k.get('duration')),
                'vod_year': str(k.get('year') or ''),
                'style': {'type': 'rect', 'ratio': 1.33},
            })
        return res

    def _local_search(self, key):
        key_l = key.lower()
        out = []
        try:
            classes = self.class_cache or self._classes()
        except Exception:
            classes = []
        for c in classes[:12]:
            try:
                data = self._api('/api/short/video/getShortVideos?classifyId=%s&videoMark=4&page=1&pageSize=50'
                                 % c['type_id'])
            except Exception:
                continue
            arr = self._as_list(data.get('data')) if isinstance(data, dict) else []
            for it in self._items(arr):
                if key_l in str(it['vod_name']).lower():
                    out.append(it)
            if len(out) >= 40:
                break
        return out[:60]

    def _play_url(self, auth, path):
        path = str(path or '').strip()
        if not path:
            return '正片$'
        if path.startswith('http'):
            return path
        if auth:
            return 'auth_key=%s&path=%s' % (quote(str(auth), safe=''), self._enc(path))
        return path

    def _enc(self, s):
        s = str(s or '')
        if any(c in s for c in '&#?=+ '):
            return quote(s, safe='')
        return s

    def _time(self, seconds):
        try:
            s = int(float(seconds or 0))
            h = s // 3600
            m = s % 3600 // 60
            sec = s % 60
            return '%02d:%02d:%02d' % (h, m, sec) if h else '%02d:%02d' % (m, sec)
        except Exception:
            return ''

    def _pic(self, u):
        if not u:
            return ''
        u = str(u).strip()
        if u.startswith('data:'):
            return u
        if self.cfg.get('inline_pic'):
            d = self._inline_image(u)
            if d:
                return d
        return self._proxy(u)

    def _proxy(self, u):
        if not u:
            return ''
        return 'proxy://do=img&type=img&u=%s' % quote(str(u), safe='')

    def _proxy_param(self, param):
        try:
            if isinstance(param, dict):
                if param.get('u') or param.get('url'):
                    return (param.get('do') or param.get('type') or 'img',
                            str(param.get('u') or param.get('url') or ''))
                q = parse_qs(str(param.get('query') or param.get('params') or ''))
            else:
                q = parse_qs(str(param))
            return ((q.get('do') or q.get('type') or ['img'])[0],
                    unquote((q.get('u') or q.get('url') or [''])[0]))
        except Exception:
            return 'img', ''

    def _inline_image(self, u):
        ct, body = self._img_asset(u)
        if not body or len(body) > int(self.cfg.get('img_max') or 200) * 1024:
            return ''
        return 'data:%s;base64,%s' % (ct or 'image/jpeg', base64.b64encode(body).decode('ascii'))

    def _img_url(self, u):
        if not u:
            return ''
        u = str(u).strip()
        if u.startswith('//'):
            return 'https:' + u
        if u.startswith('http'):
            return u
        if u.startswith('\\/'):
            u = u.replace('\\/', '/')
        base = self.phost or (self.host or '')
        if u.startswith('/'):
            return base + u
        return base + '/' + u

    def _img_asset(self, u):
        u = str(u or '').strip()
        if not u:
            return 'image/png', PIXEL
        if u in self.img_cache:
            return self.img_cache[u]
        try:
            status, body, headers = self._http(
                'GET', self._img_url(u),
                {'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 11; M2012K10C Build/RP1A.200720.011)'},
                None, 15)
            if status != 200 or not body:
                return 'image/png', PIXEL
            body = self._img_decode(body, 100, IMG_XOR_KEY)
            ct = ''
            for k, v in (headers or {}).items():
                if k.lower() == 'content-type':
                    ct = str(v).split(';')[0].strip()
                    break
            if not ct.startswith('image'):
                ct = 'image/jpeg'
            if not body:
                return 'image/png', PIXEL
            if len(self.img_cache) > 160:
                self.img_cache.clear()
            self.img_cache[u] = (ct, body)
            return ct, body
        except Exception:
            return 'image/png', PIXEL

    def _img_decode(self, data, length, key):
        if not data:
            return data
        if self._is_known_image(data):
            return data
        kb = key if isinstance(key, bytes) else key.encode('utf-8')
        arr = bytearray(data)
        for i in range(min(length, len(arr))):
            arr[i] ^= kb[i % len(kb)]
        out = bytes(arr)
        return out if self._is_known_image(out) else data

    def _is_known_image(self, d):
        if not d or len(d) < 4:
            return False
        if d[:3] == b'GIF':
            return True
        if d[:3] == b'\xff\xd8\xff':
            return True
        if len(d) > 8 and d[:8] == b'\x89PNG\r\n\x1a\n':
            return True
        if len(d) > 12 and d[:4] == b'RIFF' and d[8:12] == b'WEBP':
            return True
        if len(d) > 2 and d[:2] == b'BM':
            return True
        return False

    def _did(self):
        try:
            did = self.getCache('did')
        except Exception:
            did = ''
        if not did:
            did = self._md5(str(int(time.time())) + self._rand(6))
            try:
                self.setCache('did', did)
            except Exception:
                pass
        return did

    def _cache_get(self, k):
        try:
            v = self.getCache(k)
            if isinstance(v, str) and v.startswith('{'):
                try:
                    return json.loads(v)
                except Exception:
                    return v
            return v
        except Exception:
            return ''

    def _cache_set(self, k, v):
        try:
            self.setCache(k, v if isinstance(v, str) else json.dumps(v))
        except Exception:
            pass

    def _md5(self, text):
        return hashlib.md5(str(text).encode('utf-8')).hexdigest()
