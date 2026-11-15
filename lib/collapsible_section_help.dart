import 'package:flutter/material.dart';

class CollapsibleSectionHelp extends StatefulWidget {
  const CollapsibleSectionHelp({
    super.key,
    required this.brief,
    required this.fullText,
    required this.toggleKey,
  });

  final String brief;
  final String fullText;
  final ValueKey<String> toggleKey;

  @override
  State<CollapsibleSectionHelp> createState() =>
      _CollapsibleSectionHelpState();
}

class _CollapsibleSectionHelpState extends State<CollapsibleSectionHelp> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.brief),
        InkWell(
          key: widget.toggleKey,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('说明', style: TextStyle(color: colors.primary)),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: colors.primary,
                ),
              ],
            ),
          ),
        ),
        if (_expanded) Text(widget.fullText),
      ],
    );
  }
}
