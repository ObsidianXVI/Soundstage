import '../breakpoint.dart';
import '../document.dart';

/// [breakpoints] ordered by `minWidth`, ascending (ties keep their order).
List<Breakpoint> breakpointsByWidth(List<Breakpoint> breakpoints) {
  final indexed = [
    for (var i = 0; i < breakpoints.length; i++) (i, breakpoints[i]),
  ];
  indexed.sort((x, y) {
    final c = x.$2.minWidth.compareTo(y.$2.minWidth);
    return c != 0 ? c : x.$1.compareTo(y.$1);
  });
  return [for (final (_, b) in indexed) b];
}

/// The breakpoints whose patches apply, in application order, when
/// [activeId] is active and [baseId] holds the node's own values
/// (architecture §3.1).
///
/// Walks outward from the base towards the active breakpoint, by
/// `minWidth`: with desktop base, `mobile` applies `[tablet, mobile]`; with
/// mobile base, `desktop` applies `[tablet, desktop]`. The base itself is
/// never in the list (its values are the node's own), so `active == base`
/// gives `[]`. Unknown ids give `[]`.
List<Breakpoint> breakpointCascade(
  List<Breakpoint> breakpoints,
  String baseId,
  String activeId,
) {
  final ordered = breakpointsByWidth(breakpoints);
  final b = ordered.indexWhere((x) => x.id == baseId);
  final a = ordered.indexWhere((x) => x.id == activeId);
  if (a < 0 || b < 0 || a == b) return const [];
  return a < b
      ? [for (var i = b - 1; i >= a; i--) ordered[i]]
      : [for (var i = b + 1; i <= a; i++) ordered[i]];
}

/// The active breakpoint at viewport [width]: the one with the largest
/// `minWidth` ≤ [width] (§3.1). Below every `minWidth`, the narrowest
/// breakpoint. Null only when there are no breakpoints.
Breakpoint? activeBreakpoint(List<Breakpoint> breakpoints, double width) {
  final ordered = breakpointsByWidth(breakpoints);
  if (ordered.isEmpty) return null;
  Breakpoint? best;
  for (final bp in ordered) {
    if (bp.minWidth <= width) best = bp;
  }
  return best ?? ordered.first;
}

/// [activeBreakpoint] for [doc]'s breakpoints.
Breakpoint? breakpointForWidth(StageDocument doc, double width) =>
    activeBreakpoint(doc.breakpoints, width);
