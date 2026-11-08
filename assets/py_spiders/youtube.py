# -*- coding: utf-8 -*-
import hashlib
import json
import re
import time
import urllib.request
import urllib.error

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        def __init__(self):
            pass


API = 'https://www.youtube.com/youtubei/v1/'
KEY_WEB = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8'
KEY_AND = 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w'
UA_WEB = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
UA_VIS = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
          '(KHTML, like Gecko) Version/18.0 Safari/605.1.15')
UA_VR = ('com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; '
         'eureka-user Build/SQ3A.220605.009.A1) gzip')
UA_AND = ('com.google.android.youtube/20.10.80 (Linux; U; Android 13; Pixel 7) gzip')
UA_IOS = ('com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)')

CLIENT_WEB = {'clientName': 'WEB', 'clientVersion': '2.20241127.01.00', 'userAgent': UA_WEB}
CLIENT_VIS = {'clientName': 'VISIONOS', 'clientVersion': '1.02', 'deviceMake': 'Apple',
              'deviceModel': 'Apple Vision Pro', 'userAgent': UA_VIS,
              'osName': 'visionOS', 'osVersion': '2.0'}
CLIENT_VR = {'clientName': 'ANDROID_VR', 'clientVersion': '1.65.10', 'deviceMake': 'Oculus',
             'deviceModel': 'Quest 3', 'androidSdkVersion': 32, 'userAgent': UA_VR,
             'osName': 'Android', 'osVersion': '12L'}
CLIENT_AND = {'clientName': 'ANDROID', 'clientVersion': '20.10.80', 'androidSdkVersion': 30,
              'userAgent': UA_AND, 'osName': 'Android', 'osVersion': '13'}
CLIENT_IOS = {'clientName': 'IOS', 'clientVersion': '21.26.4', 'deviceMake': 'Apple',
              'deviceModel': 'iPhone16,2', 'userAgent': UA_IOS,
              'osName': 'iPhone', 'osVersion': '18_3_2'}
CLIENT_NUM = {'WEB': 1, 'VISIONOS': 101, 'ANDROID_VR': 28, 'ANDROID': 3, 'IOS': 5}
CLIENT_KEY = {'WEB': KEY_WEB, 'VISIONOS': KEY_WEB, 'ANDROID_VR': KEY_AND, 'ANDROID': KEY_AND, 'IOS': KEY_WEB}
CLIENT_OBJ = {'WEB': CLIENT_WEB, 'VISIONOS': CLIENT_VIS, 'ANDROID_VR': CLIENT_VR, 'ANDROID': CLIENT_AND, 'IOS': CLIENT_IOS}
CLIENT_UA = {'WEB': UA_WEB, 'VISIONOS': UA_VIS, 'ANDROID_VR': UA_VR, 'ANDROID': UA_AND, 'IOS': UA_IOS}

SHORTS_SP = 'EgIYAQ%3D%3D'

CLASSES = [
    {'type_id': 'preset:动漫', 'type_name': '动漫'},
    {'type_id': 'preset:短剧', 'type_name': '短剧'},
    {'type_id': 'preset:电视剧', 'type_name': '电视剧'},
    {'type_id': 'preset:电影', 'type_name': '电影'},
    {'type_id': 'preset:战争片', 'type_name': '战争片'},
    {'type_id': 'preset:沙雕动漫', 'type_name': '沙雕动漫'},
    {'type_id': 'preset:新闻', 'type_name': '新闻'},
    {'type_id': 'home', 'type_name': '首页'},
    {'type_id': 'shorts', 'type_name': 'Shorts'},
    {'type_id': 'channel:UC-9-kyTW8ZkZNDHQJ6FgpwQ', 'type_name': '音乐'},
    {'type_id': 'channel:UC4R8DWoMoI7CAwX8_LjQHig', 'type_name': '直播'},
    {'type_id': 'preset:学习', 'type_name': '学习'},
    {'type_id': 'preset:纪录片', 'type_name': '纪录片'},
    {'type_id': 'preset:综艺', 'type_name': '综艺'},
    {'type_id': 'preset:体育', 'type_name': '体育'},
    {'type_id': 'preset:科技', 'type_name': '科技'},
    {'type_id': 'preset:时尚', 'type_name': '时尚'},
    {'type_id': 'preset:科普', 'type_name': '科普'},
    {'type_id': 'preset:新闻直播', 'type_name': '新闻直播'},
    {'type_id': 'preset:4K', 'type_name': '4K'},
    {'type_id': 'live', 'type_name': '直播台'},
]

