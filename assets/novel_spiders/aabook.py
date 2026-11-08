# -*- coding: utf-8 -*-
import concurrent.futures
import gzip
import http.cookiejar
import json
import re
import sys
import time
import urllib.parse
import urllib.request

try:
    sys.path.append("..")
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

BASE = "https://aabook.net"
MOBILE = BASE + "/m/"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
TIMEOUT = 60
DETAIL_WORKERS = 8
DETAIL_MAX_PAGE = 40

CATS = [
    ("chuanyue", "穿越"),
    ("danmei", "耽美"),
    ("danpian", "单篇"),
    ("dushi", "都市"),
    ("guanchang", "官场"),
    ("gudian", "古典"),
    ("jingsong", "惊悚"),
    ("lishi", "历史"),
    ("nvzun", "女尊"),
    ("tongren", "同人"),
    ("wangyou", "网游"),
    ("wuxia", "武侠"),
    ("xiangtu", "乡土"),
    ("xianxia", "仙侠"),
    ("xiaoyuan", "校园"),
    ("xuanhuan", "玄幻"),
    ("yanqing", "言情"),
    ("yineng", "异能"),
]


def _clean(text):
    text = re.sub(r"<[^>]+>", "", text or "")
    text = text.replace("&nbsp;", " ").replace("&amp;", "&")
    text = text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
    return text.strip()


def _norm_extend(extend):
    if isinstance(extend, dict):
        return extend
    if isinstance(extend, str) and extend.strip():
        try:
            data = json.loads(extend)
            if isinstance(data, dict):
                return data
        except Exception:
            return {}
    return {}


