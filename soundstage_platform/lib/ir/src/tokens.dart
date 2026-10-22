import 'package:freezed_annotation/freezed_annotation.dart';

import 'nodes/effect.dart';
import 'nodes/paint.dart';
import 'nodes/text.dart';
import 'values/ir_value.dart';

part 'tokens.freezed.dart';
part 'tokens.g.dart';

@JsonEnum()
enum VariableType { color, number, string, boolean, fontFamily }

/// A reference to a token variable (architecture §8).
@freezed
abstract class TokenRef with _$TokenRef {
  const factory TokenRef({required String variableId}) = _TokenRef;

  factory TokenRef.fromJson(Map<String, dynamic> json) =>
      _$TokenRefFromJson(json);
}

/// A mode of a variable collection (e.g. light/dark, compact/roomy).
@freezed
abstract class TokenMode with _$TokenMode {
  const factory TokenMode({required String id, required String name}) =
      _TokenMode;

  factory TokenMode.fromJson(Map<String, dynamic> json) =>
      _$TokenModeFromJson(json);
}

/// A design token (Figma variable).
///
/// `valuesByMode`: `{ modeId: IrValue }`; an alias is an
/// `IrValue.tokenRef`. `name` is slash-grouped, e.g. `color/brand/primary`.
@freezed
abstract class Variable with _$Variable {
  const factory Variable({
    required String id,
    required String name,
    required VariableType type,
    @Default(<String, IrValue>{}) Map<String, IrValue> valuesByMode,
  }) = _Variable;

  factory Variable.fromJson(Map<String, dynamic> json) =>
      _$VariableFromJson(json);
}

/// A collection of variables sharing a set of modes.
///
/// `breakpointModes`: `{ breakpointId: modeId }` — responsive tokens; empty =
/// the default mode at every breakpoint.
@freezed
abstract class VariableCollection with _$VariableCollection {
  const factory VariableCollection({
    required String id,
    required String name,
    required List<TokenMode> modes,
    required String defaultModeId,
    @Default(<String, String>{}) Map<String, String> breakpointModes,
    @Default(<Variable>[]) List<Variable> variables,
  }) = _VariableCollection;

  factory VariableCollection.fromJson(Map<String, dynamic> json) =>
      _$VariableCollectionFromJson(json);
}

/// A named text style: a partial [TextStyleOverride] layered over the
/// document's default text style. Its fields may be token-bound via `bindings`
/// (`{ PropertyPath relative to the style: TokenRef }`).
@freezed
abstract class TextStyleDef with _$TextStyleDef {
  const factory TextStyleDef({
    required String name,
    @Default(TextStyleOverride()) TextStyleOverride style,
    @Default(<String, TokenRef>{}) Map<String, TokenRef> bindings,
  }) = _TextStyleDef;

  factory TextStyleDef.fromJson(Map<String, dynamic> json) =>
      _$TextStyleDefFromJson(json);
}

@freezed
abstract class PaintStyleDef with _$PaintStyleDef {
  const factory PaintStyleDef({
    required String name,
    @Default(<Paint>[]) List<Paint> paints,
  }) = _PaintStyleDef;

  factory PaintStyleDef.fromJson(Map<String, dynamic> json) =>
      _$PaintStyleDefFromJson(json);
}

@freezed
abstract class EffectStyleDef with _$EffectStyleDef {
  const factory EffectStyleDef({
    required String name,
    @Default(<Effect>[]) List<Effect> effects,
  }) = _EffectStyleDef;

  factory EffectStyleDef.fromJson(Map<String, dynamic> json) =>
      _$EffectStyleDefFromJson(json);
}

/// Tokens and named styles (architecture §8). Style maps are keyed by id.
@freezed
abstract class TokenSystem with _$TokenSystem {
  const factory TokenSystem({
    @Default(<VariableCollection>[]) List<VariableCollection> collections,
    @Default(<String, TextStyleDef>{}) Map<String, TextStyleDef> textStyles,
    @Default(<String, PaintStyleDef>{}) Map<String, PaintStyleDef> paintStyles,
    @Default(<String, EffectStyleDef>{})
    Map<String, EffectStyleDef> effectStyles,
  }) = _TokenSystem;

  factory TokenSystem.fromJson(Map<String, dynamic> json) =>
      _$TokenSystemFromJson(json);
}
