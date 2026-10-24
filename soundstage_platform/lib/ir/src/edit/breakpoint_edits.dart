import '../breakpoint.dart';
import '../components.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../nodes/node.dart';
import '../registry/patch.dart';
import '../registry/property_registry.dart';
import '../resolve/breakpoints.dart';
import '../scene.dart';
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

// ---- Breakpoint management (T1.10) -----------------------------------------
//
// The editor's breakpoint manager adds, edits and removes breakpoints. Every
// helper validates the resulting list first (`validateBreakpointList`) and
// fails atomically on an error, so an edit can never introduce an
// `inheritsFrom` cycle, a dangling parent or a document without a primary
// breakpoint.

/// Problems with [breakpoints] as a document's breakpoint list, as errors:
/// none at all, a duplicate or empty id, an empty name, a negative
/// `minWidth`, a non-positive design size, an unknown `inheritsFrom`, an
/// `inheritsFrom` cycle, or no primary breakpoint (the editor shows primary
/// breakpoints as artboards). Empty when the list is valid.
List<IrDiagnostic> validateBreakpointList(List<Breakpoint> breakpoints) {
  final out = <IrDiagnostic>[];
  if (breakpoints.isEmpty) {
    return [
      editError(
        IrDiagnosticKind.missingBreakpoint,
        'A document needs at least one breakpoint.',
      ),
    ];
  }
  final ids = <String>{};
  for (final b in breakpoints) {
    if (b.id.isEmpty) {
      out.add(
        editError(IrDiagnosticKind.invalidValue, 'A breakpoint has no id.'),
      );
    } else if (!ids.add(b.id)) {
      out.add(
        editError(
          IrDiagnosticKind.duplicateId,
          'Two breakpoints have the id "${b.id}".',
        ),
      );
    }
    if (b.name.trim().isEmpty) {
      out.add(
        editError(
          IrDiagnosticKind.invalidValue,
          'Breakpoint "${b.id}" needs a name.',
        ),
      );
    }
    if (b.minWidth < 0 || !b.minWidth.isFinite) {
      out.add(
        editError(
          IrDiagnosticKind.invalidValue,
          'Breakpoint "${b.name}": the minimum width must be 0 or more.',
        ),
      );
    }
    final d = b.designSize;
    if (!(d.width > 0) ||
        !(d.height > 0) ||
        !d.width.isFinite ||
        !d.height.isFinite) {
      out.add(
        editError(
          IrDiagnosticKind.invalidValue,
          'Breakpoint "${b.name}": the design size must be positive.',
        ),
      );
    }
  }
  final reported = <String>{};
  for (final b in breakpoints) {
    final parent = b.inheritsFrom;
    if (parent == null) continue;
    if (parent == b.id) {
      out.add(
        editError(
          IrDiagnosticKind.breakpointCycle,
          'Breakpoint "${b.name}" cannot inherit from itself.',
        ),
      );
      reported.add(b.id);
      continue;
    }
    if (!ids.contains(parent)) {
      out.add(
        editError(
          IrDiagnosticKind.missingBreakpoint,
          'Breakpoint "${b.name}" inherits from "$parent", which does not '
          'exist.',
        ),
      );
      continue;
    }
    final r = breakpointChain(breakpoints, b.id);
    if (r.problem == BreakpointChainProblem.cycle && !reported.contains(b.id)) {
      reported.addAll(r.chain.map((x) => x.id));
      out.add(
        editError(
          IrDiagnosticKind.breakpointCycle,
          'Breakpoints would inherit in a cycle: '
          '${[...r.chain.map((x) => x.name), r.chain.first.name].join(' → ')}.',
        ),
      );
    }
  }
  if (!breakpoints.any((b) => b.primary)) {
    out.add(
      editError(
        IrDiagnosticKind.noPrimaryBreakpoint,
        'At least one breakpoint must be primary (shown as an artboard).',
      ),
    );
  }
  return out;
}

/// Adds [breakpoint] at [index] (default: last). Fails when the resulting
/// list is invalid ([validateBreakpointList]).
EditResult addBreakpoint(
  StageDocument doc,
  Breakpoint breakpoint, {
  int? index,
}) {
  final list = [...doc.breakpoints];
  list.insert((index ?? list.length).clamp(0, list.length), breakpoint);
  final errors = validateBreakpointList(list);
  if (errors.isNotEmpty) return failed(doc, errors);
  return EditResult(document: doc.copyWith(breakpoints: list), changed: true);
}

/// Replaces breakpoint [id] by [next] (same id: ids are referenced by
/// patches and tracks). Fails on an unknown id, a changed id, or an invalid
/// resulting list.
EditResult updateBreakpoint(StageDocument doc, String id, Breakpoint next) {
  final i = doc.breakpoints.indexWhere((b) => b.id == id);
  if (i < 0) return failed(doc, [_missingBreakpoint(id)]);
  if (next.id != id) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        'A breakpoint keeps its id ("$id"); patches refer to it.',
      ),
    ]);
  }
  if (doc.breakpoints[i] == next) return unchanged(doc);
  final list = [...doc.breakpoints]..[i] = next;
  final errors = validateBreakpointList(list);
  if (errors.isNotEmpty) return failed(doc, errors);
  return EditResult(document: doc.copyWith(breakpoints: list), changed: true);
}

