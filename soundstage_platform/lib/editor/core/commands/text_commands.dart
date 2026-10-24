import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../text/rich_text_model.dart';
import '../command.dart';
import '../editor_state.dart';
import 'property_commands.dart';

// Text commands (T1.8, architecture §7, §15).
//
// **Content lives in the base.** Typing, deleting, splitting and merging
// paragraphs and links change the node's shared `content`, whatever the
// edit scope: wording is not breakpoint-specific. A content edit also
// removes text-content patches (`characters`, `content.*.spans.*.text`) on
// every breakpoint, since they would hide the edit there.
//
// **Styles follow the edit scope.** Style edits address spans and
// paragraphs by path (`content.<p>.spans.<s>.style.<field>`,
// `content.<p>.style.<field>`) and go through [writeProperty] like any
// property: *Both* writes the base and clears that path on the primary
// breakpoints, *This breakpoint* writes a patch. To style part of the text,
// the base spans are first split at the range ends (a structural change with
// no visual effect), so a breakpoint patch can address exactly the range.
//
// **Index-addressed patches follow the text.** Every content edit returns
// span and paragraph origins (`ContentEdit`); patch keys and token bindings
// under `content.<p>…` are rewritten to the new indices (a split span's
// patch applies to both halves; a deleted span's patch is dropped). Spans
// merge only when their base style, link and patches are all equal.

final RegExp _spanKey = RegExp(r'^content\.(\d+)\.spans\.(\d+)(\..*)?$');
final RegExp _paraKey = RegExp(r'^content\.(\d+)(\..*)?$');

/// Whether [key] is a text-content path that content edits clear.
bool isTextContentKey(String key) {
  if (key == 'characters') return true;
  final m = _spanKey.firstMatch(key);
  return m != null && m.group(3) == '.text';
}

/// [map] (a patch or the bindings) with keys under `content.<p>` rewritten
/// for [edit]; [map] itself when nothing changes.
Map<String, V> remapContentKeys<V>(
  Map<String, V> map,
  ContentEdit edit, {
  bool dropTextContent = false,
}) {
  if (!map.keys.any((k) => k.startsWith('content.') || k == 'characters')) {
    return map;
  }
  final identity = edit.isIdentityMapping;
  if (identity && !dropTextContent) return map;
  // Old (p, s) → new refs; old p → new paragraphs.
  final spanTargets = <SpanRef, List<SpanRef>>{};
  final paraTargets = <int, List<int>>{};
  for (var p = 0; p < edit.paragraphOrigins.length; p++) {
    final o = edit.paragraphOrigins[p];
    if (o != null) (paraTargets[o] ??= []).add(p);
    final spans = edit.spanOrigins[p];
    for (var s = 0; s < spans.length; s++) {
      final so = spans[s];
      if (so != null) (spanTargets[so] ??= []).add(SpanRef(p, s));
    }
  }
  final out = <String, V>{};
  var changed = false;
  for (final MapEntry(:key, :value) in map.entries) {
    if (dropTextContent && isTextContentKey(key)) {
      changed = true;
      continue;
    }
    if (identity) {
      out[key] = value;
      continue;
    }
    final sm = _spanKey.firstMatch(key);
    if (sm != null) {
      final ref = SpanRef(int.parse(sm.group(1)!), int.parse(sm.group(2)!));
      final rest = sm.group(3) ?? '';
      for (final t in spanTargets[ref] ?? const <SpanRef>[]) {
        out['content.${t.paragraph}.spans.${t.span}$rest'] = value;
      }
      changed = true;
      continue;
    }
    final pm = _paraKey.firstMatch(key);
    if (pm != null) {
      final p = int.parse(pm.group(1)!);
      final rest = pm.group(2) ?? '';
      final targets = paraTargets[p] ?? const <int>[];
      // Paragraph styles carry over to every paragraph split from it; other
      // paragraph-level keys go to the first.
      final all = rest.startsWith('.style');
      for (final t in all ? targets : targets.take(1)) {
        out['content.$t$rest'] = value;
      }
      changed = true;
      continue;
    }
    out[key] = value;
  }
  return changed ? out : map;
}

