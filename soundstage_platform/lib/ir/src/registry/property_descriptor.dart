import '../animation/interpolate.dart';
import '../nodes/node.dart';
import '../values/ir_value.dart';
import 'display_names.dart';
import 'lens.dart';

/// The node kinds a property can apply to (architecture §4.1).
enum NodeKind { frame, text, shape, instance, video, embed }

/// The kind of [node].
NodeKind nodeKindOf(Node node) => switch (node) {
  FrameNode() => NodeKind.frame,
  TextNode() => NodeKind.text,
  ShapeNode() => NodeKind.shape,
  InstanceNode() => NodeKind.instance,
  VideoNode() => NodeKind.video,
  EmbedNode() => NodeKind.embed,
};

/// The value type of a property: which [IrValue] variant it takes.
enum IrValueType {
  number,
  color,
  boolean,
  string,
  enumValue,
  size,
  point,
  insets,
  cornerRadius,
  strokeWeight,
  gap,
  paint,
  paints,
  effect,
  effects,
  lineHeight,
  letterSpacing,
  numbers,
  gridTracks,

  /// Any value (component prop values, embed inputs).
  any,
}

/// What a runtime must redo when a property changes (architecture §11.2,
/// §14).
enum Invalidation {
  /// Nothing: the property never affects rendering (names, the editor-only
  /// lock, semantic roles, reading order, alt text).
  none,

  /// Repaint only (colours, blur radii, shadows, blend, corners).
  paint,

  /// Re-composite only: a layer-level change (opacity, `motion.*`).
  compositing,

  /// Relayout (geometry, sizing, auto layout, padding, text metrics).
  layout,
}

/// How a property animates between keyframes (architecture §10.2).
enum Interpolation {
  /// Interpolated by value type (`lerpIrValue`); falls back to a step when
  /// the two values cannot be interpolated (e.g. paint stacks whose
  /// structure differs).
  continuous,

  /// Holds the earlier keyframe's value until the later keyframe's time.
  step,
}

/// Values bound to a pattern's `<param>` segments, e.g.
/// `{'paintId': 'p1'}` for `fills.p1.color` against `fills.<paintId>.color`.
typedef PathParams = Map<String, String>;

/// One addressable property (architecture §11.2).
///
/// [get] returns null when the property does not exist on the node (wrong
/// kind, or no paint/effect/span with the bound id/index). A nullable
/// property that is currently unset reads as `IrValue.none()`.
class PropertyDescriptor {
  PropertyDescriptor({
    required this.pathPattern,
    required this.appliesTo,
    required Leaf<Node> leaf,
    this.defaultValue,
    this.animatable = true,
    this.invalidation = Invalidation.paint,
    Interpolation? interpolation,
    this._label,
  }) : _leaf = leaf,
       _lens = leaf.lens,
       _codec = leaf.codec,
       interpolation =
           interpolation ??
           (leaf.codec.continuous
               ? Interpolation.continuous
               : Interpolation.step);

  /// The dotted pattern, with `<name>` for bound segments.
  final String pathPattern;

  /// Node kinds this property exists on.
  final Set<NodeKind> appliesTo;

  /// The model default (null when there is none, e.g. a paint's colour).
  final IrValue? defaultValue;

  final bool animatable;
  final Invalidation invalidation;
  final Interpolation interpolation;

  final String? _label;

  /// The human name of the property ("Translate X", "Fill color"), shown
  /// by the editor (timeline lane labels, the Motion section). An explicit
  /// label, else one derived from [pathPattern] ([propertyDisplayName]).
  late final String displayName = _label ?? propertyDisplayName(pathPattern);

  final Leaf<Node> _leaf;
  final PropertyLens _lens;
  final IrValueCodec _codec;

  /// This descriptor with [defaultValue] replaced.
  PropertyDescriptor copyWithDefault(IrValue? defaultValue) =>
      PropertyDescriptor(
        pathPattern: pathPattern,
        appliesTo: appliesTo,
        leaf: _leaf,
        defaultValue: defaultValue,
        animatable: animatable,
        invalidation: invalidation,
        interpolation: interpolation,
        label: _label,
      );

  IrValueType get valueType => _codec.valueType;

  /// Whether `IrValue.none()` is accepted (clears the property).
  bool get nullable => _codec.nullable;

  /// The allowed serialised names when [valueType] is `enumValue`.
  List<String>? get enumValues => _codec.enumValues;

  /// The segments of [pathPattern].
  late final List<String> patternSegments = pathPattern.split('.');

  /// Names of the `<param>` segments, in order.
  late final List<String> paramNames = [
    for (final s in patternSegments)
      if (_isParam(s)) s.substring(1, s.length - 1),
  ];

  /// Reads the property from [node], or null when it does not exist there.
  IrValue? get(Node node, [PathParams params = const {}]) {
    if (!appliesTo.contains(nodeKindOf(node))) return null;
    return _lens.get(node, params);
  }

  /// Writes [value] into [node]. Returns null when the property does not
  /// exist on the node or [value] has the wrong type; never throws.
  Node? trySet(Node node, IrValue value, [PathParams params = const {}]) {
    if (!appliesTo.contains(nodeKindOf(node))) return null;
    if (value is NoneValue && !nullable) return null;
    if (value is TokenRefValue) return null;
    if (value is! NoneValue && !_codec.accepts(value)) return null;
    return _lens.set(node, value, params);
  }

  /// [trySet], returning [node] unchanged when the write does not apply.
  Node set(Node node, IrValue value, [PathParams params = const {}]) =>
      trySet(node, value, params) ?? node;

  /// Interpolates from [a] to [b] at eased progress [t]. Null means the
  /// values step: hold [a] until the later keyframe's time.
  IrValue? interpolate(IrValue a, IrValue b, double t) =>
      interpolation == Interpolation.step ? null : lerpIrValue(a, b, t);

  @override
  String toString() => 'PropertyDescriptor($pathPattern)';
}

bool _isParam(String segment) =>
    segment.length > 2 && segment.startsWith('<') && segment.endsWith('>');

/// Whether a pattern segment is a `<param>`.
bool isPatternParam(String segment) => _isParam(segment);

/// A concrete path matched to its descriptor, with the bound params.
/// `get`/`set` here have the spec's `get(Node)` / `set(Node, IrValue)` shape.
class PropertyMatch {
  const PropertyMatch(this.path, this.descriptor, this.params);

  final String path;
  final PropertyDescriptor descriptor;
  final PathParams params;

  IrValue? get(Node node) => descriptor.get(node, params);

  Node? trySet(Node node, IrValue value) =>
      descriptor.trySet(node, value, params);

  Node set(Node node, IrValue value) => descriptor.set(node, value, params);

  IrValue? interpolate(IrValue a, IrValue b, double t) =>
      descriptor.interpolate(a, b, t);

  /// The property's human name (see [PropertyDescriptor.displayName]).
  String get displayName => descriptor.displayName;

  @override
  String toString() => 'PropertyMatch($path → ${descriptor.pathPattern})';
}
