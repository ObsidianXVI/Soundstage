import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';

/// The property paths that have a track on some selected node (any clock,
/// any breakpoint), compared by value. Fields of other paths never watch
/// the playheads.
@immutable
class AnimatedPaths {
  const AnimatedPaths(this.paths);

  final Set<String> paths;

  @override
  bool operator ==(Object other) =>
      other is AnimatedPaths && setEquals(other.paths, paths);

  @override
  int get hashCode => Object.hashAllUnordered(paths);
}

final animatedPathsProvider = Provider.autoDispose<AnimatedPaths>((ref) {
  final ids = ref.watch(selectionIdsProvider);
  if (ids.isEmpty) return const AnimatedPaths({});
  final doc = ref
      .watch(editorControllerProvider.select((s) => Identity(s.document)))
      .value;
  final sel = ids.ids.toSet();
  return AnimatedPaths({
    for (final s in doc.scenes)
      for (final t in s.tracks)
        if (sel.contains(t.target)) t.property,
  });
}, dependencies: [editorControllerProvider, selectionIdsProvider]);

/// Rows at least this wide show ‹ › beside the keyframe toggle.
const double kKeyframeControlsFullWidth = 120;

/// Whether the inspector shows keyframe controls for [path]: a registered,
/// animatable property that interpolates (numbers, colours, paints,
/// effects). Step-valued properties (enums, booleans) are keyed through
/// auto-key and the timeline: their segmented and icon controls have no
/// room for the controls at the inspector's narrowest width (open question
/// in DECISIONS_NEEDED.md, T2.1-3).
bool showsKeyframeControls(String path) {
  final d = ir.PropertyRegistry.standard.lookup(path)?.descriptor;
  return d != null &&
      d.animatable &&
      d.interpolation == ir.Interpolation.continuous;
}

/// The keyframe controls of one animatable inspector row (m2.md
/// "Inspector"): ‹ jump to the previous keyframe, the toggle (◇ none, ◆ a
/// keyframe at the playhead, half-filled when the track has keyframes
/// elsewhere), › jump to the next. The arrows show once the property is
/// animated.
class KeyframeControls extends ConsumerWidget {
  const KeyframeControls({required this.path, this.compact = false, super.key});

  final String path;

  /// The toggle only (no ‹ ›): for narrow cells.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ss.colors;
    final scope = InspectorScope.of(context);
    final animated = ref.watch(
      animatedPathsProvider.select((a) => a.paths.contains(path)),
    );
    final nav = animated
        ? ref.watch(
            editorControllerProvider.select(
              (s) => keyframeNavFor(s, scope.ids, path),
            ),
          )
        : (mark: KeyframeMark.none, clockId: null, prev: null, next: null);
    final editor = ref.read(editorControllerProvider.notifier);

    void toggle() {
      final nodes = ref.read(selectedNodesProvider);
      final values = <String, ir.IrValue>{
        for (var i = 0; i < nodes.ids.length; i++)
          nodes.ids[i]: ?nodes.valueAt(i, path),
      };
      if (values.isEmpty) return;
      editor.execute(ToggleKeyframes(path, values));
    }

    void jump(double? t) {
      final clock = nav.clockId;
      final st = ref.read(editorControllerProvider);
      final scene = st.activeSceneId;
      if (t == null || clock == null || scene == null) return;
      editor.setPlayhead(scene, clock, t);
    }

    final on = nav.mark != KeyframeMark.none;
    final arrows = on && !compact;
    final color = on ? c.accentText : c.textDisabled;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (arrows)
          _Tap(
            key: ValueKey<String>('kf-prev:$path'),
            label: 'Previous keyframe',
            width: 12,
            onTap: nav.prev == null ? null : () => jump(nav.prev),
            child: SsIcon(
              SsIcons.chevronLeft,
              size: 10,
              color: nav.prev == null ? c.textDisabled : c.textSecondary,
            ),
          ),
        _Tap(
          key: ValueKey<String>('kf-toggle:$path'),
          label: switch (nav.mark) {
            KeyframeMark.none => 'Add keyframe',
            KeyframeMark.atPlayhead => 'Remove keyframe',
            KeyframeMark.elsewhere => 'Add keyframe at the playhead',
          },
          width: 12,
          onTap: toggle,
          child: CustomPaint(
            size: const Size(9, 9),
            painter: _DiamondPainter(nav.mark, color, c.surface1),
          ),
        ),
        if (arrows)
          _Tap(
            key: ValueKey<String>('kf-next:$path'),
            label: 'Next keyframe',
            width: 12,
            onTap: nav.next == null ? null : () => jump(nav.next),
            child: SsIcon(
              SsIcons.chevronRight,
              size: 10,
              color: nav.next == null ? c.textDisabled : c.textSecondary,
            ),
          ),
      ],
    );
  }
}

class _Tap extends StatelessWidget {
  const _Tap({
    required this.label,
    required this.width,
    required this.onTap,
    required this.child,
    super.key,
  });

  final String label;
  final double width;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => SsTooltip(
    message: label,
    child: Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: 24,
            child: Center(child: child),
          ),
        ),
      ),
    ),
  );
}

class _DiamondPainter extends CustomPainter {
  const _DiamondPainter(this.mark, this.color, this.background);

  final KeyframeMark mark;
  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2;
    final path = Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r, cy)
      ..lineTo(cx, cy + r)
      ..lineTo(cx - r, cy)
      ..close();
    final fill = Paint()..color = color;
    switch (mark) {
      case KeyframeMark.atPlayhead:
        canvas.drawPath(path, fill);
      case KeyframeMark.elsewhere:
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(0, 0, cx, size.height));
        canvas.drawPath(path, fill);
        canvas.restore();
      case KeyframeMark.none:
        break;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_DiamondPainter old) =>
      old.mark != mark || old.color != color || old.background != background;
}
