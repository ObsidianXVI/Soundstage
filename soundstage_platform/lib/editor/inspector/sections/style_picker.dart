import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';

// Named styles in the inspector (m3.md T3.1 "Styles"): the section header
// button of Fill, Stroke, Effects and Text lists the styles of its kind to
// apply, creates a style from the selection, and detaches. Applying is a
// property write (it follows the edit scope); creating a style is one undo
// step that adds the style and points the selected layers at it.

/// The style id the selection's authored nodes share at [stylePath], ''
/// when they differ, or null when none has one.
String? sharedStyleId(SelectedNodes s, String stylePath) {
  final reg = ir.PropertyRegistry.standard;
  String? common;
  var first = true;
  for (final n in s.authored) {
    final v = n == null ? null : reg.get(n, stylePath);
    final id = v is ir.StringValue ? v.value : null;
    if (first) {
      common = id;
      first = false;
    } else if (id != common) {
      return '';
    }
  }
  return common;
}

Map<String, String> _styleNames(ir.TokenSystem t, ir.StyleKind kind) =>
    switch (kind) {
      ir.StyleKind.text => {
        for (final e in t.textStyles.entries) e.key: e.value.name,
      },
      ir.StyleKind.paint => {
        for (final e in t.paintStyles.entries) e.key: e.value.name,
      },
      ir.StyleKind.effect => {
        for (final e in t.effectStyles.entries) e.key: e.value.name,
      },
    };

/// A text node's full local style: its text style's fields (if any) under
/// its own overrides.
ir.TextStyleOverride effectiveTextOverride(
  ir.StageDocument doc,
  ir.TextNode n,
) {
  final named = doc.tokens.textStyles[n.textStyleId]?.style;
  Map<String, Object?> nonNull(ir.TextStyleOverride s) => {
    for (final e in s.toJson().entries)
      if (e.value != null) e.key: e.value,
  };
  // Round-trip through JSON so nested values are plain maps.
  final merged = {if (named != null) ...nonNull(named), ...nonNull(n.style)};
  return ir.TextStyleOverride.fromJson(
    jsonDecode(jsonEncode(merged)) as Map<String, dynamic>,
  );
}

/// The header button of a style-bearing section.
///
/// - [stylePath]: `fillStyleId`, `strokeStyleId`, `effectStyleId` or
///   `textStyleId`.
/// - [valuePath]: the stack a new paint or effect style is made from
///   (`fills`, `strokes.paints`, `effects`); null for text.
class StylePickerButton extends ConsumerWidget {
  const StylePickerButton({
    required this.kind,
    required this.stylePath,
    this.valuePath,
    super.key,
  });

  final ir.StyleKind kind;
  final String stylePath;
  final String? valuePath;

  String get _noun => switch (kind) {
    ir.StyleKind.text => 'text style',
    ir.StyleKind.paint => 'colour style',
    ir.StyleKind.effect => 'effect style',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    return Builder(
      builder: (anchor) => SsIconButton(
        key: ValueKey<String>('style-picker-$stylePath'),
        icon: SsIcons.layoutTemplate,
        semanticLabel: 'Styles',
        tooltip: 'Styles',
        size: 24,
        iconSize: 14,
        onPressed: () => _open(context, anchor, ref, scope.writer),
      ),
    );
  }

  void _open(
    BuildContext context,
    BuildContext anchor,
    WidgetRef ref,
    PropertyWriter writer,
  ) {
    final sel = ref.read(selectedNodesProvider);
    final names = _styleNames(sel.document.tokens, kind);
    final current = sharedStyleId(sel, stylePath);
    final box = anchor.findRenderObject()! as RenderBox;
    showSsMenu(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      placement: SsPlacement.belowEnd,
      entries: [
        if (names.isEmpty)
          SsMenuItem(label: 'No ${_noun}s yet', enabled: false),
        for (final MapEntry(key: id, value: name) in names.entries)
          SsMenuItem(
            label: name,
            checked: current == id,
            onSelected: () => writer.set(stylePath, ir.IrValue.string(id)),
          ),
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Create $_noun…',
          icon: SsIcons.plus,
          onSelected: () => _create(context, ref),
        ),
        if (current != null && current.isNotEmpty)
          SsMenuItem(
            label: 'Detach style',
            icon: SsIcons.unlink,
            onSelected: () => _detach(ref),
          ),
      ],
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final ctl = ref.read(editorControllerProvider.notifier);
    final sel = ref.read(selectedNodesProvider);
    final taken = _styleNames(sel.document.tokens, kind).values.toSet();
    var suggestion = switch (kind) {
      ir.StyleKind.text => 'Text style',
      ir.StyleKind.paint => 'Colour',
      ir.StyleKind.effect => 'Effect',
    };
    for (var i = 2; taken.contains(suggestion); i++) {
      suggestion = '${suggestion.split(' ').first} $i';
    }
    final name = await showSsPrompt(
      context,
      title: 'Create $_noun',
      initialValue: suggestion,
      confirmLabel: 'Create',
    );
    if (name == null) return;
    final ids = sel.ids.where((id) => !id.contains('/')).toList();
    final stack = valuePath == null ? null : sel.read(valuePath!).value;
    final styleId = ir.IdGenerator.forDocument(sel.document).next();
    final reg = ir.PropertyRegistry.standard;
    ctl.execute(
      TokenEdit('Create style', (doc) {
        var r = switch (kind) {
          ir.StyleKind.paint => ir.setPaintStyle(
            doc,
            styleId,
            ir.PaintStyleDef(
              name: name,
              paints: stack is ir.PaintsValue ? stack.value : const [],
            ),
          ),
          ir.StyleKind.effect => ir.setEffectStyle(
            doc,
            styleId,
            ir.EffectStyleDef(
              name: name,
              effects: stack is ir.EffectsValue ? stack.value : const [],
            ),
          ),
          ir.StyleKind.text => ir.setTextStyle(
            doc,
            styleId,
            ir.TextStyleDef(
              name: name,
              style: switch (ir.DocumentIndex.of(doc).node(ids.first)) {
                final ir.TextNode n => effectiveTextOverride(doc, n),
                _ => const ir.TextStyleOverride(),
              },
            ),
          ),
        };
        for (final id in ids) {
          if (!r.ok) break;
          r = ir.updateNode(r.document, id, (n) {
            final next =
                reg.lookup(stylePath)?.trySet(n, ir.IrValue.string(styleId)) ??
                n;
            // The style now holds the text's look; local overrides would
            // hide later edits of the style.
            return next is ir.TextNode && kind == ir.StyleKind.text
                ? next.copyWith(style: const ir.TextStyleOverride())
                : next;
          });
        }
        return r.ok ? r.copyWith(changed: true) : r;
      }),
    );
  }

  void _detach(WidgetRef ref) {
    final ctl = ref.read(editorControllerProvider.notifier);
    final ids = ref
        .read(selectedNodesProvider)
        .ids
        .where((id) => !id.contains('/'))
        .toList();
    ctl.execute(
      TokenEdit('Detach style', (doc) {
        var r = ir.EditResult(document: doc, changed: false);
        for (final id in ids) {
          final d = r.document;
          r = ir.updateNode(d, id, (n) => ir.detachStyle(d, n, stylePath));
          if (!r.ok) break;
        }
        return r.ok ? r.copyWith(changed: !identical(r.document, doc)) : r;
      }),
    );
  }
}
