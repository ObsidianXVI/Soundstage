import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';

// What the inspector reads. Every field subscribes to exactly one
// [propertyReadingProvider] (and, for its badge, one
// [valueSourceProvider]), both value-compared, so an edit rebuilds only the
// fields whose own value changed.

const String _sep = '\u0001';

/// A property of a set of nodes, compared by value: the key of the small
/// per-section `Provider.family`s that derive facts from the selection.
/// (Fields themselves use [SelectedNodes.read].)
@immutable
class ReadKey {
  ReadKey(Iterable<String> ids, this.path) : idsKey = ids.join(_sep);

  final String idsKey;
  final String path;

  List<String> get ids => idsKey.isEmpty ? const [] : idsKey.split(_sep);

  @override
  bool operator ==(Object other) =>
      other is ReadKey && other.idsKey == idsKey && other.path == path;

  @override
  int get hashCode => Object.hash(idsKey, path);
}

/// The value of one property across the selection, at the edited breakpoint.
///
/// - `value`: the value shared by every node that has the property (the
///   first one's when [mixed]).
/// - `mixed`: nodes with the property disagree.
/// - `applicable`: nodes the property exists on (of [total] selected).
@immutable
class PropertyReading {
  const PropertyReading({
    this.value,
    this.mixed = false,
    this.applicable = 0,
    this.total = 0,
  });

  static const PropertyReading none = PropertyReading();

  final ir.IrValue? value;
  final bool mixed;
  final int applicable;
  final int total;

  /// Whether any selected node has the property.
  bool get exists => applicable > 0;

  /// The number, when the value is one.
  double? get number => switch (value) {
    ir.NumberValue(:final value) => value,
    _ => null,
  };

  /// The enum name, when the value is one.
  String? get enumName => switch (value) {
    ir.EnumValue(:final value) => value,
    _ => null,
  };

  bool? get boolean => switch (value) {
    ir.BoolValue(:final value) => value,
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is PropertyReading &&
      other.value == value &&
      other.mixed == mixed &&
      other.applicable == applicable &&
      other.total == total;

  @override
  int get hashCode => Object.hash(value, mixed, applicable, total);
}

/// The selected nodes at the edited breakpoint: the single shared input of
/// every field.
///
/// Fields do `ref.watch(selectedNodesProvider.select((s) => s.read(path)))`:
/// one provider for the whole panel and one cheap selector per field, instead
/// of a provider per field. The provider's value is compared by node
/// identity, so an edit elsewhere in the story (which re-resolves only its
/// own path) does not even run the selectors.
@immutable
class SelectedNodes {
  const SelectedNodes({
    required this.ids,
    required this.resolved,
    required this.authored,
    required this.document,
    required this.breakpointId,
    this.resolver,
    this.animated = const [],
    this.clockValues = const {},
  });

  /// Ids of the selected nodes that exist at [breakpointId], in selection
  /// order; [resolved] and [authored] are parallel to it ([authored] is null
  /// for nodes inside instances).
  final List<String> ids;
  final List<ir.ResolvedNode> resolved;
  final List<ir.Node?> authored;

  /// The document these were read from (names in tooltips; not compared).
  final ir.StageDocument document;

  /// The edited breakpoint's long-lived resolver, current for [document]
  /// (`explain` reuses its memo); null without a breakpoint. Not compared.
  final ir.Resolver? resolver;
  final String? breakpointId;

  /// The animated values at the playheads, parallel to [ids] (empty when no
  /// selected node is animated; null entries for nodes without tracks):
  /// `property path → value` of every track that animates the node at
  /// [breakpointId] (m2.md: the inspector shows the value at the playhead).
  /// Compared by value, so scrubbing rebuilds only fields whose animated
  /// value changed, and nothing when the selection is not animated.
  final List<Map<String, ir.IrValue>?> animated;

  /// The playheads the [animated] values were evaluated at (`clockId →
  /// value`), for `explainAt`. Not compared.
  final Map<String, double> clockValues;

  /// Whether node [i] has a track on [path], a path under it or a path
  /// containing it.
  bool isAnimated(int i, String path) {
    final a = i < animated.length ? animated[i] : null;
    if (a == null) return false;
    for (final k in a.keys) {
      if (k == path || k.startsWith('$path.') || path.startsWith('$k.')) {
        return true;
      }
    }
    return false;
  }

