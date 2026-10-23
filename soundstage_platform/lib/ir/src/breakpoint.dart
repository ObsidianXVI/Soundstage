import 'package:freezed_annotation/freezed_annotation.dart';

import 'values/geometry.dart';

part 'breakpoint.freezed.dart';
part 'breakpoint.g.dart';

/// A responsive breakpoint (architecture §3.1). Active when it has the
/// largest `minWidth` ≤ the viewport width. `designSize` is the reference
/// viewport the author designs at, and the reference size for constraints on
/// a scene's stage root.
///
/// Shared-base model: a node's own values are the base every breakpoint
/// starts from. A breakpoint resolves as base → the patches along its
/// `inheritsFrom` chain (root first) → its own patch (`breakpointChain`).
/// `inheritsFrom: null` makes it a peer over the shared base. `primary`
/// breakpoints get their own artboard in the editor (§15) and are the ones
/// the "Both" edit scope clears.
@freezed
abstract class Breakpoint with _$Breakpoint {
  const factory Breakpoint({
    required String id,
    required String name,
    required double minWidth,
    required StageSize designSize,
    String? inheritsFrom,
    @Default(false) bool primary,
  }) = _Breakpoint;

  factory Breakpoint.fromJson(Map<String, dynamic> json) =>
      _$BreakpointFromJson(json);
}
