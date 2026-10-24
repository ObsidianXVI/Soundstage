// Reads what the Fonts panel needs to group an uploaded font file into a
// family (architecture §12): the family name, weight, style and variation
// axes, from the sfnt `name`, `OS/2`, `head` and `fvar` tables. Pure Dart.
//
// Formats. The engine's `FontLoader` takes sfnt data (TrueType/OpenType);
// we accept
// - `.ttf` / `.otf` (TrueType and CFF outlines, variable or not) as they
//   are;
// - `.woff` (WOFF 1) by unpacking it to the sfnt it wraps (zlib), so the
//   stored file is plain sfnt and every engine loads it the same way.
//
// and reject, with a message, `.woff2` (it needs Brotli, which this build
// does not carry: convert to TTF/OTF), `.ttc`/`.otc` collections (several
// fonts in one file) and anything that is not a font.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// The container format of a font file, by its first four bytes.
enum FontFormat { ttf, otf, woff, woff2, collection, unknown }

/// The format of [bytes].
FontFormat sniffFontFormat(Uint8List bytes) {
  if (bytes.length < 12) return FontFormat.unknown;
  final tag = ByteData.sublistView(bytes).getUint32(0);
  return switch (tag) {
    0x00010000 || 0x74727565 => FontFormat.ttf, // 1.0, 'true'
    0x4F54544F => FontFormat.otf, // 'OTTO'
    0x774F4646 => FontFormat.woff, // 'wOFF'
    0x774F4632 => FontFormat.woff2, // 'wOF2'
    0x74746366 => FontFormat.collection, // 'ttcf'
    _ => FontFormat.unknown,
  };
}

/// The file extensions the Fonts panel offers in its picker.
const String kFontAccept = '.ttf,.otf,.woff';

/// What an uploaded font file says about itself.
class FontInfo {
  const FontInfo({
    required this.format,
    required this.cff,
    required this.familyName,
    required this.styleName,
    required this.weight,
    required this.italic,
    required this.variable,
    required this.axes,
    required this.sfnt,
    this.fullName,
  });

  /// The format the file arrived in.
  final FontFormat format;

  /// Whether the outlines are CFF (OpenType `OTTO`) rather than TrueType.
  final bool cff;

  /// The typographic family (name ID 16, else 1): "Inter", not "Inter
  /// Light".
  final String familyName;

  /// The subfamily (name ID 17, else 2): "Light Italic".
  final String styleName;
  final String? fullName;

  /// `usWeightClass` (100–900); for a variable font the default of its
  /// `wght` axis.
  final int weight;
  final bool italic;
  final bool variable;
  final List<ir.FontAxis> axes;

  /// The font as plain sfnt bytes: the input for TTF/OTF, the unpacked
  /// font for WOFF. Store and load these.
  final Uint8List sfnt;

  /// A MIME type for [sfnt].
  String get mime => cff ? 'font/otf' : 'font/ttf';

  /// The document face for this file stored as asset [assetId].
  ir.FontFace face(String assetId) => ir.FontFace(
    assetId: assetId,
    weight: weight,
    italic: italic,
    variable: variable,
    axes: axes,
  );
}

/// The outcome of [parseFontInfo]: the font, or why the file is refused.
typedef FontInfoResult = ({FontInfo? info, String? problem});

/// Reads [bytes] as a font file. Never throws.
FontInfoResult parseFontInfo(Uint8List bytes) {
  try {
    return _parse(bytes);
  } on RangeError {
    return (info: null, problem: 'The font file is truncated or damaged.');
  } on Object {
    return (info: null, problem: 'The font file could not be read.');
  }
}

FontInfoResult _refuse(String problem) => (info: null, problem: problem);