  /// [path] of selected node [i] as shown: the animated value at the
  /// playhead when a track animates it, else the resolved (static) value.
  ir.IrValue? valueAt(int i, String path) {
    final n = resolved[i];
    final a = i < animated.length ? animated[i] : null;
    if (a == null || a.isEmpty) return ir.resolvedPropertyValue(n, path);
    final exact = a[path];
    if (exact != null) return exact;
    var node = n.node;
    var touched = false;
    a.forEach((p, v) {
      if (!(p.startsWith('$path.') || path.startsWith('$p.'))) return;
      final next = ir.PropertyRegistry.standard.lookup(p)?.trySet(node, v);
      if (next == null) return;
      node = next;
      touched = true;
    });
    return ir.resolvedPropertyValue(touched ? n.copyWith(node: node) : n, path);
  }

  /// [path] across the selection.
  PropertyReading read(String path) {
    ir.IrValue? first;
    var mixed = false;
    var applicable = 0;
    for (var i = 0; i < resolved.length; i++) {
      final v = valueAt(i, path);
      if (v == null) continue;
      applicable++;
      if (first == null) {
        first = v;
      } else if (v != first) {
        mixed = true;
      }
    }
    return PropertyReading(
      value: first,
      mixed: mixed,
      applicable: applicable,
      total: resolved.length,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! SelectedNodes ||
        other.breakpointId != breakpointId ||
        other.ids.length != ids.length) {
      return false;
    }
    for (var i = 0; i < ids.length; i++) {
      if (other.ids[i] != ids[i] ||
          !identical(other.resolved[i], resolved[i]) ||
          !identical(other.authored[i], authored[i])) {
        return false;
      }
    }
    if (other.animated.length != animated.length) return false;
    for (var i = 0; i < animated.length; i++) {
      if (!mapEquals(other.animated[i], animated[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(breakpointId, Object.hashAll(ids));
}

/// The live selection as [SelectedNodes].
final selectedNodesProvider = Provider.autoDispose<SelectedNodes>(
  (ref) {
    final ids = ref.watch(selectionIdsProvider);
    final bp = ref.watch(
      editorControllerProvider.select((s) => s.breakpointId),
    );
    if (bp == null || ids.isEmpty) {
      return SelectedNodes(
        ids: const [],
        resolved: const [],
        authored: const [],
        document: ref.read(editorControllerProvider).document,
        breakpointId: bp,
      );
    }
    final art = ref.watch(resolvedForProvider(bp));
    final index = ir.DocumentIndex.of(art.document);
    final found = <String>[];
    final resolved = <ir.ResolvedNode>[];
    final authored = <ir.Node?>[];
    for (final id in ids.ids) {
      final n = art.resolved.nodeIndex[id];
      if (n == null) continue;
      found.add(id);
      resolved.add(n);
      authored.add(id.contains('/') ? null : index.node(id));
    }
    // Animated values at the playheads. The playheads are watched only
    // while a selected node is animated, so scrubbing never touches the
    // inspector of a static selection.
    final sceneId = ref.watch(
      editorControllerProvider.select((s) => s.activeSceneId),
    );
    final tracks = art.scene(sceneId)?.tracks ?? const <ir.Track>[];
    final selected = found.toSet();
    final mine = [
      for (final t in tracks)
        if (selected.contains(t.target)) t,
    ];
    var animated = const <Map<String, ir.IrValue>?>[];
    var clocks = const <String, double>{};
    if (mine.isNotEmpty) {
      clocks = ref
          .watch(
            editorControllerProvider.select(
              (s) => Identity(s.clockValuesOf(sceneId)),
            ),
          )
          .value;
      final byNode = <String, Map<String, ir.IrValue>>{};
      for (final t in mine) {
        final v = ir.evaluateTrack(t, clocks[t.clockId] ?? 0);
        if (v != null) (byNode[t.target] ??= {})[t.property] = v;
      }
      animated = [for (final id in found) byNode[id]];
    }
    return SelectedNodes(
      animated: animated,
      clockValues: clocks,
      ids: found,
      resolved: resolved,
      authored: authored,
      document: art.document,
      breakpointId: bp,
      resolver: ref.read(editorControllerProvider.notifier).resolverFor(bp),
    );
  },
  dependencies: [
    editorControllerProvider,
    resolvedForProvider,
    selectionIdsProvider,
  ],
);

/// [ReadKey.path] of the nodes [ReadKey.ids] (any nodes, not just the
/// selection) at the edited breakpoint. For one-off reads in section logic;
/// fields use [SelectedNodes.read], which is much cheaper per field.
final propertyReadingProvider = Provider.autoDispose
    .family<PropertyReading, ReadKey>((ref, key) {
      final bp = ref.watch(
        editorControllerProvider.select((s) => s.breakpointId),
      );
      if (bp == null) return PropertyReading.none;
      final index = ref.watch(resolvedForProvider(bp)).resolved.nodeIndex;
      ir.IrValue? first;
      var mixed = false;
      var applicable = 0;
      var total = 0;
      for (final id in key.ids) {
        final n = index[id];
        if (n == null) continue;
        total++;
        final v = ir.resolvedPropertyValue(n, key.path);
        if (v == null) continue;
        applicable++;
        if (first == null) {
          first = v;
        } else if (v != first) {
          mixed = true;
        }
      }
      return PropertyReading(
        value: first,
        mixed: mixed,
        applicable: applicable,
        total: total,
      );
    }, dependencies: [editorControllerProvider, resolvedForProvider]);

// ---- Selection ---------------------------------------------------------------

/// The selected ids in selection order, compared by value.
@immutable
class IdList {
  IdList(Iterable<String> ids) : ids = List.unmodifiable(ids);

  final List<String> ids;

  bool get isEmpty => ids.isEmpty;
  int get length => ids.length;

  @override
  bool operator ==(Object other) =>
      other is IdList && listEquals(other.ids, ids);

  @override
  int get hashCode => Object.hashAll(ids);
}

/// The selection.
final selectionIdsProvider = Provider.autoDispose<IdList>(
  (ref) =>
      ref.watch(editorControllerProvider.select((s) => IdList(s.selection))),
  dependencies: [editorControllerProvider],
);

/// What the selection is, for deciding which sections and options apply.
/// Value-compared, so sections rebuild only when the answer changes.
@immutable
class SelectionInfo {
  const SelectionInfo({
    this.ids = const [],
    this.kinds = const {},
    this.frames = 0,
    this.autoLayoutFrames = 0,
    this.inAutoLayout = 0,
    this.absoluteInAutoLayout = 0,
    this.inFreeParent = 0,
    this.roots = 0,
    this.innerNodes = 0,
    this.geometries = const {},
    this.flowAutoLayoutRoots = 0,
    this.hasModes = false,
    this.inGrid = 0,
    this.isolated = false,
  });

  final List<String> ids;
  final Set<ir.NodeKind> kinds;

  /// Selected frames; of those, ones with auto layout.
  final int frames;
  final int autoLayoutFrames;

  /// Selected nodes whose parent has auto layout; of those, ones that
  /// ignore it (absolute).
  final int inAutoLayout;
  final int absoluteInAutoLayout;

  /// Selected nodes with a (non-auto-layout) frame parent: constraints
  /// apply to these and to [absoluteInAutoLayout] ones.
  final int inFreeParent;

  /// Scene roots, and nodes inside instances (geometry is not editable).
  final int roots;
  final int innerNodes;

  /// The geometry kinds of the selected shapes (`ellipse`, `star`, …).
  final Set<String> geometries;

  /// Selected roots of flow scenes that have auto layout (their height can
  /// hug).
  final int flowAutoLayoutRoots;

  /// Whether some token collection has more than one mode (the Modes
  /// section has something to pick).
  final bool hasModes;

  /// Selected nodes whose parent is a grid frame (§4.5).
  final int inGrid;

  /// Whether the editor is in component isolation mode (not the overlay's).
  final bool isolated;

  int get count => ids.length;
  bool get isEmpty => ids.isEmpty;
  bool get isSingle => ids.length == 1;
  bool get anyFrame => frames > 0;
  bool get anyAutoLayout => autoLayoutFrames > 0;
  bool get anyInAutoLayout => inAutoLayout > 0;

  /// Whether the in-flow sizing of children is meaningful for some node.
  bool get anyLayoutChild => inAutoLayout > absoluteInAutoLayout;

  /// Some node is placed by constraints.
  bool get anyConstrained => inFreeParent + absoluteInAutoLayout > 0;

  bool get hasAppearance => kinds.any(
    const {ir.NodeKind.frame, ir.NodeKind.shape, ir.NodeKind.video}.contains,
  );

  bool get hasStroke => hasAppearance || kinds.contains(ir.NodeKind.text);

  @override
  bool operator ==(Object other) =>
      other is SelectionInfo &&
      listEquals(other.ids, ids) &&
      setEquals(other.kinds, kinds) &&
      other.frames == frames &&
      other.autoLayoutFrames == autoLayoutFrames &&
      other.inAutoLayout == inAutoLayout &&
      other.absoluteInAutoLayout == absoluteInAutoLayout &&
      other.inFreeParent == inFreeParent &&
      other.roots == roots &&
      other.innerNodes == innerNodes &&
      setEquals(other.geometries, geometries) &&
      other.flowAutoLayoutRoots == flowAutoLayoutRoots &&
      other.hasModes == hasModes &&
      other.inGrid == inGrid &&
      other.isolated == isolated;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(ids),
    Object.hashAll(kinds),
    frames,
    autoLayoutFrames,
    inAutoLayout,
    absoluteInAutoLayout,
    inFreeParent,
    roots,
    innerNodes,
    Object.hashAll(geometries),
    flowAutoLayoutRoots,
    hasModes,
    inGrid,
    isolated,
  );
}

/// Classifies the selection at the edited breakpoint.
SelectionInfo classifySelection(
  ir.StageDocument doc,
  Map<String, ir.ResolvedNode> index,
  Iterable<String> selection,
) {
  final docIndex = ir.DocumentIndex.of(doc);
  final ids = <String>[];
  final kinds = <ir.NodeKind>{};
  var frames = 0, autoFrames = 0, inAuto = 0, absInAuto = 0, inFree = 0;
  var inGrid = 0;
  var roots = 0, inner = 0;
  final geometries = <String>{};
  var flowRoots = 0;
  for (final id in selection) {
    final rn = index[id];
    if (rn == null) continue;
    ids.add(id);
    final node = rn.node;
    // An instance's resolved node is its component root: classify by the
    // authored node, so an instance stays an instance.
    kinds.add(ir.nodeKindOf(docIndex.node(id) ?? node));
    if (node is ir.FrameNode) {
      frames++;
      if (node.autoLayout != null) autoFrames++;
    }
    if (node is ir.ShapeNode) {
      geometries.add(switch (node.geometry) {
        ir.RectangleGeometry() => 'rectangle',
        ir.EllipseGeometry() => 'ellipse',
        ir.LineGeometry() => 'line',
        ir.PolygonGeometry() => 'polygon',
        ir.StarGeometry() => 'star',
      });
    }
    if (id.contains('/')) {
      inner++;
      continue;
    }
    final loc = docIndex.locate(id);
    if (loc == null) continue;
    if (loc.isRoot) {
      roots++;
      final si = loc.sceneIndex;
      if (si != null &&
          doc.scenes[si].kind == ir.SceneKind.flow &&
          node is ir.FrameNode &&
          node.autoLayout != null) {
        flowRoots++;
      }
      continue;
    }
    final parent = index[loc.parentId!]?.node;
    if (parent is ir.FrameNode && parent.grid != null) {
      inGrid++;
    } else if (parent is ir.FrameNode && parent.autoLayout != null) {
      inAuto++;
      if (node.common.layoutChild.positioning == ir.Positioning.absolute) {
        absInAuto++;
      }
    } else if (parent is ir.FrameNode) {
      inFree++;
    }
  }
  return SelectionInfo(
    ids: ids,
    kinds: kinds,
    frames: frames,
    autoLayoutFrames: autoFrames,
    inAutoLayout: inAuto,
    absoluteInAutoLayout: absInAuto,
    inFreeParent: inFree,
    roots: roots,
    innerNodes: inner,
    geometries: geometries,
    flowAutoLayoutRoots: flowRoots,
    hasModes: doc.tokens.collections.any((c) => c.modes.length > 1),
    inGrid: inGrid,
    isolated:
        doc.scenes.length == 1 && doc.scenes.first.id == kIsolationSceneId,
  );
}

/// [classifySelection] for the live selection.
final selectionInfoProvider = Provider.autoDispose<SelectionInfo>(
  (ref) {
    final ids = ref.watch(selectionIdsProvider);
    final bp = ref.watch(
      editorControllerProvider.select((s) => s.breakpointId),
    );
    if (ids.isEmpty || bp == null) return const SelectionInfo();
    final art = ref.watch(resolvedForProvider(bp));
    return classifySelection(art.document, art.resolved.nodeIndex, ids.ids);
  },
  dependencies: [
    editorControllerProvider,
    resolvedForProvider,
    selectionIdsProvider,
  ],
);

// ---- Value sources -------------------------------------------------------------

/// Where a field's value comes from (architecture §15 "value-source badge").
enum ValueSourceKind {
  /// The node's own (shared) value: no badge.
  own,

  /// A breakpoint patch: the property is overridden for this breakpoint.
  breakpointOverride,

  /// An override on a component instance.
  instanceOverride,

  /// Inherited from a component (default, binding or placement).
  component,

  /// Bound to a token variable.
  token,

  /// Taken from a paint, effect or text style.
  style,

  /// Animated by a track: the value shown is the value at the playhead.
  animated,
}

/// How the value of one property was produced, summarised for the badge.
///
/// `resettable` is true when [ResetProperty] has a layer to remove.
@immutable
class ValueSource {
  const ValueSource(
    this.kind,
    this.description, {
    this.resettable = false,
    this.variableId,
    this.value,
  });

  static const ValueSource own = ValueSource(ValueSourceKind.own, '');

  final ValueSourceKind kind;

  /// "Mobile override", "Token: Brand/Primary", …; the tooltip text.
  final String description;
  final bool resettable;

  /// The variable the value is bound to (m3.md "Binding"), when a token
  /// produced it and no later layer replaced it; [value] is then the value
  /// shown, which detaching writes back as a literal.
  final String? variableId;
  final ir.IrValue? value;

  bool get isOverride =>
      kind == ValueSourceKind.breakpointOverride ||
      kind == ValueSourceKind.instanceOverride;

  @override
  bool operator ==(Object other) =>
      other is ValueSource &&
      other.kind == kind &&
      other.description == description &&
      other.resettable == resettable &&
      other.variableId == variableId &&
      other.value == value;

  @override
  int get hashCode =>
      Object.hash(kind, description, resettable, variableId, value);
}

/// Summarises [p] (an `explain` result) for [doc]: the topmost non-base layer
/// decides, overrides outranking everything else.
ValueSource summariseProvenance(ir.StageDocument doc, ir.Provenance p) {
  ValueSource? best;
  int rank(ValueSourceKind k) => switch (k) {
    ValueSourceKind.own => 0,
    ValueSourceKind.component => 1,
    ValueSourceKind.style => 2,
    ValueSourceKind.token => 3,
    ValueSourceKind.breakpointOverride => 4,
    ValueSourceKind.instanceOverride => 5,
    ValueSourceKind.animated => 6,
  };
  for (final e in p.entries) {
    final s = switch (e.source) {
      ir.BreakpointPatchSource(:final breakpointId) => ValueSource(
        ValueSourceKind.breakpointOverride,
        '${_bpName(doc, breakpointId)} override',
        resettable: true,
      ),
      ir.InstanceOverrideSource() => const ValueSource(
        ValueSourceKind.instanceOverride,
        'Instance override',
        resettable: true,
      ),
      ir.ComponentDefaultSource(:final componentId) => ValueSource(
        ValueSourceKind.component,
        'From component ${doc.components[componentId]?.name ?? componentId}',
      ),
      ir.ComponentBindingSource() => const ValueSource(
        ValueSourceKind.component,
        'Component property',
      ),
      ir.InstancePlacementSource() => const ValueSource(
        ValueSourceKind.component,
        'Placed by instance',
      ),
      ir.TokenSource(:final variableId) => ValueSource(
        ValueSourceKind.token,
        'Token: ${_variableName(doc, variableId)}',
      ),
      ir.PaintStyleSource(:final styleId) => ValueSource(
        ValueSourceKind.style,
        'Style: ${doc.tokens.paintStyles[styleId]?.name ?? styleId}',
      ),
      ir.EffectStyleSource(:final styleId) => ValueSource(
        ValueSourceKind.style,
        'Style: ${doc.tokens.effectStyles[styleId]?.name ?? styleId}',
      ),
      ir.TextStyleSource(:final styleId) => ValueSource(
        ValueSourceKind.style,
        'Text style: $styleId',
      ),
      ir.AnimatedSource() => const ValueSource(
        ValueSourceKind.animated,
        'Animated',
      ),
      _ => null,
    };
    if (s != null && (best == null || rank(s.kind) >= rank(best.kind))) {
      best = s;
    }
  }
  // The binding shows while a token is the last layer (bar animation).
  String? bound;
  for (final e in p.entries.reversed) {
    if (e.source is ir.AnimatedSource) continue;
    if (e.source case ir.TokenSource(:final variableId)) bound = variableId;
    break;
  }
  final b = best ?? ValueSource.own;
  if (bound == null) return b;
  return ValueSource(
    b.kind,
    b.description,
    resettable: b.resettable,
    variableId: bound,
    value: p.finalValue,
  );
}

String _bpName(ir.StageDocument doc, String id) {
  for (final b in doc.breakpoints) {
    if (b.id == id) return b.name;
  }
  return id;
}

String _variableName(ir.StageDocument doc, String variableId) {
  for (final c in doc.tokens.collections) {
    for (final v in c.variables) {
      if (v.id == variableId) return v.name;
    }
  }
  return variableId;
}

bool _overlaps(String key, String path) =>
    key == path || key.startsWith('$path.') || path.startsWith('$key.');

/// Whether [node] could have a source other than its own value for [path]
/// (a patch, binding or style on that path, or an instance's inner node),
/// so the comparatively costly explain is worth running. Most fields of most
/// nodes cost a few map-key comparisons.
bool _mayHaveSource(String id, ir.Node? node, String path) {
  if (id.contains('/')) return true;
  if (node == null) return false;
  final c = node.common;
  for (final MapEntry(key: bp, value: patch) in c.breakpointOverrides.entries) {
    for (final k in patch.keys) {
      // Measured sizes of auto-sized text are not overrides.
      if (!isShownOverrideKey(node, bp, k)) continue;
      if (_overlaps(k, path)) return true;
    }
  }
  for (final k in c.bindings.keys) {
    if (_overlaps(k, path)) return true;
  }
  for (final k in c.componentBindings.keys) {
    if (_overlaps(k, path)) return true;
  }
  return _hasStyleRef(node, path);
}

/// The value source of [path] across [nodes] at the edited breakpoint: the
/// strongest of the nodes' (an override outranks the rest).
ValueSource valueSourceOf(SelectedNodes nodes, String path) {
  final resolver = nodes.resolver;
  if (resolver == null) return ValueSource.own;
  final ctx = ir.ResolveContext(breakpointId: nodes.breakpointId);
  final propertyPath = ir.PropertyPath(path);
  ValueSource? best;
  for (var i = 0; i < nodes.ids.length; i++) {
    final id = nodes.ids[i];
    final animated = nodes.isAnimated(i, path);
    if (!animated && !_mayHaveSource(id, nodes.authored[i], path)) continue;
    final s = summariseProvenance(
      nodes.document,
      animated
          ? resolver.explainAt(
              nodes.document,
              id,
              propertyPath,
              nodes.clockValues,
              ctx,
            )
          : resolver.explain(nodes.document, id, propertyPath, ctx),
    );
    if (s.kind == ValueSourceKind.own) continue;
    if (best == null || s.isOverride && !best.isOverride) best = s;
  }
  return best ?? ValueSource.own;
}

bool _hasStyleRef(ir.Node n, String path) {
  final a = switch (n) {
    ir.FrameNode(:final appearance) ||
    ir.ShapeNode(:final appearance) ||
    ir.VideoNode(:final appearance) => appearance,
    _ => null,
  };
  if (a == null) return false;
  if (path == 'fills' || path.startsWith('fills.')) {
    return a.fillStyleId != null;
  }
  if (path.startsWith('strokes.')) return a.strokeStyleId != null;
  if (path == 'effects' || path.startsWith('effects.')) {
    return a.effectStyleId != null;
  }
  return false;
}

// ---- Section collapse state ------------------------------------------------------

/// Which inspector sections are collapsed, by section id: remembered for
/// the editor session across selections.
final collapsedSectionsProvider =
    NotifierProvider<CollapsedSections, Set<String>>(CollapsedSections.new);

class CollapsedSections extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool isCollapsed(String id) => state.contains(id);

  void set(String id, {required bool collapsed}) {
    if (state.contains(id) == collapsed) return;
    state = collapsed ? {...state, id} : ({...state}..remove(id));
  }
}
