import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

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
}
