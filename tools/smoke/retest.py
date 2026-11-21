#!/usr/bin/env python3
"""对首轮失败的站做低并发复测（首轮大批并发把本机出口打限流了，
那些 429/502 是假失败）。串行 + 长间隔 + 重试，结果合并回 results.json。
"""
import json, time, sys
sys.path.insert(0, "tools/smoke")
from smoke import probe, classify

SUSPECT_ERRS = {"conn", "timeout"}


def main():
    rs = json.load(open("tools/smoke/results.json"))
    todo = [r for r in rs if r["class"] in SUSPECT_ERRS
            or r["class"] in ("http_403", "cf_403", "http_500", "thin_page", "http_404", "cf_block")]
    print("retest", len(todo), flush=True)
    fixed = 0
    for i, r in enumerate(todo, 1):
        home = r["home"]
        res = None
        for attempt in range(3):
            res = probe(home, timeout=25)
            cls = classify(res)
            if cls != "conn" and cls != "timeout":
                break
            detail = (res.get("detail") or "")
            if "429" in detail or "502" in detail or "503" in detail:
                time.sleep(4 * (attempt + 1))
                continue
            break
        cls = classify(res)
        old = r["class"]
        r.update({
            "class": cls, "status": res.get("status"), "elapsed": res.get("elapsed"),
            "server": res.get("server"), "cf_ray": res.get("cf_ray"),
            "url": res.get("url"), "err": res.get("err"), "detail": res.get("detail"),
            "retested": True, "first_class": old,
        })
        if cls == "ok":
            fixed += 1
            r.pop("snip", None)
        print("  [%d/%d] %-22s %-14s -> %-14s %s" % (i, len(todo), r["id"], old, cls, (res.get("status") or "")), flush=True)
        time.sleep(1.2)
    json.dump(rs, open("tools/smoke/results.json", "w"), ensure_ascii=False, indent=1)
    print("fixed_to_ok", fixed)


if __name__ == "__main__":
    main()
