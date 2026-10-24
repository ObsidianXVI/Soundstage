import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'rich_text_model.dart';

// What a text style edit applies to, and the effective styles it reads:
// the span styles of a text selection in edit mode, or every span of whole
// text nodes otherwise (T1.8).

/// The text selection a style edit targets in edit mode: document range
/// [start, end) of [nodeId]. Collapsed, it is the caret, whose style is
/// that of the span typed text would join plus [pending] (span-relative
/// paths set by Cmd+B with nothing selected).
class TextRangeTarget {
  const TextRangeTarget({
    required this.nodeId,
    required this.start,
    required this.end,
    this.pending = const {},
  });

  final String nodeId;
  final int start;
  final int end;
  final Map<String, ir.IrValue> pending;

  bool get collapsed => start == end;

  @override
  bool operator ==(Object other) =>
      other is TextRangeTarget &&
      other.nodeId == nodeId &&
      other.start == start &&
      other.end == end &&
      _mapEquals(other.pending, pending);

  @override
  int get hashCode => Object.hash(nodeId, start, end, pending.length);
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}

/// The (paragraph, span) refs a style edit over [start, end) of [content]
/// reads: the spans overlapping it, or for a collapsed range the span typed
/// text joins.
List<SpanRef> spanRefsFor(List<ir.Paragraph> content, int start, int end) {
  if (start != end) {
    return [for (final (r, _, _) in spansInRange(content, start, end)) r];
  }
  final at = typingSpanAt(content, start);
  return at == null ? const [] : [at.ref];
}

/// Every span of [content] with text (all spans when none has any).
List<SpanRef> allSpanRefs(List<ir.Paragraph> content) {
  final out = <SpanRef>[];
  for (var p = 0; p < content.length; p++) {
    final spans = content[p].spans;
    for (var s = 0; s < spans.length; s++) {
      if (spans[s].text.isNotEmpty) out.add(SpanRef(p, s));
    }
  }
  if (out.isNotEmpty) return out;
  return [
    for (var p = 0; p < content.length; p++)
      for (var s = 0; s < content[p].spans.length; s++) SpanRef(p, s),
  ];
}

/// The resolved spans of [rn] at [refs] (refs past the resolved content are
/// skipped).
List<ir.ResolvedSpan> resolvedSpansAt(ir.ResolvedNode rn, List<SpanRef> refs) {
  final paras = rn.paragraphs;
  if (paras == null) return const [];
  return [
    for (final r in refs)
      if (r.paragraph < paras.length &&
          r.span < paras[r.paragraph].spans.length)
        paras[r.paragraph].spans[r.span],
  ];
}

/// The keyboard style toggles (Cmd+B / I / U).
enum TextToggle { bold, italic, underline }

/// The weight from which text counts as bold.
const int kBoldThreshold = 600;

bool _isOn(TextToggle t, ir.TextStyle s) => switch (t) {
  TextToggle.bold => s.fontWeight >= kBoldThreshold,
  TextToggle.italic => s.italic,
  TextToggle.underline => s.decoration.kind == ir.TextDecorationKind.underline,
};

/// Whether [t] is on for every style of [styles] (none: off).
bool toggleIsOn(TextToggle t, Iterable<ir.TextStyle> styles) {
  var any = false;
  for (final s in styles) {
    if (!_isOn(t, s)) return false;
    any = true;
  }
  return any;
}

/// The span-relative writes that toggle [t] over spans whose effective
/// styles are [styles], given the node-level style [inherited] the spans
/// fall back to:
///
/// - bold: on → weight 700, off → back to the inherited weight; when the
///   inherited weight is itself bold, on clears the span's weight and off
///   writes 400;
/// - italic: the same with the inherited slant;
/// - underline: `decoration.kind` underline ↔ none.
Map<String, ir.IrValue> toggleWrites(
  TextToggle t,
  Iterable<ir.TextStyle> styles,
  ir.TextStyle? inherited,
) {
  final on = !toggleIsOn(t, styles);
  switch (t) {
    case TextToggle.bold:
      final inheritedBold = (inherited?.fontWeight ?? 400) >= kBoldThreshold;
      return {
        'fontWeight': on
            ? (inheritedBold
                  ? const ir.IrValue.none()
                  : const ir.IrValue.number(700))
            : (inheritedBold
                  ? const ir.IrValue.number(400)
                  : const ir.IrValue.none()),
      };
    case TextToggle.italic:
      final inheritedItalic = inherited?.italic ?? false;
      return {
        'italic': on == inheritedItalic
            ? const ir.IrValue.none()
            : ir.IrValue.boolean(on),
      };
    case TextToggle.underline:
      return {
        'decoration.kind': ir.IrValue.enumValue(on ? 'underline' : 'none'),
      };
  }
}

/// [s] as an override that sets every field.
ir.TextStyleOverride fullOverride(ir.TextStyle s) => ir.TextStyleOverride(
  fontFamilyId: s.fontFamilyId,
  fontWeight: s.fontWeight,
  italic: s.italic,
  fontVariations: s.fontVariations,
  fontSize: s.fontSize,
  lineHeight: s.lineHeight,
  letterSpacing: s.letterSpacing,
  paragraphSpacing: s.paragraphSpacing,
  paragraphIndent: s.paragraphIndent,
  textCase: s.textCase,
  decoration: s.decoration,
  fills: s.fills,
  openType: s.openType,
  baselineShift: s.baselineShift,
  listStyle: s.listStyle,
);

/// [style] with span-relative [writes] applied (the pending typing style
/// shown at a collapsed caret). `none` restores the field from [inherited].
/// Paths that do not apply are skipped.
ir.TextStyle applyStyleWrites(
  ir.TextStyle style,
  Map<String, ir.IrValue> writes, {
  ir.TextStyle? inherited,
}) {
  if (writes.isEmpty) return style;
  final reg = ir.PropertyRegistry.standard;
  ir.Node carrier = ir.TextNode(
    common: const ir.NodeCommon(id: ''),
    style: fullOverride(style),
  );
  final from = fullOverride(inherited ?? style);
  for (final MapEntry(key: rel, :value) in writes.entries) {
    if (value is ir.NoneValue && !rel.contains('.')) {
      final back = reg.get(
        ir.TextNode(
          common: const ir.NodeCommon(id: ''),
          style: from,
        ),
        'style.$rel',
      );
      if (back == null) continue;
      carrier = reg.trySet(carrier, 'style.$rel', back) ?? carrier;
      continue;
    }
    carrier = reg.trySet(carrier, 'style.$rel', value) ?? carrier;
  }
  return ir.mergeTextStyle(style, (carrier as ir.TextNode).style);
}