/// The merge signature of a span of [node]: its patches and bindings,
/// relative to the span. Spans with different signatures never merge.
SpanSignature spanSignatureOf(ir.TextNode node) {
  final c = node.common;
  final hasContent =
      c.bindings.keys.any((k) => k.startsWith('content.')) ||
      c.breakpointOverrides.values.any(
        (p) => p.keys.any((k) => k.startsWith('content.')),
      );
  if (!hasContent) return (_) => null;
  final cache = <SpanRef, String>{};
  return (o) {
    if (o == null) return null;
    return cache.putIfAbsent(o, () {
      final prefix = 'content.${o.paragraph}.spans.${o.span}.';
      final parts = <String>[];
      for (final MapEntry(key: bp, value: patch)
          in c.breakpointOverrides.entries) {
        for (final MapEntry(:key, :value) in patch.entries) {
          if (key.startsWith(prefix)) {
            parts.add('$bp|${key.substring(prefix.length)}=$value');
          }
        }
      }
      for (final MapEntry(:key, :value) in c.bindings.entries) {
        if (key.startsWith(prefix)) {
          parts.add('#|${key.substring(prefix.length)}=$value');
        }
      }
      parts.sort();
      return parts.join(';');
    });
  };
}

/// [node] with [edit]'s content and its patches and bindings remapped.
ir.TextNode applyContentEdit(
  ir.TextNode node,
  ContentEdit edit, {
  bool dropTextContent = false,
}) {
  final c = node.common;
  final overrides = <String, ir.Patch>{};
  var changed = false;
  for (final MapEntry(key: bp, value: patch) in c.breakpointOverrides.entries) {
    final next = remapContentKeys(
      patch,
      edit,
      dropTextContent: dropTextContent,
    );
    changed |= !identical(next, patch);
    if (next.isNotEmpty) overrides[bp] = next;
  }
  final bindings = remapContentKeys(
    c.bindings,
    edit,
    dropTextContent: dropTextContent,
  );
  changed |= !identical(bindings, c.bindings);
  return node.copyWith(
    content: edit.content,
    common: changed
        ? c.copyWith(breakpointOverrides: overrides, bindings: bindings)
        : c,
  );
}

/// The text node [nodeId] of [doc] for an in-place edit, or a diagnostic.
(ir.TextNode?, ir.IrDiagnostic?) textNodeFor(ir.StageDocument doc, String id) {
  if (id.contains('/')) {
    return (
      null,
      commandError(
        'Text inside a component instance is edited on the component.',
        nodeId: id,
      ),
    );
  }
  final n = ir.DocumentIndex.of(doc).node(id);
  if (n is! ir.TextNode) {
    return (null, commandError('"$id" is not a text node.', nodeId: id));
  }
  return (n, null);
}

ir.EditResult _contentEdit(
  ir.StageDocument doc,
  String nodeId,
  ContentEdit Function(ir.TextNode node) edit, {
  bool dropTextContent = false,
}) {
  final (node, err) = textNodeFor(doc, nodeId);
  if (node == null) {
    return ir.EditResult(document: doc, changed: false, diagnostics: [err!]);
  }
  final e = edit(node);
  if (!e.changed) return ir.EditResult(document: doc, changed: false);
  return ir.updateNode(
    doc,
    nodeId,
    (_) => applyContentEdit(node, e, dropTextContent: dropTextContent),
  );
}

/// Re-normalises [nodeId]'s content after style writes (spans that became
/// equal merge, with their patches).
ir.EditResult normaliseText(ir.StageDocument doc, String nodeId) =>
    _contentEdit(
      doc,
      nodeId,
      (n) => normalise(n.content, signature: spanSignatureOf(n)),
    );

// ---- Content -----------------------------------------------------------------

