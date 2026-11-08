#!/usr/bin/env python3
"""检查已编出的 iOS IPA 是否内嵌了可用的 Python 运行时。

在 CI 的 iOS 任务里，build_ios.py 之后、upload-artifact 之前跑：
    python3 scripts/check_ios_py_runtime.py [dist/ios]

逐个检查 dist/ios/*.ipa 的 zip 条目：
  - Payload/*.app/Frameworks/Python.framework/lib/python3.12/os.py
    （备料脚本并入框架的 stdlib 里程碑，解释器 PYTHONHOME 探测点）
  - 任一 py_spider_host.py（宿主脚本，主包根或 Pod 资源包内均可）
  - PythonVendor.bundle/requests/__init__.py 与
    PythonVendor.bundle/certifi/cacert.pem（requests 兼容包）
任一缺失即退出非零，让缺运行时的包在 CI 失败，而不是发到用户手里
再由桥探针报“安装包未集成 Python 桥”或“运行时未就绪”。
"""

import sys
import zipfile
from pathlib import Path


def check_ipa(ipa_path):
    with zipfile.ZipFile(ipa_path) as archive:
        names = archive.namelist()
    app_prefixes = set()
    for name in names:
        parts = name.split("/")
        if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
            app_prefixes.add(parts[0] + "/" + parts[1] + "/")
    problems = []
    if not app_prefixes:
        return ["IPA 内没有 Payload/*.app"]
    for prefix in sorted(app_prefixes):
        landmark = prefix + "Frameworks/Python.framework/lib/python3.12/os.py"
        if landmark not in names:
            problems.append("%s 缺 Python.framework stdlib 里程碑" % prefix)
        if not any(name.startswith(prefix) and name.endswith("/py_spider_host.py")
                   for name in names):
            problems.append("%s 缺 py_spider_host.py" % prefix)
        for required in ("PythonVendor.bundle/requests/__init__.py",
                         "PythonVendor.bundle/certifi/cacert.pem"):
            if not any(name.startswith(prefix) and required in name
                       for name in names):
                problems.append("%s 缺 %s" % (prefix, required))
    return problems


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dist/ios")
    ipas = sorted(root.glob("*.ipa"))
    if not ipas:
        print("未找到 IPA：%s/*.ipa" % root)
        return 1
    failed = False
    for ipa in ipas:
        problems = check_ipa(ipa)
        if problems:
            failed = True
            print("FAIL %s" % ipa)
            for problem in problems:
                print("  - %s" % problem)
        else:
            print("OK %s（Python 运行时、宿主脚本、requests 兼容包齐全）" % ipa)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
