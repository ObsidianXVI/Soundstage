import 'dart:typed_data';

/// A content hash of [bytes] for deduplicating assets and fonts: two
/// 32-bit FNV-1a lanes with different seeds, plus the length, as
/// `<16 hex>-<length>`.
///
/// Not cryptographic: it only has to tell one author's files apart. The
/// multiply is done with shifts so it is exact in JavaScript numbers too.
String contentHash(Uint8List bytes) {
  var a = 0x811c9dc5;
  var b = 0x9747b28c;
  for (final x in bytes) {
    a = _mul(a ^ x);
    b = _mul(b ^ ((x + 0x9d) & 0xFF));
  }
  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${hex(a)}${hex(b)}-${bytes.length}';
}

// h * 16777619 (mod 2^32) as shifts and adds.
int _mul(int h) =>
    (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) & 0xFFFFFFFF;
