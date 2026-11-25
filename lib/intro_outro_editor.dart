import 'package:flutter/material.dart';

import 'intro_outro_skip.dart';

/// 播放器菜单里的「跳过片头片尾」编辑区（主播放器与西瓜共用同一份）。
///
/// 只管当前这部剧的分段秒数：步进按钮改值，改完立即回调存盘。
/// 全局总开关在播放设置页，这里不重复放。
class IntroOutroEditor extends StatefulWidget {
  const IntroOutroEditor({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IntroOutroSettings value;

  /// 全局总开关是否开着；关着时这里仍可改秒数，只是暂不生效。
  final bool enabled;
  final Future<void> Function(IntroOutroSettings) onChanged;

  @override
  State<IntroOutroEditor> createState() => _IntroOutroEditorState();
}

class _IntroOutroEditorState extends State<IntroOutroEditor> {
  late IntroOutroSettings _value = widget.value;

  Future<void> _update(IntroOutroSettings next) async {
    setState(() => _value = next);
    await widget.onChanged(next);
  }

  Widget _row({
    required String label,
    required int seconds,
    required ValueChanged<int> onSeconds,
  }) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          key: ValueKey('intro-outro-minus-$label'),
          tooltip: '减少 5 秒',
          onPressed: seconds <= 0
              ? null
              : () => onSeconds(seconds - 5 < 0 ? 0 : seconds - 5),
          icon: const Icon(Icons.remove_circle_outline, size: 20),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$seconds 秒',
            textAlign: TextAlign.center,
            key: ValueKey('intro-outro-value-$label'),
          ),
        ),
        IconButton(
          key: ValueKey('intro-outro-plus-$label'),
          tooltip: '增加 5 秒',
          onPressed: seconds >= maxSkipSeconds
              ? null
              : () => onSeconds(seconds + 5),
          icon: const Icon(Icons.add_circle_outline, size: 20),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('跳过片头片尾（本剧）'),
        const SizedBox(height: 4),
        Text(
          widget.enabled
              ? '从头播时自动跳过片头；播到片尾段自动切下一集。'
                    '片头加片尾超过单集一半时长时不跳，防短剧误跳。'
              : '全局「自动跳过片头片尾」已关，这里改了暂不生效，'
                    '去播放设置里打开。',
          style: TextStyle(
            fontSize: 12,
            color: colors.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        _row(
          label: '片头',
          seconds: _value.introSeconds,
          onSeconds: (seconds) =>
              _update(_value.copyWith(introSeconds: seconds)),
        ),
        _row(
          label: '片尾',
          seconds: _value.outroSeconds,
          onSeconds: (seconds) =>
              _update(_value.copyWith(outroSeconds: seconds)),
        ),
      ],
    );
  }
}
