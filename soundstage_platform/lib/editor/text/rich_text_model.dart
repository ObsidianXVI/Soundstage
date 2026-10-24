import 'package:soundstage_platform/ir/ir.dart' as ir;

// The rich-text editing model (T1.8) over a text node's
// `content: [Paragraph{spans}]` (architecture §7).
//
// **Offsets.** A document offset counts UTF-16 code units of the plain text
// with one separator unit between paragraphs (`textCharacters`: paragraphs
// joined by `\n`). [TextPoint] is the same position as (paragraph, offset in
// the paragraph's text).
//
// **Origins.** Every edit returns a [ContentEdit]: the new content plus, for
// each new paragraph and span, the old paragraph/span it came from. Split
// halves and text typed into a span keep that span's origin. The commands
// use the origins to carry breakpoint patches and token bindings addressed
// by index (`content.<p>.spans.<s>.style.*`) over to the new indices, so an
// edit never silently moves a mobile-only style onto other text.
//
// **Normal form.** After an edit, adjacent spans of a paragraph merge when
// their style, link and patch signature (see [SpanSignature]) are equal;
// empty spans are dropped, except that every paragraph keeps at least one
// span (an empty paragraph keeps the style it will type with).

/// A position in a text node's content: paragraph index and UTF-16 offset in
/// that paragraph's text.
class TextPoint {
  const TextPoint(this.paragraph, this.offset);

  final int paragraph;
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is TextPoint &&
      other.paragraph == paragraph &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(paragraph, offset);

  @override
  String toString() => 'TextPoint($paragraph, $offset)';
}

/// A span of the content: paragraph and span indices.
class SpanRef {
  const SpanRef(this.paragraph, this.span);

  final int paragraph;
  final int span;

  @override
  bool operator ==(Object other) =>
      other is SpanRef && other.paragraph == paragraph && other.span == span;

  @override
  int get hashCode => Object.hash(paragraph, span);

  @override
  String toString() => 'SpanRef($paragraph, $span)';
}

/// Where a document offset falls: the span and the offset inside it.
class SpanLocation {
  const SpanLocation(this.paragraph, this.span, this.offsetInSpan);

  final int paragraph;
  final int span;
  final int offsetInSpan;

  SpanRef get ref => SpanRef(paragraph, span);
}

/// Decides which spans may merge beyond style and link equality: spans whose
/// origins have different signatures (different breakpoint patches) stay
/// apart. Null signatures compare equal.
typedef SpanSignature = Object? Function(SpanRef? origin);

/// The result of a content edit (see the file comment).
class ContentEdit {
  const ContentEdit({
    required this.content,
    required this.paragraphOrigins,
    required this.spanOrigins,
    required this.sourceShape,
    this.changed = true,
  });

  /// [content] unchanged, with the identity mapping.
  factory ContentEdit.identity(List<ir.Paragraph> content) => ContentEdit(
    content: content,
    paragraphOrigins: [for (var i = 0; i < content.length; i++) i],
    spanOrigins: [
      for (var p = 0; p < content.length; p++)
        [for (var s = 0; s < content[p].spans.length; s++) SpanRef(p, s)],
    ],
    sourceShape: shapeOf(content),
    changed: false,
  );

  final List<ir.Paragraph> content;

  /// Per new paragraph, the old paragraph it continues (null: new).
  final List<int?> paragraphOrigins;

  /// Per new paragraph, per span, the old span it came from (null: new).
  final List<List<SpanRef?>> spanOrigins;

  final bool changed;

  /// The span count of each paragraph of the content before the edit.
  final List<int> sourceShape;

  /// Whether every old paragraph and span is still there at its old index
  /// (no patch remapping needed).
  bool get isIdentityMapping {
    if (sourceShape.length != paragraphOrigins.length) return false;
    for (var p = 0; p < paragraphOrigins.length; p++) {
      if (paragraphOrigins[p] != p) return false;
      final spans = spanOrigins[p];
      if (spans.length != sourceShape[p]) return false;
      for (var s = 0; s < spans.length; s++) {
        final o = spans[s];
        if (o == null || o.paragraph != p || o.span != s) return false;
      }
    }
    return true;
  }

