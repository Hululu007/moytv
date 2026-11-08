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
import hashlib
import html as _html
import http.client
import json
import random
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

try:
    import requests
    _HAS_REQ = True
except Exception:
    _HAS_REQ = False


API = 'https://zdap.gkquu.cn:4438/zd2/'
HOST = 'guohnsqj.hdyubao.cyou'
SALT = '@1243asd31**21#'
AES_KEY = b'mh_aes=19@#$@%@#'
AES_IV = b'5e1y6w452uqw9jq8'
UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
NONCE_ALPH = 'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678'
GUID = str(uuid.uuid4())

CATS = [
    ('video', '全部视频'),
    ('game', 'Sex游戏'),
]

HOME_SIZE = 30
GAME_SIZE = 20
SEARCH_SIZE = 25


def _gf_mul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def _gf_pow(a, n):
    r = 1
    while n:
        if n & 1:
            r = _gf_mul(r, a)
        a = _gf_mul(a, a)
        n >>= 1
    return r


def _build_sboxes():
    sbox = []
    for i in range(256):
        inv = 0 if i == 0 else _gf_pow(i, 254)
        s = inv
        for kk in (1, 2, 3, 4):
            s ^= ((inv << kk) | (inv >> (8 - kk))) & 0xFF
        sbox.append((s ^ 0x63) & 0xFF)
    inv_sbox = [0] * 256
    for i, v in enumerate(sbox):
        inv_sbox[v] = i
    return sbox, inv_sbox


_SBOX, _INV_SBOX = _build_sboxes()
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D]


