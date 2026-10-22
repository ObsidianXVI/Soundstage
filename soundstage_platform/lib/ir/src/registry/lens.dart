// Internal building blocks for property descriptors: small functional
// lenses over the immutable IR, and codecs between Dart field values and
// `IrValue`. Not exported from `ir.dart`.

import '../nodes/effect.dart';
import '../nodes/layout.dart';
import '../nodes/node.dart';
import '../nodes/paint.dart';
import '../nodes/stroke.dart';
import '../nodes/text.dart';
import '../values/geometry.dart';
import '../values/ir_value.dart';
import '../values/stage_color.dart';
import 'property_descriptor.dart';

/// A focus on an `A` inside an `S`. Both directions return null when the
/// focus does not exist (wrong node kind, missing id, index out of range)
/// or the value is rejected; nothing throws.
class Lens<S, A> {
  const Lens(this.get, this.set);

  final A? Function(S s, PathParams p) get;
  final S? Function(S s, A a, PathParams p) set;

  /// This lens focused further by [inner].
  Lens<S, B> then<B>(Lens<A, B> inner) => Lens<S, B>(
    (s, p) {
      final a = get(s, p);
      return a == null ? null : inner.get(a, p);
    },
    (s, b, p) {
      final a = get(s, p);
      if (a == null) return null;
      final a2 = inner.set(a, b, p);
      return a2 == null ? null : set(s, a2, p);
    },
  );

  /// This lens ending in [leaf].
  Leaf<S> leaf(Leaf<A> leaf) => Leaf<S>(then(leaf.lens), leaf.codec);
}

/// A lens onto a node property as an [IrValue].
typedef PropertyLens = Lens<Node, IrValue>;

/// A terminal lens onto an [IrValue] plus the codec metadata (value type,
/// nullability) the descriptor reports.
class Leaf<S> {
  const Leaf(this.lens, this.codec);

  final Lens<S, IrValue> lens;
  final IrValueCodec codec;
}

/// Metadata of a codec, independent of its Dart type.
abstract class IrValueCodec {
  const IrValueCodec();

  IrValueType get valueType;
  bool get nullable;
  bool get continuous;
  List<String>? get enumValues;

  /// Whether a non-`none` value decodes.
  bool accepts(IrValue value);
}

/// Converts between a Dart field value and an [IrValue]. [decode] returns
/// null when the value has the wrong type or is out of range.
class Codec<A extends Object> extends IrValueCodec {
  const Codec(
    this.valueType,
    this.encode,
    this.decode, {
    this.continuous = false,
    this.enumValues,
    this.nullable = false,
  });

  @override
  final IrValueType valueType;
  final IrValue Function(A a) encode;
  final A? Function(IrValue v) decode;
  @override
  final bool continuous;
  @override
  final List<String>? enumValues;
  @override
  final bool nullable;

  Codec<A> asNullable() => Codec<A>(
    valueType,
    encode,
    decode,
    continuous: continuous,
    enumValues: enumValues,
    nullable: true,
  );

  @override
  bool accepts(IrValue value) => decode(value) != null;
}

// ---- Codecs ---------------------------------------------------------------

double? _finite(IrValue v) =>
    v is NumberValue && v.value.isFinite ? v.value : null;

const Codec<double> numC = Codec<double>(
  IrValueType.number,
  IrValue.number,
  _finite,
  continuous: true,
);

/// An integer stored field. [continuous] fields (font weight) lerp as
/// numbers and round on write; others step.
Codec<int> intC({bool continuous = false, int? min, int? max}) =>
    Codec<int>(IrValueType.number, (a) => IrValue.number(a.toDouble()), (v) {
      final d = _finite(v);
      if (d == null) return null;
      var i = d.round();
      if (min != null && i < min) i = min;
      if (max != null && i > max) i = max;
      return i;
    }, continuous: continuous);

/// Image paint rotation: a quarter turn in degrees (0, 90, 180, 270).
final Codec<int> quarterTurnC = Codec<int>(
  IrValueType.number,
  (a) => IrValue.number(a.toDouble()),
  (v) {
    final d = _finite(v);
    if (d == null || d % 90 != 0) return null;
    return (d.toInt() % 360 + 360) % 360;
  },
);

final Codec<bool> boolC = Codec<bool>(
  IrValueType.boolean,
  IrValue.boolean,
  (v) => v is BoolValue ? v.value : null,
);