  /// Composes [next] (applied to this edit's content) after this edit.
  ContentEdit then(ContentEdit next) => ContentEdit(
    content: next.content,
    paragraphOrigins: [
      for (final o in next.paragraphOrigins)
        o == null ? null : paragraphOrigins[o],
    ],
    spanOrigins: [
      for (final ps in next.spanOrigins)
        [
          for (final o in ps)
            o == null ? null : spanOrigins[o.paragraph][o.span],
        ],
    ],
    sourceShape: sourceShape,
    changed: changed || next.changed,
  );
}

/// The span count of each paragraph of [content].
List<int> shapeOf(List<ir.Paragraph> content) => [
  for (final p in content) p.spans.length,
];

// ---- Measuring -----------------------------------------------------------------

/// The text length of [p] (UTF-16 units).
int paragraphLength(ir.Paragraph p) {
  var n = 0;
  for (final s in p.spans) {
    n += s.text.length;
  }
  return n;
}

/// The plain text of [content] (paragraphs joined by `\n`).
String plainTextOf(List<ir.Paragraph> content) {
  final b = StringBuffer();
  for (var i = 0; i < content.length; i++) {
    if (i > 0) b.write('\n');
    for (final s in content[i].spans) {
      b.write(s.text);
    }
  }
  return b.toString();
}

/// The document length of [content] (text plus paragraph separators).
int documentLength(List<ir.Paragraph> content) {
  if (content.isEmpty) return 0;
  var n = content.length - 1;
  for (final p in content) {
    n += paragraphLength(p);
  }
  return n;
}

/// The document offset where paragraph [index] starts.
int paragraphStart(List<ir.Paragraph> content, int index) {
  var n = 0;
  for (var i = 0; i < index && i < content.length; i++) {
    n += paragraphLength(content[i]) + 1;
  }
  return n;
}

/// The point of document offset [offset] (clamped to the document).
TextPoint pointOf(List<ir.Paragraph> content, int offset) {
  if (content.isEmpty) return const TextPoint(0, 0);
  var rest = offset < 0 ? 0 : offset;
  for (var i = 0; i < content.length; i++) {
    final len = paragraphLength(content[i]);
    if (rest <= len) return TextPoint(i, rest);
    rest -= len + 1;
  }
  final last = content.length - 1;
  return TextPoint(last, paragraphLength(content[last]));
}

/// The document offset of [point] (clamped to its paragraph).
int offsetOf(List<ir.Paragraph> content, TextPoint point) {
  if (content.isEmpty) return 0;
  final p = point.paragraph.clamp(0, content.length - 1);
  final len = paragraphLength(content[p]);
  return paragraphStart(content, p) + point.offset.clamp(0, len);
}

/// The span holding document offset [offset].
///
/// At a boundary between two spans, [before] picks the span that ends there
/// (the character before the caret), else the one that starts there. A
/// paragraph's start always gives its first span. Null for a paragraph
/// without spans.
SpanLocation? locate(
  List<ir.Paragraph> content,
  int offset, {
  bool before = true,
}) {
  final pt = pointOf(content, offset);
  if (content.isEmpty) return null;
  final p = pt.paragraph;
  final spans = content[p].spans;
  if (spans.isEmpty) return null;
  final rest = pt.offset;
  var at = 0;
  for (var i = 0; i < spans.length; i++) {
    final len = spans[i].text.length;
    if (len > 0) {
      if (rest > at && rest < at + len) return SpanLocation(p, i, rest - at);
      if (rest == at + len && before && rest > 0) {
        return SpanLocation(p, i, len);
      }
      if (rest == at && (!before || rest == 0)) return SpanLocation(p, i, 0);
    }
    at += len;
  }
  for (var i = spans.length - 1; i >= 0; i--) {
    if (spans[i].text.isNotEmpty) {
      return SpanLocation(p, i, spans[i].text.length);
    }
  }
  return SpanLocation(p, 0, 0);
}

