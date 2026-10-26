import 'package:freezed_annotation/freezed_annotation.dart';

import '../behaviors.dart';
import '../values/geometry.dart';
import '../values/ir_value.dart';
import 'appearance.dart';
import 'blend_mode.dart';
import 'layout.dart';
import 'node_common.dart';
import 'paint.dart';
import 'text.dart';

part 'node.freezed.dart';
part 'node.g.dart';

/// Primitive shape geometry (architecture §4.1). Vector paths are out of
/// scope.
/// Playback controls over a video: none, a play/pause button, or a full bar
/// (play, time, scrub, mute).
@JsonEnum()
enum VideoControls { none, minimal, full }

@Freezed(unionKey: 'type')
sealed class ShapeGeometry with _$ShapeGeometry {
  @FreezedUnionValue('rectangle')
  const factory ShapeGeometry.rectangle() = RectangleGeometry;

  /// Arc angles in degrees (0 = 3 o'clock, clockwise, as in Figma).
  /// `innerRadius` is a 0–1 ratio (a ring/donut when > 0).
  @FreezedUnionValue('ellipse')
  const factory ShapeGeometry.ellipse({
    @Default(0) double arcStart,
    @Default(360) double arcEnd,
    @Default(0) double innerRadius,
  }) = EllipseGeometry;

  @FreezedUnionValue('line')
  const factory ShapeGeometry.line() = LineGeometry;

  @FreezedUnionValue('polygon')
  const factory ShapeGeometry.polygon({@Default(3) int pointCount}) =
      PolygonGeometry;

  @FreezedUnionValue('star')
  const factory ShapeGeometry.star({
    @Default(5) int pointCount,
    @Default(0.382) double innerRatio,
  }) = StarGeometry;

  factory ShapeGeometry.fromJson(Map<String, dynamic> json) =>
      _$ShapeGeometryFromJson(json);
}

/// What an instance instantiates: a component, or a variant of a variant set
/// (architecture §9: `componentId | (variantSetId + variantValues)`).
@Freezed(unionKey: 'type')
sealed class InstanceSource with _$InstanceSource {
  @FreezedUnionValue('component')
  const factory InstanceSource.component(String componentId) = ComponentSource;

  /// `variantValues`: `{ axis: value }`.
  @FreezedUnionValue('variant')
  const factory InstanceSource.variant({
    required String variantSetId,
    @Default(<String, String>{}) Map<String, String> variantValues,
  }) = VariantSource;

  factory InstanceSource.fromJson(Map<String, dynamic> json) =>
      _$InstanceSourceFromJson(json);
}

/// A layer in a scene (architecture §4.1).
///
/// Every variant holds [NodeCommon] (§4.2) plus its kind-specific fields;
/// frames, shapes and videos also hold an [Appearance], and text holds a
/// [TextAppearance] (stroke and effects). The `type` discriminators
/// are part of the file format.
@Freezed(unionKey: 'type')
sealed class Node with _$Node {
  /// A container: free (absolute children), auto layout (`autoLayout`), or
  /// grid (`grid`). At most one of the two layouts is set; neither = free.
  ///
  /// `modeOverrides`: `{ collectionId: modeId }`, inherited by descendants
  /// (§8). `behavior`: optional interactive behaviour (§9).
  @FreezedUnionValue('frame')
  const factory Node.frame({
    required NodeCommon common,
    @Default(Appearance()) Appearance appearance,
    @Default(<Node>[]) List<Node> children,
    AutoLayout? autoLayout,
    GridLayout? grid,
    @Default(false) bool clipContent,
    Behavior? behavior,
    @Default(<String, String>{}) Map<String, String> modeOverrides,
  }) = FrameNode;

