"""nvku 内置源（2026-11-21 用户令：把 https://nvku-8m2c.web.zaka.live 内置到站点列表）。

这站是一份纯静态的女优库镜像，32.2 万条、四大分类，和内置 whos 库同一套
编码（hash 直拼 hersav 的 m3u8），所以不用抓详情页、不用过盾，取一次索引
分片就能出卡、能直连播放。

站内文件结构（探站实测）：

    meta.js             window.META={total,cats:[{id,name,n,shards:[每段条数]}],an:[女优名],ac:[作品数]}
    d/new.js            window.SH("new",[记录…])   最新上架（按发行日期）
    d/c<分类>_<段>.js    window.SH("c0_0",[记录…])  每段 5000 条
    act.js              window.ACT=[头像 hash…]（本插件不用：卡片已带封面）

一条记录：`[番号, hash, 标题, 年份, 女优索引csv, 有无封面]`
- 封面  https://v.hersav.me/images/av/<hash>.jpg
- 播放  https://v.hersav.me/<hash>/<hash>.m3u8   （实测 200、标准 HLS、分段是
        伪装成 .jpeg 的 MPEG-TS，播放器直连即可，不要走代取）

分类：最新 / 有码 / 无码 / 4K / 其它（条数从 meta 里读，不写死）。
翻页：页码换算成「第几段 + 段内偏移」，跨段自动接上，不会漏条。
搜索：站上没有服务端搜索（前端是把全库索引拉到本地再筛），手机端不可能
一次拉 65MB，所以走**分段扫描**——并发取若干段，够数即停；扫描量有上限，
上限内没命中的就老实返回空，不假装搜完。
"""
import gzip
import json
import re
import ssl
import struct
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

try:
    from base.spider import BaseSpider
except Exception:
    try:
        from base import BaseSpider
    except Exception:
        class BaseSpider:
            pass


BASE = "https://nvku-8m2c.web.zaka.live"
MEDIA = "https://v.hersav.me"

# 番号索引（本站没有服务端搜索，这份是其全量番号的定长索引，按番号排序）：
# 记录 20 字节 = 番号[16] + 分类 u8 + 段号 u8 + 段内偏移 u16。
# 有它就能「按番号秒搜」：二分查到位置，只取那一段就能出详情和播放地址。
INDEX_URL = "https://nvku-idx.web.zaka.live/idx.bin.gz"
IDX_HEAD = b"NVKI1"
IDX_REC = 20
IDX_CODE = 16

UA = (
    "Mozilla/5.0 (Linux; Android 13; PGT-AN10) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
)

# 一页给播放器多少条（列表滚动续载，60 条一屏刚好）。
PAGE_SIZE = 60

# 搜索最多扫几段（每段 5000 条 ⇒ 6 万条量级，手机上大约 6–10MB）。
SEARCH_SHARD_CAP = 12

# 搜索命中多少条就提前收工。
SEARCH_HIT_STOP = 60

_SH_RE = re.compile(r'window\.SH\(\s*"([^"]+)"\s*,\s*(\[.*\])\s*\)', re.S)
_META_RE = re.compile(r'window\.META\s*=\s*(\{.*\})\s*;?\s*$', re.S)

_CACHE = {}
_CACHE_ORDER = []
_CACHE_MAX = 4

# 记录缓存与段缓存分开：列表一页 60 条会把段缓存挤爆，以前两拨共用
# 4 个槽位，导致点第 5 张卡进详情就查不到记录、标题退化成 hash。
_REC_CACHE = {}
_REC_ORDER = []
_REC_MAX = 4096

# 段缓存与分类条数：同一进程里只算一次。
_META = {}
_SH_TOTAL = {}
_LAST_ERR = ""


def _ctx():
    return ssl._create_unverified_context()


def _get(url, timeout=45):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Referer": BASE + "/",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
        return resp.read().decode("utf-8", "replace")


