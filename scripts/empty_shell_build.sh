#!/usr/bin/env bash
# 空壳版构建：同一套代码，不捆绑 jar/py 插件、不自动装插件。
# 做法：临时去掉 pubspec 里两行插件 asset 声明 + 传
# --dart-define=MOYI_EMPTY_SHELL=true 构建，构建完恢复 pubspec。
# 海阔规则、直播、阅读源等 asset 不动。
# 用法：scripts/empty_shell_build.sh [传给 flutter build apk 的额外参数]
# 环境：FLUTTER_BIN 可指定 flutter 可执行文件，默认用 PATH 里的 flutter。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="$ROOT/pubspec.yaml"
BACKUP="$ROOT/pubspec.yaml.empty-shell-bak"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

restore() {
  if [ -f "$BACKUP" ]; then
    mv -f "$BACKUP" "$PUBSPEC"
  fi
}
trap restore EXIT

cd "$ROOT"
cp "$PUBSPEC" "$BACKUP"

# 精确匹配两行插件 asset 声明，缺一行就直接失败，绝不悄悄编错变体。
grep -qxF '    - assets/py_spiders/' "$PUBSPEC" || {
  echo 'pubspec 里找不到 assets/py_spiders/ 声明，停下。' >&2
  exit 1
}
grep -qxF '    - assets/jars/zakatv.jar' "$PUBSPEC" || {
  echo 'pubspec 里找不到 assets/jars/zakatv.jar 声明，停下。' >&2
  exit 1
}
grep -vxF '    - assets/py_spiders/' "$PUBSPEC" | grep -vxF '    - assets/jars/zakatv.jar' > "$PUBSPEC.tmp"
mv -f "$PUBSPEC.tmp" "$PUBSPEC"

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk --release --target-platform android-arm64 \
  --dart-define=MOYI_EMPTY_SHELL=true "$@"

APK="$ROOT/build/app/outputs/flutter-apk/app-release.apk"
# 自检：包里不得含有剥离的插件 asset。
if unzip -l "$APK" | grep -q 'assets/py_spiders/\|assets/jars/zakatv.jar'; then
  echo '自检失败：APK 里仍有插件 asset。' >&2
  exit 1
fi
echo "空壳版已出：$APK（无捆绑插件）"