/// Replaces the document range [start, end) of text node [nodeId] with
/// [text] (typing, deleting, Enter, paste), in the base.
///
/// [styleWrites] (span-relative style paths, e.g. `fontWeight`) are then
/// applied to the inserted text, routed by the edit scope: the pending
/// typing style after Cmd+B with a collapsed caret.
class ReplaceText extends EditCommand {
  ReplaceText(
    this.nodeId,
    this.start,
    this.end,
    this.text, {
    this.styleWrites = const {},
    this.customLabel,
    this.coalesceKey,
  });

  final String nodeId;
  final int start, end;
  final String text;
  final Map<String, ir.IrValue> styleWrites;
  final String? customLabel;

  @override
  final String? coalesceKey;

  @override
  String get label =>
      customLabel ?? (text.isEmpty ? 'Delete text' : 'Type "${_short(text)}"');

  static String _short(String t) =>
      t.length <= 12 ? t.replaceAll('\n', '↵') : '${t.substring(0, 12)}…';

  @override
  CommandResult apply(EditorState state) {
    var r = _contentEdit(
      state.document,
      nodeId,
      (n) => replaceText(
        n.content,
        start,
        end,
        text,
        signature: spanSignatureOf(n),
      ),
      dropTextContent: true,
    );
    if (r.ok && styleWrites.isNotEmpty && text.isNotEmpty) {
      final from = start < end ? start : end;
      final s = writeRangeStyle(
        state.copyWith(document: r.document),
        nodeId,
        from,
        from + text.length,
        styleWrites,
      );
      if (s.ok) {
        r = s.copyWith(changed: r.changed || s.changed);
      }
    }
    return resultOf(
      state,
      r,
      label: label,
      coalesceKey: coalesceKey,
      selectionAfter: {nodeId},
    );
  }
}

/// Sets or removes ([link] null) the link on [start, end) of [nodeId].
class SetTextLink extends EditCommand {
  const SetTextLink(this.nodeId, this.start, this.end, this.link);

  final String nodeId;
  final int start, end;
  final ir.SpanLink? link;

  @override
  String get label => link == null ? 'Remove link' : 'Add link';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    _contentEdit(
      state.document,
      nodeId,
      (n) =>
          setLink(n.content, start, end, link, signature: spanSignatureOf(n)),
    ),
    label: label,
    selectionAfter: {nodeId},
  );
}

// ---- Styles ------------------------------------------------------------------

/// The top-level field of span-relative style path [rel] (`fills.p.color` →
/// `fills`, `decoration.kind` → `decoration`).
String styleFieldOf(String rel) {
  final dot = rel.indexOf('.');
  return dot < 0 ? rel : rel.substring(0, dot);
}

const List<String> _decorationLeaves = [
  'kind',
  'style',
  'thickness',
  'color',
  'skipInk',
];

/// The writes that set [rel] to [value] on a style level whose effective
/// (merged) style is [effective], as paths relative to that level's
/// `style`:
///
/// - inside `fills` (`fills.<paintId>.<field>`): the whole list, with the
///   change applied to the effective fills (a span inheriting its fills
///   gets its own copy);
/// - inside `decoration`: every decoration leaf, so the parts not being
///   changed keep their effective values instead of the defaults;
/// - otherwise [rel] itself.
///
/// Empty when the change does not apply (an unknown paint id).
Map<String, ir.IrValue> expandStyleWrite(
  ir.TextStyle? effective,
  String rel,
  ir.IrValue value, {
  ir.PropertyRegistry? registry,
}) {
  final reg = registry ?? ir.PropertyRegistry.standard;
  final field = styleFieldOf(rel);
  if (effective == null || field == rel) return {rel: value};
  if (field == 'fills') {
    final carrier = ir.TextNode(
      common: const ir.NodeCommon(id: ''),
      style: ir.TextStyleOverride(fills: effective.fills),
    );
    final next = reg.trySet(carrier, 'style.$rel', value);
    if (next is! ir.TextNode || next.style.fills == null) return const {};
    return {'fills': ir.IrValue.paints(next.style.fills!)};
  }
  if (field == 'decoration') {
    final carrier = ir.TextNode(
      common: const ir.NodeCommon(id: ''),
      style: ir.TextStyleOverride(decoration: effective.decoration),
    );
    final next = reg.trySet(carrier, 'style.$rel', value);
    if (next == null) return const {};
    return {
      for (final leaf in _decorationLeaves)
        'decoration.$leaf':
            reg.get(next, 'style.decoration.$leaf') ?? const ir.IrValue.none(),
    };
  }
  return {rel: value};
}

