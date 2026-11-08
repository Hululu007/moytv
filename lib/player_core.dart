import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlayerCore {
  exo('exo', 'EXO', 'Media3', 'Android 原生硬解，TV 最流畅'),
  mpv('mpv', 'MPV', 'media_kit', '稳定、功能丰富'),
  ijk('ijk', 'IJK', 'ijkplayer', '兼容性强，老片源兜底');

  const PlayerCore(this.id, this.label, this.engine, this.description);

  final String id;
  final String label;
  final String engine;
  final String description;

  String get dialogTitle => '$label ($engine)';

  static PlayerCore parse(String? value) => PlayerCore.values.firstWhere(
    (core) => core.id == value,
    orElse: () => PlayerCore.mpv,
  );
}

PlayerCore effectivePlayerCore({
  required PlayerCore stored,
}) => stored;

class PlayerCoreOption {
  const PlayerCoreOption({
    required this.core,
    required this.enabled,
    this.disabledNote,
  });

  final PlayerCore core;
  final bool enabled;
  final String? disabledNote;
}

List<PlayerCoreOption> playerCoreOptions({
  required bool exoAvailable,
  bool ijkAvailable = false,
}) {
  return PlayerCore.values.map((core) {
    if (core == PlayerCore.exo && !exoAvailable) {
      return PlayerCoreOption(
        core: core,
        enabled: false,
        disabledNote: '仅 Android 可用',
      );
    }
    if (core == PlayerCore.ijk && !ijkAvailable) {
      return PlayerCoreOption(
        core: core,
        enabled: false,
        disabledNote: '仅 Android 可用',
      );
    }
    return PlayerCoreOption(core: core, enabled: true);
  }).toList();
}

class PlayerCoreBadge extends StatelessWidget {
  const PlayerCoreBadge({super.key, required this.core, required this.onTap});

  final PlayerCore core;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: Text(
            core.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerCoreStorage {
  static const String key = 'playerCore';

  static PlayerCore read(SharedPreferences preferences) =>
      PlayerCore.parse(preferences.getString(key));

  static Future<void> write(SharedPreferences preferences, PlayerCore core) =>
      preferences.setString(key, core.id);
}

Future<PlayerCore?> showPlayerCoreDialog(
  BuildContext context,
  PlayerCore current, {
  required bool exoAvailable,
  bool ijkAvailable = false,
}) {
  final options = playerCoreOptions(
    exoAvailable: exoAvailable,
    ijkAvailable: ijkAvailable,
  );
  return showDialog<PlayerCore>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('切换播放器内核'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((option) {
            final selected = option.core == current;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: selected
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: option.enabled
                      ? () => Navigator.of(context).pop(option.core)
                      : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                option.core.dialogTitle,
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                option.enabled
                                    ? option.core.description
                                    : (option.disabledNote ?? ''),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            color: theme.colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );
    },
  );
}
