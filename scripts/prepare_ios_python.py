#!/usr/bin/env python3
"""准备 iOS 侧嵌入式 CPython（BeeWare Python-Apple-support 预编译包）。

钉死版本（2026-10-24 联网查证）：
  - 发布仓：beeware/Python-Apple-support，标签规约 ``{PYTHON_VER}-b{BUILD}``；
    GitHub Tags API 实测 3.12 线最新构建为 ``3.12-b5``
    （commit 9a461d6ef518df88f1285e907735477bb4e98b63），与安卓 Chaquopy 的
    CPython 3.12 对齐，故选此版，不追 3.13/3.14/3.15 线。
  - 资产命名（该仓 release/publish 工作流规约）：
    ``Python-3.12-iOS-support.b5.tar.gz``，内含 ``Python.xcframework``、
    ``VERSIONS`` 与可用作 PYTHONHOME 的目录结构。
  - 下载地址（先 GitHub Release，失败回退 BeeWare 官方 S3 镜像，二者为同一
    发布产物：publish 工作流把 Release 资产同步到 briefcase-support 桶）：
      1. https://github.com/beeware/Python-Apple-support/releases/download/3.12-b5/Python-3.12-iOS-support.b5.tar.gz
      2. https://briefcase-support.s3.amazonaws.com/python/3.12/iOS/Python-3.12-iOS-support.b5.tar.gz

产物（均不进 git，.gitignore 已忽略 ios/Frameworks/）：
  - ios/Frameworks/Python.xcframework        解压出的 XCFramework 本体
  - ios/Runner.xcodeproj/project.pbxproj     备料后做幂等手术：给 Runner
        目标挂 Python.xcframework 文件引用 + Frameworks 链接条目 + Embed
        Frameworks 内嵌条目（链接不再经 podspec 的 user_target_xcconfig）
  - ios/PythonBridge/Resources/py_spider_host.py
        宿主脚本的 iOS 侧副本，由本脚本从单一真源逐字同步：
        android/app/src/main/python/py_spider_host.py（安卓已验，禁止手改副本）
  - ios/PythonBridge/Resources/PythonVendor.bundle/
        requests 兼容包（requests/urllib3/certifi/charset_normalizer/idna/
        beautifulsoup4/soupsieve/chardet/typing_extensions，纯 Python wheel
        解包，备料时从 PyPI 下载，不进 git）：iOS 无 pip，安卓 Chaquopy
        预装 requests； iOS 侧由本脚本备料、JHPyBridge.c 起解释器时挂进
        sys.path，蜘蛛 import requests / bs4 与安卓同行为

CI 用法（最终轮 macOS job，pod install / 构建之前先跑）：
    python3 scripts/prepare_ios_python.py            # 下载+校验+同步宿主脚本+备 requests 兼容包
    python3 scripts/prepare_ios_python.py --check    # 只校验已准备产物，不下载
    cd ios && pod install                            # 再装 Pod（PythonBridge 以
                                                     # :path 引入，vendored 指向
                                                     # ../Frameworks/Python.xcframework）
本机（Linux）可跑 --sync-only 验证宿主脚本同步逻辑：
    python3 scripts/prepare_ios_python.py --sync-only
"""

import argparse
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SUPPORT_TAG = "3.12-b5"
SUPPORT_ASSET = "Python-3.12-iOS-support.b5.tar.gz"
SUPPORT_URLS = [
    "https://github.com/beeware/Python-Apple-support/releases/download/"
    + SUPPORT_TAG + "/" + SUPPORT_ASSET,
    "https://briefcase-support.s3.amazonaws.com/python/3.12/iOS/" + SUPPORT_ASSET,
]
EXPECTED_PYTHON_SERIES = "3.12"

