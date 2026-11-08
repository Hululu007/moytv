import 'package:flutter/material.dart';

import 'picture_quality.dart';

/// 三态画质档（原画/锐化/Anime4K）选择面板。
///
/// 由 guo / xigua 两个播放器的播放菜单（普通与电视布局）共用。
/// 选择结果写回 [PlaybackPreferences.pictureQuality]，随用户偏好持久化，
/// 因此切换播放器（guo↔xigua）时选择不丢失。
class PictureQualityPanel extends StatelessWidget {
  const PictureQualityPanel({
    super.key,
    required this.value,
    required this.onChanged,
    this.busy = false,
    this.television = false,
  });

  final PictureQualityPreferences value;
  final ValueChanged<PictureQualityPreferences> onChanged;
  final bool busy;
  final bool television;

  Widget _choice({
    required String id,
    required String label,
    required bool selected,
    required VoidCallback action,
  }) => television
      ? ChoiceChip(
          key: ValueKey(id),
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: selected,
          onSelected: busy ? null : (_) => action(),
        )
      : ChoiceChip(
          key: ValueKey(id),
          label: Text(label),
          selected: selected,
          onSelected: busy ? null : (_) => action(),
        );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final helperStyle = TextStyle(
      fontSize: 12,
      color: colors.onSurfaceVariant,
      height: 1.5,
    );
    final mode = value.mode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('画质档', style: television ? const TextStyle(fontSize: 12) : null),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final choice in PictureQualityMode.values)
              _choice(
                id: 'picture-quality-${choice.name}',
                label: choice.label,
                selected: mode == choice,
                action: () => onChanged(value.copyWith(mode: choice)),
              ),
          ],
        ),
        if (mode == PictureQualityMode.sharpen) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('锐化强度'),
              Expanded(
                child: Slider(
                  key: const ValueKey('picture-quality-sharpen'),
                  min: 0,
                  max: 100,
                  divisions: 10,
                  label: '${value.strength}',
                  value: value.strength.toDouble(),
                  onChanged: busy
                      ? null
                      : (next) =>
                            onChanged(value.copyWith(strength: next.round())),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${value.strength}%',
                  textAlign: TextAlign.end,
                  style: helperStyle,
                ),
              ),
            ],
          ),
        ] else if (mode == PictureQualityMode.anime4k) ...[
          const SizedBox(height: 8),
          Text(
            'Anime4K 面向动漫与 AI 动漫；真人写实画面可能偏平滑。'
            '需 GPU 渲染，弱设备会自动退化为原画。',
            style: helperStyle,
          ),
        ] else ...[
          const SizedBox(height: 8),
          Text('使用源站原始视频流，不做画面处理。', style: helperStyle),
        ],
      ],
    );
  }
}
