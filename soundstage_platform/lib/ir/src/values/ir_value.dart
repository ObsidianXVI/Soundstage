import 'package:freezed_annotation/freezed_annotation.dart';

import '../nodes/effect.dart';
import '../nodes/layout.dart';
import '../nodes/paint.dart';
import '../nodes/stroke.dart';
import '../nodes/text.dart';
import '../tokens.dart';
import 'geometry.dart';
import 'stage_color.dart';

part 'ir_value.freezed.dart';
part 'ir_value.g.dart';

/// A set of property values keyed by `PropertyPath` string (architecture
/// §3.1, §11.1). Used for breakpoint overrides and instance overrides.
typedef Patch = Map<String, IrValue>;

/// A JSON-serialisable property value (architecture §11.1): the value type of
/// patches, keyframes, token variables and component properties.
///
/// The `type` discriminators are part of the file format.
@Freezed(unionKey: 'type')
sealed class IrValue with _$IrValue {
  @FreezedUnionValue('number')
  const factory IrValue.number(double value) = NumberValue;

  @FreezedUnionValue('color')
  const factory IrValue.color(StageColor value) = ColorValue;

  @FreezedUnionValue('bool')
  const factory IrValue.boolean(bool value) = BoolValue;

  @FreezedUnionValue('string')
  const factory IrValue.string(String value) = StringValue;

  /// An enum value, by its serialised (camelCase) name.
  @FreezedUnionValue('enum')
  const factory IrValue.enumValue(String value) = EnumValue;

  @FreezedUnionValue('size')
  const factory IrValue.size(StageSize value) = SizeValue;

  @FreezedUnionValue('point')
  const factory IrValue.point(StagePoint value) = PointValue;

  @FreezedUnionValue('insets')
  const factory IrValue.insets(EdgeInsetsValue value) = InsetsValue;

  @FreezedUnionValue('cornerRadius')
  const factory IrValue.cornerRadius(CornerRadius value) = CornerRadiusValue;

  @FreezedUnionValue('strokeWeight')
  const factory IrValue.strokeWeight(StrokeWeight value) = StrokeWeightValue;

  @FreezedUnionValue('gap')
  const factory IrValue.gap(Gap value) = GapValue;

  @FreezedUnionValue('paint')
  const factory IrValue.paint(Paint value) = PaintValue;

  @FreezedUnionValue('paints')
  const factory IrValue.paints(List<Paint> value) = PaintsValue;

  @FreezedUnionValue('effect')
  const factory IrValue.effect(Effect value) = EffectValue;

  @FreezedUnionValue('effects')
  const factory IrValue.effects(List<Effect> value) = EffectsValue;

  @FreezedUnionValue('lineHeight')
  const factory IrValue.lineHeight(LineHeight value) = LineHeightValue;

  @FreezedUnionValue('letterSpacing')
  const factory IrValue.letterSpacing(LetterSpacing value) = LetterSpacingValue;

  /// A list of numbers (e.g. a stroke dash pattern).
  @FreezedUnionValue('numbers')
  const factory IrValue.numbers(List<double> value) = NumbersValue;

  /// Grid row or column tracks (§4.5), so a grid's columns can differ per
  /// breakpoint.
  @FreezedUnionValue('gridTracks')
  const factory IrValue.gridTracks(List<GridTrack> value) = GridTracksValue;

  /// A reference to a token variable (§8). Also the alias form of a
  /// variable's value.
  @FreezedUnionValue('tokenRef')
  const factory IrValue.tokenRef(TokenRef value) = TokenRefValue;

  /// No value: clears a nullable property (e.g. `layoutChild.maxWidth`) in a
  /// patch.
  @FreezedUnionValue('none')
  const factory IrValue.none() = NoneValue;

  factory IrValue.fromJson(Map<String, dynamic> json) =>
      _$IrValueFromJson(json);
}
