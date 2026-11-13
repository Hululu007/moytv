import 'dart:convert';

import 'web_scrape_analyzer.dart';

/// 生成失败：[reasons] 列出全部缺失的数据项，调用方逐条展示。
class PyGeneratorException implements Exception {
  const PyGeneratorException(this.reasons);
  final List<String> reasons;
  @override
  String toString() => reasons.join('\n');
}

/// 生成结果：文件名用站点 key，[source] 为完整的蜘蛛源码。
class GeneratedPySpider {
  const GeneratedPySpider({
    required this.fileName,
    required this.key,
    required this.source,
  });
  final String fileName;
  final String key;
  final String source;
}

/// 生成阻塞项：返回空表示数据足够，可以生成；非空时逐条说明缺了什么。
List<String> generationBlockers(ScrapedSiteData data) {
  final blockers = <String>[];
  final uri = Uri.tryParse(data.base);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    blockers.add('站点地址无效');
  }
  if (data.siteName.trim().isEmpty) {
    blockers.add('未识别出站名');
  }
  if (pyKeyForSite(data.base) == null) {
    blockers.add('无法从站点地址生成站点 key');
  }
  if (data.isMacCMS) {
    // MacCMS 模式：采集接口已由探站验活，分类与详情由接口在运行时给出。
    return blockers;
  }
  if (data.categories.length < 2) {
    blockers.add(
      '分类不足：需要 2 个以上同规律分类，实得 ${data.categories.length} 个',
    );
  }
  final template = data.categoryUrlTemplate;
  if (template == null || template.isEmpty || !template.contains('{cateId}')) {
    blockers.add('未识别出分类地址模板');
  }
  final usableItems = data.listItems.where(
    (e) => e.title.trim().isNotEmpty && e.url.trim().isNotEmpty,
  );
  if (usableItems.isEmpty) {
    blockers.add('分类页未抓到带标题与链接的列表项');
  }
  if (data.detailHrefPattern == null || data.detailHrefPattern!.isEmpty) {
    blockers.add('未归纳出详情链接规律');
  }
  if (data.detailSample == null) {
    blockers.add('未抓到详情页示例');
  }
  if (data.playChain == PlayChain.none) {
    blockers.add('详情页未发现可播放地址（无直链、无播放页链接）');
  }
  if (data.playChain == PlayChain.viaPlayPage &&
      (data.detailSample?.playHrefPattern == null ||
          data.detailSample!.playHrefPattern!.isEmpty)) {
    blockers.add('未归纳出播放页链接规律');
  }
  return blockers;
}

/// 由站点地址推导 key：取主机首段，只保留小写字母数字下划线。
String? pyKeyForSite(String base) {
  final uri = Uri.tryParse(base);
  if (uri == null || uri.host.isEmpty) return null;
  var host = uri.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  final first = host.split('.').first;
  final cleaned = first.replaceAll(RegExp(r'[^a-z0-9_]'), '');
  if (cleaned.isEmpty) return null;
  final key =
      RegExp(r'^[0-9]').hasMatch(cleaned) ? 'site_$cleaned' : cleaned;
  return key.length > 32 ? key.substring(0, 32) : key;
}

/// 纯函数：爬取数据 -> 蜘蛛源码。数据不足时抛 [PyGeneratorException]，绝不编假规则。
GeneratedPySpider generatePySpider(ScrapedSiteData data) {
  final blockers = generationBlockers(data);
  if (blockers.isNotEmpty) {
    throw PyGeneratorException(blockers);
  }
  final key = pyKeyForSite(data.base)!;
  final source = data.isMacCMS ? _macCmsSpider(data, key) : _htmlSpider(data, key);
  return GeneratedPySpider(fileName: '$key.py', key: key, source: source);
}

/// Python 字符串字面量：JSON 转义与 Python 双引号字符串兼容。
String _s(String value) => jsonEncode(value);

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';

const _mediaPattern =
    r'''(?:https?:)?//[^\s"'<>]+\.(?:m3u8|mp4)(?:\?[^\s"'<>]*)?''';
const _anchorPattern = r'''<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>''';
const _imgPattern =
    r'''<img[^>]*?(?:src|data-src|data-original)="([^"]+)"''';
