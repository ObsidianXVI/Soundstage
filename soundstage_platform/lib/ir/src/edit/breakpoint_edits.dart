import '../diagnostics.dart';
import '../document.dart';
import '../nodes/node.dart';
import '../registry/patch.dart';
import '../registry/property_registry.dart';
import '../resolve/breakpoints.dart';
import '../values/ir_value.dart';
import 'document_index.dart';
import 'edit_core.dart';
import 'edit_result.dart';
import 'node_edits.dart';

// Property writes for the editor's edit scope (architecture §3.1, §15):
// "Both" writes the shared base and clears the primary breakpoints'
// patches for that path; "This breakpoint" writes one breakpoint's patch.
// Each copies only the path to the node (see `updateNode`).

/// Whether property paths [a] and [b] overlap: equal, or one is a prefix of
/// the other at a segment boundary (`fills` and `fills.p.color`).
bool pathsOverlap(String a, String b) =>
    a == b || a.startsWith('$b.') || b.startsWith('$a.');

/// The "Both" edit scope: writes [value] at [path] on node [nodeId]'s
/// shared base (with `applyPatch` semantics: a `tokenRef` binds, a
/// concrete value detaches a binding on the same path), then makes the new
/// value show through on every breakpoint in [clearPatchesOn]:
///
/// - patch keys equal to [path] or under it (`fills.p.color` when writing
///   `fills`) are removed;
/// - a patch key *above* [path] (`fills` when writing `fills.p.color`) is
///   kept, and its value is rewritten with [value] applied inside it, so the
///   breakpoint's other overrides in that value survive. When that is not
///   possible (the patch value is a token reference, [value] is one, or the
///   sub-path does not exist in the patched value) the key is left as is
///   with an `invalidEdit` warning.
///
/// Empty patches are dropped. Unknown breakpoint ids in [clearPatchesOn]
/// are skipped with a warning. Patches on other breakpoints are untouched.
EditResult setPropertyAcrossBreakpoints(
  StageDocument doc,
  String nodeId,
  String path,
  IrValue value, {
  required Set<String> clearPatchesOn,
  PropertyRegistry? registry,
}) {
  final reg = registry ?? PropertyRegistry.standard;
  final diags = <IrDiagnostic>[];
  final known = {for (final b in doc.breakpoints) b.id};
  for (final bp in clearPatchesOn) {
    if (!known.contains(bp)) {
      diags.add(
        editWarning(
          IrDiagnosticKind.missingBreakpoint,
          'Breakpoint "$bp" does not exist; nothing to clear there.',
          path: path,
        ),
      );
    }
  }
  final errors = <IrDiagnostic>[];
  final r = updateNode(doc, nodeId, (n) {
    final local = <IrDiagnostic>[];
    final base = applyPatch(
      n,
      {path: value},
      diagnostics: local,
      registry: reg,
    );
    if (local.isNotEmpty) {
      errors.addAll(local);
      return n;
    }
    final overrides = {...base.common.breakpointOverrides};
    for (final bp in clearPatchesOn) {
      final patch = overrides[bp];
      if (patch == null) continue;
      final next = <String, IrValue>{};
      for (final MapEntry(key: k, value: v) in patch.entries) {
        if (k == path || k.startsWith('$path.')) continue;
        if (path.startsWith('$k.')) {
          final rewritten = _setInside(base, k, v, path, value, reg);
          if (rewritten == null) {
            diags.add(
              editWarning(
                IrDiagnosticKind.invalidEdit,
                'Breakpoint "$bp" overrides "$k" as a whole; the new "$path" '
                'could not be written into it and does not show there.',
                nodeId: nodeId,
                path: k,
              ),
            );
            next[k] = v;
          } else {
            next[k] = rewritten;
          }
          continue;
        }
        next[k] = v;
      }
      if (next.isEmpty) {
        overrides.remove(bp);
      } else {
        overrides[bp] = next;
      }
    }
    return base.copyWith(
      common: base.common.copyWith(breakpointOverrides: overrides),
    );
  });
  if (errors.isNotEmpty) return failed(doc, errors);
  if (!r.ok) return r;
  return r.copyWith(diagnostics: [...diags, ...r.diagnostics]);
}

