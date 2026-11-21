#!/usr/bin/env python3
"""全站点冒烟：直连打每个站点首页，判定盾的类型。

不挂代理、不带任何特殊头（就是 App 里规则请求层的真实形态），
唯一附加的是手机 UA（App 默认）。

输出 results.json：每站 status/耗时/盾判定/证据片段。
"""
import json, re, ssl, sys, time, socket
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse
import urllib.request, urllib.error

UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CF_CHALLENGE = [
    "just a moment", "cf-browser-verification", "__cf_chl_opt", "challenge-platform",
    "cf_chl_rt_tk", "_cf_chl_", "/cdn-cgi/challenge-platform",
]
CF_BLOCK = [
    "attention required", "error 1020", "access denied", "you have been blocked",
    "cf-error-details", "ray id",
]
GENERIC_JS = ["enable javascript", "请开启javascript", "请启用javascript", "javascript is required"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    pass


def probe(origin, path="/", timeout=18, follow=True):
    url = origin.rstrip("/") + path
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    })
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=CTX) if follow else NoRedirect
    )
    t0 = time.time()
    try:
        with opener.open(req, timeout=timeout) as r:
            body = r.read(60000)
            return {
                "ok": True, "status": r.status, "url": r.geturl(),
                "elapsed": round(time.time() - t0, 2),
                "server": r.headers.get("server", ""),
                "ctype": r.headers.get("content-type", ""),
                "cf_mitigated": r.headers.get("cf-mitigated", ""),
                "cf_ray": bool(r.headers.get("cf-ray")),
                "body": body,
            }
    except urllib.error.HTTPError as e:
        try:
            body = e.read(60000)
        except Exception:
            body = b""
        return {
            "ok": False, "status": e.code, "url": e.geturl(),
            "elapsed": round(time.time() - t0, 2),
            "server": e.headers.get("server", "") if e.headers else "",
            "ctype": e.headers.get("content-type", "") if e.headers else "",
            "cf_mitigated": e.headers.get("cf-mitigated", "") if e.headers else "",
            "cf_ray": bool(e.headers.get("cf-ray")) if e.headers else False,
            "body": body, "err": "http_%d" % e.code,
        }
    except ssl.SSLError as e:
        return {"ok": False, "err": "tls", "detail": str(e)[:160], "elapsed": round(time.time() - t0, 2)}
    except socket.timeout:
        return {"ok": False, "err": "timeout", "elapsed": round(time.time() - t0, 2)}
    except urllib.error.URLError as e:
        r = e.reason
        kind = "dns" if isinstance(r, socket.gaierror) else (
            "timeout" if isinstance(r, socket.timeout) else "conn")
        return {"ok": False, "err": kind, "detail": str(r)[:160], "elapsed": round(time.time() - t0, 2)}
    except Exception as e:
        return {"ok": False, "err": "other", "detail": str(e)[:160], "elapsed": round(time.time() - t0, 2)}


def classify(res):
    """把一次探测归一成盾的类别。"""
    if not res.get("ok") and not res.get("status"):
        return res.get("err") or "fail"
    body = res.get("body") or b""
    text = ""
    try:
        text = body.decode("utf-8", "ignore").lower()
    except Exception:
        pass
    st = res.get("status") or 0
    if res.get("cf_mitigated") == "challenge":
        return "cf_challenge"
    for k in CF_CHALLENGE:
        if k in text:
            return "cf_challenge"
    if st in (403, 503) and (res.get("cf_ray") or "cloudflare" in text):
        for k in CF_BLOCK:
            if k in text:
                return "cf_block"
        return "cf_403"
    if st == 403:
        return "http_403"
    if st == 429:
        return "rate_limit"
    if st in (401, 407):
        return "auth_required"
    if st >= 500:
        return "http_%d" % st
    if st in (301, 302, 303, 307, 308):
        return "redirect"
    if st == 200:
        if res.get("ctype", "").startswith("text/html"):
            for k in GENERIC_JS:
                if k in text:
                    return "js_required"
            if len(body) < 600:
                return "thin_page"
        return "ok"
    return "http_%d" % st


def run_one(item):
    kind, sid, home = item
    res = probe(home)
    cls = classify(res)
    out = {
        "kind": kind, "id": sid, "home": home, "class": cls,
        "status": res.get("status"), "elapsed": res.get("elapsed"),
        "server": res.get("server"), "cf_ray": res.get("cf_ray"),
        "url": res.get("url"), "err": res.get("err"), "detail": res.get("detail"),
    }
    if cls not in ("ok",):
        b = res.get("body") or b""
        try:
            t = b.decode("utf-8", "ignore")
            out["snip"] = re.sub(r"\s+", " ", t)[:300]
        except Exception:
            pass
    return out


def main():
    data = json.load(open("tools/smoke/sites.json"))
    items = []
    seen = set()
    for kind, arr in data.items():
        for x in arr:
            key = (kind, x["id"])
            if key in seen:
                continue
            seen.add(key)
            items.append((kind, x["id"], x["home"]))
    print("probing", len(items), flush=True)
    t0 = time.time()
    out = []
    with ThreadPoolExecutor(max_workers=12) as ex:
        for i, r in enumerate(ex.map(run_one, items), 1):
            out.append(r)
            if i % 25 == 0:
                print("  %d/%d  %.0fs" % (i, len(items), time.time() - t0), flush=True)
    json.dump(out, open("tools/smoke/results.json", "w"), ensure_ascii=False, indent=1)
    from collections import Counter
    print(Counter(r["class"] for r in out))
    print("done %.0fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