/// A lookup of resolved nodes at the edited breakpoint of [state],
/// resolving the document once, on first use.
ir.ResolvedNode? Function(String id) lazyResolved(EditorState state) {
  Map<String, ir.ResolvedNode>? index;
  return (id) => (index ??= ir
      .resolveDocument(
        state.document,
        ir.ResolveContext(breakpointId: state.breakpointId),
      )
      .nodeIndex)[id];
}

/// The effective style of span ([paragraph], [span]) of resolved [node].
ir.TextStyle? resolvedSpanStyle(
  ir.ResolvedNode? node,
  int paragraph,
  int span,
) {
  final paras = node?.paragraphs;
  if (paras == null || paragraph >= paras.length) return null;
  final spans = paras[paragraph].spans;
  if (span >= spans.length) return null;
  return spans[span].style;
}

/// Writes span-relative style [writes] over the document range
/// [start, end) of [nodeId], routed by the edit scope (see the file
/// comment). [effective] gives a span's effective style before the edit
/// (for [expandStyleWrite]); by default it is resolved from [state].
ir.EditResult writeRangeStyle(
  EditorState state,
  String nodeId,
  int start,
  int end,
  Map<String, ir.IrValue> writes, {
  ir.TextStyle? Function(int paragraph, int span)? effective,
}) {
  final doc0 = state.document;
  final (node0, err) = textNodeFor(doc0, nodeId);
  if (node0 == null) {
    return ir.EditResult(document: doc0, changed: false, diagnostics: [err!]);
  }
  // Effective styles are read before the split; split halves share them.
  final lookup = lazyResolved(state);
  final eff =
      effective ?? (int p, int s) => resolvedSpanStyle(lookup(nodeId), p, s);
  final split = splitSpansAt(node0.content, [start, end]);
  var doc = doc0;
  if (split.changed) {
    final u = ir.updateNode(doc, nodeId, (_) => applyContentEdit(node0, split));
    if (!u.ok) return u;
    doc = u.document;
  }
  final targets = spansInRange(split.content, start, end);
  final diags = <ir.IrDiagnostic>[];
  var current = doc;
  for (final (ref, _, _) in targets) {
    final origin = split.spanOrigins[ref.paragraph][ref.span];
    final style = origin == null ? null : eff(origin.paragraph, origin.span);
    for (final MapEntry(key: rel, :value) in writes.entries) {
      final expanded = expandStyleWrite(style, rel, value);
      for (final MapEntry(key: r, value: v) in expanded.entries) {
        final w = writeProperty(
          state.copyWith(document: current),
          current,
          nodeId,
          'content.${ref.paragraph}.spans.${ref.span}.style.$r',
          v,
        );
        if (!w.ok) {
          diags.addAll(w.diagnostics.map(asWarning));
          continue;
        }
        current = w.document;
        diags.addAll(w.diagnostics);
      }
    }
  }
  final n = normaliseText(current, nodeId);
  if (n.ok) current = n.document;
  return ir.EditResult(
    document: current,
    changed: !identical(current, doc0),
    diagnostics: diags,
  );
}

/// Styles the document range [start, end) of [nodeId] (edit mode, or the
/// inspector with a text selection): span-relative [writes] such as
/// `{'fontWeight': 700}`, routed by the edit scope.
class StyleTextRange extends EditCommand {
  StyleTextRange(
    this.nodeId,
    this.start,
    this.end,
    this.writes, {
    this.effective,
    this.customLabel,
    this.coalesceKey,
  });

  final String nodeId;
  final int start, end;
  final Map<String, ir.IrValue> writes;

  /// The spans' effective styles before the edit (default: resolved).
  final ir.TextStyle? Function(int paragraph, int span)? effective;
  final String? customLabel;

  @override
  final String? coalesceKey;