def _expand_key(key):
    nk = len(key) // 4
    nr = nk + 6
    w = list(key)
    for i in range(nk, 4 * (nr + 1)):
        t = w[4 * (i - 1):4 * i]
        if i % nk == 0:
            t = [_SBOX[t[1]] ^ _RCON[i // nk - 1], _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        base = 4 * (i - nk)
        w += [w[base + j] ^ t[j] for j in range(4)]
    return w, nr


def _decrypt_block(block, rk, nr):
    s = [block[r + 4 * c] for c in range(4) for r in range(4)]

    def add_rk(rnd):
        for c in range(4):
            for r in range(4):
                s[r + 4 * c] ^= rk[16 * rnd + 4 * c + r]

    def inv_shift():
        old = s[:]
        for r in range(4):
            for c in range(4):
                s[r + 4 * c] = old[r + 4 * ((c - r) % 4)]

    def inv_sub():
        for i in range(16):
            s[i] = _INV_SBOX[s[i]]

    def inv_mix():
        for c in range(4):
            i = 4 * c
            a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
            s[i] = _gf_mul(a0, 14) ^ _gf_mul(a1, 11) ^ _gf_mul(a2, 13) ^ _gf_mul(a3, 9)
            s[i + 1] = _gf_mul(a0, 9) ^ _gf_mul(a1, 14) ^ _gf_mul(a2, 11) ^ _gf_mul(a3, 13)
            s[i + 2] = _gf_mul(a0, 13) ^ _gf_mul(a1, 9) ^ _gf_mul(a2, 14) ^ _gf_mul(a3, 11)
            s[i + 3] = _gf_mul(a0, 11) ^ _gf_mul(a1, 13) ^ _gf_mul(a2, 9) ^ _gf_mul(a3, 14)

    add_rk(nr)
    for rnd in range(nr - 1, 0, -1):
        inv_shift()
        inv_sub()
        add_rk(rnd)
        inv_mix()
    inv_shift()
    inv_sub()
    add_rk(0)
    return bytes(s[r + 4 * c] for c in range(4) for r in range(4))


def _aes_cbc_decrypt(ct, key, iv):
    try:
        from Crypto.Cipher import AES as _AES
        pt = _AES.new(key, _AES.MODE_CBC, iv).decrypt(ct)
    except Exception:
        rk, nr = _expand_key(key)
        out = bytearray()
        prev = iv
        for off in range(0, len(ct), 16):
            blk = ct[off:off + 16]
            if len(blk) < 16:
                break
            dec = _decrypt_block(list(blk), rk, nr)
            out += bytes(b ^ p for b, p in zip(dec, prev))
            prev = blk
        pt = bytes(out)
    if pt:
        n = pt[-1]
        if 1 <= n <= 16 and len(pt) >= n and pt[-n:] == bytes([n]) * n:
            pt = pt[:-n]
    return pt


def _ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _nonce(n=16):
    return ''.join(random.choice(NONCE_ALPH) for _ in range(n))


def _sign_headers():
    ts = int(time.time() * 1000)
    nonce = _nonce()
    sign = hashlib.md5(('%d%s%s%s' % (ts, GUID, nonce, SALT)).encode()).hexdigest().upper()
    return {
        'User-Agent': UA,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Accept-Encoding': 'gzip, deflate',
        'Content-Type': 'application/x-www-form-urlencoded',
        'token': GUID,
        'sign': sign,
        'timestamp': str(ts),
        'nonce': nonce,
        'url': HOST,
    }


def _http_get(url, timeout=60):
    h = _sign_headers()
    for _ in range(3):
        if _HAS_REQ:
            try:
                r = requests.get(url, headers=h, timeout=timeout)
                if r.status_code == 200 and r.text.strip():
                    return r.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                data = resp.read()
                enc = (resp.headers.get('Content-Encoding') or '').lower()
                if enc == 'gzip' or data[:2] == b'\x1f\x8b':
                    try:
                        data = gzip.decompress(data)
                    except Exception:
                        pass
                txt = data.decode('utf-8', 'replace')
                if txt.strip():
                    return txt
        except urllib.error.HTTPError as e:
            try:
                return e.read().decode('utf-8', 'ignore')
            except http.client.IncompleteRead as ie:
                return ie.partial.decode('utf-8', 'ignore')
        except Exception:
            pass
        time.sleep(2)
    return ''


def _unwrap_return_data(raw):
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str) or not raw.strip():
        return {}
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass
    ct = None
    try:
        ct = base64.b64decode(raw)
    except Exception:
        ct = None
    if ct:
        try:
            pt = _aes_cbc_decrypt(ct, AES_KEY, AES_IV).decode('utf-8', 'replace')
            obj = json.loads(pt)
            if isinstance(obj, dict):
                return obj
        except Exception:
            pass
    return {}


def _api(path, params=None):
    qs = urllib.parse.urlencode(params or {})
    url = API + path.lstrip('/')
    if qs:
        url += '?' + qs
    txt = _http_get(url)
    if not txt:
        return {}
    try:
        obj = json.loads(txt)
    except Exception:
        return {}
    if not isinstance(obj, dict):
        return {}
    if obj.get('returnValue') != 1:
        return {}
    return _unwrap_return_data(obj.get('returnData'))


def _str(v):
    if v is None:
        return ''
    return str(v)


def _fix_url(u):
    if not u:
        return ''
    u = _html.unescape(u)
    if u.startswith('//'):
        return 'https:' + u
    return u


def _video_title(it):
    title = (it.get('videoTitle') or '').strip()
    if title:
        return title
    user = (it.get('userName') or '').strip()
    if user:
        return user
    return '视频' + _str(it.get('videoId'))


def _video_cards(lst):
    out = []
    for it in lst or []:
        if not isinstance(it, dict):
            continue
        vid = _str(it.get('videoId'))
        if not vid:
            continue
        out.append({
            'vod_id': 'v:' + vid,
            'vod_name': _video_title(it),
            'vod_pic': _fix_url(it.get('videoCover') or ''),
            'vod_remarks': _str(it.get('userName') or ''),
        })
    return out


def _game_cards(lst):
    out = []
    for it in lst or []:
        if not isinstance(it, dict):
            continue
        gid = _str(it.get('id'))
        if not gid:
            continue
        out.append({
            'vod_id': 'g:' + gid,
            'vod_name': 'Sex游戏 #' + gid,
            'vod_pic': _fix_url(it.get('cover') or ''),
            'vod_remarks': '',
        })
    return out


def _parse_json_text(raw):
    if isinstance(raw, list):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            obj = json.loads(raw)
            if isinstance(obj, list):
                return obj
        except Exception:
            pass
    return []


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


class Spider(BaseSpider):
    def getName(self):
        return '欲望乐园'

    def getDependence(self):
        return []

    def init(self, extend=''):
        pass

    def destroy(self):
        pass

    def _home(self, pg):
        body = _api('/sp/getHomeList', {'page': pg, 'size': HOME_SIZE})
        total = 0
        try:
            total = int(body.get('total') or 0)
        except Exception:
            total = 0
        return _video_cards(body.get('videoList')), total

    def _games(self, pg):
        body = _api('/mod/getGameList', {'page': pg, 'size': GAME_SIZE})
        total = 0
        try:
            total = int(body.get('total') or 0)
        except Exception:
            total = 0
        return _game_cards(body.get('gameList')), total

    def homeContent(self, filter=''):
        items, _ = self._home(1)
        return {
            'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS],
            'list': items,
        }

    def homeVideoContent(self):
        items, _ = self._home(1)
        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        pg = _norm_pg(pg)
        if tid == 'game':
            items, total = self._games(pg)
        else:
            items, total = self._home(pg)
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': total}

    def _video_detail(self, vid):
        body = _api('/sp/getVideoDetail', {'videoId': vid})
        info = body.get('videoDetail') if isinstance(body, dict) else None
        if not isinstance(info, dict):
            return None
        if not _str(info.get('videoId')):
            return None
        return info

    def _game_detail(self, gid):
        body = _api('/mod/getGameDetail', {'id': gid})
        info = body.get('gameDetail') if isinstance(body, dict) else None
        if not isinstance(info, dict):
            return None
        if not _str(info.get('id')):
            return None
        vbody = _api('/mod/getGameVideoDetail', {'id': gid})
        cmds = []
        det = vbody.get('gameVideosDetail') if isinstance(vbody, dict) else None
        if isinstance(det, dict):
            cmds = _parse_json_text(det.get('modVideo'))
        return info, cmds

    def detailContent(self, ids):
        nid = _norm_id(ids)
        if not nid:
            return {'list': []}
        if nid.startswith('g:'):
            got = self._game_detail(nid[2:])
            if not got:
                return {'list': []}
            info, cmds = got
            title = _str(info.get('modName')) or ('Sex游戏 #' + nid[2:])
            free = []
            vip_count = 0
            for c in cmds:
                if not isinstance(c, dict):
                    continue
                name = _str(c.get('name') or c.get('key'))
                key = _str(c.get('key'))
                video = c.get('video') if isinstance(c.get('video'), dict) else {}
                url = _fix_url(video.get('phone') or video.get('pc') or '')
                if not name or not key or not url:
                    continue
                if c.get('isVip'):
                    vip_count += 1
                    continue
                free.append('%s$guohnsqj:g:%s:%s' % (name, nid[2:], key))
            stills = []
            for im in _parse_json_text(info.get('modJeiTu')):
                if isinstance(im, dict):
                    u = _fix_url(im.get('imageUrl') or '')
                    if u:
                        stills.append(u)
            parts = ['Sex游戏']
            parts.append('免费指令 %d 个' % len(free))
            if vip_count:
                parts.append('VIP指令 %d 个需会员' % vip_count)
            return {'list': [{
                'vod_id': nid,
                'vod_name': title,
                'vod_pic': _fix_url(info.get('modCover') or ''),
                'vod_actor': '',
                'vod_director': '',
                'vod_remarks': '免费 %d / 共 %d' % (len(free), len(free) + vip_count),
                'vod_year': '',
                'vod_area': '',
                'vod_content': '\n'.join(parts),
                'type_name': 'Sex游戏',
                'vod_tag': 'Sex游戏',
                'vod_play_from': '在线播放',
                'vod_play_url': '#'.join(free),
                'stills': stills[:8],
            }]}
        if nid.startswith('v:'):
            vid = nid[2:]
        else:
            vid = nid
        info = self._video_detail(vid)
        if not info:
            return {'list': []}
        title = _video_title(info)
        user = _str(info.get('userName') or '')
        lines = []
        eps = []
        url_one = _fix_url(info.get('videoUrlOne') or '')
        url_two = _fix_url(info.get('videoUrlTwo') or '')
        if url_one:
            lines.append('线路一')
            eps.append('播放$guohnsqj:v:%s:1' % vid)
        if url_two:
            lines.append('线路二')
            eps.append('播放$guohnsqj:v:%s:2' % vid)
        parts = []
        if user:
            parts.append('博主：' + user)
        des = _str(info.get('videoDes') or '')
        if des:
            parts.append(des)
        return {'list': [{
            'vod_id': 'v:' + vid,
            'vod_name': title,
            'vod_pic': _fix_url(info.get('videoCover') or ''),
            'vod_actor': user,
            'vod_director': '',
            'vod_remarks': user,
            'vod_year': '',
            'vod_area': '',
            'vod_content': '\n'.join(parts),
            'type_name': '全部视频',
            'vod_tag': '',
            'vod_play_from': '#'.join(lines),
            'vod_play_url': '$$$'.join(eps),
            'stills': [],
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        body = _api('/sp/getSearchList', {'searchName': key or '', 'searchType': 'all', 'page': pg, 'size': SEARCH_SIZE})
        total = 0
        try:
            total = int(body.get('total') or 0)
        except Exception:
            total = 0
        return {'list': _video_cards(body.get('videoList')), 'page': pg, 'pagecount': 0, 'total': total}

    def playerContent(self, flag, id, vipFlags=None):
        raw = _norm_id(id)
        if raw.startswith('guohnsqj:'):
            raw = raw[len('guohnsqj:'):]
        header = {'User-Agent': UA, 'Referer': 'https://' + HOST + '/'}
        stream = ''
        if raw.startswith('http'):
            stream = raw
        elif raw.startswith('g:'):
            parts = raw[2:].split(':', 1)
            if len(parts) == 2:
                got = self._game_detail(parts[0])
                if got:
                    _, cmds = got
                    for c in cmds:
                        if not isinstance(c, dict):
                            continue
                        if _str(c.get('key')) != parts[1]:
                            continue
                        if c.get('isVip'):
                            stream = ''
                            break
                        video = c.get('video') if isinstance(c.get('video'), dict) else {}
                        stream = _fix_url(video.get('phone') or video.get('pc') or '')
                        break
        elif raw.startswith('v:'):
            parts = raw[2:].split(':')
            vid = parts[0]
            line = parts[1] if len(parts) > 1 else '1'
            info = self._video_detail(vid)
            if info:
                if line == '2':
                    stream = _fix_url(info.get('videoUrlTwo') or '')
                else:
                    stream = _fix_url(info.get('videoUrlOne') or '')
        return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': header}

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        url = (url or '').lower()
        return url.endswith('.m3u8') or url.endswith('.mp4') or '.m3u8?' in url or '.mp4?' in url

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