/// The "This breakpoint" edit scope: sets [path] to [value] in breakpoint
/// [breakpointId]'s patch on node [nodeId].
///
/// The path must exist on the node as that breakpoint sees it (its
/// `inheritsFrom` chain applied), and [value] must fit it (or be a
/// `tokenRef`, which binds). Keys under [path] in the same patch are
/// removed (they would be overwritten), and the key moves to the end of
/// the patch so it applies after any key above it.
EditResult setBreakpointPatchValue(
  StageDocument doc,
  String nodeId,
  String breakpointId,
  String path,
  IrValue value, {
  PropertyRegistry? registry,
}) {
  final reg = registry ?? PropertyRegistry.standard;
  if (!doc.breakpoints.any((b) => b.id == breakpointId)) {
    return failed(doc, [_missingBreakpoint(breakpointId)]);
  }
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  if (locateForEdit(index, nodeId, diags) == null) return failed(doc, diags);
  final node = index.node(nodeId)!;
  final match = reg.lookup(path);
  if (match == null) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.unknownPath,
        'No property is registered at "$path".',
        nodeId: nodeId,
        path: path,
      ),
    ]);
  }
  // The node as this breakpoint sees it, before its own write.
  var seen = node;
  for (final bp in breakpointChain(doc.breakpoints, breakpointId).chain) {
    final p = node.common.breakpointOverrides[bp.id];
    if (p != null) seen = applyPatch(seen, p, registry: reg);
  }
  final fits = value is TokenRefValue
      ? match.get(seen) != null
      : match.trySet(seen, value) != null;
  if (!fits) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.inapplicablePath,
        'Property "$path" does not exist on "$nodeId" at breakpoint '
        '"$breakpointId", or the value has the wrong type.',
        nodeId: nodeId,
        path: path,
      ),
    ]);
  }
  return updateNode(doc, nodeId, (n) {
    final overrides = {...n.common.breakpointOverrides};
    final patch = {
      for (final MapEntry(key: k, value: v)
          in (overrides[breakpointId] ?? const <String, IrValue>{}).entries)
        if (k != path && !k.startsWith('$path.')) k: v,
      path: value,
    };
    overrides[breakpointId] = patch;
    return n.copyWith(
      common: n.common.copyWith(breakpointOverrides: overrides),
    );
  });
}

/// Removes [path] from breakpoint [breakpointId]'s patch on node [nodeId]
/// ("reset to shared"). Dropping the last key drops the patch. A path that
/// is not in the patch is a successful no-op.
EditResult clearBreakpointPatchValue(
  StageDocument doc,
  String nodeId,
  String breakpointId,
  String path,
) {
  if (!doc.breakpoints.any((b) => b.id == breakpointId)) {
    return failed(doc, [_missingBreakpoint(breakpointId)]);
  }
  return updateNode(doc, nodeId, (n) {
    final patch = n.common.breakpointOverrides[breakpointId];
    if (patch == null || !patch.containsKey(path)) return n;
    final overrides = {...n.common.breakpointOverrides};
    final next = {...patch}..remove(path);
    if (next.isEmpty) {
      overrides.remove(breakpointId);
    } else {
      overrides[breakpointId] = next;
    }
    return n.copyWith(
      common: n.common.copyWith(breakpointOverrides: overrides),
    );
  });
}

IrDiagnostic _missingBreakpoint(String id) => editError(
  IrDiagnosticKind.missingBreakpoint,
  'Breakpoint "$id" does not exist.',
);

/// The patch value [outer] (at [outerPath], above [path]) with [value]
/// written at [path] inside it, or null when that is not possible.
IrValue? _setInside(
  Node base,
  String outerPath,
  IrValue outer,
  String path,
  IrValue value,
  PropertyRegistry reg,
) {
  if (outer is TokenRefValue || value is TokenRefValue) return null;
  final withOuter = reg.trySet(base, outerPath, outer);
  if (withOuter == null) return null;
  final written = reg.trySet(withOuter, path, value);
  if (written == null) return null;
  return reg.get(written, outerPath);
}