  @override
  String get label =>
      customLabel ??
      (writes.length == 1
          ? 'Change ${styleFieldOf(writes.keys.single)}'
          : 'Change text style');

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    writeRangeStyle(state, nodeId, start, end, writes, effective: effective),
    label: label,
    coalesceKey: coalesceKey,
    selectionAfter: state.selection,
  );
}

/// Paragraph-level style paths (written on paragraphs, not spans).
const Set<String> kParagraphStyleFields = {
  'alignHorizontal',
  'paragraphSpacing',
  'paragraphIndent',
  'listStyle',
};

/// Sets paragraph-level [field] (one of [kParagraphStyleFields]) on the
/// paragraphs the document range [start, end] touches, routed by the edit
/// scope (`content.<p>.style.<field>`).
class StyleTextParagraphs extends EditCommand {
  const StyleTextParagraphs(
    this.nodeId,
    this.start,
    this.end,
    this.field,
    this.value, {
    this.coalesceKey,
  });

  final String nodeId;
  final int start, end;
  final String field;
  final ir.IrValue value;

  @override
  final String? coalesceKey;

  @override
  String get label => 'Change $field';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final (node, err) = textNodeFor(doc, nodeId);
    if (node == null) return failedCommand(state, label, [err!]);
    var current = doc;
    final diags = <ir.IrDiagnostic>[];
    for (final p in paragraphsInRange(node.content, start, end)) {
      final w = writeProperty(
        state.copyWith(document: current),
        current,
        nodeId,
        'content.$p.style.$field',
        value,
      );
      if (!w.ok) return failedCommand(state, label, w.diagnostics);
      current = w.document;
      diags.addAll(w.diagnostics);
    }
    return resultOf(
      state,
      ir.EditResult(
        document: current,
        changed: !identical(current, doc),
        diagnostics: diags,
      ),
      label: label,
      coalesceKey: coalesceKey,
      selectionAfter: state.selection,
    );
  }
}

/// Whether span override [s] sets top-level [field].
bool overrideSets(ir.TextStyleOverride s, String field) => switch (field) {
  'fontFamilyId' => s.fontFamilyId != null,
  'fontWeight' => s.fontWeight != null,
  'italic' => s.italic != null,
  'fontVariations' => s.fontVariations != null,
  'fontSize' => s.fontSize != null,
  'lineHeight' => s.lineHeight != null,
  'letterSpacing' => s.letterSpacing != null,
  'paragraphSpacing' => s.paragraphSpacing != null,
  'paragraphIndent' => s.paragraphIndent != null,
  'textCase' => s.textCase != null,
  'decoration' => s.decoration != null,
  'fills' => s.fills != null,
  'openType' => s.openType != null,
  'baselineShift' => s.baselineShift != null,
  'listStyle' => s.listStyle != null,
  _ => false,
};

/// Sets text style [rel] (span-relative, e.g. `fontSize`, `fills.p.color`)
/// on whole text nodes [nodeIds] (the inspector without edit mode): the
/// node-level `style` override, routed by the edit scope. Spans that
/// override the same field (in the base or a patch) are cleared back to
/// inheriting it (decoration, which has no whole-value path, gets the value
/// written instead), so the whole text shows it (Figma: a text layer's style
/// applies to every character). Paragraph-level fields write the node level and clear the
/// paragraphs' own values.
class StyleTextNodes extends EditCommand {
  StyleTextNodes(
    this.nodeIds,
    this.rel,
    this.value, {
    this.resolved,
    this.coalesceKey,
  });

  final List<String> nodeIds;

  /// The nodes resolved at the edited breakpoint before the edit (default:
  /// resolved from the state on first use).
  final ir.ResolvedNode? Function(String id)? resolved;
  final String rel;
  final ir.IrValue value;

  @override
  final String? coalesceKey;

  @override
  String get label => 'Change ${styleFieldOf(rel)}';

