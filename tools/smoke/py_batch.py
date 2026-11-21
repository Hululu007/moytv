#!/usr/bin/env python3
"""批量跑 py 蜘蛛 homeContent 冒烟，低并发避免本机出口限流。"""
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

SITES = json.load(open("tools/smoke/pysites.json"))


def run(item):
    asset = item["asset"]
    r = {"id": item["id"], "asset": asset}
    try:
        p = subprocess.run(
            [sys.executable, "tools/smoke/spyder_smoke_one.py", asset],
            capture_output=True, text=True, timeout=90,
        )
        line = [x for x in p.stdout.strip().splitlines() if x.startswith("{")]
        if line:
            r.update(json.loads(line[-1]))
        else:
            r.update(ok=False, stage="crash", err=(p.stderr or "")[-300:])
    except subprocess.TimeoutExpired:
        r.update(ok=False, stage="timeout", err="hard_timeout_90s")
    r["site_id"] = item["id"]
    return r


def main():
    out = []
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=4) as ex:
        for i, r in enumerate(ex.map(run, SITES), 1):
            out.append(r)
            flag = "OK " if r.get("ok") else "ERR"
            print("[%d/%d] %s %-16s cls=%-3s items=%-3s %s %s" % (
                i, len(SITES), flag, r["id"], r.get("classes", "-"), r.get("items", "-"),
                str(r.get("elapsed", "")), (r.get("stage") if not r.get("ok") else "") + " " + str(r.get("err", ""))[:90]
            ), flush=True)
    json.dump(out, open("tools/smoke/py_results.json", "w"), ensure_ascii=False, indent=1)
    ok = sum(1 for r in out if r.get("ok"))
    print("\npy spiders: ok=%d / %d  (%.0fs)" % (ok, len(out), time.time() - t0))


if __name__ == "__main__":
    main()