const _imgDataPattern =
    r'''(?:data-src|data-original)\s*=\s*"([^"]+)"''';
const _imgSrcPattern = r'''(?<![\w-])src\s*=\s*"([^"]+)"''';
const _h1Pattern = r'''<h1[^>]*>(.*?)</h1>''';
const _titleTagPattern = r'''<title[^>]*>(.*?)</title>''';
const _metaDescPattern =
    r'''<meta[^>]*name=["']description["'][^>]*content=["']([^"']*)["']''';
const _ogDescPattern =
    r'''<meta[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']''';
const _ogImagePattern =
    r'''<meta[^>]*property=["']og:image["'][^>]*content=["']([^"']*)["']''';
const _tagStripPattern = r'''<[^>]+>''';

void _writeHeader(StringBuffer buf, {required bool needsJson}) {
  buf.writeln('try:');
  buf.writeln('    from base.spider import BaseSpider');
  buf.writeln('except Exception:');
  buf.writeln('    try:');
  buf.writeln('        from base import BaseSpider');
  buf.writeln('    except Exception:');
  buf.writeln('        class BaseSpider:');
  buf.writeln('            pass');
  buf.writeln();
  buf.writeln();
  buf.writeln('import gzip');
  buf.writeln('import html as _html');
  buf.writeln('import http.client');
  if (needsJson) {
    buf.writeln('import json');
  }
  buf.writeln('import re');
  buf.writeln('import ssl');
  buf.writeln('import time');
  buf.writeln('import urllib.error');
  buf.writeln('import urllib.parse');
  buf.writeln('import urllib.request');
  buf.writeln();
  buf.writeln('try:');
  buf.writeln('    import requests');
  buf.writeln('    _HAS_REQ = True');
  buf.writeln('except Exception:');
  buf.writeln('    _HAS_REQ = False');
  buf.writeln();
  buf.writeln();
}

const _sharedHelpers = r'''
def _ctx():
    return ssl._create_unverified_context()


def _unescape(text):
    text = _html.unescape(text or '')
    return re.sub(r'\s+', ' ', text).strip()


def _http_get(url, referer='', timeout=15):
    headers = {
        'User-Agent': UA,
        'Accept': 'text/html,application/json,*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': referer or BASE + '/',
    }
    for attempt in range(3):
        if _HAS_REQ:
            try:
                resp = requests.get(url, headers=headers, timeout=timeout, verify=False)
                if resp.status_code in (200, 206):
                    resp.encoding = resp.apparent_encoding or 'utf-8'
                    return resp.text
            except Exception:
                pass
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
                raw = resp.read()
                if raw[:2] == b'\x1f\x8b':
                    raw = gzip.decompress(raw)
                enc = resp.headers.get_content_charset() or 'utf-8'
                return raw.decode(enc, errors='replace')
        except urllib.error.HTTPError as e:
            try:
                raw = e.read()
                if raw[:2] == b'\x1f\x8b':
                    raw = gzip.decompress(raw)
                return raw.decode('utf-8', errors='replace')
            except Exception:
                return ''
        except (http.client.IncompleteRead, Exception):
            if attempt < 2:
                time.sleep(0.5)
    return ''


def _norm_id(ids):
    if isinstance(ids, list):
        return str(ids[0]) if ids else ''
    return str(ids or '').strip()


def _norm_pg(pg):
    try:
        return max(1, int(pg))
    except Exception:
        return 1
''';

