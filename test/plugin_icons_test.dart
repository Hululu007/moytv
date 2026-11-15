import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/neon_glass_kit.dart';
import 'package:moyi/plugin_icons.dart';

void main() {
  testWidgets('jar and py plugin icons paint without error', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              PluginTypeIcon(kind: PluginIconKind.jar),
              PluginTypeIcon(kind: PluginIconKind.py, size: 32),
              PluginTypeIcon(
                kind: PluginIconKind.jar,
                size: 16,
                color: Colors.red,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(PluginTypeIcon), findsNWidgets(3));
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('NeonIconTile child replaces the default icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NeonIconTile(
            icon: Icons.dns_outlined,
            child: Text('PLUGIN'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('PLUGIN'), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsNothing);
  });

  testWidgets('NeonRow leading replaces the default icon tile', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NeonRow(
            icon: Icons.dns_outlined,
            leading: const NeonIconTile(
              icon: Icons.dns_outlined,
              child: Text('LEAD'),
            ),
            title: 'row',
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('LEAD'), findsOneWidget);
    expect(find.text('row'), findsOneWidget);
  });
}
