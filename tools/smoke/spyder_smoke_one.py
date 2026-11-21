#!/usr/bin/env python3
"""单蜘蛛冒烟：加载 py 蜘蛛，调 init + homeContent，判定是否真能出数据。

用法: python3 spyder_smoke_one.py <asset_path>
输出一行 JSON。
"""
import importlib.util
import json
import os
import socket
import sys
import time
import traceback

socket.setdefaulttimeout(20)


def main():
    asset = sys.argv[1]
    name = "sp_" + os.path.basename(asset).replace(".py", "")
    out = {"asset": asset}
    t0 = time.time()
    try:
        spec = importlib.util.spec_from_file_location(name, asset)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
    except Exception as e:
        out.update(ok=False, stage="load", err=type(e).__name__ + ": " + str(e)[:200])
        out["elapsed"] = round(time.time() - t0, 1)
        print(json.dumps(out, ensure_ascii=False))
        return

    cls = getattr(mod, "Spider", None)
    if cls is None:
        out.update(ok=False, stage="class", err="no Spider class")
        print(json.dumps(out, ensure_ascii=False))
        return

    try:
        sp = cls()
        if hasattr(sp, "init"):
            sp.init("")
    except Exception as e:
        out.update(ok=False, stage="init", err=type(e).__name__ + ": " + str(e)[:200])
        out["elapsed"] = round(time.time() - t0, 1)
        print(json.dumps(out, ensure_ascii=False))
        return

    # homeContent(False) —— 标准 BaseSpider 形态
    try:
        res = sp.homeContent(False)
    except TypeError:
        try:
            res = sp.homeContent(True)
        except Exception as e:
            out.update(ok=False, stage="home", err=type(e).__name__ + ": " + str(e)[:200])
            out["elapsed"] = round(time.time() - t0, 1)
            print(json.dumps(out, ensure_ascii=False))
            return
    except Exception as e:
        out.update(ok=False, stage="home", err=type(e).__name__ + ": " + str(e)[:200])
        out["elapsed"] = round(time.time() - t0, 1)
        print(json.dumps(out, ensure_ascii=False))
        return

    host = getattr(sp, "host", "") or ""
    nclass = 0
    nlist = 0
    sample = ""
    if isinstance(res, dict):
        cls_list = res.get("class") or []
        items = res.get("list") or []
        nclass = len(cls_list) if isinstance(cls_list, list) else 0
        nlist = len(items) if isinstance(items, list) else 0
        if nlist and isinstance(items[0], dict):
            sample = str(items[0].get("vod_name") or items[0].get("name") or "")[:40]
    out.update(
        ok=(nclass > 0 or nlist > 0),
        stage="done",
        host=host,
        classes=nclass,
        items=nlist,
        sample=sample,
        elapsed=round(time.time() - t0, 1),
    )
    if not out["ok"]:
        out["err"] = "empty_home"
        out["raw_type"] = type(res).__name__
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