const _htmlHelpers = r'''
def _parse_cards(html, base):
    anchors = list(ANCHOR_RE.finditer(html or ''))
    covers = {}
    for m in anchors:
        href = m.group(1).strip()
        if not DETAIL_HREF_RE.search(href):
            continue
        url = urllib.parse.urljoin(base + '/', href)
        inner = m.group(2)
        dm = IMG_DATA_RE.search(inner)
        if dm:
            covers[url] = urllib.parse.urljoin(base + '/', dm.group(1).strip())
            continue
        if url not in covers:
            sm = IMG_SRC_RE.search(inner)
            if sm:
                covers[url] = urllib.parse.urljoin(
                    base + '/', sm.group(1).strip())
    out = []
    seen = set()
    for m in anchors:
        href = m.group(1).strip()
        if not DETAIL_HREF_RE.search(href):
            continue
        url = urllib.parse.urljoin(base + '/', href)
        if url in seen:
            continue
        title = _unescape(re.sub(TAG_STRIP_RE, ' ', m.group(2)))
        if not title:
            continue
        seen.add(url)
        out.append({'vod_id': url, 'vod_name': title,
                    'vod_pic': covers.get(url, ''), 'vod_remarks': ''})
    return out


def _parse_play_links(html, base):
    out = []
    seen = set()
    for m in ANCHOR_RE.finditer(html or ''):
        href = m.group(1).strip()
        if not PLAY_HREF_RE.search(href):
            continue
        url = urllib.parse.urljoin(base + '/', href)
        if url in seen:
            continue
        seen.add(url)
        name = _unescape(re.sub(TAG_STRIP_RE, ' ', m.group(2)))
        out.append((name, url))
    return out


def _detail_fields(html):
    title = ''
    hm = H1_RE.search(html or '')
    if hm:
        title = _unescape(re.sub(TAG_STRIP_RE, ' ', hm.group(1)))
    if not title:
        tm = TITLE_TAG_RE.search(html or '')
        if tm:
            title = _unescape(re.sub(TAG_STRIP_RE, ' ', tm.group(1)))
    cover = ''
    om = OG_IMAGE_RE.search(html or '')
    if om:
        cover = om.group(1).strip()
    if not cover:
        im = IMG_RE.search(html or '')
        if im:
            cover = im.group(1).strip()
    if cover.startswith('//'):
        cover = 'https:' + cover
    synopsis = ''
    dm = DESC_RE.search(html or '')
    if dm:
        synopsis = _unescape(dm.group(1))
    if not synopsis:
        om2 = OG_DESC_RE.search(html or '')
        if om2:
            synopsis = _unescape(om2.group(1))
    return title, cover, synopsis
''';

const _macCmsHelpers = r'''
def _api(params):
    qs = urllib.parse.urlencode(params)
    txt = _http_get(API + '?' + qs, referer=BASE + '/')
    if not txt:
        return {}
    try:
        return json.loads(txt)
    except Exception:
        return {}


def _vod_item(v):
    return {
        'vod_id': str(v.get('vod_id') or ''),
        'vod_name': str(v.get('vod_name') or ''),
        'vod_pic': str(v.get('vod_pic') or ''),
        'vod_remarks': str(v.get('vod_remarks') or ''),
    }


def _episodes(play_url):
    groups = (play_url or '').split('$$$')
    first = groups[0] if groups else ''
    out = []
    for part in first.split('#'):
        if '$' in part:
            name, link = part.split('$', 1)
        else:
            name, link = part, part
        name = name.strip()
        link = link.strip()
        if link:
            out.append((name or link, link))
    return out
''';

void _writeClassHead(StringBuffer buf, String siteName) {
  buf.writeln('class Spider(BaseSpider):');
  buf.writeln('    def getName(self):');
  buf.writeln('        return ${_s(siteName)}');
  buf.writeln();
  buf.writeln('    def getDependence(self):');
  buf.writeln('        return []');
  buf.writeln();
  buf.writeln("    def init(self, extend=''):");
  buf.writeln('        pass');
  buf.writeln();
  buf.writeln('    def destroy(self):');
  buf.writeln('        pass');
  buf.writeln();
}

void _writeClassTail(StringBuffer buf) {
  buf.writeln('    def localProxy(self, param):');
  buf.writeln("        return [404, 'text/plain', '']");
  buf.writeln();
  buf.writeln('    def isVideoFormat(self, url):');
  buf.writeln("        url = (url or '').lower()");
  buf.writeln(
    "        return url.endswith('.m3u8') or url.endswith('.mp4') or "
    "'.m3u8?' in url or '.mp4?' in url",
  );
  buf.writeln();
  buf.writeln('    def manualVideoCheck(self):');
  buf.writeln('        return False');
  buf.writeln();
  buf.writeln('    def action(self, action):');
  buf.writeln('        return None');
}

