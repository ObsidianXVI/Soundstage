// Font metrics read from sfnt (TrueType/OpenType) bytes, for
// `leadingTrim: capHeight` (architecture §7, DECISIONS_NEEDED #5).
//
// Pure Dart (no Flutter imports).

import 'dart:typed_data';

/// Vertical metrics of a font, in font units, from its `head` and `OS/2`
/// tables. [capHeight] needs OS/2 version 2 or later.
class StageFontMetrics {
  const StageFontMetrics({
    required this.unitsPerEm,
    required this.os2Version,
    required this.capHeight,
    required this.xHeight,
    required this.typoAscender,
    required this.typoDescender,
    required this.winAscent,
    required this.winDescent,
  });

  final int unitsPerEm;
  final int os2Version;

  /// `sCapHeight`; null before OS/2 v2 (or when it is 0, i.e. unset).
  final int? capHeight;

  /// `sxHeight`; null before OS/2 v2.
  final int? xHeight;
  final int typoAscender;
  final int typoDescender;
  final int winAscent;
  final int winDescent;

  /// Cap height as a fraction of the em, or null when unknown.
  double? get capHeightEm =>
      capHeight == null || unitsPerEm <= 0 ? null : capHeight! / unitsPerEm;

  @override
  String toString() =>
      'StageFontMetrics(upem $unitsPerEm, OS/2 v$os2Version, cap $capHeight, '
      'x $xHeight, typo $typoAscender/$typoDescender, '
      'win $winAscent/$winDescent)';
}

/// The outcome of [parseFontMetrics]: metrics, or why there are none.
typedef FontMetricsResult = ({StageFontMetrics? metrics, String? problem});

/// Reads [StageFontMetrics] from the bytes of a TrueType/OpenType font.
/// Never throws: unsupported or malformed input returns a problem instead
/// (font collections, WOFF/WOFF2, missing or truncated tables).
FontMetricsResult parseFontMetrics(Uint8List bytes) {
  try {
    return _parse(ByteData.sublistView(bytes));
  } on RangeError {
    return (metrics: null, problem: 'truncated font data');
  }
}

FontMetricsResult _parse(ByteData d) {
  if (d.lengthInBytes < 12) {
    return (metrics: null, problem: 'not an sfnt font (too short)');
  }
  final version = d.getUint32(0);
  const trueType = 0x00010000, otto = 0x4F54544F, ttTrue = 0x74727565;
  if (version == 0x74746366) {
    return (
      metrics: null,
      problem: 'font collections (.ttc) are not supported',
    );
  }
  if (version == 0x774F4646 || version == 0x774F4632) {
    return (metrics: null, problem: 'WOFF/WOFF2 fonts are not supported');
  }
  if (version != trueType && version != otto && version != ttTrue) {
    return (metrics: null, problem: 'not an sfnt font');
  }
  final numTables = d.getUint16(4);
  int? head, os2;
  for (var i = 0; i < numTables; i++) {
    final r = 12 + i * 16;
    final tag = d.getUint32(r);
    final offset = d.getUint32(r + 8);
    if (tag == 0x68656164) head = offset; // 'head'
    if (tag == 0x4F532F32) os2 = offset; // 'OS/2'
  }
  if (head == null) return (metrics: null, problem: 'no head table');
  final upem = d.getUint16(head + 18);
  if (os2 == null) return (metrics: null, problem: 'no OS/2 table');
  final v = d.getUint16(os2);
  final hasV2 = v >= 2;
  final cap = hasV2 ? d.getInt16(os2 + 88) : null;
  return (
    metrics: StageFontMetrics(
      unitsPerEm: upem,
      os2Version: v,
      capHeight: cap == null || cap <= 0 ? null : cap,
      xHeight: hasV2 ? d.getInt16(os2 + 86) : null,
      typoAscender: d.getInt16(os2 + 68),
      typoDescender: d.getInt16(os2 + 70),
      winAscent: d.getUint16(os2 + 74),
      winDescent: d.getUint16(os2 + 76),
    ),
    problem: hasV2 && (cap == null || cap <= 0)
        ? 'OS/2 sCapHeight is unset'
        : (hasV2 ? null : 'OS/2 version $v has no sCapHeight (needs v2+)'),
  );
}
