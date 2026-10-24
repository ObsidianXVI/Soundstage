import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../text/rich_text_model.dart';
import '../../text/text_edit_session.dart';
import '../../text/text_style_target.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';

// The text section reads and writes text styles through these, so the
// registry-driven controls (`NumberProp('style.fontSize')`, the paint stack
// on `style.fills`) work unchanged in both modes (T1.8):
//
// - **Outside edit mode** a `style.*` path means the whole text: it reads
//   every span (Mixed when they differ) and writes the node-level `style`
//   override, clearing span overrides of that field (`StyleTextNodes`).
// - **In edit mode** it means the text selection: it reads the selected
//   spans (at a collapsed caret, the typing style) and writes those spans
//   (`StyleTextRange`), or the pending typing style at a collapsed caret.
// - Paragraph-level fields (`alignHorizontal`, `style.paragraphSpacing`,
//   `style.paragraphIndent`, `style.listStyle`) read and write paragraphs:
//   all of them, or those the selection touches.
// - Every other path (`autoResize`, `maxLines`, …) is the node's own.

/// The span-relative style path of inspector path [path], or null when it
/// is not a text style path.
String? textStyleRel(String path) {
  if (path == 'alignHorizontal') return path;
  if (path.startsWith('style.')) return path.substring(6);
  return null;
}

bool _isParagraphField(String rel) =>
    kParagraphStyleFields.contains(styleFieldOf(rel));

/// [SelectedNodes] whose text style paths read the text target.
@immutable
class TextTargetNodes extends SelectedNodes {
  TextTargetNodes(SelectedNodes base, this.target)
    : super(
        ids: base.ids,
        resolved: base.resolved,
        authored: base.authored,
        document: base.document,
        breakpointId: base.breakpointId,
        resolver: base.resolver,
      );

  /// The edit-mode text selection; null outside edit mode.
  final TextRangeTarget? target;

  @override
  PropertyReading read(String path) {
    final rel = textStyleRel(path);
    if (rel == null) return super.read(path);
    final values = <ir.IrValue>[];
    var total = 0;
    for (var i = 0; i < ids.length; i++) {
      final n = authored[i];
      final rn = resolved[i];
      if (n is! ir.TextNode) continue;
      total++;
      final t = target?.nodeId == ids[i] ? target : null;
      if (_isParagraphField(rel)) {
        final paras = rn.paragraphs ?? const <ir.ResolvedParagraph>[];
        final which = t == null
            ? [for (var p = 0; p < paras.length; p++) p]
            : paragraphsInRange(n.content, t.start, t.end);
        for (final p in which) {
          if (p < paras.length) values.add(_paragraphValue(paras[p], rel));
        }
        continue;
      }
      final refs = t == null
          ? allSpanRefs(n.content)
          : spanRefsFor(n.content, t.start, t.end);
      if (t != null && t.collapsed && t.pending.isNotEmpty) {
        for (final s in resolvedSpansAt(rn, refs)) {
          final styled = applyStyleWrites(
            s.style,
            t.pending,
            inherited: rn.textStyle,
          );
          final v = ir.PropertyRegistry.standard.get(
            ir.TextNode(
              common: const ir.NodeCommon(id: ''),
              style: fullOverride(styled),
            ),
            'style.$rel',
          );
          if (v != null) values.add(v);
        }
        continue;
      }
      for (final r in refs) {
        final v = ir.resolvedPropertyValue(
          rn,
          'content.${r.paragraph}.spans.${r.span}.style.$rel',
        );
        if (v != null) values.add(v);
      }
      if (refs.isEmpty) {
        final v = ir.resolvedPropertyValue(rn, 'style.$rel');
        if (v != null) values.add(v);
      }
    }
    if (values.isEmpty) {
      return PropertyReading(total: total);
    }
    final first = values.first;
    return PropertyReading(
      value: first,
      mixed: values.any((v) => v != first),
      applicable: total,
      total: total,
    );
  }