FRAMEWORKS_DIR = ROOT / "ios" / "Frameworks"
XCFRAMEWORK_DIR = FRAMEWORKS_DIR / "Python.xcframework"
CACHE_DIR = FRAMEWORKS_DIR / ".cache"
HOST_SOURCE = ROOT / "android" / "app" / "src" / "main" / "python" / "py_spider_host.py"
HOST_DEST = ROOT / "ios" / "PythonBridge" / "Resources" / "py_spider_host.py"

VENDOR_PACKAGES = (
    ("requests", "2.34.2", "requests"),
    ("urllib3", "2.8.0", "urllib3"),
    ("certifi", "2026.10.23", "certifi"),
    ("charset_normalizer", "3.5.2", "charset_normalizer"),
    ("idna", "3.20", "idna"),
    ("beautifulsoup4", "4.15.0", "bs4"),
    ("soupsieve", "3.0.4", "soupsieve"),
    ("chardet", "7.7.0", "chardet"),
    ("typing_extensions", "4.15.0", "typing_extensions"),
    ("websocket-client", "1.9.2", "websocket"),
    ("httpx", "0.28.1", "httpx"),
    ("httpcore", "1.0.9", "httpcore"),
    ("h11", "0.16.0", "h11"),
    ("sniffio", "1.3.1", "sniffio"),
    ("anyio", "4.15.1", "anyio"),
)
VENDOR_BUNDLE_DIR = ROOT / "ios" / "PythonBridge" / "Resources" / "PythonVendor.bundle"
VENDOR_REQUIRED_FILES = (
    "requests/__init__.py",
    "urllib3/__init__.py",
    "certifi/__init__.py",
    "certifi/cacert.pem",
    "charset_normalizer/__init__.py",
    "idna/__init__.py",
    "bs4/__init__.py",
    "soupsieve/__init__.py",
    "chardet/__init__.py",
    "typing_extensions.py",
    "websocket/__init__.py",
    "httpx/__init__.py",
    "httpcore/__init__.py",
    "h11/__init__.py",
    "sniffio/__init__.py",
    "anyio/__init__.py",
)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(urls, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    last_error = None
    for url in urls:
        try:
            print("下载：%s" % url)
            request = urllib.request.Request(
                url, headers={"User-Agent": "huoyi-prepare-ios-python/1.0"})
            with urllib.request.urlopen(request) as response, \
                    open(destination, "wb") as out:
                shutil.copyfileobj(response, out)
            print("已下载：%s（%d 字节，sha256=%s）"
                  % (destination, destination.stat().st_size, sha256_of(destination)))
            return
        except Exception as error:  # noqa: BLE001 逐个回退下载源
            last_error = error
            print("下载失败（%s）：%s" % (url, error), file=sys.stderr)
    raise SystemExit("全部下载源失败：%s" % last_error)


def slice_dirs(xcframework):
    info_path = xcframework / "Info.plist"
    if not info_path.is_file():
        raise SystemExit("XCFramework 缺少 Info.plist：%s" % xcframework)
    info = plistlib.loads(info_path.read_bytes())
    libraries = info.get("AvailableLibraries") or []
    if not libraries:
        raise SystemExit("XCFramework Info.plist 无 AvailableLibraries")
    slices = []
    for library in libraries:
        identifier = library.get("LibraryIdentifier", "")
        supported = " ".join(library.get("SupportedPlatforms") or [])
        if supported and supported != "ios":
            continue
        path = xcframework / identifier / (library.get("LibraryPath") or "")
        slices.append((identifier, path))
    if not slices:
        raise SystemExit("XCFramework 无 iOS 切片")
    return slices


def validate_xcframework(xcframework):
    """校验版本与结构：须含真机（ios-arm64）切片、Python.h 与 stdlib 的 os.py。"""
    if not xcframework.is_dir():
        raise SystemExit("未找到 Python.xcframework：%s" % xcframework)
    slices = slice_dirs(xcframework)
    print("XCFramework 切片：%s" % ", ".join(name for name, _ in slices))
    device = [path for name, path in slices if "simulator" not in name]
    if not device:
        raise SystemExit("XCFramework 缺少真机切片（ios-arm64）")
    for name, path in slices:
        headers = list(path.rglob("Python.h"))
        stdlib_os = list(path.rglob("lib/python%s/os.py" % EXPECTED_PYTHON_SERIES))
        print("切片 %s：Python.h=%s，stdlib os.py=%s"
              % (name, headers[0] if headers else "缺失",
                 stdlib_os[0] if stdlib_os else "缺失"))
        if name == [n for n, p in slices if p in device][0]:
            if not headers:
                raise SystemExit("真机切片缺少 Python.h：%s" % path)
            if not stdlib_os:
                raise SystemExit(
                    "真机切片缺少 lib/python%s/os.py（stdlib 布局异常）：%s"
                    % (EXPECTED_PYTHON_SERIES, path))


def extract_support_package(archive):
    staging = CACHE_DIR / "extract"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    with tarfile.open(archive, "r:gz") as tar:
        tar.extractall(staging)  # 官方发布包，可信来源
    versions = staging / "VERSIONS"
    if versions.is_file():
        text = versions.read_text(encoding="utf-8", errors="replace")
        print("发布包 VERSIONS：\n%s" % text.strip())
        if EXPECTED_PYTHON_SERIES not in text:
            raise SystemExit("VERSIONS 未标明 Python %s，与钉死版本不符"
                             % EXPECTED_PYTHON_SERIES)
    candidates = sorted(staging.rglob("Python.xcframework"))
    candidates = [c for c in candidates if c.is_dir()]
    if not candidates:
        raise SystemExit("发布包内未找到 Python.xcframework")
    source = candidates[0]
    if XCFRAMEWORK_DIR.exists():
        shutil.rmtree(XCFRAMEWORK_DIR)
    shutil.copytree(source, XCFRAMEWORK_DIR)
    print("已安装：%s" % XCFRAMEWORK_DIR)
    merge_stdlib_into_framework(XCFRAMEWORK_DIR)
    others = sorted(p.name for p in staging.iterdir())
    print("发布包顶层条目（除 XCFramework 外仅记录、不安装）：%s" % ", ".join(others))
    validate_xcframework(XCFRAMEWORK_DIR)


def merge_stdlib_into_framework(xcframework):
    """把每个切片根部的 lib/（stdlib 本体）并入其 Python.framework。

    BeeWare 发布包实测布局（3.12-b5 官方包逐项核对）：stdlib 在切片根
    ``<slice>/lib/python3.12/``，与 ``Python.framework`` 平级，框架内只有
    二进制与头文件。而 Xcode 只会把 framework 本体嵌入 App，运行时
    （PythonRuntime.swift）也按 framework 根目录探测
    ``lib/python<series>/os.py`` 定 PYTHONHOME。故安装时逐切片并入，
    与 PEP 730 的框架内布局对齐。
    """
    for slice_dir in sorted(xcframework.iterdir()):
        if not slice_dir.is_dir():
            continue
        src = slice_dir / "lib"
        framework = slice_dir / "Python.framework"
        if not src.is_dir() or not framework.is_dir():
            continue
        dst = framework / "lib"
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
        print("stdlib 已并入框架：%s -> %s" % (src, dst))
        # BeeWare 的 Python.framework 不带 module.modulemap，Swift 侧
        # `import Python` 无法解析模块；按框架模块惯例补伞头模块图。
        modules_dir = framework / "Modules"
        modules_dir.mkdir(exist_ok=True)
        (modules_dir / "module.modulemap").write_text(
            "framework module Python {\n"
            "    umbrella header \"Python.h\"\n"
            "    export *\n"
            "    module * { export * }\n"
            "}\n", encoding="utf-8")
        print("module.modulemap 已写入：%s" % (modules_dir / "module.modulemap"))


PBXPROJ_PATH = ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"
XCF_MAIN_GROUP_ID = "97C146E51CF9000F007C117D"
XCF_FRAMEWORKS_PHASE_ID = "97C146EB1CF9000F007C117D"
XCF_EMBED_PHASE_ID = "9705A1C41CF9048500538489"


def _stable_object_id(seed):
    digest = hashlib.md5(("jhyy-ios-python-" + seed).encode("utf-8")).hexdigest()
    return digest[:24].upper()


XCF_FILE_REF_ID = _stable_object_id("fileref")
XCF_LINK_BUILD_ID = _stable_object_id("buildfile-frameworks")
XCF_EMBED_BUILD_ID = _stable_object_id("buildfile-embed")


def _pbx_block_span(text, object_id):
    header = text.find("\n\t\t" + object_id)
    if header < 0:
        raise SystemExit("pbxproj 找不到对象：%s" % object_id)
    end = text.find("\n\t\t};", header)
    if end < 0:
        raise SystemExit("pbxproj 对象未闭合：%s" % object_id)
    return header, end


def _pbx_block(text, object_id):
    start, end = _pbx_block_span(text, object_id)
    return text[start:end]


def _pbx_insert_into_list(text, object_id, list_key, line):
    start, end = _pbx_block_span(text, object_id)
    block = text[start:end]
    anchor_text = list_key + " = (\n"
    anchor = block.find(anchor_text)
    if anchor < 0:
        raise SystemExit("pbxproj 对象 %s 无 %s 列表" % (object_id, list_key))
    insert_at = start + anchor + len(anchor_text)
    return text[:insert_at] + line + text[insert_at:]


def _pbx_insert_before_marker(text, marker, line):
    if text.count(marker) != 1:
        raise SystemExit("pbxproj 标记不唯一或缺失：%s" % marker)
    at = text.find(marker)
    return text[:at] + line + text[at:]


def _pbx_wiring_missing(text):
    missing = []
    if XCF_FILE_REF_ID not in text:
        missing.append("PBXFileReference")
    if XCF_LINK_BUILD_ID not in text:
        missing.append("Frameworks 的 PBXBuildFile")
    if XCF_EMBED_BUILD_ID not in text:
        missing.append("Embed 的 PBXBuildFile")
    if XCF_FILE_REF_ID not in _pbx_block(text, XCF_MAIN_GROUP_ID):
        missing.append("主 group 子项")
    if XCF_LINK_BUILD_ID not in _pbx_block(text, XCF_FRAMEWORKS_PHASE_ID):
        missing.append("Runner Frameworks 阶段条目")
    if XCF_EMBED_BUILD_ID not in _pbx_block(text, XCF_EMBED_PHASE_ID):
        missing.append("Runner Embed Frameworks 阶段条目")
    return missing


def wire_python_into_xcode_project():
    """把 Python.xcframework 正经挂进 Runner 工程（定版修法）。

    五轮构建实证：podspec 的 user_target_xcconfig 只有 `-framework Python`
    没有搜索路径，链接期报 Framework 'Python' not found。按 BeeWare 模板
    的挂法在 App 工程里加文件引用 + Frameworks 链接条目 + Embed
    Frameworks 内嵌条目（动态框架不内嵌装上也闪退）。手术按条目粒度
    幂等：对象 ID 由固定种子 md5 派生、稳定可复现，缺哪条补哪条。
    """
    if not PBXPROJ_PATH.is_file():
        raise SystemExit("未找到 Xcode 工程文件：%s" % PBXPROJ_PATH)
    text = PBXPROJ_PATH.read_text(encoding="utf-8")
    for object_id, isa in ((XCF_MAIN_GROUP_ID, "PBXGroup"),
                           (XCF_FRAMEWORKS_PHASE_ID, "PBXFrameworksBuildPhase"),
                           (XCF_EMBED_PHASE_ID, "PBXCopyFilesBuildPhase")):
        if isa not in _pbx_block(text, object_id):
            raise SystemExit("pbxproj 锚点对象 %s 不是 %s，拒绝手术" % (object_id, isa))
    missing_before = _pbx_wiring_missing(text)
    if not missing_before:
        print("Xcode 工程已挂接 Python.xcframework，无变化")
        return
    if XCF_FILE_REF_ID not in text:
        text = _pbx_insert_before_marker(
            text, "/* End PBXFileReference section */",
            "\t\t%s /* Python.xcframework */ = {isa = PBXFileReference; "
            "lastKnownFileType = wrapper.xcframework; "
            "path = Frameworks/Python.xcframework; sourceTree = \"<group>\"; };\n"
            % XCF_FILE_REF_ID)
    if XCF_LINK_BUILD_ID not in text:
        text = _pbx_insert_before_marker(
            text, "/* End PBXBuildFile section */",
            "\t\t%s /* Python.xcframework in Frameworks */ = {isa = PBXBuildFile; "
            "fileRef = %s /* Python.xcframework */; };\n"
            % (XCF_LINK_BUILD_ID, XCF_FILE_REF_ID))
    if XCF_EMBED_BUILD_ID not in text:
        text = _pbx_insert_before_marker(
            text, "/* End PBXBuildFile section */",
            "\t\t%s /* Python.xcframework in Embed Frameworks */ = {isa = PBXBuildFile; "
            "fileRef = %s /* Python.xcframework */; "
            "settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };\n"
            % (XCF_EMBED_BUILD_ID, XCF_FILE_REF_ID))
    if XCF_FILE_REF_ID not in _pbx_block(text, XCF_MAIN_GROUP_ID):
        text = _pbx_insert_into_list(
            text, XCF_MAIN_GROUP_ID, "children",
            "\t\t\t\t%s /* Python.xcframework */,\n" % XCF_FILE_REF_ID)
    if XCF_LINK_BUILD_ID not in _pbx_block(text, XCF_FRAMEWORKS_PHASE_ID):
        text = _pbx_insert_into_list(
            text, XCF_FRAMEWORKS_PHASE_ID, "files",
            "\t\t\t\t%s /* Python.xcframework in Frameworks */,\n" % XCF_LINK_BUILD_ID)
    if XCF_EMBED_BUILD_ID not in _pbx_block(text, XCF_EMBED_PHASE_ID):
        text = _pbx_insert_into_list(
            text, XCF_EMBED_PHASE_ID, "files",
            "\t\t\t\t%s /* Python.xcframework in Embed Frameworks */,\n" % XCF_EMBED_BUILD_ID)
    PBXPROJ_PATH.write_text(text, encoding="utf-8")
    missing_after = _pbx_wiring_missing(PBXPROJ_PATH.read_text(encoding="utf-8"))
    if missing_after:
        raise SystemExit("pbxproj 手术后仍缺：%s" % ", ".join(missing_after))
    print("Xcode 工程已挂接 Python.xcframework（补齐：%s）" % ", ".join(missing_before))


def verify_project_wiring():
    if not PBXPROJ_PATH.is_file():
        raise SystemExit("未找到 Xcode 工程文件：%s" % PBXPROJ_PATH)
    missing = _pbx_wiring_missing(PBXPROJ_PATH.read_text(encoding="utf-8"))
    if missing:
        raise SystemExit("Xcode 工程未挂接 Python.xcframework（缺：%s），请先跑本脚本（不带 --check）"
                         % ", ".join(missing))
    print("校验通过：Xcode 工程已挂接 Python.xcframework（引用/链接/内嵌齐全）")


def sync_host_script():
    if not HOST_SOURCE.is_file():
        raise SystemExit("宿主脚本真源不存在：%s" % HOST_SOURCE)
    HOST_DEST.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(HOST_SOURCE, HOST_DEST)
    if sha256_of(HOST_SOURCE) != sha256_of(HOST_DEST):
        raise SystemExit("宿主脚本同步后哈希不一致：%s" % HOST_DEST)
    print("宿主脚本已同步（逐字一致，sha256=%s）：%s -> %s"
          % (sha256_of(HOST_DEST), HOST_SOURCE, HOST_DEST))


def verify_vendor_bundle():
    missing = [name for name in VENDOR_REQUIRED_FILES
               if not (VENDOR_BUNDLE_DIR / name).is_file()]
    if missing:
        raise SystemExit("requests 兼容包缺文件：%s" % ", ".join(missing))
    natives = [str(path) for path in VENDOR_BUNDLE_DIR.rglob("*.so")]
    if natives:
        raise SystemExit("requests 兼容包混入本机扩展（iOS 无法加载）：%s" % ", ".join(natives))
    print("校验通过：requests 兼容包齐全（%s）" % ", ".join(
        "%s==%s" % (package[0], package[1]) for package in VENDOR_PACKAGES))


def vendor_requests():
    if VENDOR_BUNDLE_DIR.exists():
        shutil.rmtree(VENDOR_BUNDLE_DIR)
    with tempfile.TemporaryDirectory() as temporary:
        download_dir = Path(temporary) / "wheels"
        download_dir.mkdir()
        for name, version, _dirname in VENDOR_PACKAGES:
            spec = "%s==%s" % (name, version)
            result = subprocess.run(
                [sys.executable, "-m", "pip", "download", "--quiet",
                 "--disable-pip-version-check", "--no-deps",
                 "--only-binary=:all:", "--platform", "any",
                 "--python-version", "312", "--abi", "none",
                 "--dest", str(download_dir), spec],
                capture_output=True, text=True)
            if result.returncode != 0:
                raise SystemExit("下载 %s 失败：%s" % (spec, result.stderr.strip()))
        wheels = sorted(download_dir.glob("*.whl"))
        if len(wheels) != len(VENDOR_PACKAGES):
            raise SystemExit("下载到的 wheel 数量不对：%d（期望 %d）"
                             % (len(wheels), len(VENDOR_PACKAGES)))
        staging = Path(temporary) / "unpacked"
        for wheel in wheels:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(staging)
        VENDOR_BUNDLE_DIR.mkdir(parents=True)
        for _name, _version, dirname in VENDOR_PACKAGES:
            package_dir = staging / dirname
            package_file = staging / (dirname + ".py")
            if package_dir.is_dir():
                shutil.copytree(package_dir, VENDOR_BUNDLE_DIR / dirname)
            elif package_file.is_file():
                shutil.copy2(package_file, VENDOR_BUNDLE_DIR / package_file.name)
            else:
                raise SystemExit("wheel 内未找到包：%s" % dirname)
    verify_vendor_bundle()


def main():
    parser = argparse.ArgumentParser(description="准备 iOS 嵌入式 CPython 与宿主脚本")
    parser.add_argument("--check", action="store_true",
                        help="只校验 ios/Frameworks/Python.xcframework 与宿主脚本同步状态")
    parser.add_argument("--sync-only", action="store_true",
                        help="只同步宿主脚本（可在 Linux 上跑）")
    options = parser.parse_args()

    if options.sync_only:
        sync_host_script()
        return
    if options.check:
        validate_xcframework(XCFRAMEWORK_DIR)
        if not HOST_DEST.is_file() or sha256_of(HOST_SOURCE) != sha256_of(HOST_DEST):
            raise SystemExit("宿主脚本未同步或与真源不一致，请先跑本脚本（不带 --check）")
        verify_project_wiring()
        verify_vendor_bundle()
        print("校验通过：XCFramework 结构、宿主脚本同步状态与 requests 兼容包正常")
        return
    archive = CACHE_DIR / SUPPORT_ASSET
    if not archive.is_file():
        download(SUPPORT_URLS, archive)
    else:
        print("复用已下载发布包：%s（sha256=%s）" % (archive, sha256_of(archive)))
    extract_support_package(archive)
    wire_python_into_xcode_project()
    sync_host_script()
    vendor_requests()


if __name__ == "__main__":
    main()
