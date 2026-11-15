/// 构建变体开关：空壳版与正常版同一套代码。
///
/// 空壳版不捆绑 jar/py 插件（构建时去掉对应 asset）、不自动装插件；
/// 海阔规则、直播、阅读源等不受影响。用户从插件市场安装插件后
/// 与正常版行为一致。
///
/// 打开方式（构建时）：`--dart-define=MOYI_EMPTY_SHELL=true`。
/// 树里脚本 scripts/empty_shell_build.sh 封装了去 asset + 传参
/// + 恢复 pubspec 的全过程，直接用它构建，不要手工改 pubspec。
const bool emptyShellBuild = bool.fromEnvironment('MOYI_EMPTY_SHELL');
