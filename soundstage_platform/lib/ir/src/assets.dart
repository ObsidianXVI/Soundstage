import 'package:freezed_annotation/freezed_annotation.dart';

import 'values/stage_color.dart';

part 'assets.freezed.dart';
part 'assets.g.dart';

@JsonEnum()
enum AssetKind { image, video, audio, font, imageSequence, lottie, rive }

/// Generic family used until (or if) a font's bytes fail to load.
@JsonEnum()
enum FontFallback { serif, sans, mono }

/// A resized/re-encoded rendition of an asset (e.g. a 640 px WebP).
@freezed
abstract class AssetVariant with _$AssetVariant {
  const factory AssetVariant({
    required int width,
    required String uri,
    required String format,
  }) = _AssetVariant;

  factory AssetVariant.fromJson(Map<String, dynamic> json) =>
      _$AssetVariantFromJson(json);
}

/// What to show while an asset loads.
@freezed
abstract class AssetPlaceholder with _$AssetPlaceholder {
  const factory AssetPlaceholder({
    required StageColor dominantColor,
    String? blurhash,
  }) = _AssetPlaceholder;

  factory AssetPlaceholder.fromJson(Map<String, dynamic> json) =>
      _$AssetPlaceholderFromJson(json);
}

/// A media file referenced by the document (architecture §12).
///
/// `uri`: `local://<id>`, `https://…` or `asset://<path>`. `width`/`height`
/// in pixels, `duration` in seconds — each only where meaningful.
@freezed
abstract class Asset with _$Asset {
  const factory Asset({
    required String id,
    required AssetKind kind,
    required String uri,
    @Default('') String name,
    @Default('') String mime,
    @Default(0) int byteSize,
    int? width,
    int? height,
    double? duration,
    int? frameCount,
    @Default(<AssetVariant>[]) List<AssetVariant> variants,
    AssetPlaceholder? placeholder,
    @Default('') String alt,
    @Default('') String credit,
  }) = _Asset;

  factory Asset.fromJson(Map<String, dynamic> json) => _$AssetFromJson(json);
}

/// A variable-font axis.
@freezed
abstract class FontAxis with _$FontAxis {
  const factory FontAxis({
    required String tag,
    required double min,
    required double max,
    @JsonKey(name: 'default') required double defaultValue,
  }) = _FontAxis;

  factory FontAxis.fromJson(Map<String, dynamic> json) =>
      _$FontAxisFromJson(json);
}

/// One font file of a family. For a variable face, `weight` is the default
/// weight and `axes` lists the variation axes.
@freezed
abstract class FontFace with _$FontFace {
  const factory FontFace({
    required String assetId,
    @Default(400) int weight,
    @Default(false) bool italic,
    @Default(false) bool variable,
    @Default(<FontAxis>[]) List<FontAxis> axes,
  }) = _FontFace;

  factory FontFace.fromJson(Map<String, dynamic> json) =>
      _$FontFaceFromJson(json);
}

/// A font family (architecture §12).
@freezed
abstract class FontFamily with _$FontFamily {
  const factory FontFamily({
    required String id,
    required String name,
    @Default(<FontFace>[]) List<FontFace> faces,
    @Default(FontFallback.sans) FontFallback fallback,
  }) = _FontFamily;

  factory FontFamily.fromJson(Map<String, dynamic> json) =>
      _$FontFamilyFromJson(json);
}

// Image sequences (architecture §12): the asset's `uri` is a numbered
// pattern, e.g. `https://…/frame_{0001}.webp` or `local://<id>_{0001}`. The
// digits in braces give the first frame's number and the zero padding;
// `frameCount` frames follow it.

final RegExp _framePattern = RegExp(r'\{(\d+)\}');

/// The default playback rate of an image sequence without a duration.
const double kSequenceFrameRate = 24;

/// The URI of frame [index] (0-based) of the image sequence [asset]; [asset]'s
/// `uri` when it has no `{0001}` placeholder.
String sequenceFrameUri(Asset asset, int index) =>
    frameUriFromPattern(asset.uri, index);

/// The URI of frame [index] (0-based) of numbered [pattern].
String frameUriFromPattern(String pattern, int index) {
  final m = _framePattern.firstMatch(pattern);
  if (m == null) return pattern;
  final digits = m.group(1)!;
  final n = (int.parse(digits) + index).toString().padLeft(digits.length, '0');
  return pattern.replaceRange(m.start, m.end, n);
}

/// Whether [uri] is a numbered frame pattern.
bool isFramePattern(String uri) => _framePattern.hasMatch(uri);