/// The span typed text takes its style from at [offset] (Figma): the
/// character before the caret, or the one after it at a paragraph start.
SpanLocation? typingSpanAt(List<ir.Paragraph> content, int offset) {
  final pt = pointOf(content, offset);
  return locate(content, offset, before: pt.offset > 0);
}

/// The spans overlapping the document range [start, end), as
/// (span, start-in-span, end-in-span). A collapsed range in an empty
/// paragraph yields its (empty) span.
List<(SpanRef, int, int)> spansInRange(
  List<ir.Paragraph> content,
  int start,
  int end,
) {
  final out = <(SpanRef, int, int)>[];
  if (content.isEmpty) return out;
  final a = pointOf(content, start);
  final b = pointOf(content, end < start ? start : end);
  for (var p = a.paragraph; p <= b.paragraph; p++) {
    final spans = content[p].spans;
    final from = p == a.paragraph ? a.offset : 0;
    final to = p == b.paragraph ? b.offset : paragraphLength(content[p]);
    if (paragraphLength(content[p]) == 0 && spans.isNotEmpty) {
      if (from == to) out.add((SpanRef(p, 0), 0, 0));
      continue;
    }
    var at = 0;
    for (var s = 0; s < spans.length; s++) {
      final len = spans[s].text.length;
      final lo = at, hi = at + len;
      at = hi;
      if (len == 0) continue;
      final x = from > lo ? from : lo;
      final y = to < hi ? to : hi;
      if (x < y) out.add((SpanRef(p, s), x - lo, y - lo));
    }
  }
  return out;
}

/// The paragraph indices the range [start, end] touches.
List<int> paragraphsInRange(List<ir.Paragraph> content, int start, int end) {
  if (content.isEmpty) return const [];
  final a = pointOf(content, start).paragraph;
  final b = pointOf(content, end < start ? start : end).paragraph;
  return [for (var p = a; p <= b; p++) p];
}

// ---- Working form ------------------------------------------------------------------

class _WSpan {
  _WSpan(this.text, this.style, this.link, this.origin);

  _WSpan.of(ir.Span s, SpanRef o) : this(s.text, s.style, s.link, o);

  String text;
  ir.TextStyleOverride style;
  ir.SpanLink? link;
  SpanRef? origin;

  _WSpan copy([String? text]) => _WSpan(text ?? this.text, style, link, origin);
}

class _WPara {
  _WPara(this.spans, this.style, this.origin);

  final List<_WSpan> spans;
  ir.ParagraphStyle? style;
  int? origin;

  int get length {
    var n = 0;
    for (final s in spans) {
      n += s.text.length;
    }
    return n;
  }

  /// Splits the span containing [offset] there, returning the index of the
  /// first span at or after [offset].
  int splitAt(int offset) {
    var at = 0;
    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      final len = s.text.length;
      if (offset == at) return i;
      if (offset < at + len) {
        final k = offset - at;
        spans
          ..[i] = s.copy(s.text.substring(0, k))
          ..insert(i + 1, s.copy(s.text.substring(k)));
        return i + 1;
      }
      at += len;
    }
    return spans.length;
  }
}

List<_WPara> _working(List<ir.Paragraph> content) => [
  for (var p = 0; p < content.length; p++)
    _WPara(
      [
        for (var s = 0; s < content[p].spans.length; s++)
          _WSpan.of(content[p].spans[s], SpanRef(p, s)),
      ],
      content[p].style,
      p,
    ),
];

bool _sameLink(ir.SpanLink? a, ir.SpanLink? b) => a == b;

