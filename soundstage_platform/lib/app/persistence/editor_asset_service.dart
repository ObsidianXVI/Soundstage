import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'local_asset_store.dart';
import 'platform.dart' as platform;
import 'providers.dart';
import 'records.dart';

/// [EditorAssetService] over the IndexedDB [LocalAssetStore].
class LocalEditorAssetService implements EditorAssetService {
  const LocalEditorAssetService(this._store);

  final LocalAssetStore _store;

  @override
  bool get available => true;

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on UnsupportedAssetException catch (e) {
      throw AssetServiceException(e.message);
    } on StorageFullException catch (e) {
      throw AssetServiceException(e.message);
    }
  }

  @override
  Future<ir.Asset> add(Uint8List bytes, String mime, {String name = ''}) =>
      _guard(() => _store.put(bytes, mime, name: name));

  @override
  Future<ir.Asset> replace(
    String assetId,
    Uint8List bytes,
    String mime, {
    String? name,
  }) => _guard(() => _store.replace(assetId, bytes, mime, name: name));

  @override
  Future<Uint8List?> bytes(String assetId) => _store.get(assetId);

  @override
  Future<ir.Asset?> stored(String assetId) async {
    final rec = await _store.record(assetId);
    return rec == null ? null : _store.toAsset(rec.meta);
  }
}

/// What the editor has when browser storage is blocked: nothing can be
/// stored, and the UI says why.
class UnavailableAssetService implements EditorAssetService {
  const UnavailableAssetService([this.reason = 'Browser storage is blocked.']);

  final String reason;

  @override
  bool get available => false;

  Never _no() => throw AssetServiceException(
    '$reason Files cannot be added until storage is available.',
  );

  @override
  Future<ir.Asset> add(Uint8List bytes, String mime, {String name = ''}) =>
      _no();

  @override
  Future<ir.Asset> replace(
    String assetId,
    Uint8List bytes,
    String mime, {
    String? name,
  }) => _no();

  @override
  Future<Uint8List?> bytes(String assetId) async => null;

  @override
  Future<ir.Asset?> stored(String assetId) async => null;
}

/// The app's asset service: the IndexedDB store, or
/// [UnavailableAssetService] when storage did not open.
final appEditorAssetServiceProvider = Provider<EditorAssetService>((ref) {
  final storage = ref.watch(appStorageProvider);
  final assets = storage.assets;
  return assets == null
      ? UnavailableAssetService(storage.unavailableReason ?? 'No storage.')
      : LocalEditorAssetService(assets);
});

/// The browser file picker as the editor's [EditorFilePicker].
Future<List<EditorFile>> pickEditorFiles({
  String accept = '',
  bool multiple = false,
}) async => [
  for (final f in await platform.pickFiles(accept: accept, multiple: multiple))
    (name: f.name, bytes: f.bytes, mime: f.mime),
];