  /// Rich text (architecture §7). `appearance` holds the text's stroke and
  /// effects. `style` is an override layer over the named style / document default
  /// (architecture §7); resolved fills are in `ResolvedNode.paragraphs`.
  @FreezedUnionValue('text')
  const factory Node.text({
    required NodeCommon common,
    @Default(TextAppearance()) TextAppearance appearance,
    @Default(<Paragraph>[]) List<Paragraph> content,
    String? textStyleId,
    @Default(TextStyleOverride()) TextStyleOverride style,
    @Default(TextAutoResize.widthAndHeight) TextAutoResize autoResize,
    int? maxLines,
    @Default(TextTruncation.none) TextTruncation truncation,
    @Default(TextAlignHorizontal.left) TextAlignHorizontal alignHorizontal,
    @Default(TextAlignVertical.top) TextAlignVertical alignVertical,
    @Default(LeadingTrim.none) LeadingTrim leadingTrim,
  }) = TextNode;

  @FreezedUnionValue('shape')
  const factory Node.shape({
    required NodeCommon common,
    @Default(ShapeGeometry.rectangle()) ShapeGeometry geometry,
    @Default(Appearance()) Appearance appearance,
  }) = ShapeNode;

  /// An instance of a component or variant (§9).
  ///
  /// - `propValues`: `{ propId: IrValue }`.
  /// - `overrides`: `{ innerNodePath: Patch }`, where `innerNodePath` is
  ///   inner ids joined by `/`.
  @FreezedUnionValue('instance')
  const factory Node.instance({
    required NodeCommon common,
    required InstanceSource source,
    @Default(<String, IrValue>{}) Map<String, IrValue> propValues,
    @Default(<String, Patch>{}) Map<String, Patch> overrides,
  }) = InstanceNode;

  /// Video, with the same `scaleMode` + `focalPoint` semantics as images (§6).
  /// `appearance` gives it corners, a stroke and effects; its fills paint
  /// behind the video.
  @FreezedUnionValue('video')
  const factory Node.video({
    required NodeCommon common,
    required String assetId,
    @Default(Appearance()) Appearance appearance,
    @Default(ImageScaleMode.fill) ImageScaleMode scaleMode,
    @Default(StagePoint(x: 0.5, y: 0.5)) StagePoint focalPoint,
    StageRect? cropRect,
    String? posterAssetId,
    @Default(true) bool autoplay,
    @Default(true) bool loop,
    @Default(true) bool muted,

    /// Playback controls shown over the video (m3.md T3.6).
    @Default(VideoControls.none) VideoControls controls,

    /// Trim: play from [startTime] to [endTime] seconds (null: the end).
    @Default(0) double startTime,
    double? endTime,
    @Default(1) double playbackRate,
    @Default(1) double volume,

    /// Play only while on screen (pause when scrolled away).
    @Default(true) bool playWhenVisible,

    /// When set, the video does not play: its time follows this clock
    /// (0–1 progress maps to startTime–endTime), e.g. scrubbed by scroll.
    String? scrubClockId,
  }) = VideoNode;

  /// A Rive or Lottie asset (runtime: M3).
  ///
  /// - `artboard` / `stateMachine`: Rive names; null = the file's default.
  /// - `inputs`: static state-machine input values `{ inputName: IrValue }`.
  /// - `inputBindings`: inputs driven by clocks `{ inputName: clockId }`.
  @FreezedUnionValue('embed')
  const factory Node.embed({
    required NodeCommon common,
    required String assetId,
    @Default(ImageScaleMode.fit) ImageScaleMode scaleMode,
    String? artboard,
    String? stateMachine,
    @Default(true) bool autoplay,
    @Default(true) bool loop,
    @Default(<String, IrValue>{}) Map<String, IrValue> inputs,
    @Default(<String, String>{}) Map<String, String> inputBindings,
  }) = EmbedNode;

  const Node._();

  factory Node.fromJson(Map<String, dynamic> json) => _$NodeFromJson(json);

  /// Shorthand for `common.id`.
  String get id => common.id;

  /// `common.blendMode`, or the kind default when unset: `passThrough` for
  /// frames, `normal` otherwise.
  BlendMode get effectiveBlendMode =>
      common.blendMode ??
      (this is FrameNode ? BlendMode.passThrough : BlendMode.normal);
}