def _get_bytes(url, timeout=90):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Accept": "*/*",
            "Referer": BASE + "/",
            "Accept-Encoding": "identity",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as resp:
        return resp.read()


def _cache_put(key, value):
    if key.startswith("rec:"):
        _REC_CACHE[key] = value
        _REC_ORDER.append(key)
        while len(_REC_ORDER) > _REC_MAX:
            old = _REC_ORDER.pop(0)
            if old != key:
                _REC_CACHE.pop(old, None)
        return
    _CACHE[key] = value
    _CACHE_ORDER.append(key)
    while len(_CACHE_ORDER) > _CACHE_MAX:
        old = _CACHE_ORDER.pop(0)
        if old != key:
            _CACHE.pop(old, None)


def meta():
    """站点的元信息（分类、条数、女优名）。取不到回空字典，不抛。"""
    global _LAST_ERR
    if _META:
        return _META
    try:
        raw = _get(BASE + "/meta.js")
        hit = _META_RE.search(raw) or _META_RE.search(raw.strip())
        if not hit:
            i = raw.find("{")
            hit_json = raw[i:] if i >= 0 else ""
        else:
            hit_json = hit.group(1)
        if not hit_json:
            return {}
        data = json.loads(hit_json)
        _META.update(data if isinstance(data, dict) else {})
    except Exception as exc:  # 站点挂了/换域名：让上层降级，不在这里崩
        _LAST_ERR = str(exc)
        return {}
    return _META


def _shard_file(key):
    return BASE + "/d/" + key + ".js"


def shard(key):
    """取一段记录（带 LRU 缓存）。取不到回空列表。"""
    if key in _CACHE:
        return _CACHE[key]
    try:
        raw = _get(_shard_file(key))
    except Exception:
        return []
    rows = []
    hit = _SH_RE.search(raw)
    if hit:
        try:
            rows = json.loads(hit.group(2))
        except Exception:
            rows = []
    if not isinstance(rows, list):
        rows = []
    _cache_put(key, rows)
    return rows


_IDX = {"blob": b"", "n": 0, "tried": False}


def index_blob():
    """取番号索引（懒加载，进程内只下一次）。取不到回空 bytes，搜索退化成扫段。"""
    if _IDX["blob"] or _IDX["tried"]:
        return _IDX["blob"]
    _IDX["tried"] = True
    try:
        raw = _get_bytes(INDEX_URL, timeout=90)
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        if raw[:5] != IDX_HEAD:
            return b""
        count = struct.unpack("<I", raw[5:9])[0]
        blob = raw[9:]
        if len(blob) < count * IDX_REC:
            return b""
        _IDX["blob"] = blob
        _IDX["n"] = count
    except Exception:
        return b""
    return _IDX["blob"]


def _idx_code(blob, i):
    raw = blob[i * IDX_REC: i * IDX_REC + IDX_CODE]
    end = raw.find(b"\x00")
    if end >= 0:
        raw = raw[:end]
    return raw.decode("ascii", "ignore")


def _idx_pos(blob, i):
    cat, shard, off = struct.unpack("<BBH", blob[i * IDX_REC + IDX_CODE: i * IDX_REC + IDX_REC])
    return cat, shard, off


def _idx_lower(blob, code):
    """第一个 >= code 的下标。"""
    lo, hi = 0, _IDX["n"]
    while lo < hi:
        mid = (lo + hi) // 2
        if _idx_code(blob, mid) < code:
            lo = mid + 1
        else:
            hi = mid
    return lo


def index_lookup(keyword, limit=60):
    """按番号（可只给前缀）查位置：[(番号, 分类, 段号, 偏移)]。"""
    blob = index_blob()
    if not blob:
        return []
    key = (keyword or "").strip().lower()
    if not key:
        return []
    i = _idx_lower(blob, key)
    out = []
    while i < _IDX["n"] and len(out) < limit:
        code = _idx_code(blob, i)
        if not code.startswith(key):
            break
        cat, shard, off = _idx_pos(blob, i)
        out.append((code, cat, shard, off))
        i += 1
    return out


def rows_at(positions):
    """按索引位置取记录：同段合并成一次请求。"""
    by_shard = {}
    for code, cat, shard_idx, off in positions:
        by_shard.setdefault(("c%d" % cat, shard_idx), []).append((off, code))
    out = []
    for (cid, shard_idx), wanted in by_shard.items():
        rows = shard(_shard_key(cid, shard_idx))
        for off, code in sorted(wanted):
            if 0 <= off < len(rows):
                rec = rows[off]
                if isinstance(rec, (list, tuple)) and _code_of(rec).lower() == code:
                    out.append(rec)
    return out


def _cats():
    """[(分类 id, 名字, 段数, 条数)]，最新排最前。条数从 meta 读，不写死。"""
    m = meta()
    out = [("new", "最新上架", 1, 0)]
    for cat in m.get("cats") or []:
        try:
            cid = int(cat.get("id"))
            name = str(cat.get("name") or "").strip()
            shards = cat.get("shards") or []
            try:
                count = int(cat.get("n") or 0)
            except Exception:
                count = 0
            out.append(
                ("c%d" % cid, name or ("分类%d" % cid), max(1, len(shards)), count)
            )
        except Exception:
            continue
    return out


def _cat_index(tid):
    """分类 id → (分类 id, 段数, 条数)。认不出就当最新。"""
    tid = str(tid or "").strip()
    if not tid or tid == "new":
        return "new", 1, 0
    for cid, _name, shards, count in _cats():
        if cid == tid:
            return cid, shards, count
    return "new", 1, 0


def _shard_key(cid, index):
    return "new" if cid == "new" else "%s_%d" % (cid, index)


def _rows_for_page(cid, shards, pg):
    """页码 → 段内切片（跨段补齐）。"""
    start = (pg - 1) * PAGE_SIZE
    out = []
    idx = start // 5000
    off = start % 5000
    guard = 0
    while len(out) < PAGE_SIZE and idx < shards and guard < 4:
        guard += 1
        rows = shard(_shard_key(cid, idx))
        if not rows:
            break
        out.extend(rows[off: off + (PAGE_SIZE - len(out))])
        idx += 1
        off = 0
    return out


def _code_of(rec):
    return str(rec[0] or "").strip() if len(rec) > 0 else ""


def _hash_of(rec):
    h = str(rec[1] or "").strip() if len(rec) > 1 else ""
    return h if re.match(r"^[0-9a-fA-F]{16,64}$", h) else ""


def _title_of(rec):
    title = str(rec[2] or "").strip() if len(rec) > 2 else ""
    return title or _code_of(rec)


def _year_of(rec):
    raw = str(rec[3] or "").strip() if len(rec) > 3 else ""
    # 站里存的是两位年（26 = 2026），补成四位好看一点。
    if re.match(r"^\d{2}$", raw):
        return "20" + raw
    return raw


def _has_img(rec):
    try:
        return bool(int(rec[5]))
    except Exception:
        return len(rec) > 5 and bool(rec[5])


def _actor_names(rec):
    if len(rec) <= 4:
        return ""
    raw = str(rec[4] or "").strip()
    if not raw:
        return ""
    names = (meta().get("an") or [])
    out = []
    for piece in raw.split(","):
        piece = piece.strip()
        if not piece:
            continue
        try:
            i = int(piece)
        except Exception:
            continue
        if 0 <= i < len(names):
            name = str(names[i] or "").strip()
            if name and name not in out:
                out.append(name)
        if len(out) >= 6:
            break
    return ",".join(out)


def play_url(h):
    return MEDIA + "/" + h + "/" + h + ".m3u8"


def cover_url(h):
    return MEDIA + "/images/av/" + h + ".jpg"


def _item(rec):
    code = _code_of(rec)
    h = _hash_of(rec)
    if not h:
        return None
    title = _title_of(rec)
    year = _year_of(rec)
    item = {
        # vod_id 带上番号：详情页冷启动（进程重启、缓存被挤掉）时还能按
        # 番号回索引把整条记录捞回来，标题/演员/分类不丢。只带 hash 的话
        # 冷启动后标题只能显示那串 hash。
        "vod_id": ("nvku:%s:%s" % (code, h)) if code else ("nvku:" + h),
        "vod_name": title,
        "vod_pic": cover_url(h) if _has_img(rec) else "",
        "vod_remarks": " ".join([x for x in [code, year] if x]).strip(),
        "vod_content": "<p>%s</p><p>%s</p>" % (code or "nvku", title),
        "vod_play_from": "nvku",
        "vod_play_url": "正片$" + play_url(h),
    }
    actors = _actor_names(rec)
    if actors:
        item["vod_actor"] = actors
    if year:
        item["vod_year"] = year
    return item


def _remember(rec, item):
    if item:
        # 双键写入：详情页无论拿到 vod_id 还是裸 hash 都能命中。
        h = _hash_of(rec)
        if h:
            _cache_put("rec:nvku:" + h, rec)
        _cache_put("rec:" + item["vod_id"], rec)


def _items(rows):
    out = []
    for rec in rows:
        if not isinstance(rec, (list, tuple)):
            continue
        item = _item(rec)
        if not item:
            continue
        _remember(rec, item)
        out.append(item)
    return out


def _code_like(kw):
    """像番号的查询：字母+数字（ssis-970、juq5582、fc2ppv-4913308）。"""
    tight = re.sub(r"[\s_-]", "", kw or "")
    return bool(re.match(r"^[a-z0-9]{4,16}$", tight)) and bool(
        re.search(r"[a-z]", tight) and re.search(r"\d", tight)
    ) and bool(re.search(r"[a-z]{2,}", tight))


def _search_by_index(keyword, pg):
    """番号搜索：查索引 → 只取命中的那几段。索引不可用回 []。"""
    kw = (keyword or "").strip().lower()
    tight = re.sub(r"[\s_-]", "", kw)
    hits = []
    for probe in {kw, tight}:
        if probe:
            hits = index_lookup(probe, limit=SEARCH_HIT_STOP * 2)
            if hits:
                break
    if not hits:
        return []
    items = []
    for rec in rows_at(hits):
        item = _item(rec)
        if not item:
            continue
        _remember(rec, item)
        items.append(item)
        if len(items) >= SEARCH_HIT_STOP:
            break
    start = (pg - 1) * PAGE_SIZE
    return items[start: start + PAGE_SIZE]


def _search(keyword, pg):
    kw = (keyword or "").strip().lower()
    if not kw:
        return []
    kw_tight = kw.replace("-", "").replace("_", "").replace(" ", "")
    if _code_like(kw):
        fast = _search_by_index(keyword, pg)
        if fast:
            return fast
        # 索引是全量的：索引里没有就是真没有，不必再扫段，省流量也省时间。
        if _IDX["n"]:
            return []
    cats = _cats()
    order = [c for c in cats if c[0] == "new"] + [c for c in cats if c[0] != "new"]
    jobs = []
    for cid, _name, shards, _count in order:
        for i in range(shards):
            jobs.append(_shard_key(cid, i))
    jobs = jobs[:SEARCH_SHARD_CAP]
    hits = []
    seen = set()

    def scan(key):
        found = []
        for rec in shard(key):
            if not isinstance(rec, (list, tuple)):
                continue
            code = _code_of(rec).lower()
            title = _title_of(rec).lower()
            actors = _actor_names(rec).lower()
            tight = code.replace("-", "").replace("_", "").replace(" ", "")
            if (
                (kw and (kw in code or kw in title or kw in actors))
                or (kw_tight and kw_tight in tight)
                or (kw_tight and kw_tight in title.replace(" ", ""))
            ):
                found.append(rec)
                if len(found) >= SEARCH_HIT_STOP:
                    break
        return found

    if jobs:
        with ThreadPoolExecutor(max_workers=4) as pool:
            for found in pool.map(scan, jobs):
                for rec in found:
                    h = _hash_of(rec)
                    if not h or h in seen:
                        continue
                    seen.add(h)
                    hits.append(rec)
                    if len(hits) >= SEARCH_HIT_STOP:
                        break
                if len(hits) >= SEARCH_HIT_STOP:
                    break
    items = []
    for rec in hits:
        item = _item(rec)
        if item:
            _remember(rec, item)
            items.append(item)
    start = (pg - 1) * PAGE_SIZE
    return items[start: start + PAGE_SIZE]


class Spider(BaseSpider):
    def getName(self):
        return "nvku"

    def getDependence(self):
        return []

    def init(self, extend=""):
        return

    def destroy(self):
        return

    def homeContent(self, filter=""):
        try:
            m = meta()
            total = int(m.get("total") or 0)
        except Exception:
            total = 0
        classes = []
        for cid, name, _shards, count in _cats():
            label = name if not count else "%s · %d" % (name, count)
            classes.append({"type_id": cid, "type_name": label})
        rows = shard("new")[:PAGE_SIZE]
        return {"class": classes, "list": _items(rows)}

    def homeVideoContent(self):
        rows = shard("new")[:PAGE_SIZE]
        items = _items(rows)
        return {"list": items, "page": 1, "pagecount": 9999, "total": len(items)}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            pg = int(pg or 1)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        cid, shards, count = _cat_index(tid)
        rows = _rows_for_page(cid, shards, pg)
        items = _items(rows)
        if cid == "new" or count <= 0:
            pagecount = 1 if pg == 1 else pg
        else:
            pagecount = max(1, (count + PAGE_SIZE - 1) // PAGE_SIZE)
        return {
            "list": items,
            "page": pg,
            "pagecount": pagecount if items else pg,
            "total": len(items),
        }

    def _record_by_code(self, code, h):
        """按番号回索引精确取记录：详情页冷启动时的兜底。"""
        code = (code or "").strip().lower()
        if not code:
            return None
        try:
            for hit_code, cat, shard_idx, off in index_lookup(code, limit=8):
                if hit_code != code:
                    continue
                rows = shard(_shard_key("c%d" % cat, shard_idx))
                if 0 <= off < len(rows):
                    rec = rows[off]
                    if isinstance(rec, (list, tuple)) and _hash_of(rec) == h:
                        return rec
        except Exception:
            return None
        return None

    def detailContent(self, ids):
        raw = ids[0] if isinstance(ids, (list, tuple)) and ids else ids
        key = str(raw or "").strip()
        if key.startswith("nvku:"):
            key = key[5:]
        if not key:
            return {"list": []}
        code, h = "", ""
        if ":" in key:
            # 新格式 code:hash（见 _item）：番号在手，冷启动也能回查。
            code, _, h = key.partition(":")
            code, h = code.strip(), h.strip()
        elif re.match(r"^[0-9a-fA-F]{16,64}$", key):
            h = key.strip()
        if not h or not re.match(r"^[0-9a-fA-F]{16,64}$", h):
            return {"list": []}
        rec = _REC_CACHE.get("rec:nvku:" + h)
        if not rec and code:
            rec = _REC_CACHE.get("rec:nvku:%s:%s" % (code, h))
        if not rec and code:
            rec = self._record_by_code(code, h)
        if rec:
            item = _item(rec)
            if item:
                _remember(rec, item)
                return {"list": [item]}
        # 兜底：整条记录确实捞不回来时，标题也绝不拿那串 hash 顶上
        # （以前详情页标题就是一串 32 位十六进制）。有番号用番号。
        return {
            "list": [
                {
                    "vod_id": ("nvku:%s:%s" % (code, h)) if code else ("nvku:" + h),
                    "vod_name": code or "高清视频",
                    "vod_pic": cover_url(h),
                    "vod_remarks": code or "高清",
                    "vod_content": "<p>%s</p>" % (code or "nvku"),
                    "vod_play_from": "nvku",
                    "vod_play_url": "正片$" + play_url(h),
                }
            ]
        }

    def searchContent(self, key, quick=False, pg=1):
        try:
            pg = int(pg or 1)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        items = _search(key, pg)
        return {
            "list": items,
            "page": pg,
            "pagecount": 1 if pg == 1 and not items else 9999,
            "total": len(items),
        }

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "").strip()
        if raw.startswith("nvku:"):
            raw = raw[5:]
        if ":" in raw:
            # vod_id 是 code:hash（见 _item / detailContent），播放只认 hash。
            raw = raw.rsplit(":", 1)[-1].strip()
        url = raw if raw.startswith("http") else (
            play_url(raw) if re.match(r"^[0-9a-fA-F]{16,64}$", raw) else ""
        )
        if not url:
            return {"parse": 0, "playUrl": "", "url": "", "header": {}}
        return {
            "parse": 0,
            "playUrl": url,
            "url": url,
            "header": {"User-Agent": UA, "Referer": MEDIA + "/"},
        }

    def isVideoFormat(self, url):
        return ".m3u8" in str(url or "")

    def manualVideoCheck(self):
        return False
