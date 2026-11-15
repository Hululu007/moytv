import argparse
import os
import platform
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

from build_mirrors import china_mirror_environment, mirrored_pub_lockfile
from app_build import BuildVariant, add_variant_argument
from android_build_retry import run_android_build

# 空壳版剥离的插件 asset 声明（须与 pubspec.yaml 里的行精确匹配，
# 与 scripts/empty_shell_build.sh 同款守卫，缺一行就失败，绝不悄悄编错变体）。
PLUGIN_ASSET_LINES = ('    - assets/py_spiders/', '    - assets/jars/zakatv.jar')


def strip_plugin_assets(pubspec_path):
    """去掉 pubspec 里两行插件 asset 声明，返回原文以便构建后恢复。"""
    text = pubspec_path.read_text(encoding='utf-8')
    lines = text.splitlines(keepends=True)
    for wanted in PLUGIN_ASSET_LINES:
        if not any(line.rstrip('\r\n') == wanted for line in lines):
            raise SystemExit(f'pubspec 里找不到 {wanted} 声明，停下。')
    stripped = [line for line in lines
                if line.rstrip('\r\n') not in PLUGIN_ASSET_LINES]
    pubspec_path.write_text(''.join(stripped), encoding='utf-8')
    return text


def check_no_plugin_assets(apk_path):
    """自检：APK 里不得含有剥离的插件 asset。"""
    with zipfile.ZipFile(apk_path) as archive:
        bad = [name for name in archive.namelist()
               if name.startswith('assets/py_spiders/')
               or name == 'assets/jars/zakatv.jar']
    if bad:
        raise SystemExit(f'自检失败：{apk_path} 里仍有插件 asset：{bad[:3]}')


root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
parser.add_argument('--cn-mirrors', action='store_true', help='使用 Flutter 中国镜像和阿里云 Maven 镜像')
add_variant_argument(parser)
options = parser.parse_args()
variant = BuildVariant(options.all_sources)
empty_shell = os.environ.get('MOYI_EMPTY_SHELL', '').lower() == 'true'
environment = os.environ.copy()
if platform.system() == 'Darwin':
    environment['LANG'] = 'en_US.UTF-8'
    environment['LC_ALL'] = 'en_US.UTF-8'
environment.setdefault('GOPROXY', 'https://goproxy.cn,direct')
environment.setdefault('GOSUMDB', 'off')
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')
abi_args = [item for abi in options.abi or [] for item in ['--abi', abi]]
pubspec_path = root / 'pubspec.yaml'
original_pubspec = None
if empty_shell:
    print('空壳版构建：剥离插件 asset 声明。', flush=True)
    original_pubspec = strip_plugin_assets(pubspec_path)
try:
    with china_mirror_environment(environment, options.cn_mirrors) as env, mirrored_pub_lockfile(root, env):
        if options.cn_mirrors:
            print('本次构建启用国内依赖镜像，保留官方 Maven 仓库备用。', flush=True)
        subprocess.run([sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'android', *abi_args, *variant.arguments],
                       cwd=root, env=env, check=True)
        subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=root, env=env, check=True)
        build_args = [flutter, 'build', 'apk', '--release', '--no-pub', '--obfuscate', '--split-debug-info=build/app/outputs/symbols', *variant.flutter_arguments]
        auth_key = os.environ.get('JIANHUANG_AUTH_KEY', '')
        if auth_key:
            build_args.append('--dart-define=JIANHUANG_AUTH_KEY=' + auth_key)
        if empty_shell:
            build_args.append('--dart-define=MOYI_EMPTY_SHELL=true')
        if options.abi:
            targets = {'arm64-v8a': 'android-arm64', 'armeabi-v7a': 'android-arm', 'x86_64': 'android-x64'}
            build_args += ['--target-platform', ','.join(targets[abi] for abi in options.abi)]
        try:
            run_android_build(build_args, cwd=root, env=env, edition=variant.slug)
        except subprocess.CalledProcessError as error:
            raise SystemExit(error.returncode) from None
        if empty_shell:
            apk_dir = root / 'build' / 'app' / 'outputs' / 'flutter-apk'
            built_apks = sorted(apk_dir.glob('*.apk'))
            if not built_apks:
                raise SystemExit('自检失败：构建后找不到 APK。')
            for apk in built_apks:
                check_no_plugin_assets(apk)
        subprocess.run([sys.executable, str(root / 'scripts' / 'package_release.py'), '--platform', 'android', *abi_args, *variant.arguments],
                       cwd=root, env=env, check=True)
        if empty_shell:
            for apk in sorted((root / 'dist' / 'android').glob('*.apk')):
                check_no_plugin_assets(apk)
finally:
    if original_pubspec is not None:
        pubspec_path.write_text(original_pubspec, encoding='utf-8')
        print('空壳版构建：pubspec 已恢复。', flush=True)
