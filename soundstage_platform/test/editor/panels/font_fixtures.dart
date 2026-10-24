import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoder;

/// A variation axis for [buildFont].
typedef TestAxis = ({String tag, double min, double def, double max});

Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

Uint8List _cat(List<Uint8List> parts) {
  final out = BytesBuilder();
  parts.forEach(out.add);
  return out.toBytes();
}

Uint8List _padded(Uint8List b) {
  final extra = (4 - b.length % 4) % 4;
  return extra == 0 ? b : _cat([b, Uint8List(extra)]);
}

Uint8List _utf16be(String s) => _cat([for (final c in s.codeUnits) _u16(c)]);

Uint8List _name(Map<int, String> names) {
  final entries = names.entries.toList();
  final strings = [for (final e in entries) _utf16be(e.value)];
  final header = 6 + 12 * entries.length;
  var offset = 0;
  final records = <Uint8List>[];
  for (final (i, e) in entries.indexed) {
    records.add(
      _cat([
        _u16(3), // Windows
        _u16(1), // Unicode BMP
        _u16(0x409),
        _u16(e.key),
        _u16(strings[i].length),
        _u16(offset),
      ]),
    );
    offset += strings[i].length;
  }
  return _cat([
    _u16(0),
    _u16(entries.length),
    _u16(header),
    ...records,
    ...strings,
  ]);
}

Uint8List _head({required bool italic}) {
  final b = Uint8List(54);
  final d = b.buffer.asByteData();
  d.setUint16(18, 1000); // unitsPerEm
  d.setUint16(44, italic ? 2 : 0); // macStyle
  return b;
}

Uint8List _os2({required int weight, required bool italic}) {
  final b = Uint8List(96);
  final d = b.buffer.asByteData();
  d.setUint16(0, 4); // version
  d.setUint16(4, weight);
  d.setUint16(62, italic ? 1 : 0x40); // fsSelection: italic | regular
  d.setInt16(68, 800);
  d.setInt16(70, -200);
  d.setUint16(74, 900);
  d.setUint16(76, 250);
  d.setInt16(86, 500);
  d.setInt16(88, 700);
  return b;
}

Uint8List _fvar(List<TestAxis> axes) {
  Uint8List fixed(double v) =>
      Uint8List(4)..buffer.asByteData().setInt32(0, (v * 65536).round());
  return _cat([
    _u16(1),
    _u16(0),
    _u16(16), // axesArrayOffset
    _u16(2),
    _u16(axes.length),
    _u16(20),
    _u16(0), // instanceCount
    _u16(0), // instanceSize
    for (final a in axes) ...[
      Uint8List.fromList(ascii.encode(a.tag)),
      fixed(a.min),
      fixed(a.def),
      fixed(a.max),
      _u16(0),
      _u16(256),
    ],
  ]);
}

/// A minimal TrueType font file with the tables the Fonts panel reads.
///
/// [family] is name ID 1 and [typographicFamily] (when given) name ID 16;
/// [style] is ID 2 (and 17). [axes] adds an `fvar` table.
Uint8List buildFont({
  String family = 'Test Sans',
  String? typographicFamily,
  String style = 'Regular',
  int weight = 400,
  bool italic = false,
  List<TestAxis> axes = const [],
  bool cff = false,
}) {
  final tables = <String, Uint8List>{
    'OS/2': _os2(weight: weight, italic: italic),
    'fvar': ?(axes.isEmpty ? null : _fvar(axes)),
    'head': _head(italic: italic),
    'name': _name({
      1: family,
      2: style,
      16: ?typographicFamily,
      if (typographicFamily != null) 17: style,
      4: '$family $style',
    }),
  };
  final tags = tables.keys.toList()..sort();
  final dirSize = 12 + 16 * tags.length;
  var offset = dirSize;
  final dir = <Uint8List>[];
  final bodies = <Uint8List>[];
  for (final tag in tags) {
    final body = tables[tag]!;
    dir.add(
      _cat([
        Uint8List.fromList(ascii.encode(tag)),
        _u32(0),
        _u32(offset),
        _u32(body.length),
      ]),
    );
    final padded = _padded(body);
    bodies.add(padded);
    offset += padded.length;
  }
  return _cat([
    _u32(cff ? 0x4F54544F : 0x00010000),
    _u16(tags.length),
    _u16(0),
    _u16(0),
    _u16(0),
    ...dir,
    ...bodies,
  ]);
}

/// [sfnt] wrapped as WOFF 1 (each table zlib-compressed).
Uint8List toWoff(Uint8List sfnt) {
  final d = sfnt.buffer.asByteData(sfnt.offsetInBytes);
  final n = d.getUint16(4);
  final entries = <(Uint8List tag, Uint8List data)>[];
  for (var i = 0; i < n; i++) {
    final r = 12 + i * 16;
    final off = d.getUint32(r + 8);
    final len = d.getUint32(r + 12);
    entries.add((
      Uint8List.sublistView(sfnt, r, r + 4),
      Uint8List.sublistView(sfnt, off, off + len),
    ));
  }
  final dirEnd = 44 + 20 * n;
  var offset = dirEnd;
  final dir = <Uint8List>[];
  final bodies = <Uint8List>[];
  for (final (tag, data) in entries) {
    final comp = Uint8List.fromList(const ZLibEncoder().encodeBytes(data));
    final useComp = comp.length < data.length;
    final stored = useComp ? comp : data;
    dir.add(
      _cat([
        tag,
        _u32(offset),
        _u32(stored.length),
        _u32(data.length),
        _u32(0),
      ]),
    );
    final padded = _padded(stored);
    bodies.add(padded);
    offset += padded.length;
  }
  return _cat([
    _u32(0x774F4646),
    _u32(d.getUint32(0)),
    _u32(offset),
    _u16(n),
    _u16(0),
    _u32(sfnt.length),
    _u16(1),
    _u16(0),
    _u32(0),
    _u32(0),
    _u32(0),
    _u32(0),
    _u32(0),
    ...dir,
    ...bodies,
  ]);
}