/// Removes breakpoint [id] and everything that belongs to it:
///
/// - every node's patch for [id] (scenes, the overlay and component
///   definitions; untouched trees keep their identity);
/// - [id] from tracks' `breakpoints` lists (a track that applied only there
///   then applies nowhere);
/// - breakpoints that inherited from [id] now inherit from its own parent
///   (or nothing), keeping the rest of their chain.
///
/// Fails on an unknown id or when the remaining list is invalid (the last
/// breakpoint, or the last primary one).
EditResult removeBreakpoint(StageDocument doc, String id) {
  final removed = doc.breakpoints.where((b) => b.id == id).firstOrNull;
  if (removed == null) return failed(doc, [_missingBreakpoint(id)]);
  final list = [
    for (final b in doc.breakpoints)
      if (b.id != id)
        b.inheritsFrom == id
            ? b.copyWith(inheritsFrom: removed.inheritsFrom)
            : b,
  ];
  final errors = validateBreakpointList(list);
  if (errors.isNotEmpty) return failed(doc, errors);

  final scenes = <Scene>[];
  var scenesChanged = false;
  for (final s in doc.scenes) {
    final root = _withoutPatch(s.root, id) as FrameNode;
    // freezed list getters return a new view per read: compare one read.
    final oldTracks = s.tracks;
    var tracks = oldTracks;
    if (tracks.any((t) => t.breakpoints?.contains(id) ?? false)) {
      tracks = [
        for (final t in tracks)
          (t.breakpoints?.contains(id) ?? false)
              ? t.copyWith(
                  breakpoints: [
                    for (final b in t.breakpoints!)
                      if (b != id) b,
                  ],
                )
              : t,
      ];
    }
    if (identical(root, s.root) && identical(tracks, oldTracks)) {
      scenes.add(s);
    } else {
      scenesChanged = true;
      scenes.add(s.copyWith(root: root, tracks: tracks));
    }
  }
  final overlay = doc.overlay == null
      ? null
      : _withoutPatch(doc.overlay!, id) as FrameNode;
  final components = <String, ComponentDef>{};
  var componentsChanged = false;
  for (final MapEntry(:key, :value) in doc.components.entries) {
    final root = _withoutPatch(value.root, id) as FrameNode;
    if (!identical(root, value.root)) componentsChanged = true;
    components[key] = identical(root, value.root)
        ? value
        : value.copyWith(root: root);
  }
  return EditResult(
    document: doc.copyWith(
      breakpoints: list,
      scenes: scenesChanged ? scenes : doc.scenes,
      overlay: overlay,
      components: componentsChanged ? components : doc.components,
    ),
    changed: true,
  );
}

/// Whether node [n] has a non-empty patch for [breakpointId].
bool hasBreakpointPatch(Node n, String breakpointId) =>
    n.common.breakpointOverrides[breakpointId]?.isNotEmpty ?? false;

/// Whether node [n] has any breakpoint patch.
bool hasAnyBreakpointPatch(Node n) =>
    n.common.breakpointOverrides.values.any((p) => p.isNotEmpty);

/// Removes the whole patch of breakpoint [breakpointId] from node [nodeId]
/// ("reset overrides on this breakpoint"). A node without one is a
/// successful no-op.
EditResult clearBreakpointPatch(
  StageDocument doc,
  String nodeId,
  String breakpointId,
) {
  if (!doc.breakpoints.any((b) => b.id == breakpointId)) {
    return failed(doc, [_missingBreakpoint(breakpointId)]);
  }
  return updateNode(doc, nodeId, (n) {
    if (!n.common.breakpointOverrides.containsKey(breakpointId)) return n;
    final overrides = {...n.common.breakpointOverrides}..remove(breakpointId);
    return n.copyWith(
      common: n.common.copyWith(breakpointOverrides: overrides),
    );
  });
}

/// [n]'s subtree without breakpoint [id]'s patches; [n] itself (identical)
/// when none had one.
Node _withoutPatch(Node n, String id) {
  var out = n;
  if (n is FrameNode) {
    final kids = n.children;
    List<Node>? next;
    for (var i = 0; i < kids.length; i++) {
      final k = _withoutPatch(kids[i], id);
      if (!identical(k, kids[i])) (next ??= [...kids])[i] = k;
    }
    if (next != null) out = n.copyWith(children: next);
  }
  if (out.common.breakpointOverrides.containsKey(id)) {
    final o = {...out.common.breakpointOverrides}..remove(id);
    out = out.copyWith(common: out.common.copyWith(breakpointOverrides: o));
  }
  return out;
}
