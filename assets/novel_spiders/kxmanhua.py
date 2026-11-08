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

BASE = 'https://kxmanhua.com'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

CATEGORIES = [
    ('0', '全部漫画'),
    ('1', '3D漫画'),
    ('2', '韩漫'),
    ('3', '日漫'),
    ('4', '真人漫画'),
    ('5', '耽美BL漫画'),
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
    covers = {}
    for cover, wid in re.findall(
            r'data-setbg="([^"]+)"[^>]*onclick="location\.href=\'/manga/(\d+)\'',
            page):
        covers[wid] = cover
    for wid, title in re.findall(r'<a href="/manga/(\d+)"[^>]*>([^<]*)</a>', page):
        if wid in seen:
            continue
        seen.add(wid)
        name = _clean_text(title)
        if not name:
            continue
        items.append({'vod_id': wid, 'vod_name': name, 'vod_pic': covers.get(wid, ''), 'vod_remarks': ''})
    return items


class Spider(BaseSpider):

    def getName(self):
        return '🔞kxmanhua'

    def getDependence(self):
        return []

    def init(self, extend=None):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=False):
        return {'class': [{'type_id': tid, 'type_name': name} for tid, name in CATEGORIES], 'filters': {}}

    def homeVideoContent(self):
        return {'list': _parse_list(_fetch(BASE + '/manga/library?type=0&complete=1&page=1&orderby=1')), 'page': 1, 'pagecount': 0, 'total': 0}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        tid = _norm_id(tid)
        pg = _norm_pg(pg)
        url = BASE + '/manga/library?type=%s&complete=1&page=%d&orderby=1' % (tid, pg)
        items = _parse_list(_fetch(url))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def detailContent(self, ids):
        wid = _norm_id(ids)
        m = re.search(r'(\d+)', wid)
        if m:
            wid = m.group(1)
        page = _fetch(BASE + '/manga/%s' % wid)
        if not page:
            return {'list': []}
        m_title = re.search(r'<title>(.*?)</title>', page, flags=re.S)
        name = _clean_text(m_title.group(1)) if m_title else wid
        name = name.split('-免费看')[0].strip()
        cover = ''
        m_cover = re.search(r'anime__details__pic set-bg" data-setbg="([^"]+)"', page)
        if m_cover:
            cover = m_cover.group(1)
        if not cover:
            m_cover = re.search(r'data-setbg="([^"]+)"', page)
            if m_cover:
                cover = m_cover.group(1)
        numbered = []
        others = []
        seen = set()
        for cid, label in re.findall(
                r'<a[^>]*href="/manga/%s/detail/(\d+)"[^>]*>(.*?)</a>' % wid, page, flags=re.S):
            lab = _clean_text(label)
            if not lab or lab == '开始阅读' or '公告' in lab or '停刊' in lab or '休刊' in lab:
                continue
            if cid in seen:
                continue
            seen.add(cid)
            mm = re.search(r'第(\d+)话', lab)
            if mm:
                numbered.append((int(mm.group(1)), lab, cid))
            else:
                others.append((lab, cid))
        numbered.sort(key=lambda x: x[0])
        eps = ['%s$kxmanhua:%s:%s' % (lab, wid, cid) for _, lab, cid in numbered]
        eps += ['%s$kxmanhua:%s:%s' % (lab, wid, cid) for lab, cid in others]
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
            'vod_play_url': '#'.join(eps),
        }]}

    def searchContent(self, key, quick=False, pg=1):
        pg = _norm_pg(pg)
        if pg > 1:
            return {'list': [], 'page': pg, 'pagecount': 0, 'total': 0}
        q = urllib.parse.quote(str(key))
        url = BASE + '/manga/search?keyword=%s' % q
        items = _parse_list(_fetch(url))
        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or '')
        url = raw
        if '$' in raw:
            url = raw.split('$', 1)[1]
        if url.startswith('pics://'):
            return {'parse': 0, 'playUrl': url, 'url': url, 'header': {'Referer': BASE + '/'}, 'vod_player': '画'}
        parts = url.split(':')
        if len(parts) >= 3 and parts[0] == 'kxmanhua' and parts[2].isdigit():
            wid = parts[1]
            cid = parts[2]
            page = _fetch(BASE + '/manga/%s/detail/%s' % (wid, cid))
            imgs = []
            seen = set()
            for img in re.findall(r'<img[^>]*src="(https://img\.imh99\.top/webtoon/content/[^"]+)"', page):
                if img not in seen:
                    seen.add(img)
                    imgs.append(img)
            out = 'pics://' + '&&'.join(imgs)
            if not imgs:
                return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}
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