String _htmlSpider(ScrapedSiteData data, String key) {
  final buf = StringBuffer();
  _writeHeader(buf, needsJson: false);
  buf.writeln('BASE = ${_s(data.base)}');
  buf.writeln('KEY = ${_s(key)}');
  buf.writeln('UA = ${_s(_ua)}');
  buf.writeln('CATS = [');
  for (final c in data.categories) {
    buf.writeln('    (${_s(c.id)}, ${_s(c.name)}),');
  }
  buf.writeln(']');
  buf.writeln('CAT_URL = ${_s(data.categoryUrlTemplate!)}');
  buf.writeln('SEARCH_URL = ${_s(data.searchUrl ?? '')}');
  buf.writeln('DETAIL_HREF_RE = re.compile(${_s(data.detailHrefPattern!)})');
  buf.writeln(
    'PLAY_HREF_RE = re.compile(${_s(data.detailSample?.playHrefPattern ?? '')})',
  );
  buf.writeln('MEDIA_RE = re.compile(${_s(_mediaPattern)})');
  buf.writeln('ANCHOR_RE = re.compile(${_s(_anchorPattern)}, re.S)');
  buf.writeln('IMG_RE = re.compile(${_s(_imgPattern)}, re.I)');
  buf.writeln('IMG_DATA_RE = re.compile(${_s(_imgDataPattern)}, re.I)');
  buf.writeln('IMG_SRC_RE = re.compile(${_s(_imgSrcPattern)}, re.I)');
  buf.writeln('H1_RE = re.compile(${_s(_h1Pattern)}, re.S)');
  buf.writeln('TITLE_TAG_RE = re.compile(${_s(_titleTagPattern)}, re.S)');
  buf.writeln('DESC_RE = re.compile(${_s(_metaDescPattern)}, re.I)');
  buf.writeln('OG_DESC_RE = re.compile(${_s(_ogDescPattern)}, re.I)');
  buf.writeln('OG_IMAGE_RE = re.compile(${_s(_ogImagePattern)}, re.I)');
  buf.writeln('TAG_STRIP_RE = re.compile(${_s(_tagStripPattern)})');
  buf.write(_sharedHelpers);
  buf.writeln();
  buf.write(_htmlHelpers);
  buf.writeln();
  buf.writeln();
  _writeClassHead(buf, data.siteName);
  buf.writeln('    def _catalog(self, tid, pg):');
  buf.writeln(
    "        url = CAT_URL.replace('{cateId}', str(tid)).replace('{catePg}', str(pg))",
  );
  buf.writeln(
    "        return _parse_cards(_http_get(url, referer=BASE + '/'), BASE)",
  );
  buf.writeln();
  buf.writeln("    def homeContent(self, filter=''):");
  buf.writeln('        items = []');
  buf.writeln('        if CATS:');
  buf.writeln('            items = self._catalog(CATS[0][0], 1)');
  buf.writeln(
    "        return {'class': [{'type_id': tid, 'type_name': name} for tid, name in CATS], 'list': items}",
  );
  buf.writeln();
  buf.writeln('    def homeVideoContent(self):');
  buf.writeln('        items = []');
  buf.writeln('        if CATS:');
  buf.writeln('            items = self._catalog(CATS[0][0], 1)');
  buf.writeln(
    "        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}",
  );
  buf.writeln();
  buf.writeln(
    '    def categoryContent(self, tid, pg, filter=False, extend=None):',
  );
  buf.writeln('        pg = _norm_pg(pg)');
  buf.writeln('        items = self._catalog(tid, pg)');
  buf.writeln(
    "        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}",
  );
  buf.writeln();
  buf.writeln('    def detailContent(self, ids):');
  buf.writeln('        url = _norm_id(ids)');
  buf.writeln('        if not url:');
  buf.writeln("            return {'list': []}");
  buf.writeln("        if not url.startswith('http'):");
  buf.writeln("            url = urllib.parse.urljoin(BASE + '/', url)");
  buf.writeln("        html = _http_get(url, referer=BASE + '/')");
  buf.writeln('        if not html:');
  buf.writeln("            return {'list': []}");
  buf.writeln('        title, cover, synopsis = _detail_fields(html)');
  buf.writeln('        if not title:');
  buf.writeln("            return {'list': []}");
  if (data.playChain == PlayChain.viaPlayPage) {
    buf.writeln('        links = _parse_play_links(html, BASE)');
    buf.writeln('        parts = []');
    buf.writeln('        for i, (name, link) in enumerate(links):');
    buf.writeln("            label = name or ('第%d集' % (i + 1))");
    buf.writeln("            parts.append(label + '\$' + KEY + ':' + link)");
    buf.writeln('        if not parts:');
    buf.writeln("            parts.append('立即播放\$' + KEY + ':' + url)");
    buf.writeln("        play_url = '#'.join(parts)");
  } else {
    buf.writeln("        play_url = '立即播放\$' + KEY + ':' + url");
  }
  buf.writeln(
    "        return {'list': [{'vod_id': url, 'vod_name': title, 'vod_pic': cover, "
    "'vod_actor': '', 'vod_director': '', 'vod_remarks': '', 'vod_year': '', "
    "'vod_area': '', 'vod_content': synopsis, 'type_name': '', 'vod_tag': '', "
    "'vod_play_from': '在线播放', 'vod_play_url': play_url, 'stills': []}]}",
  );
  buf.writeln();
  buf.writeln('    def searchContent(self, key, quick=False, pg=1):');
  if (data.searchUrl != null && data.searchUrl!.isNotEmpty) {
    buf.writeln('        pg = _norm_pg(pg)');
    buf.writeln(
      "        url = SEARCH_URL.replace('{wd}', urllib.parse.quote(key or ''))",
    );
    buf.writeln(
      "        items = _parse_cards(_http_get(url, referer=BASE + '/'), BASE)",
    );
    buf.writeln(
      "        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}",
    );
  } else {
    buf.writeln(
      "        return {'list': [], 'page': _norm_pg(pg), 'pagecount': 0, 'total': 0}",
    );
  }
  buf.writeln();
  buf.writeln('    def playerContent(self, flag, id, vipFlags=None):');
  buf.writeln('        raw = _norm_id(id)');
  buf.writeln("        prefix = KEY + ':'");
  buf.writeln('        if raw.startswith(prefix):');
  buf.writeln('            raw = raw[len(prefix):]');
  buf.writeln("        header = {'User-Agent': UA, 'Referer': BASE + '/'}");
  buf.writeln("        stream = ''");
  buf.writeln("        if raw.startswith('http'):");
  buf.writeln("            html = _http_get(raw, referer=BASE + '/')");
  buf.writeln('            m = MEDIA_RE.search(html or \'\')');
  buf.writeln('            if m:');
  buf.writeln('                stream = m.group(0)');
  buf.writeln("                if stream.startswith('//'):");
  buf.writeln("                    stream = 'https:' + stream");
  buf.writeln("                header['Referer'] = stream");
  buf.writeln(
    "        return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': header}",
  );
  buf.writeln();
  _writeClassTail(buf);
  return buf.toString();
}

