import 'package:freezed_annotation/freezed_annotation.dart';

import '../values/geometry.dart';

part 'layout.freezed.dart';
part 'layout.g.dart';

@JsonEnum()
enum LayoutDirection { horizontal, vertical }

@JsonEnum()
enum PrimaryAlign { start, center, end }

/// `baseline` is valid for horizontal layouts only.
@JsonEnum()
enum CounterAlign { start, center, end, baseline }

@JsonEnum()
enum RowAlign { start, center, end }

/// Auto-layout frame sizing along an axis.
@JsonEnum()
enum AxisSizing { fixed, hug }

@JsonEnum()
enum GridAutoFlow { row, column }

/// Spacing between children: a fixed amount (negative = overlap) or `auto`
/// (space-between) (architecture §4.4).
@Freezed(unionKey: 'type')
sealed class Gap with _$Gap {
  @FreezedUnionValue('fixed')
  const factory Gap.fixed([@Default(0) double value]) = FixedGap;

  @FreezedUnionValue('auto')
  const factory Gap.auto() = AutoGap;

  factory Gap.fromJson(Map<String, dynamic> json) => _$GapFromJson(json);
}

/// Auto layout (architecture §4.4).
@freezed
abstract class AutoLayout with _$AutoLayout {
  const factory AutoLayout({
    @Default(LayoutDirection.horizontal) LayoutDirection direction,

    /// Horizontal only.
    @Default(false) bool wrap,
    @Default(Gap.fixed()) Gap gap,

    /// Between wrapped rows.
    @Default(Gap.fixed()) Gap counterAxisGap,
    @Default(EdgeInsetsValue()) EdgeInsetsValue padding,
    @Default(PrimaryAlign.start) PrimaryAlign primaryAlign,
    @Default(CounterAlign.start) CounterAlign counterAlign,
    @Default(RowAlign.start) RowAlign rowAlign,
    @Default(AxisSizing.hug) AxisSizing primarySizing,
    @Default(AxisSizing.hug) AxisSizing counterSizing,
    @Default(false) bool strokesIncludedInLayout,

    /// First child paints on top.
    @Default(false) bool reverseZIndex,
  }) = _AutoLayout;

  factory AutoLayout.fromJson(Map<String, dynamic> json) =>
      _$AutoLayoutFromJson(json);
}

/// A grid row or column track (architecture §4.5).
@Freezed(unionKey: 'type')
sealed class GridTrack with _$GridTrack {
  /// A fixed size in pixels.
  @FreezedUnionValue('fixed')
  const factory GridTrack.fixed(double px) = FixedGridTrack;

  /// A share of the remaining space (CSS `fr`).
  @FreezedUnionValue('flex')
  const factory GridTrack.flex([@Default(1) double fr]) = FlexGridTrack;

  /// Sized to its content.
  @FreezedUnionValue('hug')
  const factory GridTrack.hug() = HugGridTrack;

  factory GridTrack.fromJson(Map<String, dynamic> json) =>
      _$GridTrackFromJson(json);
}

/// Grid layout (architecture §4.5). Runtime support lands in M3; the model is
/// part of the v1 file format.
@freezed
abstract class GridLayout with _$GridLayout {
  const factory GridLayout({
    @Default(<GridTrack>[]) List<GridTrack> columns,
    @Default(<GridTrack>[]) List<GridTrack> rows,
    @Default(0) double columnGap,
    @Default(0) double rowGap,
    @Default(EdgeInsetsValue()) EdgeInsetsValue padding,
    @Default(GridAutoFlow.row) GridAutoFlow autoFlow,
  }) = _GridLayout;

  factory GridLayout.fromJson(Map<String, dynamic> json) =>
      _$GridLayoutFromJson(json);
}
