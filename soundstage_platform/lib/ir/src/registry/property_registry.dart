import '../nodes/appearance.dart';
import '../nodes/effect.dart';
import '../nodes/layout.dart';
import '../nodes/node.dart';
import '../nodes/node_common.dart';
import '../nodes/paint.dart';
import '../nodes/stroke.dart';
import '../nodes/text.dart';
import '../values/ir_value.dart';
import '../values/stage_color.dart';
import 'property_descriptor.dart';
import 'standard_properties.dart';

/// Maps `PropertyPath` strings to [PropertyDescriptor]s (architecture
/// §11.2). Patches, instance overrides, token bindings, tracks and the
/// inspector all address properties through this.
class PropertyRegistry {
  /// A registry over [descriptors]. Patterns must be unique.
  PropertyRegistry(Iterable<PropertyDescriptor> descriptors)
    : descriptors = List.unmodifiable(descriptors) {
    for (final d in this.descriptors) {
      if (_byPattern.containsKey(d.pathPattern)) {
        throw ArgumentError('Duplicate property pattern ${d.pathPattern}');
      }
      _byPattern[d.pathPattern] = d;
      (_byLength[d.patternSegments.length] ??= []).add(d);
    }
  }

  /// Every standard property of architecture §4.2, §5, §6 and §7.
  static final PropertyRegistry standard = PropertyRegistry(
    _withDefaults(buildStandardProperties()),
  );

  final List<PropertyDescriptor> descriptors;
  final Map<String, PropertyDescriptor> _byPattern = {};
  final Map<int, List<PropertyDescriptor>> _byLength = {};
  final Map<String, PropertyMatch?> _cache = {};

  /// The descriptor registered under exactly [pattern].
  PropertyDescriptor? descriptorFor(String pattern) => _byPattern[pattern];

  /// Matches a concrete [path] (e.g. `fills.p1.color`) to its descriptor and
  /// bound params. Returns null for an unknown path; never throws. A
  /// literal segment wins over a `<param>` when both match.
  PropertyMatch? lookup(String path) {
    if (_cache.containsKey(path)) return _cache[path];
    final match = _lookup(path);
    if (_cache.length > 4096) _cache.clear();
    return _cache[path] = match;
  }

  PropertyMatch? _lookup(String path) {
    if (path.isEmpty) return null;
    final segments = path.split('.');
    final candidates = _byLength[segments.length];
    if (candidates == null) return null;
    PropertyMatch? best;
    var bestParams = 1 << 30;
    for (final d in candidates) {
      final params = <String, String>{};
      var ok = true;
      for (var i = 0; i < segments.length && ok; i++) {
        final pat = d.patternSegments[i];
        final seg = segments[i];
        if (isPatternParam(pat)) {
          final name = pat.substring(1, pat.length - 1);
          ok =
              seg.isNotEmpty &&
              (!name.endsWith('Index') || RegExp(r'^\d+$').hasMatch(seg));
          params[name] = seg;
        } else {
          ok = pat == seg;
        }
      }
      if (ok && params.length < bestParams) {
        best = PropertyMatch(path, d, Map.unmodifiable(params));
        bestParams = params.length;
      }
    }
    return best;
  }

  /// Reads [path] from [node]; null when the path is unknown or does not
  /// exist on the node.
  IrValue? get(Node node, String path) => lookup(path)?.get(node);

  /// Writes [path]; null when the path is unknown, does not exist on the
  /// node, or [value] has the wrong type.
  Node? trySet(Node node, String path, IrValue value) =>
      lookup(path)?.trySet(node, value);
}

// ---- Defaults ----------------------------------------------------------------

/// Candidate values for pattern params, matching [_prototypes].
const Map<String, List<String>> _paramCandidates = {
  'paintId': ['solid', 'gradient', 'image'],
  'effectId': ['dropShadow', 'innerShadow', 'layerBlur', 'backgroundBlur'],
};

/// Model-default nodes of every kind, with one paint/effect of each kind,
/// auto layout and grid present, and one paragraph with one span, so every
/// descriptor can read its default. Required fields with no model default
/// (a solid's colour, gradient stops, asset ids) use neutral placeholders.
List<Node> _prototypes() {
  const paints = <Paint>[
    Paint.solid(id: 'solid', color: StageColor.black),
    Paint.gradient(
      id: 'gradient',
      stops: [
        ColorStop(position: 0, color: StageColor.black),
        ColorStop(position: 1, color: StageColor.white),
      ],
    ),
    Paint.image(id: 'image', assetId: ''),
  ];
  const effects = <Effect>[
    Effect.dropShadow(id: 'dropShadow'),
    Effect.innerShadow(id: 'innerShadow'),
    Effect.layerBlur(id: 'layerBlur'),
    Effect.backgroundBlur(id: 'backgroundBlur'),
  ];
  const appearance = Appearance(
    fills: paints,
    strokes: Stroke(paints: paints),
    effects: effects,
  );
  const common = NodeCommon(id: '');
  return [
    const FrameNode(
      common: common,
      appearance: appearance,
      autoLayout: AutoLayout(),
    ),
    const FrameNode(common: common, grid: GridLayout()),
    const TextNode(
      common: common,
      appearance: TextAppearance(
        strokes: Stroke(paints: paints),
        effects: effects,
      ),
      style: TextStyleOverride(fills: paints),
      content: [
        Paragraph(spans: [Span(text: '')]),
      ],
    ),
    const ShapeNode(common: common, appearance: appearance),
    const ShapeNode(common: common, geometry: ShapeGeometry.ellipse()),
    const ShapeNode(common: common, geometry: ShapeGeometry.star()),
    const InstanceNode(common: common, source: InstanceSource.component('')),
    const VideoNode(common: common, assetId: '', appearance: appearance),
    const EmbedNode(common: common, assetId: ''),
  ];
}

Iterable<PathParams> _paramCombos(List<String> names) sync* {
  if (names.isEmpty) {
    yield const {};
    return;
  }
  final first = names.first;
  final values = _paramCandidates[first] ?? const ['0'];
  for (final rest in _paramCombos(names.sublist(1))) {
    for (final v in values) {
      yield {first: v, ...rest};
    }
  }
}

List<PropertyDescriptor> _withDefaults(List<PropertyDescriptor> list) {
  final protos = _prototypes();
  return [
    for (final d in list)
      if (d.defaultValue != null)
        d
      else
        d.copyWithDefault(_readDefault(d, protos)),
  ];
}

IrValue? _readDefault(PropertyDescriptor d, List<Node> protos) {
  for (final node in protos) {
    if (!d.appliesTo.contains(nodeKindOf(node))) continue;
    for (final params in _paramCombos(d.paramNames)) {
      final v = d.get(node, params);
      if (v != null) return v;
    }
  }
  return null;
}
