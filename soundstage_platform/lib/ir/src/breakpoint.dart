import 'package:freezed_annotation/freezed_annotation.dart';

import 'values/geometry.dart';

part 'breakpoint.freezed.dart';
part 'breakpoint.g.dart';

/// A responsive breakpoint (architecture §3.1). Active when it has the
/// largest `minWidth` ≤ the viewport width. `designSize` is the reference
/// viewport the author designs at, and the reference size for constraints on
/// a scene's stage root.
@freezed
abstract class Breakpoint with _$Breakpoint {
  const factory Breakpoint({
    required String id,
    required String name,
    required double minWidth,
    required StageSize designSize,
  }) = _Breakpoint;

  factory Breakpoint.fromJson(Map<String, dynamic> json) =>
      _$BreakpointFromJson(json);
}