final Codec<String> strC = Codec<String>(
  IrValueType.string,
  IrValue.string,
  (v) => v is StringValue ? v.value : null,
);

/// An enum serialised by name; [names] overrides a value's file-format name
/// (e.g. `TextDecorationStyle.doubleLine` is `"double"`).
Codec<E> enumC<E extends Enum>(List<E> values, [Map<E, String>? names]) {
  String nameOf(E e) => names?[e] ?? e.name;
  final byName = {for (final e in values) nameOf(e): e};
  return Codec<E>(
    IrValueType.enumValue,
    (e) => IrValue.enumValue(nameOf(e)),
    (v) => v is EnumValue ? byName[v.value] : null,
    enumValues: [for (final e in values) nameOf(e)],
  );
}

final Codec<StageColor> colorC = Codec<StageColor>(
  IrValueType.color,
  IrValue.color,
  (v) => v is ColorValue ? v.value : null,
  continuous: true,
);

final Codec<StagePoint> pointC = Codec<StagePoint>(
  IrValueType.point,
  IrValue.point,
  (v) => v is PointValue ? v.value : null,
  continuous: true,
);

final Codec<EdgeInsetsValue> insetsC = Codec<EdgeInsetsValue>(
  IrValueType.insets,
  IrValue.insets,
  (v) => switch (v) {
    InsetsValue(:final value) => value,
    NumberValue(:final value) when value.isFinite => EdgeInsetsValue.all(value),
    _ => null,
  },
  continuous: true,
);

/// Accepts a number as a uniform radius.
final Codec<CornerRadius> cornerRadiusC = Codec<CornerRadius>(
  IrValueType.cornerRadius,
  IrValue.cornerRadius,
  (v) => switch (v) {
    CornerRadiusValue(:final value) => value,
    NumberValue(:final value) when value.isFinite => CornerRadius.uniform(
      value,
    ),
    _ => null,
  },
  continuous: true,
);

/// Accepts a number as a uniform weight.
final Codec<StrokeWeight> strokeWeightC = Codec<StrokeWeight>(
  IrValueType.strokeWeight,
  IrValue.strokeWeight,
  (v) => switch (v) {
    StrokeWeightValue(:final value) => value,
    NumberValue(:final value) when value.isFinite => StrokeWeight.uniform(
      value,
    ),
    _ => null,
  },
  continuous: true,
);

/// Accepts a number as a fixed gap.
final Codec<Gap> gapC = Codec<Gap>(
  IrValueType.gap,
  IrValue.gap,
  (v) => switch (v) {
    GapValue(:final value) => value,
    NumberValue(:final value) when value.isFinite => Gap.fixed(value),
    _ => null,
  },
  continuous: true,
);

final Codec<Paint> paintC = Codec<Paint>(
  IrValueType.paint,
  IrValue.paint,
  (v) => v is PaintValue ? v.value : null,
  continuous: true,
);

final Codec<List<Paint>> paintsC = Codec<List<Paint>>(
  IrValueType.paints,
  IrValue.paints,
  (v) => v is PaintsValue ? v.value : null,
  continuous: true,
);

final Codec<Effect> effectC = Codec<Effect>(
  IrValueType.effect,
  IrValue.effect,
  (v) => v is EffectValue ? v.value : null,
  continuous: true,
);

final Codec<List<Effect>> effectsC = Codec<List<Effect>>(
  IrValueType.effects,
  IrValue.effects,
  (v) => v is EffectsValue ? v.value : null,
  continuous: true,
);

final Codec<LineHeight> lineHeightC = Codec<LineHeight>(
  IrValueType.lineHeight,
  IrValue.lineHeight,
  (v) => v is LineHeightValue ? v.value : null,
  continuous: true,
);

final Codec<LetterSpacing> letterSpacingC = Codec<LetterSpacing>(
  IrValueType.letterSpacing,
  IrValue.letterSpacing,
  (v) => v is LetterSpacingValue ? v.value : null,
  continuous: true,
);

final Codec<List<double>> numbersC = Codec<List<double>>(
  IrValueType.numbers,
  IrValue.numbers,
  (v) => v is NumbersValue ? v.value : null,
  continuous: true,
);

/// Any concrete value (component prop values, embed inputs). Interpolated
/// by the value's own type.
final Codec<IrValue> anyC = Codec<IrValue>(
  IrValueType.any,
  (a) => a,
  (v) => v is NoneValue || v is TokenRefValue ? null : v,
  continuous: true,
);

