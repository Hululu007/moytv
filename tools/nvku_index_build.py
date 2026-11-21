"""生成 nvku 站点的番号索引（给内置源做秒搜用）。

站上 32.2 万条全在 62 个分片 js 里，没有服务端搜索。做法：把所有分片
拉一遍，抽 (番号, 分类, 段号, 段内偏移) 写成定长记录、按番号排序，客户端
二分查找 → 直接定位到那一段那一条，只取一个分片就能出详情和播放地址。

索引格式（定长 20 字节，小端）：
    code[16]  u8  cat  u8 shard  u16 offset
- code：ASCII 小写，右补 0x00；超长截断（站上最长的番号也在 16 内）
- cat：分类序号（0=有码 1=无码 2=4K … 与 meta 的 id 一致）
- shard/offset：段号与段内下标
文件头 8 字节：b"NVKI1" + count(u32)  + 另外一份 gzip。
"""
import gzip
import json
import struct
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BASE = "https://nvku-8m2c.web.zaka.live"
UA = (
    "Mozilla/5.0 (Linux; Android 13; PGT-AN10) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
)
REC = 20
CODE_MAX = 16


def get(url, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def main(out_dir="idx"):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    raw = get(BASE + "/meta.js").decode("utf-8", "replace")
    meta, _end = json.JSONDecoder().raw_decode(raw, raw.index("{"))
    cats = [(c["id"], len(c["shards"])) for c in meta["cats"]]
    jobs = []
    for cid, shards in cats:
        for i in range(shards):
            jobs.append((cid, i))
    print("分片数：", len(jobs), "总条数：", meta.get("total"), flush=True)

    records = []

    def one(job):
        cid, i = job
        key = "c%d_%d" % (cid, i)
        try:
            body = get(BASE + "/d/%s.js" % key).decode("utf-8", "replace")
        except Exception as exc:
            print("  取不到", key, exc, flush=True)
            return []
        s = body.find("[", body.find("window.SH"))
        e = body.rfind("]")
        rows = json.loads(body[s:e + 1]) if s >= 0 and e > s else []
        local = []
        for idx, rec in enumerate(rows):
            if not isinstance(rec, (list, tuple)) or len(rec) < 2:
                continue
            code = str(rec[0] or "").strip().lower()
            h = str(rec[1] or "").strip().lower()
            if not code or len(h) != 32:
                continue
            local.append((code, cid, i, idx))
        print("  %s %d 条" % (key, len(local)), flush=True)
        return local

    with ThreadPoolExecutor(max_workers=6) as pool:
        for part in pool.map(one, jobs):
            records.extend(part)

    records.sort(key=lambda r: (r[0], r[1], r[2], r[3]))
    print("合计", len(records), "条", flush=True)

    blob = bytearray()
    seen = set()
    n = 0
    for code, cid, shard, off in records:
        key = (code, cid)
        if key in seen:  # 同分类同番号只留第一条
            continue
        seen.add(key)
        raw_code = code.encode("ascii", "ignore")[:CODE_MAX]
        blob += raw_code + b"\x00" * (CODE_MAX - len(raw_code))
        blob += struct.pack("<BBH", cid & 0xFF, shard & 0xFF, off & 0xFFFF)
        n += 1

    header = b"NVKI1" + struct.pack("<I", n)
    data = header + bytes(blob)
    (out / "idx.bin").write_bytes(data)
    with gzip.open(out / "idx.bin.gz", "wb", compresslevel=9) as fh:
        fh.write(data)
    print("idx.bin", len(data), "字节 →", out / "idx.bin")
    print("idx.bin.gz", (out / "idx.bin.gz").stat().st_size, "字节")
    return n


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "idx")
