import 'package:freezed_annotation/freezed_annotation.dart';

import 'nodes/node.dart';
import 'values/ir_value.dart';

part 'components.freezed.dart';
part 'components.g.dart';

@JsonEnum()
enum ComponentPropType { text, boolean, number, asset, instanceSwap, variant }

/// A component property (architecture §9). Nodes inside the component's root
/// bind to it through `NodeCommon.componentBindings`.
@freezed
abstract class ComponentPropDef with _$ComponentPropDef {
  const factory ComponentPropDef({
    required String name,
    required ComponentPropType type,
    @JsonKey(name: 'default') required IrValue defaultValue,
  }) = _ComponentPropDef;

  factory ComponentPropDef.fromJson(Map<String, dynamic> json) =>
      _$ComponentPropDefFromJson(json);
}

/// A reusable component (architecture §9).
///
/// `root` is typed [FrameNode] rather than [Node]: a component's root is
/// always a frame (as in Figma, and so it has a box, layout and appearance
/// to instantiate). Freezed generates `FrameNode.fromJson`/`toJson` for the
/// union variant, so the JSON is the same `{"type": "frame", …}` object a
/// `Node` would produce, and the type system rules out non-frame roots.
///
/// `properties`: `{ propId: ComponentPropDef }`.
@freezed
abstract class ComponentDef with _$ComponentDef {
  const factory ComponentDef({
    required String id,
    required String name,
    required FrameNode root,
    @Default('') String description,
    @Default(<String, ComponentPropDef>{})
    Map<String, ComponentPropDef> properties,
  }) = _ComponentDef;

  factory ComponentDef.fromJson(Map<String, dynamic> json) =>
      _$ComponentDefFromJson(json);
}

/// One variant of a variant set: its axis values and the component that
/// implements it. `values`: `{ axis: value }`.
@freezed
abstract class Variant with _$Variant {
  const factory Variant({
    required String componentId,
    @Default(<String, String>{}) Map<String, String> values,
  }) = _Variant;

  factory Variant.fromJson(Map<String, dynamic> json) =>
      _$VariantFromJson(json);
}

/// A set of component variants (architecture §9). `axes`: `{ axis: [values] }`.
@freezed
abstract class VariantSet with _$VariantSet {
  const factory VariantSet({
    required String id,
    required String name,
    @Default(<String, List<String>>{}) Map<String, List<String>> axes,
    @Default(<Variant>[]) List<Variant> variants,
  }) = _VariantSet;

  factory VariantSet.fromJson(Map<String, dynamic> json) =>
      _$VariantSetFromJson(json);
}