// ---- Leaves ----------------------------------------------------------------

/// A required field of `S`.
Leaf<S> field<S, A extends Object>(
  Codec<A> codec,
  A Function(S s) get,
  S Function(S s, A a) set,
) => Leaf<S>(
  Lens<S, IrValue>((s, _) => codec.encode(get(s)), (s, v, _) {
    final a = codec.decode(v);
    return a == null ? null : set(s, a);
  }),
  codec,
);

/// A nullable field of `S`: null reads as `IrValue.none()`, and writing
/// `none` clears it.
Leaf<S> optField<S, A extends Object>(
  Codec<A> codec,
  A? Function(S s) get,
  S Function(S s, A? a) set,
) => Leaf<S>(
  Lens<S, IrValue>(
    (s, _) {
      final a = get(s);
      return a == null ? const IrValue.none() : codec.encode(a);
    },
    (s, v, _) {
      if (v is NoneValue) return set(s, null);
      final a = codec.decode(v);
      return a == null ? null : set(s, a);
    },
  ),
  codec.asNullable(),
);

/// An entry of a string-keyed map in `S`, keyed by the path param [param].
/// A missing entry reads as `none`; writing `none` removes it.
Leaf<S> mapEntry<S, A extends Object>(
  Codec<A> codec,
  String param,
  Map<String, A>? Function(S s) get,
  S Function(S s, Map<String, A> m) set,
) => Leaf<S>(
  Lens<S, IrValue>(
    (s, p) {
      final a = get(s)?[p[param]];
      return a == null ? const IrValue.none() : codec.encode(a);
    },
    (s, v, p) {
      final key = p[param];
      if (key == null) return null;
      final m = Map<String, A>.of(get(s) ?? const {});
      if (v is NoneValue) {
        m.remove(key);
      } else {
        final a = codec.decode(v);
        if (a == null) return null;
        m[key] = a;
      }
      return set(s, m);
    },
  ),
  codec.asNullable(),
);

// ---- Structural lenses -----------------------------------------------------

/// Focus on `S` when it is a `T` (e.g. a node of one kind, a paint of one
/// kind).
Lens<S, T> whenType<S, T extends S>() =>
    Lens<S, T>((s, _) => s is T ? s : null, (s, t, _) => t);

/// The element of a list whose id (read by [idOf]) is the path param
/// [param]. Writes keep the element's id.
Lens<List<E>, E> byId<E>(
  String param,
  String Function(E e) idOf,
  E Function(E e, String id) withId,
) => Lens<List<E>, E>(
  (l, p) {
    final id = p[param];
    for (final e in l) {
      if (idOf(e) == id) return e;
    }
    return null;
  },
  (l, e, p) {
    final id = p[param];
    final i = l.indexWhere((x) => idOf(x) == id);
    if (i < 0 || id == null) return null;
    return [...l.sublist(0, i), withId(e, id), ...l.sublist(i + 1)];
  },
);

/// The element at the integer path param [param].
Lens<List<E>, E> atIndex<E>(String param) => Lens<List<E>, E>(
  (l, p) {
    final i = int.tryParse(p[param] ?? '');
    return i == null || i < 0 || i >= l.length ? null : l[i];
  },
  (l, e, p) {
    final i = int.tryParse(p[param] ?? '');
    if (i == null || i < 0 || i >= l.length) return null;
    return [...l.sublist(0, i), e, ...l.sublist(i + 1)];
  },
);

/// A required sub-object.
Lens<S, A> sub<S, A>(A Function(S s) get, S Function(S s, A a) set) =>
    Lens<S, A>((s, _) => get(s), (s, a, _) => set(s, a));

/// An optional sub-object that only exists when set (inapplicable when null).
Lens<S, A> present<S, A extends Object>(
  A? Function(S s) get,
  S Function(S s, A a) set,
) => Lens<S, A>((s, _) => get(s), (s, a, _) => set(s, a));

/// An optional value-like sub-object: reads as [fallback] when null, and a
/// write creates it.
Lens<S, A> materialised<S, A extends Object>(
  A? Function(S s) get,
  S Function(S s, A a) set,
  A fallback,
) => Lens<S, A>((s, _) => get(s) ?? fallback, (s, a, _) => set(s, a));
