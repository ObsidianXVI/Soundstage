// Animated text styles (architecture §7, §17.1; DECISIONS "Animated text
// styles must render"): `style.*` and `content.<p>.spans.<s>.style.*` tracks
// compiled to typed channels that re-merge only the affected span styles.

import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_box.dart' show StageInvalidation;
import 'compiled_track.dart';

/// A render object that applies some tracks itself, in typed form, instead
/// of through the node animator (the registry). The animator offers every
/// non-slot track to [bindTrack]; a non-null handle means the host owns it.
abstract interface class StageTypedTrackHost {
  /// Returns a handle when this host applies [track], else null.
  Object? bindTrack(CompiledTrack track);

  /// [track]'s output changed (after `evaluate` returned true).
  void trackChanged(Object handle);

  /// Stops applying the track of [handle].
  void unbindTrack(Object handle);
}

/// Which text style field a channel writes.
enum TextStyleField {
  fontSize,
  fontWeight,
  letterSpacing,
  lineHeight,
  paragraphSpacing,
  paragraphIndent,

  /// `fontVariations.<tag>`.
  fontVariation,

  /// `fills.<paintId>.color` (solid paints).
  fillColor,

  /// `fills.<paintId>.opacity`.
  fillOpacity,

  /// Any other `style.*` path: applied through the registry. Only discrete
  /// (step) and structured (boxed) tracks land here; they touch `IrValue`s
  /// only when their value changes (a keyframe crossing for step tracks).
  generic,
}

final RegExp _spanPath = RegExp(r'^content\.(\d+)\.spans\.(\d+)\.style\.(.+)$');

const ir.NodeCommon _carrierCommon = ir.NodeCommon(id: '_text_style_carrier');

/// One `style.*` / `content.<p>.spans.<s>.style.*` track bound to a text
/// node.
///
/// - **Precedence.** A node-level channel (`style.*`) writes the node's
///   override, so it reaches only spans (and, for paragraph fields,
///   paragraphs) that do not override the field themselves. A span-level
///   channel writes that span. Node-level channels apply first.
/// - **Fills.** `style.fills.<id>.*` changes the paint with that id in each
///   reached span's merged fills (the named or default style's fills when
///   the node has no fill override), so a colour track on the default
///   `text` fill animates.
/// - **Invalidation** comes from the property's descriptor: colour and fill
///   fields repaint, size, spacing, weight, line height and variations
///   relayout.
class TextStyleChannel {
  TextStyleChannel._({
    required this.track,
    required this.paragraph,
    required this.span,
    required this.field,
    required this.key,
    required this.invalidation,
    required this.rest,
    this.generic,
  });

  /// The channel for [track], or null when its property is not a text
  /// style path this node can address.
  static TextStyleChannel? compile(
    CompiledTrack track, {
    ir.PropertyRegistry? registry,
  }) {
    final match = track.match;
    if (match == null) return null;
    final path = track.track.property;
    int p = -1, s = -1;
    String rest;
    if (path.startsWith('style.')) {
      rest = path.substring(6);
    } else {
      final m = _spanPath.firstMatch(path);
      if (m == null) return null;
      p = int.parse(m.group(1)!);
      s = int.parse(m.group(2)!);
      rest = m.group(3)!;
    }
    final parts = rest.split('.');
    TextStyleField field;
    String? key;
    switch (parts) {
      case ['fontSize']:
        field = TextStyleField.fontSize;
      case ['fontWeight']:
        field = TextStyleField.fontWeight;
      case ['letterSpacing']:
        field = TextStyleField.letterSpacing;
      case ['lineHeight']:
        field = TextStyleField.lineHeight;
      case ['paragraphSpacing'] when p < 0:
        field = TextStyleField.paragraphSpacing;
      case ['paragraphIndent'] when p < 0:
        field = TextStyleField.paragraphIndent;
      case ['fontVariations', final tag]:
        field = TextStyleField.fontVariation;
        key = tag;
      case ['fills', final id, 'color']:
        field = TextStyleField.fillColor;
        key = id;
      case ['fills', final id, 'opacity']:
        field = TextStyleField.fillOpacity;
        key = id;
      default:
        field = TextStyleField.generic;
    }
    ir.PropertyMatch? generic;
    if (field == TextStyleField.generic) {
      generic = (registry ?? ir.PropertyRegistry.standard).lookup(
        'style.$rest',
      );
      if (generic == null) return null;
      if (parts.first == 'paragraphSpacing' ||
          parts.first == 'paragraphIndent' ||
          parts.first == 'listStyle') {
        // Paragraph-level fields on a span have no effect.
        return null;
      }
    }
    final inv = switch (match.descriptor.invalidation) {
      ir.Invalidation.none => StageInvalidation.none,
      ir.Invalidation.layout => StageInvalidation.layout,
      ir.Invalidation.paint ||
      ir.Invalidation.compositing => StageInvalidation.paint,
    };
    return TextStyleChannel._(
      track: track,
      paragraph: p,
      span: s,
      field: field,
      key: key,
      invalidation: inv,
      rest: parts,
      generic: generic,
    );
  }