FontInfoResult _parse(Uint8List bytes) {
  final format = sniffFontFormat(bytes);
  switch (format) {
    case FontFormat.woff2:
      return _refuse(
        'WOFF2 fonts are not supported (they need Brotli). '
        'Convert the font to TTF, OTF or WOFF and upload that.',
      );
    case FontFormat.collection:
      return _refuse(
        'Font collections (.ttc, .otc) are not supported. '
        'Upload the individual fonts as TTF or OTF.',
      );
    case FontFormat.unknown:
      return _refuse('This is not a font file. Upload a TTF, OTF or WOFF.');
    case FontFormat.woff:
      final sfnt = woffToSfnt(bytes);
      if (sfnt == null) return _refuse('The WOFF file is damaged.');
      bytes = sfnt;
    case FontFormat.ttf:
    case FontFormat.otf:
      break;
  }
  final d = ByteData.sublistView(bytes);
  final cff = d.getUint32(0) == 0x4F54544F;
  final tables = _tables(d);
  final head = tables['head'];
  final name = tables['name'];
  if (head == null || name == null) {
    return _refuse('The font has no ${head == null ? 'head' : 'name'} table.');
  }
  final names = _readNames(d, name.$1, name.$2);
  final family = names[16] ?? names[1];
  if (family == null || family.trim().isEmpty) {
    return _refuse('The font does not name its family.');
  }
  final style = names[17] ?? names[2] ?? 'Regular';
  // Weight and slant.
  var weight = 400;
  var italic = false;
  final os2 = tables['OS/2'];
  if (os2 != null && os2.$2 >= 64) {
    weight = d.getUint16(os2.$1 + 4);
    final sel = d.getUint16(os2.$1 + 62);
    italic = (sel & 0x01) != 0 || (sel & 0x200) != 0; // italic | oblique
  } else if (head.$2 >= 46) {
    italic = (d.getUint16(head.$1 + 44) & 0x02) != 0; // macStyle italic
    final macBold = (d.getUint16(head.$1 + 44) & 0x01) != 0;
    weight = macBold ? 700 : 400;
  }
  if (weight < 1) weight = 400;
  weight = weight.clamp(1, 1000);
  // Variation axes.
  final axes = <ir.FontAxis>[];
  final fvar = tables['fvar'];
  if (fvar != null) axes.addAll(_readAxes(d, fvar.$1, fvar.$2));
  final wght = axes.where((a) => a.tag == 'wght');
  if (wght.isNotEmpty) weight = wght.first.defaultValue.round();
  return (
    info: FontInfo(
      format: format,
      cff: cff,
      familyName: family.trim(),
      styleName: style.trim(),
      fullName: names[4]?.trim(),
      weight: weight,
      italic: italic,
      variable: axes.isNotEmpty,
      axes: axes,
      sfnt: bytes,
    ),
    problem: null,
  );
}

/// tag → (offset, length).
Map<String, (int, int)> _tables(ByteData d) {
  final n = d.getUint16(4);
  final out = <String, (int, int)>{};
  for (var i = 0; i < n; i++) {
    final r = 12 + i * 16;
    final tag = String.fromCharCodes([
      d.getUint8(r),
      d.getUint8(r + 1),
      d.getUint8(r + 2),
      d.getUint8(r + 3),
    ]);
    final offset = d.getUint32(r + 8);
    final length = d.getUint32(r + 12);
    if (offset + length > d.lengthInBytes) {
      throw RangeError('table "$tag" runs past the end of the file');
    }
    out[tag] = (offset, length);
  }
  return out;
}

/// name ID → best string (Windows English, else any Windows/Unicode, else
/// Macintosh Roman).
Map<int, String> _readNames(ByteData d, int base, int length) {
  final count = d.getUint16(base + 2);
  final storage = base + d.getUint16(base + 4);
  final best = <int, ({int rank, String text})>{};
  for (var i = 0; i < count; i++) {
    final r = base + 6 + i * 12;
    final platform = d.getUint16(r);
    final language = d.getUint16(r + 4);
    final id = d.getUint16(r + 6);
    final len = d.getUint16(r + 8);
    final off = storage + d.getUint16(r + 10);
    if (off + len > d.lengthInBytes) continue;
    final String text;
    int rank;
    if (platform == 3 || platform == 0) {
      text = _utf16be(d, off, len);
      rank = platform == 3 && language == 0x0409 ? 3 : 2;
    } else if (platform == 1) {
      text = latin1.decode(
        d.buffer.asUint8List(d.offsetInBytes + off, len),
        allowInvalid: true,
      );
      rank = 1;
    } else {
      continue;
    }
    if (text.isEmpty) continue;
    final old = best[id];
    if (old == null || rank > old.rank) best[id] = (rank: rank, text: text);
  }
  return {for (final e in best.entries) e.key: e.value.text};
}