/// Normalises [paras] (merges and drops; see the file comment) and builds
/// the [ContentEdit].
ContentEdit _finish(
  List<_WPara> paras,
  SpanSignature? signature,
  List<int> sourceShape,
) {
  if (paras.isEmpty) {
    paras.add(
      _WPara([_WSpan('', const ir.TextStyleOverride(), null, null)], null, 0),
    );
  }
  final content = <ir.Paragraph>[];
  final pOrigins = <int?>[];
  final sOrigins = <List<SpanRef?>>[];
  for (final p in paras) {
    final kept = <_WSpan>[];
    final hasText = p.spans.any((s) => s.text.isNotEmpty);
    for (final s in p.spans) {
      if (s.text.isEmpty && (hasText || kept.isNotEmpty)) continue;
      if (kept.isNotEmpty) {
        final prev = kept.last;
        if (prev.style == s.style &&
            _sameLink(prev.link, s.link) &&
            (signature == null ||
                signature(prev.origin) == signature(s.origin))) {
          prev.text += s.text;
          prev.origin ??= s.origin;
          continue;
        }
      }
      kept.add(s.copy());
    }
    if (kept.isEmpty) {
      kept.add(_WSpan('', const ir.TextStyleOverride(), null, null));
    }
    content.add(
      ir.Paragraph(
        style: p.style,
        spans: [
          for (final s in kept)
            ir.Span(text: s.text, style: s.style, link: s.link),
        ],
      ),
    );
    pOrigins.add(p.origin);
    sOrigins.add([for (final s in kept) s.origin]);
  }
  return ContentEdit(
    content: content,
    paragraphOrigins: pOrigins,
    spanOrigins: sOrigins,
    sourceShape: sourceShape,
  );
}

// ---- Edits ---------------------------------------------------------------------

/// Replaces the document range [start, end) of [content] with [text]
/// (`\n` starts a new paragraph).
///
/// - The inserted text takes the style and origin of the span the
///   replaced range starts in, or for a collapsed range of [typingSpanAt]
///   (the character before; after at a paragraph start). [style] replaces
///   that style.
/// - It joins that span's link only when typed strictly inside the link.
/// - Deleting across paragraphs merges them; the first keeps its
///   paragraph style. A new paragraph (Enter) carries over the paragraph
///   style of the one it splits, and its origin.
ContentEdit replaceText(
  List<ir.Paragraph> content,
  int start,
  int end,
  String text, {
  ir.TextStyleOverride? style,
  SpanSignature? signature,
}) {
  if (end < start) {
    final t = start;
    start = end;
    end = t;
  }
  if (start == end && text.isEmpty) return ContentEdit.identity(content);
  final paras = _working(content);
  if (paras.isEmpty) {
    paras.add(
      _WPara([_WSpan('', const ir.TextStyleOverride(), null, null)], null, 0),
    );
  }
  // The style source, from the original content.
  final source = start < end
      ? locate(content, start, before: false)
      : typingSpanAt(content, start);
  _WSpan template;
  var insideLink = false;
  if (source == null) {
    template = _WSpan('', style ?? const ir.TextStyleOverride(), null, null);
  } else {
    final s = content[source.paragraph].spans[source.span];
    insideLink =
        s.link != null &&
        source.offsetInSpan > 0 &&
        source.offsetInSpan < s.text.length;
    template = _WSpan(
      '',
      style ?? s.style,
      insideLink ? s.link : null,
      SpanRef(source.paragraph, source.span),
    );
  }

  // Delete [start, end).
  final a = pointOf(content, start);
  final b = pointOf(content, end);
  final first = paras[a.paragraph];
  if (start < end) {
    final last = paras[b.paragraph];
    final cutB = last.splitAt(b.offset);
    final tail = last.spans.sublist(cutB);
    final cutA = first.splitAt(a.offset);
    first.spans.removeRange(cutA, first.spans.length);
    first.spans.addAll(tail);
    paras.removeRange(a.paragraph + 1, b.paragraph + 1);
  }

  // Insert at a.
  if (text.isNotEmpty) {
    final lines = text.split('\n');
    final at = first.splitAt(a.offset);
    final after = first.spans.sublist(at);
    first.spans.removeRange(at, first.spans.length);
    if (lines.first.isNotEmpty) first.spans.add(template.copy(lines.first));
    var cur = first;
    for (var i = 1; i < lines.length; i++) {
      // A paragraph that would start empty keeps the typing style.
      cur.spans.add(template.copy(''));
      final next = _WPara(
        [if (lines[i].isNotEmpty) template.copy(lines[i])],
        first.style,
        first.origin,
      );
      paras.insert(paras.indexOf(cur) + 1, next);
      cur = next;
    }
    if (after.isEmpty || after.every((s) => s.text.isEmpty)) {
      cur.spans.add(template.copy(''));
    }
    cur.spans.addAll(after);
  } else if (first.spans.every((s) => s.text.isEmpty)) {
    first.spans.insert(0, template.copy(''));
  }
  return _finish(paras, signature, shapeOf(content));
}