String _macCmsSpider(ScrapedSiteData data, String key) {
  final buf = StringBuffer();
  _writeHeader(buf, needsJson: true);
  buf.writeln('BASE = ${_s(data.base)}');
  buf.writeln('KEY = ${_s(key)}');
  buf.writeln('UA = ${_s(_ua)}');
  buf.writeln("API = BASE + '/api.php/provide/vod/'");
  buf.write(_sharedHelpers);
  buf.writeln();
  buf.write(_macCmsHelpers);
  buf.writeln();
  buf.writeln();
  _writeClassHead(buf, data.siteName);
  buf.writeln("    def homeContent(self, filter=''):");
  buf.writeln("        data = _api({'ac': 'list', 'pg': 1})");
  buf.writeln('        cats = []');
  buf.writeln("        for c in data.get('class') or []:");
  buf.writeln("            tid = str(c.get('type_id') or '')");
  buf.writeln("            name = str(c.get('type_name') or '')");
  buf.writeln('            if tid and name:');
  buf.writeln(
    "                cats.append({'type_id': tid, 'type_name': name})",
  );
  buf.writeln('        if not cats:');
  buf.writeln("            cats = [{'type_id': '', 'type_name': '全部'}]");
  buf.writeln("        items = [_vod_item(v) for v in data.get('list') or []]");
  buf.writeln("        return {'class': cats, 'list': items}");
  buf.writeln();
  buf.writeln('    def homeVideoContent(self):');
  buf.writeln("        data = _api({'ac': 'list', 'pg': 1})");
  buf.writeln("        items = [_vod_item(v) for v in data.get('list') or []]");
  buf.writeln(
    "        return {'list': items, 'page': 1, 'pagecount': 0, 'total': 0}",
  );
  buf.writeln();
  buf.writeln(
    '    def categoryContent(self, tid, pg, filter=False, extend=None):',
  );
  buf.writeln('        pg = _norm_pg(pg)');
  buf.writeln("        params = {'ac': 'list', 'pg': pg}");
  buf.writeln('        if tid:');
  buf.writeln("            params['t'] = tid");
  buf.writeln('        data = _api(params)');
  buf.writeln("        items = [_vod_item(v) for v in data.get('list') or []]");
  buf.writeln(
    "        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}",
  );
  buf.writeln();
  buf.writeln('    def detailContent(self, ids):');
  buf.writeln('        vid = _norm_id(ids)');
  buf.writeln('        if not vid:');
  buf.writeln("            return {'list': []}");
  buf.writeln("        data = _api({'ac': 'detail', 'ids': vid})");
  buf.writeln("        items = data.get('list') or []");
  buf.writeln('        if not items:');
  buf.writeln("            return {'list': []}");
  buf.writeln('        v = items[0]');
  buf.writeln("        eps = _episodes(str(v.get('vod_play_url') or ''))");
  buf.writeln(
    "        play_from = str(v.get('vod_play_from') or '').split('\$\$\$')[0] or '在线播放'",
  );
  buf.writeln('        parts = []');
  buf.writeln('        for name, link in eps:');
  buf.writeln("            parts.append(name + '\$' + KEY + ':' + link)");
  buf.writeln("        play_url = '#'.join(parts)");
  buf.writeln(
    "        return {'list': [{'vod_id': str(v.get('vod_id') or vid), "
    "'vod_name': str(v.get('vod_name') or ''), 'vod_pic': str(v.get('vod_pic') or ''), "
    "'vod_actor': str(v.get('vod_actor') or ''), "
    "'vod_director': str(v.get('vod_director') or ''), "
    "'vod_remarks': str(v.get('vod_remarks') or ''), "
    "'vod_year': str(v.get('vod_year') or ''), "
    "'vod_area': str(v.get('vod_area') or ''), "
    "'vod_content': str(v.get('vod_content') or ''), "
    "'type_name': str(v.get('type_name') or ''), 'vod_tag': '', "
    "'vod_play_from': play_from, 'vod_play_url': play_url, 'stills': []}]}",
  );
  buf.writeln();
  buf.writeln('    def searchContent(self, key, quick=False, pg=1):');
  buf.writeln('        pg = _norm_pg(pg)');
  buf.writeln("        data = _api({'ac': 'list', 'wd': key or '', 'pg': pg})");
  buf.writeln("        items = [_vod_item(v) for v in data.get('list') or []]");
  buf.writeln(
    "        return {'list': items, 'page': pg, 'pagecount': 0, 'total': 0}",
  );
  buf.writeln();
  buf.writeln('    def playerContent(self, flag, id, vipFlags=None):');
  buf.writeln('        raw = _norm_id(id)');
  buf.writeln("        prefix = KEY + ':'");
  buf.writeln('        if raw.startswith(prefix):');
  buf.writeln('            raw = raw[len(prefix):]');
  buf.writeln("        header = {'User-Agent': UA, 'Referer': BASE + '/'}");
  buf.writeln("        stream = raw if raw.startswith('http') else ''");
  buf.writeln('        if stream:');
  buf.writeln("            header['Referer'] = stream");
  buf.writeln(
    "        return {'parse': 0, 'playUrl': stream, 'url': stream, 'header': header}",
  );
  buf.writeln();
  _writeClassTail(buf);
  return buf.toString();
}