String _utf16be(ByteData d, int off, int len) {
  final units = <int>[
    for (var i = 0; i + 1 < len; i += 2) d.getUint16(off + i),
  ];
  return String.fromCharCodes(units);
}

List<ir.FontAxis> _readAxes(ByteData d, int base, int length) {
  if (length < 16) return const [];
  final axesOffset = d.getUint16(base + 4);
  final count = d.getUint16(base + 8);
  final size = d.getUint16(base + 10);
  if (size < 20) return const [];
  double fixed(int o) => d.getInt32(o) / 65536;
  final out = <ir.FontAxis>[];
  for (var i = 0; i < count; i++) {
    final r = base + axesOffset + i * size;
    if (r + 20 > d.lengthInBytes) break;
    final tag = String.fromCharCodes([
      d.getUint8(r),
      d.getUint8(r + 1),
      d.getUint8(r + 2),
      d.getUint8(r + 3),
    ]);
    out.add(
      ir.FontAxis(
        tag: tag,
        min: fixed(r + 4),
        defaultValue: fixed(r + 8),
        max: fixed(r + 12),
      ),
    );
  }
  return out;
}

/// Unpacks a WOFF 1 file to the sfnt it wraps, or null when it is damaged.
///
/// WOFF stores each sfnt table zlib-compressed (or as is when compression
/// did not help) in a directory of 20-byte entries after a 44-byte header.
Uint8List? woffToSfnt(Uint8List woff) {
  try {
    final d = ByteData.sublistView(woff);
    if (woff.length < 44 || d.getUint32(0) != 0x774F4646) return null;
    final flavor = d.getUint32(4);
    final n = d.getUint16(12);
    final totalSfntSize = d.getUint32(16);
    if (totalSfntSize > (64 << 20)) return null;
    final entries =
        <
          ({int tag, int offset, int compLength, int origLength, int checksum})
        >[];
    for (var i = 0; i < n; i++) {
      final r = 44 + i * 20;
      entries.add((
        tag: d.getUint32(r),
        offset: d.getUint32(r + 4),
        compLength: d.getUint32(r + 8),
        origLength: d.getUint32(r + 12),
        checksum: d.getUint32(r + 16),
      ));
    }
    final dirSize = 12 + 16 * n;
    var offset = dirSize;
    final placed = <int>[];
    for (final e in entries) {
      placed.add(offset);
      offset += (e.origLength + 3) & ~3;
    }
    final out = Uint8List(offset);
    final o = ByteData.sublistView(out);
    o.setUint32(0, flavor);
    o.setUint16(4, n);
    var entrySelector = 0;
    while ((1 << (entrySelector + 1)) <= n) {
      entrySelector++;
    }
    final searchRange = (1 << entrySelector) * 16;
    o.setUint16(6, searchRange);
    o.setUint16(8, entrySelector);
    o.setUint16(10, n * 16 - searchRange);
    // sfnt directories are sorted by tag; WOFF directories already are.
    for (final (i, e) in entries.indexed) {
      final r = 12 + i * 16;
      o.setUint32(r, e.tag);
      o.setUint32(r + 4, e.checksum);
      o.setUint32(r + 8, placed[i]);
      o.setUint32(r + 12, e.origLength);
      final raw = Uint8List.sublistView(
        woff,
        e.offset,
        e.offset + e.compLength,
      );
      final data = e.compLength < e.origLength
          ? const ZLibDecoder().decodeBytes(raw, maxOutputSize: e.origLength)
          : raw;
      if (data.length != e.origLength) return null;
      out.setRange(placed[i], placed[i] + e.origLength, data);
    }
    return out;
  } on Object {
    return null;
  }
}
