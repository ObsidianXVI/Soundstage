import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'shortcut_map.dart';

/// Shows the keyboard shortcut reference as a dialog.
Future<void> showShortcutHelp(BuildContext context, {bool? mac}) {
  return showSsDialog<void>(
    context,
    builder: (_) => ShortcutHelpDialog(mac: mac ?? isMacPlatform()),
  );
}

/// The shortcut reference, grouped like the shortcut table.
class ShortcutHelpDialog extends StatelessWidget {
  const ShortcutHelpDialog({required this.mac, super.key});

  final bool mac;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final groups = <String, List<ShortcutDef>>{};
    for (final d in kEditorShortcuts) {
      groups.putIfAbsent(d.group, () => []).add(d);
    }
    return SsDialog(
      title: 'Keyboard shortcuts',
      width: 720,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Wrap(
            spacing: SsSpace.s8,
            runSpacing: SsSpace.s5,
            children: [
              for (final e in groups.entries)
                SizedBox(
                  width: 200,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(e.key.toUpperCase(), style: t.text.overline),
                      const SizedBox(height: SsSpace.s2),
                      for (final d in e.value)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  d.label,
                                  style: t.text.body.copyWith(
                                    color: t.colors.textPrimary,
                                  ),
                                ),
                              ),
                              Text(
                                d.keys.first.label(mac: mac),
                                style: t.text.numeric.copyWith(
                                  color: t.colors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        Builder(
          builder: (ctx) => SsButton(
            label: 'Close',
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ),
      ],
    );
  }
}
