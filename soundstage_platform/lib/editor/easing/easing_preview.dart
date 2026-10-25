import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// A dot that travels along a rail with [easing] (m2.md "Easing editor":
/// preview). It moves by `applyEasing`, so it shows exactly what the runtime
/// does, including overshoot beyond the rail's ends. With reduced motion
/// (`MediaQuery.disableAnimations`, which the web embedder sets from
/// `prefers-reduced-motion`) nothing animates: the dot rests at the end.
class EasingPreview extends StatefulWidget {
  const EasingPreview({required this.easing, super.key});

  final ir.Easing easing;

  @override
  State<EasingPreview> createState() => _EasingPreviewState();
}

/// The loop: rest at the start, move, rest at the end.
const Duration kPreviewLoop = Duration(milliseconds: 2000);
const double _restStart = 0.12, _moveEnd = 0.72;

/// Progress through the move for loop position [t] (0–1).
double previewProgress(double t) {
  if (t <= _restStart) return 0;
  if (t >= _moveEnd) return 1;
  return (t - _restStart) / (_moveEnd - _restStart);
}

class _EasingPreviewState extends State<EasingPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: kPreviewLoop,
  );
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced != _reduced || !_loop.isAnimating && !reduced) {
      _reduced = reduced;
      if (reduced) {
        _loop.stop();
      } else {
        _loop.repeat();
      }
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return Semantics(
      label: _reduced ? 'Preview (paused: reduced motion)' : 'Preview',
      child: SizedBox(
        key: const ValueKey<String>('easing-preview'),
        height: 28,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final pad = w * 0.14;
            double xOf(double v) => pad + v.clamp(-0.2, 1.2) * (w - 2 * pad);
            Widget dot(double v) => Positioned(
              left: xOf(v) - 5,
              top: 9,
              child: Container(
                key: const ValueKey<String>('easing-preview-dot'),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
              ),
            );
            Widget marker(double v) => Positioned(
              left: xOf(v) - 1,
              top: 6,
              child: Container(width: 2, height: 16, color: c.borderStrong),
            );
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: xOf(0),
                  right: w - xOf(1),
                  top: 13,
                  child: Container(height: 2, color: c.border),
                ),
                marker(0),
                marker(1),
                if (_reduced)
                  dot(ir.applyEasing(widget.easing, 1))
                else
                  AnimatedBuilder(
                    animation: _loop,
                    builder: (context, _) {
                      final u = previewProgress(_loop.value);
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [dot(ir.applyEasing(widget.easing, u))],
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
