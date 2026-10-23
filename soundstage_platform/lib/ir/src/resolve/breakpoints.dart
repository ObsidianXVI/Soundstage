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

/// Why a breakpoint's `inheritsFrom` chain stopped early.
enum BreakpointChainProblem {
  /// An `inheritsFrom` names no breakpoint.
  unknownParent,

  /// The chain loops back on itself.
  cycle,
}

/// The result of [breakpointChain]: the breakpoints whose patches apply, in
/// application order (root first, the breakpoint itself last), and why the
/// walk stopped early, if it did (`problemId` is the offending id).
typedef BreakpointChain = ({
  List<Breakpoint> chain,
  BreakpointChainProblem? problem,
  String? problemId,
});

/// The patches that apply when [activeId] is active (architecture §3.1,
/// shared-base model): the breakpoints along its `inheritsFrom` chain, root
/// first, ending with [activeId] itself. Peers (`inheritsFrom: null`) give
/// just `[active]`.
///
/// Never throws. An unknown [activeId] gives an empty chain. An unknown
/// `inheritsFrom` or a cycle stops the walk at the last good breakpoint
/// and is reported in `problem`; the breakpoints already walked still
/// apply, so a broken chain degrades to fewer patches.
BreakpointChain breakpointChain(
  List<Breakpoint> breakpoints,
  String activeId,
) {
  final byId = <String, Breakpoint>{};
  for (final b in breakpoints) {
    byId.putIfAbsent(b.id, () => b);
  }
  final active = byId[activeId];
  if (active == null) return (chain: const [], problem: null, problemId: null);
  final walked = <Breakpoint>[active];
  final seen = <String>{active.id};
  var current = active;
  while (true) {
    final parentId = current.inheritsFrom;
    if (parentId == null) break;
    final parent = byId[parentId];
    if (parent == null) {
      return (
        chain: walked.reversed.toList(growable: false),
        problem: BreakpointChainProblem.unknownParent,
        problemId: parentId,
      );
    }
    if (!seen.add(parent.id)) {
      return (
        chain: walked.reversed.toList(growable: false),
        problem: BreakpointChainProblem.cycle,
        problemId: parent.id,
      );
    }
    walked.add(parent);
    current = parent;
  }
  return (
    chain: walked.reversed.toList(growable: false),
    problem: null,
    problemId: null,
  );
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
