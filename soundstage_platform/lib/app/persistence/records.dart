import 'dart:typed_data';

/// Story metadata: one row of the `stories` store.
///
/// `headRevision` is the pointer to the current revision. A save writes the
/// new revision first and moves this pointer second, so a crash in between
/// leaves the previous head intact (architecture §17.2).
class StoryRecord {
  const StoryRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.headRevision,
    this.coverAssetId,
    this.sceneCount,
  });

  final String id;
  final String title;

  /// Milliseconds since the epoch.
  final int createdAt;
  final int updatedAt;
  final int headRevision;
  final String? coverAssetId;
  final int? sceneCount;

  StoryRecord copyWith({
    String? title,
    int? updatedAt,
    int? headRevision,
    String? coverAssetId,
    int? sceneCount,
  }) => StoryRecord(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    headRevision: headRevision ?? this.headRevision,
    coverAssetId: coverAssetId ?? this.coverAssetId,
    sceneCount: sceneCount ?? this.sceneCount,
  );
}

/// One row of the `revisions` store, keyed by (`storyId`, `rev`).
class RevisionRecord {
  const RevisionRecord({
    required this.storyId,
    required this.rev,
    required this.savedAt,
    required this.json,
  });

  final String storyId;
  final int rev;

  /// Milliseconds since the epoch.
  final int savedAt;

  /// The document, as encoded JSON text.
  final String json;

  /// UTF-16 code units of [json] (a cheap size proxy; listing never reads
  /// the document itself).
  int get size => json.length;
}

/// A revision as listed (everything but the document).
class RevisionInfo {
  const RevisionInfo({
    required this.rev,
    required this.savedAt,
    required this.size,
  });

  final int rev;

  /// Milliseconds since the epoch.
  final int savedAt;
  final int size;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(savedAt);
}

/// Everything about a stored asset except its bytes.
class AssetMeta {
  const AssetMeta({
    required this.id,
    required this.mime,
    required this.byteSize,
    required this.createdAt,
    this.name = '',
    this.width,
    this.height,
    this.duration,
    this.dominantColor,
    this.peaks,
  });

  final String id;
  final String mime;
  final int byteSize;
  final int createdAt;
  final String name;
  final int? width;
  final int? height;

  /// Seconds.
  final double? duration;

  /// `0xAARRGGBB`.
  final int? dominantColor;

  /// Audio only: the waveform peaks (one byte per 10 ms, see
  /// `WaveformPeaks`), computed at upload or on first request. Null for
  /// other kinds and for audio that has not been decoded yet.
  final Uint8List? peaks;

  /// This meta with [peaks] (and [duration], when it has none yet).
  AssetMeta withPeaks(Uint8List peaks, {double? duration}) => AssetMeta(
    id: id,
    mime: mime,
    byteSize: byteSize,
    createdAt: createdAt,
    name: name,
    width: width,
    height: height,
    duration: this.duration ?? duration,
    dominantColor: dominantColor,
    peaks: peaks,
  );
}

/// One row of the `assets` store: [meta] plus the file's bytes.
class AssetRecord {
  const AssetRecord(this.meta, this.bytes);

  final AssetMeta meta;
  final Uint8List bytes;
}

/// Browser storage usage and quota, in bytes.
class StorageEstimate {
  const StorageEstimate({this.usage, this.quota, this.persisted});

  final int? usage;
  final int? quota;

  /// Whether the browser promised not to evict the data; null when unknown.
  final bool? persisted;
}

/// The storage ran out of room. The write that failed changed nothing.
class StorageFullException implements Exception {
  const StorageFullException([this.message = 'The browser storage is full.']);

  final String message;

  @override
  String toString() => 'StorageFullException: $message';
}

/// A write to a bundled demo, which is read-only.
class ReadOnlyStoryException implements Exception {
  const ReadOnlyStoryException(this.id);

  final String id;

  @override
  String toString() =>
      'ReadOnlyStoryException: "$id" is a bundled demo. '
      'Duplicate it to your stories to edit it.';
}

/// The story does not exist (any more).
class StoryNotFoundException implements Exception {
  const StoryNotFoundException(this.id);

  final String id;

  @override
  String toString() => 'StoryNotFoundException: no story "$id".';
}

/// What the browser learned about a file by decoding it.
class AssetAnalysis {
  const AssetAnalysis({
    this.width,
    this.height,
    this.duration,
    this.dominantColor,
  });

  final int? width;
  final int? height;

  /// Seconds.
  final double? duration;

  /// `0xAARRGGBB`.
  final int? dominantColor;
}

/// A file the author picked.
class PickedFile {
  const PickedFile(this.name, this.bytes, this.mime);

  final String name;
  final Uint8List bytes;
  final String mime;
}

/// The file could not be used as an asset (not decodable, or not a media
/// type the editor handles).
class UnsupportedAssetException implements Exception {
  const UnsupportedAssetException(this.message);

  final String message;

  @override
  String toString() => 'UnsupportedAssetException: $message';
}
