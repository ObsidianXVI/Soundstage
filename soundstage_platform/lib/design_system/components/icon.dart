import 'package:flutter/widgets.dart';

import '../tokens/theme.dart';

/// A Lucide glyph at a chrome size. Pass [semanticLabel] only when the icon
/// stands alone; icons inside a labelled control are decorative.
class SsIcon extends StatelessWidget {
  const SsIcon(
    this.icon, {
    this.size = 16,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final IconData icon;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c =
        color ?? IconTheme.of(context).color ?? context.ss.colors.textSecondary;
    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: Text(
            String.fromCharCode(icon.codePoint),
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontFamily: icon.fontFamily,
              fontSize: size,
              height: 1,
              color: c,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