/// Splits spans at the document offsets of [offsets] without merging
/// (a structural change with no visual effect). The identity edit when no
/// split was needed.
ContentEdit splitSpansAt(List<ir.Paragraph> content, Iterable<int> offsets) {
  final paras = _working(content);
  var changed = false;
  for (final o in offsets) {
    if (content.isEmpty) break;
    final pt = pointOf(content, o);
    final p = paras[pt.paragraph];
    final before = p.spans.length;
    p.splitAt(pt.offset);
    changed |= p.spans.length != before;
  }
  if (!changed) return ContentEdit.identity(content);
  return ContentEdit(
    content: [
      for (final p in paras)
        ir.Paragraph(
          style: p.style,
          spans: [
            for (final s in p.spans)
              ir.Span(text: s.text, style: s.style, link: s.link),
          ],
        ),
    ],
    paragraphOrigins: [for (final p in paras) p.origin],
    spanOrigins: [
      for (final p in paras) [for (final s in p.spans) s.origin],
    ],
    sourceShape: shapeOf(content),
  );
}

/// Applies [f] to every span inside [start, end) (splitting at the ends),
/// then normalises. A collapsed range in an empty paragraph restyles its
/// empty span.
ContentEdit mapSpans(
  List<ir.Paragraph> content,
  int start,
  int end,
  ir.Span Function(ir.Span span) f, {
  SpanSignature? signature,
}) {
  final split = splitSpansAt(content, [start, end]);
  final paras = _working(split.content);
  for (final (ref, _, _) in spansInRange(split.content, start, end)) {
    final w = paras[ref.paragraph].spans[ref.span];
    final next = f(ir.Span(text: w.text, style: w.style, link: w.link));
    w
      ..style = next.style
      ..link = next.link;
  }
  final edit = _finish(paras, (o) {
    if (signature == null || o == null) return null;
    return signature(split.spanOrigins[o.paragraph][o.span]);
  }, shapeOf(split.content));
  return split.then(edit);
}

/// Sets (or with null removes) the link of the text in [start, end).
ContentEdit setLink(
  List<ir.Paragraph> content,
  int start,
  int end,
  ir.SpanLink? link, {
  SpanSignature? signature,
}) => mapSpans(
  content,
  start,
  end,
  (s) => s.copyWith(link: link),
  signature: signature,
);

/// Re-normalises [content] (merging spans that became equal, e.g. after a
/// style write), keeping origins.
ContentEdit normalise(List<ir.Paragraph> content, {SpanSignature? signature}) {
  final edit = _finish(_working(content), signature, shapeOf(content));
  if (_sameContent(edit.content, content)) {
    return ContentEdit.identity(content);
  }
  return edit;
}

