import 'package:flutter/material.dart';

import 'app_icon_switcher.dart';

/// 应用图标选择页：默认图标 + 5 张内置机械蚂蚁图，点选立即切换。
/// 切换走安卓 activity-alias 机制（见 IconSwitchBridge），桌面图标
/// 刷新速度取决于启动器，部分启动器需稍等或重进桌面才刷新。
/// 鸿蒙 NEXT 的卓易通里桌面图标不跟随 alias 变化（见桥侧注释），
/// 点选成功也可能桌面不变，页底另有“桌面快捷方式”兜底：把当前图标
/// 以快捷方式放到桌面，点它一样进应用。
class AppIconPickerPage extends StatefulWidget {
  const AppIconPickerPage({super.key, AppIconSwitcher? switcher})
    : switcher = switcher ?? const AppIconSwitcher();

  final AppIconSwitcher switcher;

  @override
  State<AppIconPickerPage> createState() => _AppIconPickerPageState();
}

class _AppIconPickerPageState extends State<AppIconPickerPage> {
  String? _currentId;
  bool _busy = false;

  /// 上次切换是否被系统拒绝过。拒绝记下来后不再让用户反复点选，
  /// 改显横条、停掉点选（降级），“再试一次”可恢复点选。
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await (
      widget.switcher.currentIconId(),
      widget.switcher.isSwitchDenied(),
    ).wait;
    if (!mounted) return;
    setState(() {
      _currentId = results.$1;
      _denied = results.$2;
    });
  }

  Future<void> _apply(AppIconOption option) async {
    if (_busy || _denied || _currentId == option.id) return;
    setState(() => _busy = true);
    final result = await widget.switcher.switchIcon(option.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _currentId = option.id;
        _denied = false;
      } else if (result.failure == AppIconSwitchFailure.denied) {
        _denied = true;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? '已切换为「${option.name}」，回桌面查看；鸿蒙卓易通里桌面图标可能不跟随，没变就用下面的快捷方式'
              : _failureText(result),
        ),
      ),
    );
  }

  /// 把当前选中的图标以桌面快捷方式放出去（alias 不生效时的兜底）。
  /// 与 alias 切换是两条路：即使上次切换被系统拒绝，这里照样能点。
  Future<void> _pinShortcut() async {
    final currentId = _currentId;
    if (_busy || currentId == null) return;
    setState(() => _busy = true);
    final result = await widget.switcher.pinShortcut(currentId);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? '已请求添加快捷方式，请在系统弹窗里点确认'
              : result.failure == AppIconSwitchFailure.unsupported
                  ? '当前桌面不支持添加快捷方式'
                  : _failureText(result),
        ),
      ),
    );
  }

  Future<void> _retry() async {
    await widget.switcher.clearSwitchDenied();
    if (!mounted) return;
    setState(() => _denied = false);
  }

  static String _failureText(AppIconSwitchResult result) {
    final detail = result.detail;
    final suffix = detail == null ? '' : '（$detail）';
    return switch (result.failure) {
      AppIconSwitchFailure.denied => '切换失败：系统拒绝了换图标，当前桌面或容器不允许$suffix',
      AppIconSwitchFailure.unsupported => '当前桌面不支持添加快捷方式',
      AppIconSwitchFailure.missing => '切换失败：图标组件未找到$suffix',
      _ => '切换失败，当前桌面可能不支持换图标$suffix',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('应用图标')),
      body: widget.switcher.supported
          ? _buildGrid(context)
          : const Center(child: Text('仅安卓支持更换应用图标')),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final currentId = _currentId;
    if (currentId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '点一张图就换上。桌面图标刷新要看启动器，有的要等几秒，'
            '有的要重进一次桌面才变。',
          ),
        ),
        if (_denied)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '上次切换被系统拒绝了：当前桌面或容器不允许换图标，'
                        '点选不会生效。可以改用下面的桌面快捷方式，'
                        '或点“再试一次”重测。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(onPressed: _retry, child: const Text('再试一次')),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 0.82,
            ),
            itemCount: appIconOptions.length,
            itemBuilder: (context, index) {
              final option = appIconOptions[index];
              final selected = option.id == currentId;
              return _IconTile(
                key: ValueKey('app-icon-${option.id}'),
                option: option,
                selected: selected,
                busy: _busy || _denied,
                onTap: () => _apply(option),
                theme: theme,
              );
            },
          ),
        ),
        // 桌面快捷方式兜底：鸿蒙卓易通里桌面图标不跟随 alias 变化，
        // 点选成功也可能桌面不变。把当前图标以快捷方式放到桌面，
        // 点它一样进应用；原图标还在，不用删。alias 被拒时这里照样能点。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('桌面图标没变？把当前图标以快捷方式放到桌面，点它一样进应用。'),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const ValueKey('app-icon-pin-shortcut'),
                    onPressed: _busy ? null : _pinShortcut,
                    child: const Text('把当前图标添加到桌面'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    super.key,
    required this.option,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.theme,
  });

  final AppIconOption option;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.dividerColor,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.asset(
                      option.previewAsset,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.check,
                        size: 16,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(option.name, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
