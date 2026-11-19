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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = await widget.switcher.currentIconId();
    if (!mounted) return;
    setState(() => _currentId = id);
  }

  Future<void> _apply(AppIconOption option) async {
    if (_busy || _currentId == option.id) return;
    setState(() => _busy = true);
    final ok = await widget.switcher.setIcon(option.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _currentId = option.id;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '已切换为「${option.name}」，桌面图标稍后刷新'
              : '切换失败，当前桌面可能不支持换图标',
        ),
      ),
    );
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
                busy: _busy,
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