class Spider(BaseSpider):

    def getName(self):
        return "🔞aabook"

    def getDependence(self):
        return []

    def init(self, extend=""):
        self._jar = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._jar))
        self._ext = extend

    def destroy(self):
        pass

    def _fetch(self, url, headers=None):
        if not getattr(self, "_opener", None):
            self.init("")
        head = {"User-Agent": UA}
        if headers:
            head.update(headers)
        req = urllib.request.Request(url, headers=head)
        raw = b""
        start = time.monotonic()
        for _ in range(5):
            try:
                with self._opener.open(req, timeout=TIMEOUT) as resp:
                    raw = resp.read()
                if raw:
                    break
            except Exception:
                pass
            if time.monotonic() - start > 45:
                break
        if not raw:
            return ""
        try:
            if raw[:2] == b"\x1f\x8b":
                raw = gzip.decompress(raw)
        except Exception:
            pass
        return raw.decode("utf-8", "ignore")

    def _fetch_pages(self, urls):
        results = [""] * len(urls)
        if not urls:
            return results
        with concurrent.futures.ThreadPoolExecutor(max_workers=DETAIL_WORKERS) as ex:
            futs = [ex.submit(self._fetch, u) for u in urls]
            for i, fut in enumerate(futs):
                try:
                    results[i] = fut.result()
                except Exception:
                    results[i] = ""
        return results

    def _list_from_category(self, tid, pg, extend=None):
        ext = _norm_extend(extend)
        order = ext.get("orderBy", "-1")
        finish = ext.get("isFinish", "-1")
        size = ext.get("size", "-1")
        updt = ext.get("updT", "-1")
        url = (MOBILE + "category.html?pageNum=%s&pageSize=30&catId=%s&size=%s"
               "&isFinish=%s&updT=%s&orderBy=%s" % (pg, tid, size, finish, updt, order))
        html = self._fetch(url)
        items = []
        for block in html.split('<li class="column-2')[1:]:
            mid = re.search(r'href="book-(\d+)\.html"', block)
            name = re.search(r'<a class="name" href="book-\d+\.html">([^<]+)</a>', block)
            if not mid or not name:
                continue
            bid = mid.group(1)
            latest = re.search(r'class="chapter">([^<]+)</a>', block)
            author = re.search(r"作者：([^<\s]+)", block)
            words = re.search(r"字数：(\d+)", block)
            remarks = ""
            if latest:
                remarks = latest.group(1).strip()
            elif words:
                remarks = words.group(1) + "字"
            items.append({
                "vod_id": bid,
                "vod_name": name.group(1).strip(),
                "vod_pic": BASE + "/img-%s.jpg" % bid,
                "vod_remarks": remarks,
                "vod_actor": author.group(1).strip() if author else "",
            })
        pagecount = pg
        pages = [int(x) for x in re.findall(r"page=(\d+)", html)]
        if pages:
            pagecount = max(pages)
        elif len(items) >= 30:
            pagecount = pg + 1
        return {"list": items, "page": pg, "pagecount": pagecount, "limit": 30, "total": 0}

    def homeContent(self, filter):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATS]
        home = self._list_from_category("-1", 1)
        return {"class": classes, "list": home["list"], "filters": {}}

    def homeVideoContent(self):
        return self._list_from_category("-1", 1)

    def categoryContent(self, tid, pg, filter, extend):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        return self._list_from_category(tid, pg, extend)

    def _add_chapter_page(self, page, seen, chapters):
        links = re.findall(r'href="(read-\d+\.html)"[^>]*>([^<]+)</a>', page)
        fresh = 0
        for href, name in links:
            rid = re.search(r"(\d+)", href).group(1)
            if rid in seen:
                continue
            seen.add(rid)
            fresh += 1
            clean = name.strip().replace("#", " ").replace("$", " ")
            chapters.append("%s$%s" % (clean, rid))
        return fresh

    def detailContent(self, ids):
        bid = ""
        if ids:
            raw = str(ids[0])
            found = re.search(r"(\d+)", raw)
            bid = found.group(1) if found else raw
        pair = self._fetch_pages([
            MOBILE + "book-%s.html" % bid,
            MOBILE + "chapter.php?p=1&id=%s&ob=asc" % bid])
        book, first = pair[0], pair[1]
        title = re.search(r"<h2>([^<]+)</h2>", book)
        author = re.search(r"作者：([^<\s]+)", book)
        words = re.search(r"字数：(\d+)", book)
        status = re.search(r'<span class="status[^>]*>([^<]+)', book)
        chapters = []
        seen = set()
        total = 0
        opts = re.findall(r"chapter\.php\?p=(\d+)&id=%s&ob=asc" % bid, first)
        if opts:
            total = max(int(x) for x in opts)
        if total > 1:
            rest = self._fetch_pages(
                [MOBILE + "chapter.php?p=%s&id=%s&ob=asc" % (n, bid)
                 for n in range(2, total + 1)])
            for page in [first] + rest:
                if self._add_chapter_page(page, seen, chapters) == 0:
                    break
        else:
            if self._add_chapter_page(first, seen, chapters) > 0:
                p = 2
                while p <= DETAIL_MAX_PAGE:
                    batch = list(range(p, min(p + DETAIL_WORKERS, DETAIL_MAX_PAGE + 1)))
                    pages = self._fetch_pages(
                        [MOBILE + "chapter.php?p=%s&id=%s&ob=asc" % (n, bid) for n in batch])
                    stop = False
                    for page in pages:
                        if self._add_chapter_page(page, seen, chapters) == 0:
                            stop = True
                            break
                    if stop:
                        break
                    p += len(batch)
        remarks = ""
        if status:
            remarks = status.group(1).strip()
        if words:
            remarks = (remarks + " " + words.group(1) + "字").strip()
        vod = {
            "vod_id": bid,
            "vod_name": title.group(1).strip() if title else bid,
            "vod_pic": BASE + "/img-%s.jpg" % bid,
            "vod_actor": author.group(1).strip() if author else "",
            "vod_remarks": remarks,
            "vod_content": "",
            "vod_play_from": "小说",
            "vod_play_url": "#".join(chapters),
        }
        return {"list": [vod]}

    def searchContent(self, key, quick, pg="1"):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        url = (MOBILE + "search.html?page=%s&searchword=%s&ob=0"
               % (pg, urllib.parse.quote(key)))
        html = self._fetch(url)
        items = []
        blocks = html.split('<li>')[1:]
        for block in blocks:
            mid = re.search(r'href="book-(\d+)\.html" class="name"', block)
            if not mid:
                continue
            bid = mid.group(1)
            name = re.search(r'class="name"[^>]*>([^<]+)</a>', block)
            author = re.search(r'<span class="author">作者：([^<]+)</span>', block)
            status = re.search(r'<span class="status[^>]*>([^<]+)</span>', block)
            summary = re.search(r'<div class="summary">\s*(.*?)\s*</div>', block, re.S)
            items.append({
                "vod_id": bid,
                "vod_name": _clean(name.group(1)) if name else bid,
                "vod_pic": BASE + "/img-%s.jpg" % bid,
                "vod_remarks": status.group(1).strip() if status else "",
                "vod_actor": author.group(1).strip() if author else "",
                "vod_content": _clean(summary.group(1))[:200] if summary else "",
            })
        total = re.search(r"共计(\d+)页", html)
        pagecount = int(total.group(1)) if total else (pg if not items else pg + 1)
        return {"list": items, "page": pg, "pagecount": pagecount, "limit": 15, "total": 0}

    def _chapter_text(self, rid):
        read_url = MOBILE + "read-%s.html" % rid
        for _ in range(2):
            page = self._fetch(read_url)
            token = re.search(
                r'_getcontent\.php\?id="\+chapid\+"&v=([A-Za-z0-9_\-]+)', page)
            if not token:
                return "", ""
            gc = self._fetch(
                BASE + "/_getcontent.php?id=%s&v=%s" % (rid, token.group(1)),
                headers={"Referer": read_url,
                         "X-Requested-With": "XMLHttpRequest"})
            if "aabook_readfile" not in gc[:200]:
                continue
            paras = re.findall(r"<p>(.*?)</p>", gc, re.S)
            lines = [_clean(p) for p in paras]
            lines = [ln for ln in lines if ln]
            title = re.search(r"<title>([^<]*)</title>", page)
            name = title.group(1).strip() if title else ""
            if "在线全文阅读" in name:
                name = name.split("在线全文阅读")[0].strip()
            return name, "\n".join(lines)
        return "", ""

    def playerContent(self, flag, id, vipFlags):
        found = re.search(r"(\d+)", str(id))
        rid = found.group(1) if found else str(id)
        name, text = self._chapter_text(rid)
        if not text:
            return {"parse": 0, "url": "", "header": {}}
        payload = json.dumps({"title": name, "content": text}, ensure_ascii=False)
        return {"parse": 0, "url": "novel://" + payload, "header": {}}

    def localProxy(self, param):
        return [200, "application/octet-stream", "", ""]

    def isVideoFormat(self, url):
        if not url:
            return False
        low = url.lower()
        if low.startswith("novel://") or low.startswith("pics://"):
            return False
        return any(low.split("?")[0].endswith(ext) for ext in
                   (".mp4", ".m3u8", ".flv", ".mkv", ".avi", ".mov", ".webm"))

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None