  @override
  CommandResult apply(EditorState state) {
    final field = styleFieldOf(rel);
    final paragraphLevel = kParagraphStyleFields.contains(field);
    final resolved = this.resolved ?? lazyResolved(state);
    final r = perNode(state.document, nodeIds, (doc, id) {
      final (node, err) = textNodeFor(doc, id);
      if (node == null) {
        return ir.EditResult(
          document: doc,
          changed: false,
          diagnostics: [err!],
        );
      }
      final rn = resolved(id);
      var current = doc;
      final diags = <ir.IrDiagnostic>[];
      bool write(String path, ir.IrValue v) {
        final w = writeProperty(
          state.copyWith(document: current),
          current,
          id,
          path,
          v,
        );
        if (!w.ok) {
          diags.addAll(w.diagnostics);
          return false;
        }
        current = w.document;
        diags.addAll(w.diagnostics);
        return true;
      }

      final nodePath = field == 'alignHorizontal' ? field : 'style.$field';
      if (paragraphLevel) {
        if (!write(nodePath, value)) {
          return ir.EditResult(
            document: doc,
            changed: false,
            diagnostics: diags,
          );
        }
        for (var p = 0; p < node.content.length; p++) {
          final ps = node.content[p].style;
          final own = switch (field) {
            'alignHorizontal' => ps?.alignHorizontal != null,
            'paragraphSpacing' => ps?.paragraphSpacing != null,
            'paragraphIndent' => ps?.paragraphIndent != null,
            _ => ps?.listStyle != null,
          };
          final patched = _patchedUnder(node, 'content.$p.style.$field');
          if (own || patched) {
            write('content.$p.style.$field', const ir.IrValue.none());
          }
        }
      } else {
        final expanded = expandStyleWrite(rn?.textStyle, rel, value);
        for (final MapEntry(key: k, value: v) in expanded.entries) {
          if (!write('style.$k', v)) {
            return ir.EditResult(
              document: doc,
              changed: false,
              diagnostics: diags,
            );
          }
        }
        for (var p = 0; p < node.content.length; p++) {
          final spans = node.content[p].spans;
          for (var s = 0; s < spans.length; s++) {
            final prefix = 'content.$p.spans.$s.style.$field';
            if (!overrideSets(spans[s].style, field) &&
                !_patchedUnder(node, prefix)) {
              continue;
            }
            if (field != 'decoration') {
              // Back to inheriting the node's new value.
              write(
                'content.$p.spans.$s.style.$field',
                const ir.IrValue.none(),
              );
              continue;
            }
            // Decoration has no whole-value path: write the leaves.
            final eff = rn?.paragraphs?[p].spans[s].style;
            for (final MapEntry(key: k, value: v) in expandStyleWrite(
              eff,
              rel,
              value,
            ).entries) {
              write('content.$p.spans.$s.style.$k', v);
            }
          }
        }
        final n = normaliseText(current, id);
        if (n.ok) current = n.document;
      }
      return ir.EditResult(
        document: current,
        changed: !identical(current, doc),
        diagnostics: diags,
      );
    });
    return resultOf(state, r, label: label, coalesceKey: coalesceKey);
  }

  static bool _patchedUnder(ir.TextNode n, String path) => n
      .common
      .breakpointOverrides
      .values
      .any((p) => p.keys.any((k) => ir.pathsOverlap(k, path)));
}

/// Runs [commands] in order as one undoable step labelled [label].
class CommandBatch extends EditCommand {
  const CommandBatch(this.commands, {required this.label, this.coalesceKey});

  final List<EditCommand> commands;

  @override
  final String label;

  @override
  final String? coalesceKey;

  @override
  CommandResult apply(EditorState state) {
    var s = state;
    var changed = false;
    final diags = <ir.IrDiagnostic>[];
    Set<String>? selection;
    for (final c in commands) {
      final r = c.apply(s);
      if (!r.ok) return failedCommand(state, label, r.diagnostics);
      changed |= r.changed;
      diags.addAll(r.diagnostics);
      selection = r.selectionAfter ?? selection;
      s = s.copyWith(document: r.document);
    }
    return CommandResult(
      document: s.document,
      label: label,
      changed: changed,
      diagnostics: diags,
      coalesceKey: coalesceKey,
      selectionAfter: selection,
    );
  }
}
