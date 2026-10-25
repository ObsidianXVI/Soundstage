// Human names of registered properties (architecture §11.2): what the
// editor shows for a property path (timeline lanes, the Motion section).

/// Names for patterns the derivation below would name badly.
const Map<String, String> _explicit = {
  'x': 'X',
  'y': 'Y',
  'visible': 'Visibility',
  'characters': 'Text',
  'motion.rotate': 'Rotate',
  'motion.translateX': 'Translate X',
  'motion.translateY': 'Translate Y',
  'motion.scaleX': 'Scale X',
  'motion.scaleY': 'Scale Y',
  'motion.skewX': 'Skew X',
  'motion.skewY': 'Skew Y',
  'motion.originX': 'Origin X',
  'motion.originY': 'Origin Y',
  'layoutChild.positioning': 'Positioning',
  'layoutChild.horizontalSizing': 'Horizontal sizing',
  'layoutChild.verticalSizing': 'Vertical sizing',
  'layoutChild.constraints.horizontal': 'Horizontal constraint',
  'layoutChild.constraints.vertical': 'Vertical constraint',
  'autoLayout.counterAxisGap': 'Cross-axis gap',
  'autoLayout.reverseZIndex': 'Reverse z-index',
  'cornerRadius.tl': 'Corner radius top left',
  'cornerRadius.tr': 'Corner radius top right',
  'cornerRadius.br': 'Corner radius bottom right',
  'cornerRadius.bl': 'Corner radius bottom left',
  'strokes.paints': 'Stroke paints',
  'strokes.weight': 'Stroke weight',
};

/// Containers whose path prefix names the thing, in matching order
/// (longest first): `fills.<paintId>.color` → "Fill color".
const List<(String, String)> _prefixes = [
  (
    'content.<paragraphIndex>.spans.<spanIndex>.style.fills.<paintId>',
    'span fill',
  ),
  ('content.<paragraphIndex>.spans.<spanIndex>.style', 'span'),
  ('content.<paragraphIndex>.spans.<spanIndex>', 'span'),
  ('content.<paragraphIndex>.style', 'paragraph'),
  ('style.fills.<paintId>', 'text fill'),
  ('style.fills', 'text fills'),
  ('strokes.paints.<paintId>', 'stroke'),
  ('fills.<paintId>', 'fill'),
  ('effects.<effectId>', 'effect'),
  ('fills', 'fills'),
  ('effects', 'effects'),
  ('strokes', 'stroke'),
  ('motion', ''),
  ('layoutChild.grid', 'grid'),
  ('layoutChild', ''),
  ('autoLayout', ''),
  ('geometry', ''),
  ('style', ''),
  ('inputs.<inputName>', 'input'),
];

/// Segment rewrites inside the rest of a path.
const Map<String, String> _segments = {
  'stops.<stopIndex>': 'stop',
  'fontVariations.<axisTag>': 'font axis',
  'openType.<featureTag>': 'OpenType feature',
  'fontFamilyId': 'fontFamily',
  'filters': '',
  'cropRect': 'crop',
  'handles': 'handle',
  'decoration': 'decoration',
};

final RegExp _camel = RegExp(r'(?<=[a-z])(?=[A-Z])');

/// The human name of property pattern [pattern] (`motion.translateX` →
/// "Translate X", `fills.<paintId>.color` → "Fill color",
/// `content.<paragraphIndex>.spans.<spanIndex>.style.fontSize` → "Span
/// font size"). Sentence case; never empty.
String propertyDisplayName(String pattern) {
  final explicit = _explicit[pattern];
  if (explicit != null) return explicit;
  var rest = pattern;
  final words = <String>[];
  for (final (prefix, name) in _prefixes) {
    if (rest == prefix || rest.startsWith('$prefix.')) {
      if (name.isNotEmpty) words.add(name);
      rest = rest == prefix ? '' : rest.substring(prefix.length + 1);
      break;
    }
  }
  for (final MapEntry(:key, :value) in _segments.entries) {
    rest = rest.replaceAll(key, value);
  }
  for (final seg in rest.split('.')) {
    if (seg.isEmpty || (seg.startsWith('<') && seg.endsWith('>'))) continue;
    // Rewritten segments ("OpenType feature") are already words.
    final parts = seg.contains(' ') ? [seg] : seg.split(_camel);
    for (final w in parts) {
      final lower = w.length == 1
          ? w.toUpperCase()
          : (seg.contains(' ') ? w : w.toLowerCase());
      if (words.isEmpty || words.last != lower) words.add(lower);
    }
  }
  if (words.isEmpty) return pattern;
  final text = words.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return text[0].toUpperCase() + text.substring(1);
}
