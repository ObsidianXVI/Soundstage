import 'dart:typed_data';

/// The pixel size of a PNG, GIF, JPEG or WebP file from its header, or
/// null for anything else (exporters that need an aspect ratio, m4.md
/// T4.5d).
({int width, int height})? imageSizeOf(Uint8List b) {
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int be32(int i) => (be16(i) << 16) | be16(i + 2);
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47]) && b.length >= 24) {
    return (width: be32(16), height: be32(20));
  }
  if (at(0, 'GIF8'.codeUnits) && b.length >= 10) {
    return (width: le16(6), height: le16(8));
  }
  if (at(0, const [0xFF, 0xD8])) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      // Start-of-frame markers carry the size (not DHT, JPG or DAC).
      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        return (width: be16(i + 7), height: be16(i + 5));
      }
      i += 2 + be16(i + 2);
    }
    return null;
  }
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits) && b.length >= 30) {
    if (at(12, 'VP8X'.codeUnits)) {
      int le24(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
      return (width: le24(24) + 1, height: le24(27) + 1);
    }
    if (at(12, 'VP8L'.codeUnits)) {
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return (width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1);
    }
    if (at(12, 'VP8 '.codeUnits)) {
      return (width: le16(26) & 0x3FFF, height: le16(28) & 0x3FFF);
    }
  }
  return null;
}