LIVE_LIST = [
    ("三立iNEWS", "pF507BLtbqU"),
    ("寰宇新聞台", "Y8eZYHy8BDc"),
    ("東森財經新聞", "1I2iq41Akmo"),
    ("momo購物一台", "xbNWkUyxQGM"),
    ("運通財經台", "Bawiw2XtjZ0"),
    ("信大電視台", "UJeImkJpaLM"),
    ("DW News", "LuKwFajn37U"),
    ("中視新聞", "TCnaIE_SAtM"),
    ("Malaimurasu Tv 24X7", "QWU7yVtUiX8"),
    ("Asianet News", "x1bfKawndzs"),
    ("華視戲劇頻道", "qH2dIrK1ILw"),
    ("中天亞洲台", "0Kdwr_zYLMY"),
    ("Al Jazeera Arabic", "N8xxOD0nT1Y"),
    ("JapaNews24", "prIN240QQyA"),
    ("民視新聞", "ylYJSBUgaMA"),
    ("東森購物台CH60", "47AwcDrtf3M"),
    ("東森購物台CH46", "utfhE3fvTOg"),
    ("LIVE NOW", "vNVp6bxkL1c"),
    ("Haberturk TV", "s4KIyYkwiM0"),
    ("鳳凰衛視資訊台", "Ry--eMIjYLQ"),
    ("新唐人LIVE", "Bhp_V7H5QoY"),
    ("ABC News", "Ykd1rMAf6XI"),
    ("台視新聞台", "Os3t0rgvkD8"),
    ("華視綜藝頻道", "0ePhPlTJbGo"),
    ("Astro AWANI", "G9ndx4uuX0Q"),
    ("中天電視", "vr3XyVCR4T0"),
    ("Tokyo Walk", "r684Q3JIoyg"),
    ("大愛一臺HD", "pM-1ytfQhos"),
    ("TVBS NEWS 24小時直播", "m_dhMSvUCIc"),
    ("三立新聞台", "yeYC0mbSIOo"),
    ("GB News", "am5YmBbWhkU"),
    ("中視經典綜藝", "ADDSmXoPDY8"),
    ("Sky News", "umLWFz4izTM"),
    ("India Today", "EATzYAm8pmA"),
    ("Euronews English", "pykpO5kQJ98"),
    ("FRANCE 24 English", "HvZt-nh9sGg"),
    ("NBC News", "8XMyQlUX8Ks"),
    ("News18 India", "tFMDyJyfwp0"),
    ("MIT台灣誌", "HKgwBLXa1Fw"),
    ("公視 網路直播頻道", "C6gYqSHLRw4"),
    ("MediaoneTV Live", "dkZStjndbRI"),
    ("TBS NEWS", "2vcpaaZzhu4"),
    ("NewsTamil24x7", "3aKRJvSdndE"),
    ("東森購物台CH47", "vZHktiRowRg"),
    ("中天2台", "bGGupuZURw8"),
    ("Malayalam News", "1wECsnGZcfc"),
    ("Arirang TV", "hvVlyZ5GiE8"),
    ("CNA LIVE", "-PWMxjBgr0k"),
    ("HTB北海道ニュース", "tvgbZZYS4Nk"),
    ("美好購物1台", "rc8px6ti8fc"),
    ("國會頻道１", "bR5UF8qNktI"),
    ("123 GO! Live", "14--w5KCSJ8"),
    ("Al Jazeera English", "gCNeDWCI0vo"),
    ("Muse木棉花-闔家歡", "Lh6xiMlkRrg"),
    ("KBS News", "sa8wOevBC58"),
    ("ABCテレビニュース", "LJtlWB1LXjU"),
    ("YOYO TV", "zIwNP6n9-X0"),
    ("Talking Tom", "cIgdDR3mAwQ"),
    ("TalkingFriendsTVMini", "Cyvom43CXbM"),
    ("Dave and Ava", "S2m_aD2pyCs"),
    ("Tayo the Little Bus", "u5VJVZzTmkU"),
    ("Disney Junio", "GpGd8QP3UFQ"),
    ("鏡新聞", "JVXNKkMPntA"),
    ("大陸尋奇", "ta7uI13rb_E"),
    ("CRUX", "be5NrSGM7SM"),
    ("豬哥會社", "v8MUGB4vst8"),
    ("TIMES NOW", "EOwAA1FOmIE"),
    ("GTV DRAMA 八大劇樂部", "grbBHMktntk"),
    ("民視戲劇館", "eP5gJqD8vB8"),
    ("Lofi Girl", "0sfDth4lMLc"),
    ("TaiwanPlus", "tdA4T2LEMg4"),
    ("earthTV", "5p_KGD4fJZs"),
    ("SBS Running Man", "d8OvbUAxaec"),
    ("飢餓遊戲", "6TsaEYaKueE"),
    ("TVBS NEWS", "k-jTRsBBRp0"),
    ("Entertainment - Mediacorp", "tyyYtckP6tM"),
    ("寰宇新聞財經台", "yAUQQ0DhPxI"),
    ("LiveNOW from FOX", "d-s6VAEAkls"),
    ("東森購物台CH34", "J3t9N0vciPI"),
    ("InquizeX", "mTEqaZj2aho"),
    ("8world", "qZsyZ03n340"),
    ("倪珍24小時播新聞", "NgqAue7oOtw"),
    ("TV5 News", "NdmSb1MnSR0"),
    ("公視新聞網", "hg4nYb3jE9A"),
    ("華視新聞", "wM0g8EoUZ_E"),
    ("華視公眾安全資訊觀測站", "KMMHw8rllic"),
    ("東森新聞 51 頻道 24 小時直播", "V1p33hqPrUk"),
    ("東森綜合2台頻道 24 小時直播", "cimbpAZUjzw"),
    ("佛光山人間衛視", "xuwehmY60eo"),
    ("Best of MLB", "sSAk4hyqnUQ"),
    ("NHK", "IimtbuqYIE8"),
]

LOGIN_CLASSES = [
    {'type_id': 'browse:FEsubscriptions', 'type_name': '订阅'},
    {'type_id': 'browse:FEhistory', 'type_name': '历史'},
    {'type_id': 'browse:FElibrary', 'type_name': '媒体库'},
]

REGION_FILTER = {'key': '地区', 'name': '地区', 'value': [
    {'n': '全部', 'v': ''}, {'n': '美国', 'v': 'US'}, {'n': '香港', 'v': 'HK'},
    {'n': '台湾', 'v': 'TW'}, {'n': '日本', 'v': 'JP'}, {'n': '韩国', 'v': 'KR'},
    {'n': '英国', 'v': 'GB'}]}
TIME_FILTER = {'key': '时间', 'name': '时间', 'value': [
    {'n': '全部', 'v': ''}, {'n': '今天', 'v': 'today'}, {'n': '本周', 'v': 'week'},
    {'n': '本月', 'v': 'month'}, {'n': '今年', 'v': 'year'}]}
YEAR_FILTER = {'key': '年份', 'name': '年份', 'value': [
    {'n': '全部', 'v': ''}, {'n': '2026', 'v': '2026'}, {'n': '2025', 'v': '2025'},
    {'n': '2024', 'v': '2024'}, {'n': '2023', 'v': '2023'}, {'n': '2022', 'v': '2022'},
    {'n': '2021', 'v': '2021'}, {'n': '2020', 'v': '2020'},
    {'n': '2019', 'v': '2019'}, {'n': '2018', 'v': '2018'}, {'n': '2017', 'v': '2017'},
    {'n': '2016', 'v': '2016'}, {'n': '2015', 'v': '2015'}]}
TAG_MAP = {
    'preset:动漫': ['一口气看完', '国漫', '日本', '修仙', '穿越', '热血', '搞笑', '恋爱', '科幻', '儿童', '小猪佩奇', 'CoComelon', '国漫社'],
    'preset:短剧': ['总裁', '穿越', '重生', '古装', '现代', '甜宠', '复仇', '抖音', '快手', '大陆', '香港', '台湾'],
    'preset:电视剧': ['古装', '现代', '谍战', '悬疑', '爱情', '家庭', '历史', '都市'],
    'preset:电影': ['大陆', '国产', '动作', '喜剧', '爱情', '科幻', '悬疑', '战争', '动画', '剧情'],
    'preset:战争片': ['大陆', '国产', '抗日', '抗美援朝', '二战', '现代战争', '谍战', '历史', '经典'],
    'preset:沙雕动漫': ['穿越', '修仙', '重生', '系统', '搞笑', '玄幻', '都市', '古代'],
    'preset:新闻': ['国内', '国际', '社会', '财经', '科技', '娱乐', '军事', 'CCTV', '凤凰卫视', 'TVB', '东森', '三立'],
    'preset:纪录片': ['自然', '历史', '科学', '人文', '动物', '宇宙', '美食', '旅行'],
    'preset:综艺': ['真人秀', '脱口秀', '选秀', '音乐', '搞笑', '访谈', '亲子'],
    'preset:体育': ['足球', '篮球', '网球', '赛车', '健身', '拳击', '奥运', '电竞'],
    'preset:科技': ['数码', 'AI', '手机', '电脑', '科学', '发明', '评测', '教程'],
    'preset:时尚': ['穿搭', '美妆', '潮流', '模特', '设计', '奢侈品', '街拍'],
    'preset:科普': ['宇宙', '物理', '生物', '化学', '天文', '地理', '医学', '心理'],
    'preset:新闻直播': ['CCTV', 'CNN', 'BBC', '凤凰卫视', 'TVB', '东森', '三立', 'Live'],
    'preset:4K': ['4K', 'HDR', '风景', '城市', '自然', '延时', '航拍', '8K'],
    'preset:学习': ['英语', '数学', '编程', '历史', '科学', '考试', '职场'],
    'shorts': ['搞笑', '音乐', '舞蹈', '美食', '宠物', '游戏', '运动', '旅行'],
}