  final CompiledTrack track;

  /// The paragraph and span a span-level channel writes; −1 for node level.
  final int paragraph;
  final int span;
  final TextStyleField field;

  /// The paint id or axis tag.
  final String? key;
  final StageInvalidation invalidation;

  /// The path below `style.`, split.
  final List<String> rest;
  final ir.PropertyMatch? generic;

  bool get isNodeLevel => paragraph < 0;
  bool get isParagraphField =>
      field == TextStyleField.paragraphSpacing ||
      field == TextStyleField.paragraphIndent;

  /// Whether a span's own override [o] sets this channel's field (a
  /// node-level channel then does not reach the span).
  bool overriddenBy(ir.TextStyleOverride o) => switch (rest.first) {
    'fontFamilyId' => o.fontFamilyId != null,
    'fontWeight' => o.fontWeight != null,
    'italic' => o.italic != null,
    'fontVariations' =>
      rest.length > 1 && (o.fontVariations?.containsKey(rest[1]) ?? false),
    'fontSize' => o.fontSize != null,
    'lineHeight' => o.lineHeight != null,
    'letterSpacing' => o.letterSpacing != null,
    'textCase' => o.textCase != null,
    'decoration' => o.decoration != null,
    'fills' => o.fills != null,
    'openType' =>
      rest.length > 1 && (o.openType?.containsKey(rest[1]) ?? false),
    'baselineShift' => o.baselineShift != null,
    _ => false,
  };

  /// [s] with this channel's current value applied. Typed fields read the
  /// compiled track's output directly.
  ir.TextStyle apply(ir.TextStyle s) {
    final t = track;
    if (!t.evaluated) return s;
    switch (field) {
      case TextStyleField.fontSize:
        final v = t.scalar;
        return v == s.fontSize ? s : s.copyWith(fontSize: v < 0 ? 0 : v);
      case TextStyleField.fontWeight:
        final v = t.scalar.round().clamp(1, 1000);
        return v == s.fontWeight ? s : s.copyWith(fontWeight: v);
      case TextStyleField.letterSpacing:
        final v = t.currentVariant;
        final ls = v == 0
            ? ir.LetterSpacing.px(t.scalar)
            : v == 1
            ? ir.LetterSpacing.percent(t.scalar)
            : _decode<ir.LetterSpacing>(t);
        return ls == null ? s : s.copyWith(letterSpacing: ls);
      case TextStyleField.lineHeight:
        final v = t.currentVariant;
        final lh = v == 0
            ? ir.LineHeight.px(t.scalar)
            : v == 1
            ? ir.LineHeight.percent(t.scalar)
            : _decode<ir.LineHeight>(t);
        return lh == null ? s : s.copyWith(lineHeight: lh);
      case TextStyleField.paragraphSpacing:
        return s.copyWith(paragraphSpacing: t.scalar);
      case TextStyleField.paragraphIndent:
        return s.copyWith(paragraphIndent: t.scalar);
      case TextStyleField.fontVariation:
        final v = t.scalar;
        if (s.fontVariations[key] == v) return s;
        return s.copyWith(fontVariations: {...s.fontVariations, key!: v});
      case TextStyleField.fillColor:
        return _withPaint(s, (p) {
          if (p is! ir.SolidPaint) return p;
          final o = t.out;
          return p.copyWith(
            color: ir.StageColor(r: o[0], g: o[1], b: o[2], a: o[3]),
          );
        });
      case TextStyleField.fillOpacity:
        return _withPaint(s, (p) => p.copyWith(opacity: t.scalar));
      case TextStyleField.generic:
        final value = t.value;
        final g = generic;
        if (value == null || g == null) return s;
        final head = rest.first;
        final seed = ir.TextStyleOverride(
          fills: head == 'fills' ? s.fills : null,
          decoration: head == 'decoration' ? s.decoration : null,
          fontVariations: head == 'fontVariations' ? s.fontVariations : null,
          openType: head == 'openType' ? s.openType : null,
        );
        final carrier = ir.TextNode(common: _carrierCommon, style: seed);
        final next = g.trySet(carrier, value);
        if (next is! ir.TextNode) return s;
        return ir.mergeTextStyle(s, next.style);
    }
  }

