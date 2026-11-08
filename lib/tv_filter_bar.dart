import 'package:flutter/material.dart';

import 'models.dart';
import 'remote_widgets.dart';

class TvFilterBar extends StatelessWidget {
  const TvFilterBar({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
    this.onExitUp,
    this.onExitDown,
  });

  final List<CatalogFilterGroup> groups;
  final Map<String, String> selected;
  final void Function(String groupKey, String optionId) onSelected;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitDown;

  int _selectedIndex(CatalogFilterGroup group) {
    final current = selected[group.key] ?? '';
    if (current.isEmpty) return 0;
    final index = group.options.indexWhere((option) => option.id == current);
    return index < 0 ? 0 : index + 1;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < groups.length; i++)
          SizedBox(
            height: 35,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: SizedBox(
                    width: 29,
                    child: Text(
                      groups[i].name,
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: RemoteRow(
                    itemKeys: [
                      'tv-filter-${groups[i].key}-',
                      for (final option in groups[i].options)
                        'tv-filter-${groups[i].key}-${option.id}',
                    ],
                    initialIndex: _selectedIndex(groups[i]),
                    onExitUp: i == 0 ? onExitUp : null,
                    onExitDown: i == groups.length - 1 ? onExitDown : null,
                    itemBuilder: (context, index, node, onFocus) {
                      final option = index == 0
                          ? null
                          : groups[i].options[index - 1];
                      final id = option?.id ?? '';
                      return RemoteButton(
                        label: option?.name ?? '全部',
                        selected: (selected[groups[i].key] ?? '') == id,
                        focusNode: node,
                        onFocus: onFocus,
                        onPressed: () => onSelected(groups[i].key, id),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
