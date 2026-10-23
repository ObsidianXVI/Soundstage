import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../inspector_providers.dart';
import '../property_writer.dart';

/// The override hint colour (Figma's purple), per theme. The chrome has a
/// single accent hue; overrides get their own so they read at a glance.
Color overrideColor(BuildContext context) => context.ss.colors.isDark
    ? const Color(0xFFB48CFF)
    : const Color(0xFF7B4DDB);

Color _sourceColor(BuildContext context, ValueSource s) =>
    s.isOverride ? overrideColor(context) : context.ss.colors.accentText;

/// Wraps a control with the value-source chrome (architecture §15):
///
/// - A value that comes from a breakpoint or instance override is tinted
///   purple; one from a component, token or style gets a blue marker. A dot
///   at the corner names the source in its tooltip.
/// - Right-click (or clicking the dot) opens a menu naming the source, with
///   "Reset to inherited" when a layer can be removed.
///
/// [paths] are all the property paths the control edits; the strongest source
/// among them is shown, and reset resets every overridden one. A plain value
/// (the node's own) draws nothing and costs one provider read.
class FieldFrame extends ConsumerWidget {
  const FieldFrame({required this.paths, required this.child, super.key});

  FieldFrame.single({required String path, required this.child, super.key})
    : paths = [path];

  final List<String> paths;
  final Widget child;

  static ValueSource _strongest(Iterable<ValueSource> all) {
    var best = ValueSource.own;
    for (final s in all) {
      if (s.kind == ValueSourceKind.own) continue;
      if (best.kind == ValueSourceKind.own ||
          (s.isOverride && !best.isOverride)) {
        best = s;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final sources = [
      for (final p in paths)
        ref.watch(valueSourceProvider(ReadKey(scope.ids, p))),
    ];
    final source = _strongest(sources);
    if (source.kind == ValueSourceKind.own) return child;

    final color = _sourceColor(context, source);
    void reset() => scope.writer.resetAll([
      for (var i = 0; i < paths.length; i++)
        if (sources[i].resettable) paths[i],
    ]);

    List<SsMenuEntry> entries() => [
      SsMenuLabel(source.description),
      SsMenuItem(
        label: 'Reset to inherited',
        icon: SsIcons.rotateCcw,
        enabled: source.resettable,
        onSelected: source.resettable ? reset : null,
      ),
    ];

    // A raw pointer listener, not a gesture: a text field inside would win
    // the secondary-tap arena.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (e.buttons == kSecondaryMouseButton) {
          showSsContextMenu(context, position: e.position, entries: entries());
        }
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (source.isOverride)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey<String>('override-tint'),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: SsRadius.brSm,
                    border: Border.all(color: color.withValues(alpha: 0.45)),
                  ),
                ),
              ),
            ),
          Positioned(
            top: -3,
            right: -3,
            child: _SourceDot(color: color, source: source, entries: entries),
          ),
        ],
      ),
    );
  }
}

class _SourceDot extends StatelessWidget {
  const _SourceDot({
    required this.color,
    required this.source,
    required this.entries,
  });

  final Color color;
  final ValueSource source;
  final List<SsMenuEntry> Function() entries;

  @override
  Widget build(BuildContext context) {
    return SsTooltip(
      message: source.resettable
          ? '${source.description}. Right-click to reset.'
          : source.description,
      child: GestureDetector(
        key: const ValueKey<String>('value-source-dot'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final box = context.findRenderObject()! as RenderBox;
          showSsMenu(
            context,
            anchor: box.localToGlobal(Offset.zero) & box.size,
            entries: entries(),
          );
        },
        child: SizedBox(
          width: 12,
          height: 12,
          child: Center(
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: context.ss.colors.surface1, width: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
