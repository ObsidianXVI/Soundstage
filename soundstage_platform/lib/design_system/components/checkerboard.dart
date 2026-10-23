import 'package:flutter/widgets.dart';

/// The transparency checkerboard drawn under translucent colours.
class SsCheckerboard extends StatelessWidget {
  const SsCheckerboard({
    this.cell = 6,
    this.borderRadius = BorderRadius.zero,
    this.child,
    super.key,
  });

  final double cell;
  final BorderRadius borderRadius;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: CustomPaint(painter: _CheckerPainter(cell), child: child),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter(this.cell);

  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final dark = Paint()..color = const Color(0xFFC8C8CE);
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        if ((x + y).isOdd) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => old.cell != cell;
}