bool _sameContent(List<ir.Paragraph> a, List<ir.Paragraph> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i].spans, y = b[i].spans;
    if (x.length != y.length || a[i].style != b[i].style) return false;
    for (var j = 0; j < x.length; j++) {
      if (x[j] != y[j]) return false;
    }
  }
  return true;
}

// ---- Words -------------------------------------------------------------------

enum _Cls { space, word, punct }

_Cls _cls(int unit) {
  if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0xA0) {
    return _Cls.space;
  }
  if ((unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      unit == 0x5F ||
      unit == 0x27 ||
      unit == 0x2019 ||
      unit >= 0xC0) {
    return _Cls.word;
  }
  return _Cls.punct;
}

/// The word around [offset] in [text] (double-click): the run of the same
/// class (word characters, spaces or punctuation) touching the offset,
/// preferring the character after it.
(int, int) wordAt(String text, int offset) {
  if (text.isEmpty) return (0, 0);
  var i = offset.clamp(0, text.length);
  if (i == text.length ||
      (i > 0 &&
          _cls(text.codeUnitAt(i)) != _Cls.word &&
          _cls(text.codeUnitAt(i - 1)) == _Cls.word)) {
    i--;
  }
  final c = _cls(text.codeUnitAt(i));
  var a = i, b = i + 1;
  while (a > 0 && _cls(text.codeUnitAt(a - 1)) == c) {
    a--;
  }
  while (b < text.length && _cls(text.codeUnitAt(b)) == c) {
    b++;
  }
  return (a, b);
}

/// The next word boundary after [offset] (Alt/Option+Right): skips spaces
/// and punctuation, then to the end of the word.
int nextWordBoundary(String text, int offset) {
  var i = offset;
  if (i >= text.length) return text.length;
  while (i < text.length && _cls(text.codeUnitAt(i)) != _Cls.word) {
    if (text.codeUnitAt(i) == 0x0A) return i == offset ? i + 1 : i;
    i++;
  }
  while (i < text.length && _cls(text.codeUnitAt(i)) == _Cls.word) {
    i++;
  }
  return i;
}

/// The previous word boundary before [offset] (Alt/Option+Left).
int previousWordBoundary(String text, int offset) {
  var i = offset;
  if (i <= 0) return 0;
  while (i > 0 && _cls(text.codeUnitAt(i - 1)) != _Cls.word) {
    if (text.codeUnitAt(i - 1) == 0x0A) return i == offset ? i - 1 : i;
    i--;
  }
  while (i > 0 && _cls(text.codeUnitAt(i - 1)) == _Cls.word) {
    i--;
  }
  return i;
}

/// Whether typing [inserted] after [before] ends a word (the undo grouping
/// boundary): a space or punctuation following a word character.
bool endsWord(String before, String inserted) {
  if (inserted.isEmpty || before.isEmpty) return false;
  final first = _cls(inserted.codeUnitAt(0));
  return first != _Cls.word &&
      _cls(before.codeUnitAt(before.length - 1)) == _Cls.word;
}

/// The previous grapheme-ish boundary (a surrogate pair counts as one).
int previousCharBoundary(String text, int offset) {
  if (offset <= 0) return 0;
  final i = offset - 1;
  if (i > 0 &&
      _isLowSurrogate(text.codeUnitAt(i)) &&
      _isHighSurrogate(text.codeUnitAt(i - 1))) {
    return i - 1;
  }
  return i;
}

/// The next grapheme-ish boundary (a surrogate pair counts as one).
int nextCharBoundary(String text, int offset) {
  if (offset >= text.length) return text.length;
  final i = offset + 1;
  if (i < text.length &&
      _isHighSurrogate(text.codeUnitAt(offset)) &&
      _isLowSurrogate(text.codeUnitAt(i))) {
    return i + 1;
  }
  return i;
}

bool _isHighSurrogate(int u) => u >= 0xD800 && u <= 0xDBFF;
bool _isLowSurrogate(int u) => u >= 0xDC00 && u <= 0xDFFF;
