import json
import re
import threading
import time
import urllib.parse
import urllib.request

try:
    import requests
except Exception:
    requests = None

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider(object):
        pass

HOST = "https://www.ximalaya.com"
MOBILE = "https://mobile.ximalaya.com"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
UA_M = ("Mozilla/5.0 (Linux; Android 12; Build/SP1A.210812.016) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
IMG = "https://imagev2.xmcdn.com/"

PER_PAGE = 200

SORTS = [("最热", "0"), ("最新", "2"), ("最赞", "3")]

CATEGORIES = [
    ("3", "有声书"), ("2", "音乐"), ("12", "相声评书"), ("4", "娱乐"),
    ("6", "儿童"), ("9", "历史"), ("8", "商业财经"), ("13", "个人成长"),
    ("5", "外语"), ("15", "广播剧"),
]

HEADERS = {
    "User-Agent": UA,
    "Referer": HOST + "/",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "zh-CN,zh;q=0.9",
}

HEADERS_M = {
    "User-Agent": UA_M,
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "device": "android",
}


def _fix_img(p):
    if not p:
        return ""
    p = str(p)
    if p.startswith("http://") or p.startswith("https://"):
        return p.replace("http://", "https://", 1)
    if p.startswith("//"):
        return "https:" + p
    return IMG + p.lstrip("/")


def _dur(sec):
    try:
        sec = int(float(sec))
    except Exception:
        return ""
    h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
    if h:
        return "%d:%02d:%02d" % (h, m, s)
    return "%d:%02d" % (m, s)


def _pick_url(t):
    for k in ("playUrl64", "playUrl32", "playPathAacv224", "playPathAacv164", "playPathHq"):
        v = t.get(k)
        if v and str(v).startswith("http"):
            return str(v)
    return ""


def _as_dict(extend):
    if isinstance(extend, dict):
        return extend
    if isinstance(extend, str) and extend.strip():
        try:
            v = json.loads(extend)
            return v if isinstance(v, dict) else {}
        except Exception:
            return {}
    return {}


class Spider(BaseSpider):

    def __init__(self):
        self.cookie = ""
        self.max_tracks = 0
        self.timeout = 12
        self.proxy = None
        self.per_page = PER_PAGE
        self.split = 0
        self._sess = None
        self._sess_m = None
        self._cache = {}
        self._filters = {}
        self._dev = {}

    def init(self, extend=""):
        ext = _as_dict(extend)
        self.cookie = str(ext.get("cookie") or "").strip()
        try:
            self.max_tracks = max(0, int(ext.get("maxTracks") or 0))
        except Exception:
            self.max_tracks = 0
        try:
            self.per_page = max(20, min(PER_PAGE, int(ext.get("perPage") or PER_PAGE)))
        except Exception:
            self.per_page = PER_PAGE
        try:
            self.split = max(0, int(ext.get("split") or 0))
        except Exception:
            self.split = 0
        self.proxy = ext.get("proxy") or None
        if requests is not None:
            for name, hdrs in (("_sess", HEADERS), ("_sess_m", HEADERS_M)):
                s = requests.Session()
                s.headers.update(hdrs)
                if self.cookie:
                    s.headers["Cookie"] = self.cookie
                if self.proxy:
                    s.proxies = {"http": self.proxy, "https": self.proxy}
                setattr(self, name, s)
        return self

    def getName(self):
        return "喜马拉雅"

    def _get(self, url, mobile=False, ttl=None):
        if url in self._cache:
            return self._cache[url]
        last = None
        for attempt in range(3):
            try:
                data = self._fetch_once(url, mobile, ttl)
                if len(self._cache) < 600:
                    self._cache[url] = data
                return data
            except Exception as e:
                last = e
                time.sleep(0.25 * (attempt + 1))
        raise last

    def _fetch_once(self, url, mobile=False, ttl=None):
        sess = self._sess_m if mobile else self._sess
        if sess is not None:
            r = sess.get(url, timeout=ttl or self.timeout)
            r.raise_for_status()
            return json.loads(r.text)
        headers = dict(HEADERS_M if mobile else HEADERS)
        if self.cookie:
            headers["Cookie"] = self.cookie
        req = urllib.request.Request(url, headers=headers)
        opener = urllib.request.urlopen
        if self.proxy:
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({"http": self.proxy, "https": self.proxy})).open
        return json.loads(opener(req, timeout=ttl or self.timeout).read().decode("utf-8", "ignore"))

    def _walk_meta(self, nodes, depth, types, tags):
        for n in nodes or []:
            if not isinstance(n, dict):
                continue
            name = n.get("name") or n.get("displayName") or ""
            subs = n.get("metadataValues") or []
            if depth == 2 and name:
                types.append(name)
            if depth >= 3 and name and not subs:
                tags.append(name)
            if subs:
                self._walk_meta(subs, depth + 1, types, tags)

    def _filters_for(self, cid):
        out = [{"key": "sort", "name": "排序",
                "value": [{"n": n, "v": v} for n, v in SORTS]}]
        types, tags = [], []
        try:
            d = self._get("%s/revision/category/v2/metadata/info?categoryId=%s" % (HOST, cid),
                          ttl=6)
            self._walk_meta((d.get("data") or {}).get("metadata") or [], 1, types, tags)
        except Exception:
            pass
        def _uniq(seq, cap):
            seen, res = set(), []
            for x in seq:
                x = str(x).strip()
                if x and x not in seen:
                    seen.add(x)
                    res.append(x)
                if len(res) >= cap:
                    break
            return res
        types = _uniq(types, 40)
        tags = _uniq(tags, 120)
        if types:
            out.append({"key": "cat", "name": "分类",
                        "value": [{"n": "全部", "v": ""}] +
                                 [{"n": t, "v": t} for t in types]})
        if tags:
            out.append({"key": "tag", "name": "题材",
                        "value": [{"n": "全部", "v": ""}] +
                                 [{"n": t, "v": t} for t in tags]})
        return out

    def _all_filters(self):
        if self._filters:
            return self._filters
        cids = [c[0] for c in CATEGORIES]

        def work(batch):
            for cid in batch:
                try:
                    self._filters[cid] = self._filters_for(cid)
                except Exception:
                    self._filters[cid] = None

        batches = [cids[i:i + 6] for i in range(0, len(cids), 6)]
        for b in batches:
            ths = [threading.Thread(target=work, args=([cid],)) for cid in b]
            for t in ths:
                t.daemon = True
                t.start()
            for t in ths:
                t.join(6)
        return self._filters

    def homeContent(self, filter=False):
        classes = [{"type_id": cid, "type_name": name} for cid, name in CATEGORIES]
        try:
            filters = self._all_filters()
        except Exception:
            filters = {}
        filters = {k: v for k, v in (filters or {}).items() if v}
        for cid, _ in CATEGORIES:
            filters.setdefault(cid, [{"key": "sort", "name": "排序",
                                      "value": [{"n": n, "v": v} for n, v in SORTS]}])
        return {"class": classes, "filters": filters, "list": self._feed("3", 1, 30, "0")}

    def _feed(self, cid, pg, size, sort="0", meta=""):
        url = "%s/revision/category/v2/albums?categoryId=%s&pageNum=%s&pageSize=%s&sort=%s" % (
            HOST, cid, pg, size, sort)
        if meta:
            url += "&metadataValues=" + urllib.parse.quote(meta)
        try:
            d = self._get(url, ttl=10)["data"] or {}
        except Exception:
            return []
        out = []
        for a in d.get("albums") or []:
            paid = "【VIP】" if a.get("isPaid") else ""
            out.append({
                "vod_id": str(a.get("albumId")),
                "vod_name": paid + str(a.get("albumTitle") or ""),
                "vod_pic": _fix_img(a.get("albumCoverPath")),
                "vod_remarks": "%s集" % (a.get("albumTrackCount") or "?"),
                "vod_content": str(a.get("intro") or ""),
            })
        return out

    def homeVod(self):
        return {"list": self._feed("3", 1, 30, "0")}

    def categoryContent(self, tid, pg, filter, extend):
        ext = _as_dict(extend)
        sort = str(ext.get("sort") or "0")
        if sort not in ("0", "2", "3"):
            sort = "0"
        cat = str(ext.get("cat") or "").strip()
        tag = str(ext.get("tag") or "").strip()
        meta = ",".join([x for x in (cat, tag) if x])
        tid = str(tid).split("|")[0]
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        items = self._feed(tid, pg, 30, sort, meta)
        if not items and meta:
            items = self._feed(tid, pg, 30, sort, cat)
        return {"page": pg, "pagecount": 999 if items else pg,
                "limit": 30, "total": 999 * 30, "list": items}

    def searchContent(self, key, quick=False):
        kw = urllib.parse.quote(str(key or "").strip())
        url = ("%s/revision/search/seo?core=album&kw=%s&page=1&spellchecker=true"
               "&rows=30&condition=relation&device=iPhone") % (HOST, kw)
        out = []
        try:
            docs = self._get(url, ttl=10)["data"]["album"]["docs"]
        except Exception:
            docs = []
        for a in docs:
            paid = "【VIP】" if a.get("isPaid") else ""
            out.append({
                "vod_id": str(a.get("albumId")),
                "vod_name": paid + str(a.get("title") or ""),
                "vod_pic": _fix_img(a.get("coverPath")),
                "vod_remarks": str(a.get("nickname") or ""),
                "vod_content": str(a.get("intro") or ""),
            })
        return {"list": out}

    def _album_meta(self, aid):
        meta = {"title": "", "cover": "", "intro": "", "paid": False, "total": 0, "nick": ""}
        try:
            d = self._get("%s/m-revision/page/album/queryAlbumPage/%s?page=1&pageSize=30"
                          % (HOST, aid), ttl=10)["data"] or {}
            info = (d.get("albumDetailInfo") or {}).get("albumInfo") or {}
            meta["title"] = info.get("title") or info.get("albumTitle") or ""
            meta["cover"] = info.get("cover") or ""
            meta["intro"] = str(info.get("shortIntro") or info.get("intro") or "")
            meta["total"] = info.get("trackCount") or 0
            if d.get("albumPayType") or d.get("albumVipPayType"):
                meta["paid"] = True
            anchor = d.get("anchorInfo") or {}
            meta["nick"] = anchor.get("nickname") or ""
        except Exception:
            pass
        if not meta["title"]:
            try:
                t = self._get("%s/tdk-web/seo/search/albumInfo?albumId=%s" % (HOST, aid),
                              ttl=8)["data"] or {}
                meta["title"] = t.get("albumTitle") or ""
                meta["cover"] = meta["cover"] or t.get("albumCoverPath") or ""
                meta["intro"] = meta["intro"] or str(t.get("albumIntro") or "")
            except Exception:
                pass
        return meta

    def _fetch_page(self, aid, page, size, dev):
        url = ("%s/mobile/others/ca/album/track/%s/true/%d/%d?device=%s"
               % (MOBILE, aid, page, size, dev))
        try:
            d = self._get(url, mobile=True, ttl=10)
        except Exception:
            return None, 0
        tr = d.get("tracks") or {}
        return (tr.get("list") or []), (tr.get("maxPageId") or 1)

    def _page_tracks(self, aid, page, size=None):
        size = size or self.per_page
        devs = []
        hint = self._dev.get(str(aid))
        if hint:
            devs.append(hint)
        for d in ("android", "ios"):
            if d not in devs:
                devs.append(d)
        best = None
        for dev in devs:
            lst, maxp = self._fetch_page(aid, page, size, dev)
            if lst is None:
                continue
            if best is None:
                best = (lst, maxp)
            if any(_pick_url(t) for t in lst):
                self._dev[str(aid)] = dev
                return lst, maxp
        return best if best else (None, 0)

    def _tracks(self, aid, limit=None):
        cap = self.max_tracks if limit is None else limit
        out = []
        page = 1
        maxp = 1
        while page <= 60:
            lst, maxp = self._page_tracks(aid, page)
            if lst is None:
                break
            if not lst:
                break
            for t in lst:
                out.append({
                    "id": t.get("trackId"),
                    "title": str(t.get("title") or ""),
                    "dur": t.get("duration"),
                    "paid": bool(t.get("isPaid")),
                    "idx": len(out),
                    "url": _pick_url(t),
                })
                if cap and len(out) >= cap:
                    return out
            if page >= maxp:
                break
            page += 1
        return out

    def _url_at(self, aid, idx, tid):
        if idx is not None and idx >= 0:
            page = idx // self.per_page + 1
            lst, _ = self._page_tracks(aid, page)
            for t in lst or []:
                if str(t.get("trackId")) == str(tid):
                    u = _pick_url(t)
                    if u:
                        return u
        page = 1
        maxp = 1
        while page <= 60:
            lst, maxp = self._page_tracks(aid, page)
            if not lst:
                break
            for t in lst:
                if str(t.get("trackId")) == str(tid):
                    u = _pick_url(t)
                    if u:
                        return u
            if page >= maxp:
                break
            page += 1
        return None

    def _alt_album(self, title, self_id):
        kw = self._clean_kw(title)
        if not kw:
            return None
        url = ("%s/revision/search/seo?core=album&kw=%s&page=1&spellchecker=true"
               "&rows=20&condition=relation&device=iPhone") % (HOST, urllib.parse.quote(kw))
        try:
            docs = self._get(url, ttl=8)["data"]["album"]["docs"]
        except Exception:
            return None
        head = kw.split(" ")[0]
        tried = 0
        for a in docs:
            aid = str(a.get("albumId") or "")
            if not aid or aid == str(self_id) or a.get("isPaid"):
                continue
            at = str(a.get("title") or "")
            pos = at.find(head)
            if pos < 0 or pos > 8:
                continue
            tried += 1
            if tried > 4:
                break
            tr = self._tracks(aid, limit=2000)
            live = [t for t in tr if t.get("url")]
            if len(live) >= 2:
                return at, live, aid
        return None

    def _join(self, tracks, aid):
        def one(group):
            segs = []
            for i, t in enumerate(group):
                label = "第%d集 %s" % (t.get("idx", i) + 1,
                                      re.sub(r"\s+", " ", t["title"])[:38])
                segs.append("%s$%s_%s_%s" % (label, aid, t.get("idx", i), t.get("id")))
            return "#".join(segs)

        if self.split and len(tracks) > self.split:
            parts = [tracks[i:i + self.split] for i in range(0, len(tracks), self.split)]
            return "$$$".join(one(p) for p in parts)
        return one(tracks)

    def detailContent(self, ids):
        aid = str(ids[0] if isinstance(ids, list) else ids).strip()
        meta = self._album_meta(aid)
        tracks = self._tracks(aid)
        content = meta["intro"] or ""
        live = sum(1 for t in tracks if t.get("url"))
        if tracks:
            if live >= len(tracks):
                content += "\n【共 %d 集，音源全部已解析，直接点就听】" % len(tracks)
            elif live == 0:
                content += "\n【共 %d 集，播放时自动解析音源】" % len(tracks)
            else:
                content += ("\n【共 %d 集，其中 %d 集可直接播放；其余为会员专属，"
                            "填 cookie 后全解锁】" % (len(tracks), live))
        else:
            content += "\n（未取到曲目，可能专辑已下架或在审核中）"
        if tracks and live < len(tracks):
            content = "【VIP/付费专辑】\n" + content

        names = ["喜马拉雅"]
        urls = [self._join(tracks, aid)]
        if self.split and len(tracks) > self.split:
            names = ["喜马拉雅%d-%d" % (i + 1, min(i + self.split, len(tracks)))
                     for i in range(0, len(tracks), self.split)]
        if tracks and live < len(tracks):
            try:
                alt = self._alt_album(meta["title"], aid)
            except Exception:
                alt = None
            if alt:
                names.append("免费同书")
                urls.append(self._join(alt[1], alt[2]))
                content += ("\n【备用线路：站内同名免费专辑《%s》，%d 集可直听】"
                            % (alt[0][:26], len(alt[1])))
        vod = {
            "vod_id": aid,
            "vod_name": meta["title"] or ("专辑 " + aid),
            "vod_pic": _fix_img(meta["cover"]),
            "vod_content": content,
            "vod_remarks": (("%s · " % meta["nick"]) if meta["nick"] else "") + "%d集" % len(tracks),
            "vod_play_from": "$$$".join(names),
            "vod_play_url": "$$$".join(urls),
        }
        return {"list": [vod]}

    def _web_free_url(self, tid):
        try:
            d = self._get("%s/revision/play/tracks?trackIds=%s" % (HOST, tid), ttl=8)
            arr = (d.get("data") or {}).get("tracksForAudioPlay") or []
            if arr and arr[0].get("src"):
                return arr[0]["src"]
        except Exception:
            pass
        return None

    def _clean_kw(self, title):
        t = re.sub(r"【[^】]*】|\[[^\]]*\]|（[^）]*）|\([^)]*\)", " ", str(title))
        t = re.sub(r"[丨|｜·、,，.。:：!！?？\"'“”/\\-]+", " ", t)
        t = re.sub(r"(?i)vip|免费|多人有声剧|有声剧|有声书|演播|出品|独家|完结|全集|首发", " ", t)
        parts = [p for p in re.sub(r"\s+", " ", t).split(" ") if len(p) >= 2]
        return " ".join(parts[:2])[:16]

    def _free_alt(self, title):
        kw = self._clean_kw(title)
        if not kw:
            return None
        url = ("%s/revision/search/seo?core=track&kw=%s&page=1&rows=20&spellchecker=true"
               "&condition=relation&device=iPhone") % (HOST, urllib.parse.quote(kw))
        try:
            docs = self._get(url, ttl=8)["data"]["track"]["docs"]
        except Exception:
            return None
        for d in [x for x in docs if not x.get("isPaid")][:6]:
            src = self._web_free_url(d.get("id"))
            if src:
                return src
        return None

    def playerContent(self, flag, did, vipFlags):
        did = str(did).strip()
        aid, idx, tid = "", None, did
        parts = did.split("_")
        if len(parts) == 3:
            aid, idx, tid = parts[0], parts[1], parts[2]
            idx = int(idx) if idx.isdigit() else None
        elif len(parts) == 2:
            aid, tid = parts[0], parts[1]
        hdr = {"User-Agent": UA, "Referer": HOST + "/"}
        if not str(tid).isdigit():
            return {"parse": 0, "playUrl": "", "url": "", "header": hdr, "msg": "参数不对"}

        if aid.isdigit():
            url = self._url_at(aid, idx, tid)
            if url:
                return {"parse": 0, "playUrl": "", "url": url, "header": hdr}
        url = self._web_free_url(tid)
        if url:
            return {"parse": 0, "playUrl": "", "url": url, "header": hdr}
        title = ""
        try:
            d = self._get("%s/m-revision/page/track/queryTrackPage/%s" % (HOST, tid), ttl=8)
            ti = ((d.get("data") or {}).get("trackDetailInfo") or {}).get("trackInfo") or {}
            title = ti.get("title") or ""
        except Exception:
            pass
        alt = self._free_alt(title) if title else None
        if alt:
            return {"parse": 0, "playUrl": "", "url": alt, "header": hdr}
        return {"parse": 0, "playUrl": "", "url": "", "header": hdr,
                "msg": "这集没取到地址，退出详情页重进一次再试"}

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def localProxy(self, param):
        return None

    def destroy(self):
        self._cache = {}