  static ir.IrValue _paragraphValue(ir.ResolvedParagraph p, String rel) =>
      switch (rel) {
        'alignHorizontal' => ir.IrValue.enumValue(p.alignHorizontal.name),
        'paragraphSpacing' => ir.IrValue.number(p.paragraphSpacing),
        'paragraphIndent' => ir.IrValue.number(p.paragraphIndent),
        _ => ir.IrValue.enumValue(p.listStyle.name),
      };

  @override
  bool operator ==(Object other) =>
      other is TextTargetNodes && other.target == target && super == other;

  @override
  int get hashCode => Object.hash(super.hashCode, target);
}

/// [PropertyWriter] whose text style paths write the text target (see the
/// file comment).
class TextTargetWriter extends PropertyWriter {
  TextTargetWriter(
    super.controller,
    super.readState,
    super.ids, {
    required this.readNodes,
    required this.readSession,
  });

  /// What the section reads now (effective styles and the target). Read
  /// live, so one writer serves a whole scrub gesture.
  final TextTargetNodes Function() readNodes;

  /// The editing session while in edit mode.
  final TextEditSession? Function() readSession;

  TextTargetNodes get nodes => readNodes();
  TextEditSession? get session => readSession();

  ir.ResolvedNode? _resolvedIn(TextTargetNodes nodes, String id) {
    final i = nodes.ids.indexOf(id);
    return i < 0 ? null : nodes.resolved[i];
  }

  /// The command writing [value] at text style [rel], or null when the
  /// write only changes the pending typing style.
  EditCommand? commandFor(String rel, ir.IrValue value) {
    final key = 'text-style:${ids.join(',')}:$rel';
    final nodes = this.nodes;
    ir.ResolvedNode? resolved(String id) => _resolvedIn(nodes, id);
    final t = nodes.target;
    if (t == null) {
      return StyleTextNodes(
        [
          for (var i = 0; i < nodes.ids.length; i++)
            if (nodes.authored[i] is ir.TextNode) nodes.ids[i],
        ],
        rel,
        value,
        resolved: resolved,
        coalesceKey: key,
      );
    }
    if (_isParagraphField(rel)) {
      return StyleTextParagraphs(
        t.nodeId,
        t.start,
        t.end,
        styleFieldOf(rel),
        value,
        coalesceKey: key,
      );
    }
    if (t.collapsed) {
      final i = nodes.ids.indexOf(t.nodeId);
      final n = i < 0 ? null : nodes.authored[i];
      final empty =
          n is ir.TextNode &&
          n.content.isNotEmpty &&
          paragraphLength(n.content[pointOf(n.content, t.start).paragraph]) ==
              0;
      if (!empty) {
        session?.addPendingStyle({rel: value});
        return null;
      }
    }
    final rn = resolved(t.nodeId);
    return StyleTextRange(
      t.nodeId,
      t.start,
      t.end,
      {rel: value},
      effective: (p, s) => resolvedSpanStyle(rn, p, s),
      coalesceKey: key,
    );
  }

  CommandResult _noChange() =>
      CommandResult(document: readState().document, label: 'Typing style');

  @override
  CommandResult set(String path, ir.IrValue value, {bool shared = false}) {
    final rel = textStyleRel(path);
    if (rel == null) return super.set(path, value, shared: shared);
    final c = commandFor(rel, value);
    return c == null ? _noChange() : run(c, shared: shared);
  }

  @override
  CommandResult setMany(Map<String, ir.IrValue> values, {bool shared = false}) {
    if (!values.keys.any((p) => textStyleRel(p) != null)) {
      return super.setMany(values, shared: shared);
    }
    final commands = <EditCommand>[];
    for (final MapEntry(key: path, :value) in values.entries) {
      final rel = textStyleRel(path);
      if (rel == null) {
        commands.add(SetProperty(ids, path, value));
        continue;
      }
      final c = commandFor(rel, value);
      if (c != null) commands.add(c);
    }
    if (commands.isEmpty) return _noChange();
    return run(
      CommandBatch(commands, label: 'Change text style'),
      shared: shared,
    );
  }
}
