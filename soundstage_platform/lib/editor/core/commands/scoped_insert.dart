import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../editor_state.dart';

/// Makes an insert follow the edit scope (DECISIONS 24/10/26, T1.9b).
///
/// Under *Both* the result is returned as it is. Under *This breakpoint*
/// the inserted nodes ([topLevelIds], already in [r]) stay in the shared
/// base, and get a `visible: false` patch on every primary breakpoint other
/// than the edited artboard, so an element added on mobile exists only on
/// mobile (and the same for any artboard). The patches are part of [r], so
/// the insert is still one undo step.
ir.EditResult scopeInsert(
  EditorState state,
  ir.EditResult r,
  Iterable<String> topLevelIds,
) {
  if (!r.ok || state.effectiveScope != EditScope.thisBreakpoint) return r;
  final edited = state.artboardId;
  if (edited == null) return r;
  final others = [
    for (final b in r.document.primaryBreakpoints)
      if (b.id != edited) b.id,
  ];
  var doc = r.document;
  final diagnostics = [...r.diagnostics];
  for (final id in topLevelIds) {
    for (final bp in others) {
      final w = ir.setBreakpointPatchValue(
        doc,
        id,
        bp,
        'visible',
        const ir.IrValue.boolean(false),
      );
      if (!w.ok) return w.copyWith(document: r.document, changed: r.changed);
      doc = w.document;
      diagnostics.addAll(w.diagnostics);
    }
  }
  return r.copyWith(document: doc, diagnostics: diagnostics);
}