SERIES = ['遮天', '凡人修仙传', '斗破苍穹', '斗罗大陆', '完美世界', '吞噬星空', '一人之下', '秦时明月', '画江湖之不良人', '灵笼', '伍六七', '诛仙', '剑来', '海贼王', '火影忍者', '鬼灭之刃']
SERIES_FILTER = {'key': '二级分类', 'name': '二级分类', 'value': [{'n': '全部', 'v': ''}] + [{'n': s, 'v': s} for s in SERIES]}


def _build_filters():
    out = {}
    for c in CLASSES + LOGIN_CLASSES:
        tid = c['type_id']
        lst = [REGION_FILTER]
        if tid == 'preset:动漫':
            lst = lst + [SERIES_FILTER]
        if tid in TAG_MAP:
            lst = lst + [TIME_FILTER, YEAR_FILTER, {'key': '标签', 'name': '标签', 'value':
                                       [{'n': '全部', 'v': ''}] + [{'n': t, 'v': t} for t in TAG_MAP[tid]]}]
        out[tid] = lst
    return out


FILTERS = _build_filters()

VID_RE = re.compile(r'^[\w-]{11}$')
DUR_RE = re.compile(r'^\d{1,2}:\d{2}(:\d{2})?$')
VIDEO_KINDS = ('videoRenderer', 'gridVideoRenderer', 'compactVideoRenderer',
               'videoCardRenderer', 'reelItemRenderer', 'tileRenderer',
               'gridMovieRenderer', 'lockupViewModel')
SHORTS_KINDS = ('shortsLockupViewModel', 'reelItemRenderer')


def _txt(node):
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return ''
    if node.get('simpleText'):
        return node['simpleText']
    if node.get('content'):
        return node['content']
    runs = node.get('runs')
    if isinstance(runs, list):
        return ''.join(r.get('text', '') for r in runs if isinstance(r, dict))
    return ''


def _walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            for x in _walk(v):
                yield x
    elif isinstance(node, list):
        for i in node:
            for x in _walk(i):
                yield x



_PREFIXES = [
    '最新爽文修仙动漫来袭', '全新爽文动漫来袭', '最新爽文动漫来袭',
    '超好看的爽文动漫来咯', '熬夜必看的暴爽动漫', '新动漫来袭',
    '全新动漫来袭', '最新动漫', '新武侠动漫', '新番上线',
    '最新漫剧', '漫剧合集', 'MULTISUB', 'FULL',
]
_MARKETING_BRACKET = ('最新', '全新', '新番', '爆款', '精选', '最火', '热门', '推荐', 'FULL', 'MULTISUB')


def _strip_prefix(title):
    for _ in range(6):
        old = title
        title = title.strip()
        title = title.lstrip('🔥💥📢🚩▶📣⚔️🎬✨❤️💖 ')
        if title.startswith('【'):
            end = title.find('】')
            if end > 0:
                inner = title[1:end]
                if any(k in inner for k in _MARKETING_BRACKET) or inner.isascii():
                    title = title[end + 1:].strip()
                    continue
        if title.startswith('['):
            end = title.find(']')
            if end > 0:
                inner = title[1:end]
                if any(k in inner for k in _MARKETING_BRACKET) or inner.isascii():
                    title = title[end + 1:].strip()
                    continue
        matched = False
        for ph in _PREFIXES:
            if title.startswith(ph):
                title = title[len(ph):].strip()
                matched = True
                break
        if not matched:
            m = re.match(r'^(.{1,12}?(?:来袭|來襲))', title)
            if m and len(title) > len(m.group(1)) + 10:
                title = title[len(m.group(1)):].strip()
                matched = True
        title = title.lstrip('！!：:、,，.。 ')
        if title == old and not matched:
            break
    return title


def _clean_title(title):
    if not title:
        return title
    title = title.strip()
    if '《' in title:
        rest = title[title.find('《'):]
        rest = rest.split('#')[0].strip()
        for sep in (' | ', '｜'):
            if sep in rest:
                head = rest.split(sep, 1)[0].strip()
                if '》' in head:
                    rest = head
                    break
        return rest if len(rest) >= 4 else title
    title = _strip_prefix(title)
    if '#' in title:
        head = title.split('#')[0].strip()
        if head:
            title = head
    return title if len(title) >= 4 else title

