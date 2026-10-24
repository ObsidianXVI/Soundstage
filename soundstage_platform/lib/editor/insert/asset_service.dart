import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/persistence/local_asset_store.dart';
import 'package:soundstage_platform/app/persistence/platform.dart' as platform;
import 'package:soundstage_platform/app/persistence/providers.dart';
import 'package:soundstage_platform/app/persistence/records.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// A file the author gave the editor: from the picker, a drop or the
/// clipboard.
typedef EditorFile = ({String name, Uint8List bytes, String mime});

/// The editor's door to the asset store (`local://<id>`, architecture §12).
///
/// Panels, the insert tools and the clipboard talk to this instead of
/// `LocalAssetStore`, so tests can swap it. Every method throws
/// [AssetServiceException] with a message fit for a toast.
abstract interface class EditorAssetService {
  /// Whether files can be stored (false when browser storage is blocked).
  bool get available;

  /// Stores [bytes] as a new asset and returns its table entry.
  Future<ir.Asset> add(Uint8List bytes, String mime, {String name = ''});

  /// Replaces the file of [assetId]; the id stays.
  Future<ir.Asset> replace(
    String assetId,
    Uint8List bytes,
    String mime, {
    String? name,
  });

  /// The stored bytes of [assetId], or null.
  Future<Uint8List?> bytes(String assetId);

  /// The table entry for an asset that is in the store but may not be in
  /// the document (a clipboard reference within the same browser profile),
  /// or null.
  Future<ir.Asset?> stored(String assetId);
}

/// A storage or format problem, worded for the author.
class AssetServiceException implements Exception {
  const AssetServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

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

/// The asset service of the open editor: the app's IndexedDB store, or
/// [UnavailableAssetService] when storage did not open.
final editorAssetServiceProvider = Provider<EditorAssetService>((ref) {
  final storage = ref.watch(appStorageProvider);
  final assets = storage.assets;
  return assets == null
      ? UnavailableAssetService(storage.unavailableReason ?? 'No storage.')
      : LocalEditorAssetService(assets);
});

/// Files that were not stored, with why (for one toast).
class IngestReport {
  IngestReport();

  final List<ir.Asset> assets = [];
  final List<String> problems = [];

  bool get ok => problems.isEmpty;

  /// "a.png: …; b.gif: …".
  String get summary => problems.join('\n');
}

/// The MIME type to store [f] under: its own when it is a known media
/// type, else by file extension.
String? mimeOfFile(EditorFile f) {
  if (assetKindForMime(f.mime) != null) return f.mime;
  final dot = f.name.lastIndexOf('.');
  return dot < 0 ? null : mimeForExtension(f.name.substring(dot + 1));
}

/// Stores each of [files] that is an image, audio or video file and
/// returns the new assets in order; the rest (fonts go through the Fonts
/// panel) and the failures are listed in `problems`.
Future<IngestReport> ingestMedia(
  EditorAssetService service,
  Iterable<EditorFile> files, {
  Set<ir.AssetKind> kinds = const {
    ir.AssetKind.image,
    ir.AssetKind.audio,
    ir.AssetKind.video,
  },
}) async {
  final report = IngestReport();
  for (final f in files) {
    final mime = mimeOfFile(f);
    final kind = mime == null ? null : assetKindForMime(mime);
    if (mime == null || kind == null || !kinds.contains(kind)) {
      report.problems.add(
        '${f.name}: not an image, audio or video file the editor can use.',
      );
      continue;
    }
    try {
      report.assets.add(await service.add(f.bytes, mime, name: f.name));
    } on AssetServiceException catch (e) {
      report.problems.add('${f.name}: ${e.message}');
    }
  }
  return report;
}

/// Opens the file picker; an empty list means cancelled.
typedef EditorFilePicker =
    Future<List<EditorFile>> Function({String accept, bool multiple});

/// The browser's file picker (tests override it). Must be called from a
/// user gesture.
final editorFilePickerProvider = Provider<EditorFilePicker>(
  (ref) =>
      ({String accept = '', bool multiple = false}) async => [
        for (final f in await platform.pickFiles(
          accept: accept,
          multiple: multiple,
        ))
          (name: f.name, bytes: f.bytes, mime: f.mime),
      ],
);
