import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';
import 'package:soundstage_platform/editor/clipboard/system_clipboard.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// An in-memory [EditorAssetService]. A file's pixel size is read from its
/// first four bytes (big-endian width and height as 16-bit numbers), so
/// tests state sizes with [png].
class FakeAssetService implements EditorAssetService {
  FakeAssetService({this.available = true});

  @override
  bool available;

  final Map<String, Uint8List> files = {};
  final Map<String, ir.Asset> entries = {};
  int _next = 0;
  int addCount = 0;

  /// A fake image of [w] x [h] pixels; [salt] makes different content.
  static Uint8List png(int w, int h, [int salt = 0]) =>
      Uint8List.fromList([w >> 8, w & 255, h >> 8, h & 255, salt]);

  static Size sizeOf(Uint8List b) =>
      Size(((b[0] << 8) | b[1]).toDouble(), ((b[2] << 8) | b[3]).toDouble());

  ir.Asset _entry(String id, Uint8List bytes, String mime, String name) {
    final kind = mime.startsWith('image/')
        ? ir.AssetKind.image
        : mime.startsWith('audio/')
        ? ir.AssetKind.audio
        : mime.startsWith('video/')
        ? ir.AssetKind.video
        : ir.AssetKind.font;
    final size = kind == ir.AssetKind.image ? sizeOf(bytes) : null;
    return ir.Asset(
      id: id,
      kind: kind,
      uri: 'local://$id',
      name: name,
      mime: mime,
      byteSize: bytes.length,
      width: size?.width.round(),
      height: size?.height.round(),
    );
  }

  @override
  Future<ir.Asset> add(Uint8List bytes, String mime, {String name = ''}) async {
    if (!available) {
      throw const AssetServiceException('Browser storage is blocked.');
    }
    addCount++;
    final id = 'asset${++_next}';
    files[id] = bytes;
    return entries[id] = _entry(id, bytes, mime, name);
  }

  @override
  Future<ir.Asset> replace(
    String assetId,
    Uint8List bytes,
    String mime, {
    String? name,
  }) async {
    final old = entries[assetId];
    if (old == null) throw const AssetServiceException('No such asset.');
    files[assetId] = bytes;
    return entries[assetId] = _entry(assetId, bytes, mime, name ?? old.name);
  }

  @override
  Future<Uint8List?> bytes(String assetId) async => files[assetId];

  @override
  Future<ir.Asset?> stored(String assetId) async => entries[assetId];

  /// Peaks to serve per asset id (tests set these); [peaksRequests] counts
  /// the asks.
  final Map<String, WaveformPeaks> peaksById = {};
  int peaksRequests = 0;

  @override
  Future<WaveformPeaks?> peaks(String assetId, {String? uri}) async {
    peaksRequests++;
    return peaksById[assetId];
  }
}

/// Serves a 1 x 1 PNG for every `local://` image, so painting an inserted
/// image has something to decode.
class StubPngLoader implements LocalAssetLoader {
  static final _png = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
      'iZk9HQAAAABJRU5ErkJggg==',
    ),
  );

  @override
  Future<Uint8List?> loadBytes(String assetId) async => _png;

  @override
  Future<String?> acquireObjectUrl(String assetId) async => null;

  @override
  void releaseObjectUrl(String assetId) {}
}

/// A [SystemClipboard] held in memory.
class FakeClipboard implements SystemClipboard {
  String? text;
  EditorFile? image;
  bool denyRead = false;
  bool denyWrite = false;

  @override
  Future<void> writeText(String t) async {
    if (denyWrite) throw const ClipboardDenied();
    text = t;
    image = null;
  }

  @override
  Future<String?> readText() async {
    if (denyRead) throw const ClipboardDenied();
    return text;
  }

  @override
  Future<EditorFile?> readImage() async {
    if (denyRead) throw const ClipboardDenied();
    return image;
  }
}