  ir.TextStyle _withPaint(ir.TextStyle s, ir.Paint Function(ir.Paint) f) {
    final fills = s.fills;
    for (var i = 0; i < fills.length; i++) {
      if (fills[i].id != key) continue;
      final next = List.of(fills);
      next[i] = f(fills[i]);
      return s.copyWith(fills: next);
    }
    return s;
  }

  static T? _decode<T>(CompiledTrack t) => switch (t.value) {
    ir.LineHeightValue(:final value) when value is T => value as T,
    ir.LetterSpacingValue(:final value) when value is T => value as T,
    _ => null,
  };
}

/// The typed text-style channels of one text node, and the re-merge of its
/// resolved paragraphs.
///
/// **Allocation.** Nothing is allocated per frame unless a channel's value
/// changed. Then [apply] allocates, per affected span, a new `TextStyle`
/// (plus a fills list and paint for fill channels) and a `ResolvedSpan`, and
/// per affected paragraph a `ResolvedParagraph` and its span list; the
/// layout then rebuilds only those paragraphs' `TextSpan`s and painters.
class StageTextAnimation {
  final List<TextStyleChannel> _channels = [];

  bool get isEmpty => _channels.isEmpty;
  int get length => _channels.length;

  void add(TextStyleChannel c) {
    // Node-level channels apply before span-level ones (spans win).
    if (c.isNodeLevel) {
      final i = _channels.indexWhere((x) => !x.isNodeLevel);
      _channels.insert(i < 0 ? _channels.length : i, c);
    } else {
      _channels.add(c);
    }
  }

  bool remove(TextStyleChannel c) => _channels.remove(c);

  /// [base] with every channel applied. Paragraphs and spans no channel
  /// changes are returned as the identical objects. [source] is the
  /// resolved text node (its spans' and paragraphs' own overrides decide
  /// which spans node-level channels reach).
  List<ir.ResolvedParagraph> apply(
    List<ir.ResolvedParagraph> base,
    ir.TextNode source,
  ) {
    if (_channels.isEmpty) return base;
    List<ir.ResolvedParagraph>? out;
    for (var pi = 0; pi < base.length; pi++) {
      final para = base[pi];
      final srcPara = pi < source.content.length ? source.content[pi] : null;
      List<ir.ResolvedSpan>? spans;
      for (var si = 0; si < para.spans.length; si++) {
        final rs = para.spans[si];
        final srcSpan = srcPara != null && si < srcPara.spans.length
            ? srcPara.spans[si]
            : null;
        var style = rs.style;
        for (final c in _channels) {
          if (c.isParagraphField) continue;
          if (c.isNodeLevel) {
            if (srcSpan != null && c.overriddenBy(srcSpan.style)) continue;
          } else if (c.paragraph != pi || c.span != si) {
            continue;
          }
          style = c.apply(style);
        }
        if (!identical(style, rs.style)) {
          spans ??= List.of(para.spans);
          spans[si] = rs.copyWith(style: style);
        }
      }
      var spacing = para.paragraphSpacing;
      var indent = para.paragraphIndent;
      final ps = srcPara?.style;
      for (final c in _channels) {
        if (!c.isParagraphField || !c.track.evaluated) continue;
        if (c.field == TextStyleField.paragraphSpacing &&
            ps?.paragraphSpacing == null) {
          spacing = c.track.scalar;
        } else if (c.field == TextStyleField.paragraphIndent &&
            ps?.paragraphIndent == null) {
          indent = c.track.scalar;
        }
      }
      if (spans != null ||
          spacing != para.paragraphSpacing ||
          indent != para.paragraphIndent) {
        out ??= List.of(base);
        out[pi] = para.copyWith(
          spans: spans ?? para.spans,
          paragraphSpacing: spacing,
          paragraphIndent: indent,
        );
      }
    }
    return out ?? base;
  }
}
