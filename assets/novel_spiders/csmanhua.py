import html as _html
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

BASE = 'https://csmanhua.cc'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    ('5', '成人AI短剧'),
    ('8', '单行本'),
    ('21', '单行本-汉化'),
    ('22', '单行本-日语'),
    ('23', '单行本-外语'),
    ('7', '同人志'),
    ('13', '同人志-汉化'),
    ('14', '同人志-日语'),
    ('15', '同人志-外语'),
    ('16', 'CG画集'),
    ('17', '3D漫画'),
    ('18', 'AI图集'),
    ('24', 'Cosplay'),
    ('6', '杂志&短篇'),
    ('10', '杂志&短篇-汉化'),
    ('11', '杂志&短篇-日语'),
    ('12', '杂志&短篇-外语'),
    ('9', '韩漫'),
    ('19', '韩漫-汉化'),
    ('20', '韩漫-其他'),
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
    for wid, cover, title in re.findall(
            r'<a href="/cs-(\d+)/"[^>]*>.*?<img[^>]*data-src="([^"]+)"[^>]*alt="([^"]*)"',
            page, flags=re.S):
        if wid in seen:
            continue
        seen.add(wid)
        name = _clean_text(title)
        if not name:
            continue
        items.append({'vod_id': wid, 'vod_name': name, 'vod_pic': cover, 'vod_remarks': ''})
    return items


def _detail_images(wid):
    page = _fetch(BASE + '/cs-%s/' % wid)
    if not page:
        return '', []
    m_title = re.search(r'<title>(.*?)</title>', page, flags=re.S)
    name = _clean_text(m_title.group(1)) if m_title else wid
    name = name.split(' - 成色漫画')[0].strip()
    imgs = []
    seen = set()
    for img in re.findall(r'<img[^>]*class="runtime-image"[^>]*src="([^"]+)"', page):
        if img not in seen:
            seen.add(img)
            imgs.append(img)
    return name, imgs


class Spider(BaseSpider):

    def getName(self):
        return '🔞csmanhua'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': tid, 'type_name': name} for tid, name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        return {'list': _parse_list(_fetch(BASE + '/cstype/8/')), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        path = '/cstype/%s/' % tid
        if pg > 1:
            path = '/cstype/%s-%d/' % (tid, pg)
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        wid = _norm_id(ids)
        m = re.search(r'(\d+)', wid)
        if m:
            wid = m.group(1)
        page = _fetch(BASE + '/cs-%s/' % wid)
        if not page:
            return {'list': []}
        m_title = re.search(r'<title>(.*?)</title>', page, flags=re.S)
        name = _clean_text(m_title.group(1)) if m_title else wid
        name = name.split(' - 成色漫画')[0].strip()
        videos = re.findall(r'<video[^>]*data-hls-src="([^"]+)"[^>]*data-fallback-src="([^"]*)"[^>]*>', page)
        if not videos:
            videos = re.findall(r'<video[^>]*data-fallback-src="([^"]+)"[^>]*data-hls-src="([^"]*)"[^>]*>', page)
            videos = [(hls, mp4) for mp4, hls in videos]
        posters = re.findall(r'<video[^>]*poster="([^"]+)"', page)
        if videos:
            eps = []
            for i, (hls, mp4) in enumerate(videos):
                media = hls if hls else mp4
                if media:
                    eps.append('第%d集$csmanhua:video:%s' % (i + 1, media))
            return {'list': [{
                'vod_id': wid,
                'vod_name': name,
                'vod_pic': posters[0] if posters else '',
                'vod_actor': '',
                'vod_remarks': '',
                'vod_content': '',
                'vod_tag': '视频',
                'vod_player': '',
                'vod_play_from': '视频',
                'vod_play_url': '#'.join(eps),
            }]}
        name2, imgs = _detail_images(wid)
        if not name:
            name = name2
        cover = imgs[0] if imgs else ''
        return {'list': [{
            'vod_id': wid,
            'vod_name': name,
            'vod_pic': cover,
            'vod_actor': '',
            'vod_remarks': '',
            'vod_content': '',
            'vod_tag': 'image',
            'vod_player': '画',
            'vod_play_from': '漫画',
            'vod_play_url': '全集$csmanhua:%s' % wid,
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        q = urllib.parse.quote(str(key))
        if pg > 1:
            path = '/cssearch/%s------%d-/' % (q, pg)
        else:
            path = '/cssearch/-------/?wd=%s' % q
        items = _parse_list(_fetch(BASE + path))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        url = raw
        if '$' in raw:
            url = raw.split('$', 1)[1]
        if url.startswith('pics://'):
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'Referer': BASE + '/'}, 'vod_player': '画'}
        if url.startswith('csmanhua:video:'):
            media = url.split(':', 2)[2]
            return {'parse': 0, 'playUrl': media, 'url': media, 'header': {'Referer': BASE + '/'}}
        if url.startswith('csmanhua:'):
            wid = url.split(':', 1)[1]
            if not wid.isdigit():
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
            _, imgs = _detail_images(wid)
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
