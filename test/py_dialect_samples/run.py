#!/usr/bin/env python3
"""方言样本实测：跑宿主 validate + load + 各动作调用。

用法（务必用 -S，模拟 iOS 运行时“标准库 + 兼容包、无线上 site-packages”的模块集）：
    python3 -S test/py_dialect_samples/run.py \
        --host android/app/src/main/python \
        --vendor ios/PythonBridge/Resources/PythonVendor.bundle

不带 --vendor 时，import_requests / import_bs4 两样本记 SKIP（不算失败）。
每个样本的期望结果见 EXPECTED：missing_core 预期校验失败（源本身缺方法，
不许用空壳冒充），其余样本预期全部通过。任一 FAIL 即退出非零。
桩依赖样本记 STUBBED（不算 PASS）；PASS 行带 mode 与 stubbedImports。
"""

import argparse
import json
import sys
import tempfile
from pathlib import Path

EXPECTED = {
    "core_only.py": "pass",
    "base_import.py": "pass",
    "infile_base.py": "pass",
    "import_requests.py": "pass",
    "arity_dialect.py": "pass",
    "bom.py": "pass",
    "import_bs4.py": "pass",
    "missing_core.py": "validate_fail",
    "base_forms.py": "pass",
    "assign_method.py": "pass",
    "gbk.py": "special",
}

ACTIONS = [
    ("ping", {"action": "ping"}),
    ("categories", {"action": "categories"}),
    ("catalog_category", {"action": "catalog", "category": "1", "page": 1}),
    ("catalog_query", {"action": "catalog", "query": "片"}),
    ("search", {"action": "search", "query": "片", "page": 1}),
    ("detail", {"action": "detail", "vodId": "v1"}),
    ("resolve", {"action": "resolve", "flag": "线路1", "playId": "play1"}),
    ("proxy", {"action": "proxy", "param": {}}),
]


def check_site_packages():
    bad = [p for p in sys.path if "site-packages" in p or "dist-packages" in p]
    if bad:
        print("请用 python3 -S 运行（当前 sys.path 含线上包，会掩盖兼容包缺失）：")
        for path in bad:
            print("  " + path)
        return False
    return True


def run_actions(host, path):
    results = {}
    ping_data = {}
    for name, request in ACTIONS:
        raw = host.handle(path, json.dumps(request, ensure_ascii=False))
        data = json.loads(raw)
        results[name] = bool(data.get("ok"))
        if name == "ping" and data.get("ok"):
            ping_data = data.get("data") or {}
        if not data.get("ok"):
            results[name + "_error"] = data.get("error", "")
    return results, ping_data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--vendor", default="")
    parser.add_argument("--samples", default=str(Path(__file__).parent))
    args = parser.parse_args()
    if not check_site_packages():
        return 2
    host_dir = Path(args.host)
    sys.path.insert(0, str(host_dir))
    if args.vendor:
        sys.path.insert(0, args.vendor)
    import py_spider_host as host

    samples_dir = Path(args.samples)
    failures = 0
    for name in sorted(EXPECTED):
        expected = EXPECTED[name]
        path = samples_dir / name
        if name in ("import_requests.py", "import_bs4.py") and not args.vendor:
            print("SKIP %s（未给 --vendor，兼容包样本不跑）" % name)
            continue
        if name == "gbk.py":
            raw_bytes = path.read_bytes()
            raw_text = raw_bytes.decode("utf-8", errors="replace")
            raw = host.handle(str(path), json.dumps({"action": "ping"}))
            raw_ok = json.loads(raw).get("ok") is True
            with tempfile.NamedTemporaryFile(
                    suffix=".py", delete=False, mode="wb") as tmp:
                tmp.write(b"# -*- coding: gbk -*-\n" + raw_bytes)
                tmp_path = tmp.name
            cooked = host.handle(tmp_path, json.dumps({"action": "ping"}))
            cooked_ok = json.loads(cooked).get("ok") is True
            status = "PASS" if (not raw_ok and cooked_ok) else "FAIL"
            if status == "FAIL":
                failures += 1
            print("%s gbk.py（无 cookie 原始加载应失败=%s，加 cookie 应成功=%s）"
                  % (status, not raw_ok, cooked_ok))
            print("  （Dart 侧 GBK 路径：解码校验 + 存盘时补 cookie 行，与本用例 cooked 支一致）")
            continue
        text = path.read_bytes().decode("utf-8")
        validation = host.validate_source(text)
        if expected == "validate_fail":
            status = "PASS" if not validation["ok"] else "FAIL"
            if status == "FAIL":
                failures += 1
            print("%s %s（预期校验失败，实际 ok=%s，missing=%s）"
                  % (status, name, validation["ok"], validation["missing"]))
            continue
        if not validation["ok"]:
            failures += 1
            print("FAIL %s（校验未通过：%s，missing=%s）"
                  % (name, validation["error"], validation["missing"]))
            continue
        results, ping_data = run_actions(host, str(path))
        bad = [key for key, _ in ACTIONS if not results[key]]
        if bad:
            failures += 1
            print("FAIL %s（动作失败：%s）" % (name, ", ".join(bad)))
            for key in bad:
                print("  %s: %s" % (key, results.get(key + "_error", "")))
        else:
            stubbed = ping_data.get("stubbedImports") or []
            mode = validation.get("mode") or "full"
            if stubbed:
                failures += 1
                print("STUBBED %s（桩依赖 %s，不算 PASS；mode=%s）"
                      % (name, ", ".join(stubbed), mode))
            else:
                print("PASS %s（校验 + 8 动作全通，mode=%s，filled=%s，"
                      "stubbedImports=[]）"
                      % (name, mode, validation["filled"]))
    print("样本实测：%s" % ("全部符合预期" if failures == 0 else "%d 项不符合预期" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
