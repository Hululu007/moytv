import 'package:flutter/material.dart';

import 'app_icon_switcher.dart';

/// 应用图标选择页：默认图标 + 5 张内置机械蚂蚁图，点选立即切换。
/// 切换走安卓 activity-alias 机制（见 IconSwitchBridge），桌面图标
/// 刷新速度取决于启动器，部分启动器需稍等或重进桌面才刷新。
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
          result.ok ? '已切换为「${option.name}」，桌面图标稍后刷新' : _failureText(result),
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
                        '点选不会生效。换个桌面启动器再试，或点“再试一次”重测。',
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