class Spider(BaseSpider):
    def __init__(self):
        super().__init__()
        self._state_ready = False

    def _lazy(self):
        if not self._state_ready:
            self.hl = 'zh-CN'
            self.gl = 'US'
            self.cookie = ''
            self.custom = []
            self._visitor = ''
            self._visitor_at = 0
            self._streams = {}   # stream_key -> {'tokens': {page: token|None}, 'mode': {...}}
            self._state_ready = True

    def init(self, extend=''):
        self._lazy()
        try:
            ext = json.loads(extend) if isinstance(extend, str) and extend else (extend or {})
        except Exception:
            ext = {}
        if isinstance(ext, dict):
            if ext.get('hl'):
                self.hl = str(ext['hl'])
            if ext.get('gl'):
                self.gl = str(ext['gl'])
            ck = ext.get('cookie') or ext.get('cookies') or ''
            if isinstance(ck, dict):
                ck = '; '.join('%s=%s' % (k, v) for k, v in ck.items())
            if isinstance(ck, str) and ck.strip():
                ck = ck.strip().replace('\n', ' ').replace('\r', ' ')
                if ck.lower().startswith('cookie:'):
                    ck = ck[7:].strip()
                self.cookie = ck
            self.custom = []
            cu = ext.get('custom') or ext.get('custom_categories') or ''
            if isinstance(cu, str) and cu.strip():
                try:
                    cu = json.loads(cu)
                except Exception:
                    cu = []
            if isinstance(cu, list):
                for _o in cu:
                    if isinstance(_o, dict):
                        _n = _o.get('name') or _o.get('n') or _o.get('type_name') or ''
                        _q = _o.get('query') or _o.get('v') or _o.get('q') or _o.get('keyword') or ''
                        if _n and _q:
                            self.custom.append({'type_id': 'custom:' + str(_q), 'type_name': str(_n)})
        return ''

    def _auth_headers(self):
        headers = {}
        if getattr(self, 'cookie', ''):
            headers['Cookie'] = self.cookie
            m = re.search(r'(?:^|;\s*)SAPISID=([^;\s]+)', self.cookie)
            if m:
                ts = str(int(time.time()))
                digest = hashlib.sha1(('%s %s https://www.youtube.com' % (ts, m.group(1))).encode()).hexdigest()
                headers['Authorization'] = 'SAPISIDHASH %s_%s' % (ts, digest)
                headers['Origin'] = 'https://www.youtube.com'
                headers['X-Goog-AuthUser'] = '0'
        return headers

    def getName(self):
        return 'YouTube'

    def destroy(self):
        return ''

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def _visitor_data(self):
        if getattr(self, '_visitor', ''):
            return self._visitor
        now = time.time()
        if now - getattr(self, '_visitor_at', 0) < 300:
            return ''
        self._visitor_at = now
        try:
            req = urllib.request.Request('https://www.youtube.com/', headers={'User-Agent': UA_WEB})
            with urllib.request.urlopen(req, timeout=15) as r:
                html = r.read().decode('utf-8', 'ignore')
            m = re.search(r'"visitorData"\s*:\s*"([^"]+)"', html)
            if m:
                self._visitor = m.group(1)
        except Exception:
            pass
        return getattr(self, '_visitor', '')

    def _innertube(self, path, client_name, extra=None, tries=2, auth='auto', gl=None):
        self._lazy()
        client = dict(CLIENT_OBJ[client_name])
        vd = self._visitor_data()
        if vd:
            client['visitorData'] = vd
        client['hl'] = self.hl
        client['gl'] = gl or self.gl
        body = {'context': {'client': client}}
        if extra:
            body.update(extra)
        data = json.dumps(body).encode('utf-8')
        url = '%s%s?key=%s&prettyPrint=false' % (API, path, CLIENT_KEY[client_name])
        last = None
        for _ in range(tries):
            hdrs = {
                'Content-Type': 'application/json',
                'User-Agent': client.get('userAgent', UA_WEB),
                'X-YouTube-Client-Name': str(CLIENT_NUM[client_name]),
                'X-YouTube-Client-Version': client.get('clientVersion', ''),
            }
            if auth is True or (auth == 'auto' and client_name == 'WEB'):
                hdrs.update(self._auth_headers())
            req = urllib.request.Request(url, data=data, headers=hdrs)
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    return json.loads(r.read().decode('utf-8', 'ignore'))
            except Exception as e:
                last = e
                time.sleep(0.6)
        if last:
            raise last
        return {}

    def _player(self, vid, client_name, auth='auto'):
        return self._innertube('player', client_name, {
            'videoId': vid,
            'playbackContext': {'contentPlaybackContext': {'signatureTimestamp': 20073}},
        }, auth=auth)

    def _usable_play(self, r, client_name):
        sd = (r or {}).get('streamingData') or {}
        hls = sd.get('hlsManifestUrl') or ''
        if hls:
            return hls, {'User-Agent': CLIENT_UA[client_name]}
        fmts = [f for f in (sd.get('formats') or []) if f.get('url')]
        fmts.sort(key=lambda f: (0 if f.get('itag') == 22 else 1 if f.get('itag') == 18 else 2))
        if fmts:
            return fmts[0]['url'], {'User-Agent': CLIENT_UA[client_name]}
        dash = sd.get('dashManifestUrl') or ''
        if dash:
            return dash, {'User-Agent': CLIENT_UA[client_name]}
        return None

    def _thumb(self, sources):
        best, bw = '', -1
        for t in sources or []:
            if isinstance(t, dict) and t.get('url'):
                w = t.get('width', 0) or 0
                if w >= bw:
                    best, bw = t['url'], w
        return best

    def _subtree_vid(self, sub):
        for n in _walk(sub):
            we = n.get('watchEndpoint')
            if isinstance(we, dict) and VID_RE.match(str(we.get('videoId', ''))):
                return we['videoId']
            ct = n.get('continuationCommand')
            if isinstance(ct, dict):
                pass
            for k in ('videoId', 'contentId'):
                v = n.get(k)
                if isinstance(v, str) and VID_RE.match(v):
                    return v
        return ''

    def _item_from(self, kind, sub):
        vid = ''
        title = ''
        pic = ''
        remarks = ''
        if kind == 'lockupViewModel':
            if sub.get('contentType') not in ('LOCKUP_CONTENT_TYPE_VIDEO', None):
                if sub.get('contentType'):
                    return None
            vid = sub.get('contentId') or ''
            if not (isinstance(vid, str) and VID_RE.match(vid)):
                return None
            meta = (sub.get('metadata') or {}).get('lockupMetadataViewModel') or {}
            title = _txt((meta.get('title') or {}))
            img = sub.get('contentImage') or {}
            pics = []
            tv = img.get('thumbnailViewModel') or {}
            if tv:
                pics = ((tv.get('image') or {}).get('sources')) or []
            if not pics:
                pv = (img.get('collectionThumbnailViewModel') or {}).get('primaryThumbnail') or {}
                pics = (((pv.get('thumbnailViewModel') or {}).get('image') or {}).get('sources')) or []
            pic = self._thumb(pics)
            for n in _walk(img):
                t = _txt(n.get('text') if isinstance(n, dict) else None)
                if t and DUR_RE.match(t.strip()):
                    remarks = t.strip()
                    break
            if not remarks:
                rows = meta.get('metadataRows') or []
                parts = []
                for row in rows:
                    for p in (row.get('metadataParts') or []):
                        parts.append(_txt(p.get('text') or {}))
                remarks = ' · '.join(x for x in parts if x)[:40]
        elif kind == 'shortsLockupViewModel':
            vid = self._subtree_vid(sub)
            if not vid:
                return None
            title = sub.get('accessibilityText') or ''
            title = re.sub(r'\s*[-–]\s*(play Short|播放 Short).*$', '', title).strip()
            if not title:
                title = _txt(sub.get('title') or {})
            pic = self._thumb(((sub.get('thumbnail') or {}).get('sources')) or [])
            remarks = 'Shorts'
        else:
            vid = sub.get('videoId') or self._subtree_vid(sub)
            if not (isinstance(vid, str) and VID_RE.match(vid)):
                return None
            title = _txt(sub.get('title') or {}) or _txt(sub.get('headline') or {})
            pic = self._thumb(((sub.get('thumbnail') or {}).get('thumbnails')) or [])
            lt = _txt(sub.get('lengthText') or {})
            if lt:
                remarks = lt
            badges = json.dumps(sub.get('badges') or [], ensure_ascii=False)
            owner = _txt(sub.get('ownerText') or {})
            vc = _txt(sub.get('viewCountText') or {}) or _txt(sub.get('shortViewCountText') or {})
            if 'LIVE' in badges or '直播' in badges or '正在观看' in vc:
                remarks = '直播'
            elif not remarks and (vc or owner):
                remarks = ' · '.join(x for x in (owner, vc) if x)[:40]
        if not vid or not title:
            return None
        if not pic:
            pic = 'https://i.ytimg.com/vi/%s/hqdefault.jpg' % vid
        return {'vod_id': vid, 'vod_name': _clean_title(title.strip()), 'vod_pic': pic,
                'vod_remarks': remarks}

    def _harvest(self, data, kinds=VIDEO_KINDS):
        out, seen = [], set()

        def rec(node):
            if isinstance(node, dict):
                for k in kinds:
                    if k in node and isinstance(node[k], dict):
                        item = self._item_from(k, node[k])
                        if item and item['vod_id'] not in seen:
                            seen.add(item['vod_id'])
                            out.append(item)
                for v in node.values():
                    rec(v)
            elif isinstance(node, list):
                for i in node:
                    rec(i)

        rec(data)
        return out

    def _continuation(self, data):
        tokens = []
        for n in _walk(data):
            cir = n.get('continuationItemRenderer')
            if isinstance(cir, dict):
                tok = (((cir.get('continuationEndpoint') or {}).get('continuationCommand') or {}).get('token'))
                if tok:
                    tokens.append(tok)
        if tokens:
            return tokens[-1]
        for n in _walk(data):
            cc = n.get('continuationCommand')
            if isinstance(cc, dict) and cc.get('token'):
                tokens.append(cc['token'])
        return tokens[-1] if tokens else ''

    def _comp_range(self, title):
        m = re.search(r'EP\s*0*(\d+)\s*[-~～]\s*(?:EP\s*)?0*(\d+)', title, re.I)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            return (a, b, m.start()) if a <= b else None
        m = re.search(r'(\d+)\s*[-~～至到]\s*(\d+)\s*[集话話期部]', title)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            return (a, b, m.start()) if a <= b else None
        m = re.search(r'第\s*(\d+)\s*[-~～至到]\s*第?\s*(\d+)\s*集', title)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            return (a, b, m.start()) if a <= b else None
        m = re.search(r'(\d+)\s*[-~～至到]\s*(?:完结|大结局|最后|最新|持续更新|更新中)', title)
        if m:
            return (int(m.group(1)), 999999, m.start())
        if '全集' in title:
            return (1, 999999, -1)
        return None

    def _comp_episode(self, title):
        m = re.search(r'第\s*(\d+)\s*[集话話]', title)
        if m:
            return int(m.group(1)), m.start()
        m = re.search(r'EP\s*0*(\d+)\b', title, re.I)
        if m:
            return int(m.group(1)), m.start()
        m = re.search(r'(\d+)\s*集', title)
        if m:
            return int(m.group(1)), m.start()
        return None

    def _comp_base(self, title, cut):
        season = ''
        m = re.search(r'(第[一二三四五六七八九十\d]+季|Season\s*\d+|S\d+)', title, re.I)
        if m:
            season = m.group(1)
        mm = re.search(r'《([^》]{2,40})》', title)
        if mm:
            return (mm.group(1).strip() + '|' + season).strip('|')
        if cut is not None and cut >= 0:
            cand = title[:cut]
            cand = re.sub(r'【[^】]*】|\[[^\]]*\]|#\S+', '', cand)
            cand = re.sub(r'[^\w\u4e00-\u9fff]+', '', cand)
            if 2 <= len(cand) <= 30:
                return (cand + '|' + season).strip('|')
        norm = re.sub(r'[^\w\u4e00-\u9fff]+', '', title).lower()
        return norm if norm else None

    def _cn_num(self, s):
        if not s:
            return 0
        if s.isdigit():
            return int(s)
        m = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}
        if '十' in s:
            left, right = s.split('十', 1)
            lv = m.get(left, 1) if left else 1
            rv = m.get(right, 0) if right else 0
            return lv * 10 + rv
        return m.get(s, 0)

    def _season_num(self, title):
        m = re.search(r'第\s*([一二三四五六七八九十\d]+)\s*季', title)
        if m:
            return self._cn_num(m.group(1))
        m = re.search(r'Season\s*(\d+)', title, re.I)
        if m:
            return int(m.group(1))
        m = re.search(r'\bS(\d+)\b', title)
        if m:
            return int(m.group(1))
        return 0

    def _strip_binge_words(self, title):
        t = title
        for _ in range(3):
            old = t
            t = re.sub(r'^(一口气看完|一口氣看完|一口气|一口氣)', '', t)
            t = re.sub(r'(一口气看完|一口氣看完|全集|合集)$', '', t)
            t = t.strip()
            if t == old:
                break
        return t

    def _series_base(self, title):
        mm = re.search(r'《([^》]{2,40})》', title)
        if mm:
            return mm.group(1).strip()
        norm = self._strip_binge_words(title)
        cr = self._comp_range(norm)
        if cr and cr[2] >= 0:
            cand = norm[:cr[2]]
        else:
            ep = self._comp_episode(norm)
            cand = norm[:ep[1]] if ep else ''
        if cand:
            cand = re.sub(r'【[^】]*】|\[[^\]]*\]|#\S+', '', cand)
            cand = re.sub(r'第\s*[一二三四五六七八九十\d]+\s*季|Season\s*\d+|\bS\d+\b', '', cand, flags=re.I)
            cand = re.sub(r'[^\w\u4e00-\u9fff]+', '', cand)
            if 2 <= len(cand) <= 30:
                return cand
        return None

    def _is_binge(self, title):
        return ('一口气' in title or '一口氣' in title or '全集' in title or '合集' in title)

    def _group_by_season(self, items):
        groups = {}
        order = []
        resolved = []
        for idx, it in enumerate(items):
            title = it.get('vod_name') or ''
            series = self._series_base(title)
            resolved.append((idx, it, series))
        known = []
        for _idx, _it, s in resolved:
            if s and s not in known:
                known.append(s)
        known_sorted = sorted(known, key=lambda s: -len(s))
        for idx, it, series in resolved:
            title = it.get('vod_name') or ''
            if not series:
                norm = self._strip_binge_words(title)
                found = ''
                for cand in known_sorted:
                    if cand in norm and norm.find(cand) <= 10:
                        found = cand
                        break
                series = found if found else '##unique##' + it['vod_id']
            if series not in groups:
                groups[series] = []
                order.append(series)
            cr = self._comp_range(title)
            if cr:
                start, end = cr[0], cr[1]
            else:
                ep = self._comp_episode(title)
                start, end = (ep[0], ep[0]) if ep else (0, 0)
            groups[series].append((self._season_num(title), start, end, idx, it))
        out = []
        for series in order:
            grp = groups[series]
            binge = [x for x in grp if self._is_binge(x[4].get('vod_name') or '')]
            rest = [x for x in grp if not self._is_binge(x[4].get('vod_name') or '')]
            binge = sorted(binge, key=lambda x: (x[0], x[1], -x[2], x[3]))
            eps = [x for x in rest if x[1] > 0]
            others = [x for x in rest if x[1] == 0]
            eps = sorted(eps, key=lambda x: (x[0], x[1], x[3]))
            out.extend(it for _s, _st, _e, _i, it in binge + eps + others)
        return out

    def _dedup_compilations(self, items, st, keep_lone_partial=True, keep_all_comps=False):
        comp = st.setdefault('comp', {'ranges': {}, 'singles': {}, 'titles': set()})
        ranges, singles, titles = comp['ranges'], comp['singles'], comp['titles']
        groups = {}
        info = {}
        for it in items:
            title = it.get('vod_name') or ''
            cr = self._comp_range(title)
            if cr:
                base = self._comp_base(title, cr[2])
                kind, val = 'comp', (cr[0], cr[1])
            else:
                ep = self._comp_episode(title)
                if ep:
                    base = self._comp_base(title, ep[1])
                    kind, val = 'single', ep[0]
                else:
                    base = self._comp_base(title, None)
                    kind, val = 'other', None
            if not base:
                info[it['vod_id']] = ('keep', None)
                continue
            groups.setdefault(base, []).append(it)
            info[it['vod_id']] = (kind, val, base)
        keep_ids = set()
        for base, grp in groups.items():
            comps = []
            for it in grp:
                kind, val, _b = info[it['vod_id']]
                if kind == 'comp':
                    comps.append((val[0], -val[1], it))
            comps.sort(key=lambda x: (x[0], x[1]))
            if keep_all_comps:
                for _s, _ne, it in comps:
                    keep_ids.add(it['vod_id'])
                ranges[base] = max([ -_ne for _s, _ne, _it in comps ] + [ranges.get(base, 0)])
            kept_end = ranges.get(base, 0)
            have_kept = kept_end > 0
            for start, _neg_end, it in comps:
                end = -_neg_end
                if not have_kept:
                    if start == 1 or keep_lone_partial:
                        keep_ids.add(it['vod_id'])
                        kept_end, have_kept = end, True
                    continue
                if start > kept_end:
                    keep_ids.add(it['vod_id'])
                    kept_end = max(kept_end, end)
            ranges[base] = kept_end
            seen_eps = singles.setdefault(base, set())
            for it in grp:
                kind, val, _b = info[it['vod_id']]
                if kind == 'single':
                    if val not in seen_eps:
                        seen_eps.add(val)
                        keep_ids.add(it['vod_id'])
                elif kind == 'other':
                    norm = re.sub(r'[^\w\u4e00-\u9fff]+', '', it.get('vod_name') or '').lower()
                    if norm and norm not in titles:
                        titles.add(norm)
                        keep_ids.add(it['vod_id'])
                    elif not norm:
                        keep_ids.add(it['vod_id'])
                elif kind == 'comp':
                    pass
        out = []
        for it in items:
            kind = info[it['vod_id']][0]
            if kind == 'keep' or it['vod_id'] in keep_ids:
                out.append(it)
        return out

    def _stream_state(self, key, mode):
        st = self._streams.get(key)
        if not st:
            st = {'mode': mode, 'tokens': {1: None}, 'seen': set(),
                  'comp': {'ranges': {}, 'singles': {}, 'titles': set()}}
            self._streams[key] = st
        return st

    def _fetch_page(self, key, mode, pg, gl_override=''):
        """mode: ('browse', browseId, params) / ('search', query, sp) / ('shorts',) / ('home',)"""
        self._lazy()
        st = self._stream_state(key, mode)
        mode = st['mode']
        pg = int(pg)
        if pg == 1:
            st['seen'] = set()
            st['comp'] = {'ranges': {}, 'singles': {}, 'titles': set()}
        token = st['tokens'].get(pg)
        if pg > 1 and token is None and pg not in st['tokens']:
            return [], False
        kind = mode[0]
        if kind == 'live':
            if pg != 1:
                return [], False
            _live_items = []
            for _ln, _lv in LIVE_LIST:
                _live_items.append({'vod_id': _lv, 'vod_name': _ln, 'vod_pic': 'https://i.ytimg.com/vi/%s/hqdefault.jpg' % _lv, 'vod_remarks': '直播'})
            return _live_items, False
        if kind == 'home':
            extra = {'browseId': 'FEwhat_to_watch'}
            if token:
                extra = {'continuation': token}
            data = self._innertube('browse', 'WEB', extra, gl=gl_override or None)
            items = self._harvest(data)
            if not items and pg == 1:
                st['mode'] = ('search', '热门', '')
                return self._fetch_page(key, st['mode'], 1, gl_override)
        elif kind == 'browse':
            extra = {'browseId': mode[1]}
            if len(mode) > 2 and mode[2]:
                extra['params'] = mode[2]
            if token:
                extra = {'continuation': token}
            data = self._innertube('browse', 'WEB', extra, gl=gl_override or None)
            items = self._harvest(data)
        elif kind in ('search', 'preset'):
            extra = {'query': mode[1]}
            if len(mode) > 2 and mode[2]:
                extra['params'] = mode[2]
            if token:
                extra = {'continuation': token}
            data = self._innertube('search', 'WEB', extra, gl=gl_override or None)
            items = self._harvest(data)
        elif kind == 'shorts':
            extra = {'query': mode[1] if len(mode) > 1 and mode[1] else '热门', 'params': SHORTS_SP}
            if token:
                extra = {'continuation': token}
            data = self._innertube('search', 'WEB', extra, gl=gl_override or None)
            items = self._harvest(data, SHORTS_KINDS)
            if not items:
                items = [it for it in self._harvest(data) if it.get('vod_remarks') == 'Shorts']
        else:
            return [], False
        nxt = self._continuation(data)
        if nxt:
            st['tokens'][pg + 1] = nxt
        fresh = [it for it in items if it['vod_id'] not in st['seen']]
        st['seen'].update(it['vod_id'] for it in fresh)
        _is_secondary = '|sub=' in key and key.split('|sub=', 1)[1].strip() != ''
        fresh = self._dedup_compilations(fresh, st, keep_all_comps=_is_secondary)
        if '一口气看完' in key:
            fresh = [it for it in fresh if ('一口气' in (it.get('vod_name') or '') or '一口氣' in (it.get('vod_name') or ''))]
        fresh = self._group_by_season(fresh)
        return fresh, bool(nxt)

    def _page_result(self, key, mode, pg, gl_override=''):
        try:
            items, has_next = self._fetch_page(key, mode, pg, gl_override)
        except Exception:
            items, has_next = [], False
        return {'list': items, 'page': int(pg), 'pagecount': 9999 if has_next else int(pg),
                'limit': len(items), 'total': 999999 if has_next else len(items)}

    def _mode_of(self, tid):
        if tid == 'live':
            return ('live',)
        if tid.startswith('custom:'):
            return ('search', tid.split(':', 1)[1], '')
        if tid == 'home':
            return ('home',)
        if tid == 'shorts':
            return ('shorts',)
        if tid.startswith('channel:'):
            return ('browse', tid.split(':', 1)[1], '')
        if tid.startswith('browse:'):
            rest = tid.split(':', 1)[1]
            if '|' in rest:
                bid, params = rest.split('|', 1)
            else:
                bid, params = rest, ''
            return ('browse', bid, params)
        if tid.startswith('preset:'):
            return ('search', tid.split(':', 1)[1], '')
        return ('search', tid, '')

    def _parse_extend(self, extend, filter_param=None):
        ext = extend if extend is not None else filter_param
        if isinstance(ext, str):
            try:
                ext = json.loads(ext)
            except Exception:
                try:
                    import urllib.parse as _up
                    ext = dict(_up.parse_qsl(ext))
                except Exception:
                    ext = {}
        if not isinstance(ext, dict):
            return {}
        out = {}
        for k, v in ext.items():
            if isinstance(v, (list, tuple)):
                v = v[0] if v else ''
            out[str(k)] = '' if v is None else str(v)
        return out

    def _filter_values(self, extend, filter_param=None):
        ext = self._parse_extend(extend, filter_param)
        area = ext.get('地区') or ext.get('area') or ''
        time_code = ext.get('时间') or ext.get('time') or ''
        tag = ext.get('标签') or ext.get('tag') or ext.get('cate') or ''
        year = ext.get('年份') or ext.get('year') or ''
        series = ext.get('二级分类') or ext.get('sub') or ext.get('series') or ''
        return area, time_code, tag, year, series

    def _time_after(self, code):
        import datetime as _dt
        today = _dt.date.today()
        if code == 'today':
            return today.isoformat()
        if code == 'week':
            return (today - _dt.timedelta(days=7)).isoformat()
        if code == 'month':
            return _dt.date(today.year, today.month, 1).isoformat()
        if code == 'year':
            return _dt.date(today.year, 1, 1).isoformat()
        return ''

    def _apply_filters(self, mode, extend, filter_param=None):
        area, time_code, tag, year, series = self._filter_values(extend, filter_param)
        kind = mode[0]
        if kind in ('search', 'preset'):
            q = series if series else mode[1]
            if tag:
                q = q + ' ' + tag
            if year and str(year).isdigit() and len(str(year)) == 4:
                y = int(year)
                q = q + ' after:%d-01-01 before:%d-01-01' % (y, y + 1)
            else:
                after = self._time_after(time_code)
                if after:
                    q = q + ' after:' + after
            return ('search', q, mode[2] if len(mode) > 2 else ''), area
        if kind == 'shorts':
            q = tag or '热门'
            if year and str(year).isdigit() and len(str(year)) == 4:
                y = int(year)
                q = q + ' after:%d-01-01 before:%d-01-01' % (y, y + 1)
            else:
                after = self._time_after(time_code)
                if after:
                    q = q + ' after:' + after
            return ('shorts', q), area
        return mode, area

    def homeContent(self, filter=None):
        self._lazy()
        classes = list(CLASSES)
        if getattr(self, 'custom', ''):
            classes = classes + list(self.custom)
        if getattr(self, 'cookie', ''):
            idx = next((i for i, c in enumerate(classes) if c['type_id'] == 'home'), len(classes))
            classes = classes[:idx] + list(LOGIN_CLASSES) + classes[idx:]
        filters = {c['type_id']: FILTERS.get(c['type_id'], [REGION_FILTER]) for c in classes}
        return {'class': classes, 'filters': filters}

    def homeVideoContent(self):
        return self._page_result('home', ('home',), 1)

    def categoryContent(self, tid, pg, filter=None, extend=None):
        base_mode = self._mode_of(str(tid))
        mode, area = self._apply_filters(base_mode, extend, filter)
        _a, _t, _tag, _y, _s = self._filter_values(extend, filter)
        key = 'cat:%s|area=%s|time=%s|tag=%s|year=%s|sub=%s' % (str(tid), _a, _t, _tag, _y, _s)
        res = self._page_result(key, mode, pg, area)
        if _s:
            lst = res.get('list') or []
            comps, singles, others = [], [], []
            for idx, it in enumerate(lst):
                title = it.get('vod_name') or ''
                cr = self._comp_range(title)
                if cr:
                    comps.append((cr[0], cr[1], idx, it))
                elif self._is_binge(title):
                    comps.append((1, 999999, idx, it))
                else:
                    ep = self._comp_episode(title)
                    if ep:
                        singles.append((ep[0], idx, it))
                    else:
                        others.append(it)
            comps = sorted(comps, key=lambda x: (x[0], x[1], x[2]))
            singles = sorted(singles, key=lambda x: (x[0], x[1]))
            res['list'] = [it for _a, _b, _i, it in comps] + [it for _e, _i, it in singles] + others
        return res

    def searchContent(self, key, quick, pg='1'):
        return self._page_result('search:' + str(key), ('search', str(key), ''), pg)

    def _related(self, vid):
        try:
            data = self._innertube('next', 'WEB', {'videoId': vid})
            items = self._harvest(data)
            out = []
            seen = set()
            for it in items:
                _id = it.get('vod_id') or ''
                if not _id or _id == vid or _id in seen:
                    continue
                seen.add(_id)
                out.append(it)
                if len(out) >= 20:
                    break
            return out
        except Exception:
            return []

    def detailContent(self, ids):
        self._lazy()
        vid = str(ids[0]) if ids else ''
        vod = {'vod_id': vid, 'vod_name': vid, 'vod_pic': 'https://i.ytimg.com/vi/%s/hqdefault.jpg' % vid,
               'vod_remarks': '', 'vod_actor': '', 'vod_content': '', 'type_name': 'YouTube'}
        try:
            r = self._player(vid, 'WEB')
            vd = r.get('videoDetails') or {}
            if vd:
                vod['vod_name'] = vd.get('title') or vid
                vod['vod_actor'] = vd.get('author') or ''
                vod['vod_content'] = (vd.get('shortDescription') or '')[:800]
                thumbs = ((vd.get('thumbnail') or {}).get('thumbnails')) or []
                if thumbs:
                    vod['vod_pic'] = self._thumb(thumbs)
                ls = int(vd.get('lengthSeconds') or 0)
                if ls:
                    vod['vod_remarks'] = '%d:%02d' % (ls // 60, ls % 60)
                if vd.get('isLiveContent'):
                    vod['vod_remarks'] = '直播'
        except Exception:
            pass
        if vod['vod_name'] == vid:
            try:
                req = urllib.request.Request(
                    'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=%s&format=json' % vid,
                    headers={'User-Agent': UA_WEB})
                with urllib.request.urlopen(req, timeout=20) as r:
                    oe = json.loads(r.read().decode('utf-8', 'ignore'))
                vod['vod_name'] = oe.get('title') or vid
                vod['vod_actor'] = oe.get('author_name') or ''
                if oe.get('thumbnail_url'):
                    vod['vod_pic'] = oe['thumbnail_url']
            except Exception:
                pass
        vod['vod_name'] = _clean_title(vod['vod_name'])
        vod['vod_play_from'] = 'HLS高清$$$DASH高清$$$1080p$$$4K$$$8K$$$360p直链'
        vod['vod_play_url'] = '正片$%s$$$正片$%s$$$正片$%s$$$正片$%s$$$正片$%s$$$正片$%s' % (vid, vid, vid, vid, vid, vid)
        _rel = self._related(vid)
        if _rel:
            _eps = []
            for _ri in _rel:
                _rt = (_ri.get('vod_name') or '').replace('$', '').replace('#', '')
                _rv = _ri.get('vod_id') or ''
                if _rv and _rt:
                    _eps.append('%s$%s' % (_rt, _rv))
            if _eps:
                vod['vod_play_from'] = vod['vod_play_from'] + '$$$相关视频'
                vod['vod_play_url'] = vod['vod_play_url'] + '$$$' + '#'.join(_eps)
        return {'list': [vod]}

    def _hls_variant(self, vid, target_res, auth='auto'):
        try:
            r = self._player(vid, 'VISIONOS', auth=auth)
        except Exception:
            return ''
        hls = ((r or {}).get('streamingData') or {}).get('hlsManifestUrl') or ''
        if not hls:
            return ''
        try:
            req = urllib.request.Request(hls, headers={'User-Agent': UA_VIS})
            with urllib.request.urlopen(req, timeout=20) as resp:
                lines = resp.read().decode('utf-8', 'ignore').splitlines()
        except Exception:
            return ''
        candidates = []
        for i, ln in enumerate(lines):
            if ln.startswith('#EXT-X-STREAM-INF') and i + 1 < len(lines):
                m = re.search(r'RESOLUTION=(\d+x\d+)', ln)
                if m and m.group(1) == target_res:
                    raw = lines[i + 1].strip()
                    if not raw.startswith('http'):
                        import urllib.parse as _up
                        raw = _up.urljoin(hls, raw)
                    candidates.append((ln, raw))
        if not candidates:
            return ''
        for ln, url in candidates:
            if 'avc1' in ln:
                return url
        return candidates[0][1]

    def playerContent(self, flag, id, vipFlags):
        self._lazy()
        vid = str(id)
        hd_map = {'1080p': '1920x1080', '4K': '3840x2160', '8K': '7680x4320'}
        if flag in hd_map:
            for auth in ('auto', True):
                if auth is True and not getattr(self, 'cookie', ''):
                    break
                url = self._hls_variant(vid, hd_map[flag], auth=auth)
                if url:
                    return {'parse': 0, 'playUrl': '', 'url': url,
                            'header': {'User-Agent': UA_VIS}}
        if flag == 'DASH高清':
            for auth in ('auto', True):
                if auth is True and not getattr(self, 'cookie', ''):
                    break
                for client_name in ['VISIONOS', 'ANDROID', 'WEB', 'ANDROID_VR', 'IOS']:
                    try:
                        r = self._player(vid, client_name, auth=auth)
                    except Exception:
                        continue
                    dash = ((r or {}).get('streamingData') or {}).get('dashManifestUrl') or ''
                    if dash:
                        return {'parse': 0, 'playUrl': '', 'url': dash,
                                'header': {'User-Agent': CLIENT_UA[client_name]}}
        if flag == '360p直链':
            order = ['ANDROID', 'ANDROID_VR', 'WEB', 'VISIONOS', 'IOS']
        else:
            order = ['VISIONOS', 'ANDROID', 'WEB', 'ANDROID_VR', 'IOS']
        for auth in ('auto', True):
            if auth is True and not getattr(self, 'cookie', ''):
                break
            for client_name in order:
                try:
                    r = self._player(vid, client_name, auth=auth)
                except Exception:
                    continue
                got = self._usable_play(r, client_name)
                if got:
                    url, header = got
                    return {'parse': 0, 'playUrl': '', 'url': url, 'header': header}
        return {'parse': 0, 'playUrl': '', 'url': '', 'header': {}}


    def getDependence(self):
        return []

    def localProxy(self, param=None):
        import urllib.parse as _up
        import urllib.request as _ur
        try:
            p = param
            if isinstance(p, str):
                try:
                    p = json.loads(p)
                except Exception:
                    p = dict(_up.parse_qsl(p))
            if not isinstance(p, dict):
                p = {}
            target = p.get("url") or p.get("u") or ""
            if isinstance(target, list):
                target = target[0] if target else ""
            target = _up.unquote(str(target or "").strip())
            if not target.startswith("http"):
                return [404, "text/plain", b"bad url", {}]
            _o = _up.urlparse(target)
            _req = _ur.Request(target, headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                "Referer": "%s://%s/" % (_o.scheme, _o.netloc)})
            with _ur.urlopen(_req, timeout=20) as _r:
                return [_r.status, _r.headers.get("Content-Type") or "application/octet-stream", _r.read(), {}]
        except Exception:
            return [502, "text/plain", b"proxy error", {}]

    def action(self, action=None):
        return {}

