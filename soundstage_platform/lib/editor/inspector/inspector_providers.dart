import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';

// What the inspector reads. Every field subscribes to exactly one
// [propertyReadingProvider] (and, for its badge, one
// [valueSourceProvider]), both value-compared, so an edit rebuilds only the
// fields whose own value changed.

const String _sep = '\u0001';

/// A property of a set of nodes: the key of the per-field providers.
/// Compared by value, so equal keys share a provider.
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

/// Reads [path] of [ids] from a resolved [index] (namespaced id → node).
PropertyReading readProperty(
  Map<String, ir.ResolvedNode> index,
  Iterable<String> ids,
  String path,
) {
  ir.IrValue? first;
  var mixed = false;
  var applicable = 0;
  var total = 0;
  for (final id in ids) {
    final n = index[id];
    if (n == null) continue;
    total++;
    final v = ir.resolvedPropertyValue(n, path);
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
}

/// [ReadKey.path] of [ReadKey.ids] at the edited breakpoint.
final propertyReadingProvider = Provider.autoDispose
    .family<PropertyReading, ReadKey>((ref, key) {
      final bp = ref.watch(
        editorControllerProvider.select((s) => s.breakpointId),
      );
      if (bp == null) return PropertyReading.none;
      final art = ref.watch(resolvedForProvider(bp));
      return readProperty(art.resolved.nodeIndex, key.ids, key.path);
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
      other.innerNodes == innerNodes;

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
  var roots = 0, inner = 0;
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
    if (id.contains('/')) {
      inner++;
      continue;
    }
    final loc = docIndex.locate(id);
    if (loc == null) continue;
    if (loc.isRoot) {
      roots++;
      continue;
    }
    final parent = index[loc.parentId!]?.node;
    if (parent is ir.FrameNode && parent.autoLayout != null) {
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
}

/// How the value of one property was produced, summarised for the badge.
///
/// `resettable` is true when [ResetProperty] has a layer to remove.
@immutable
class ValueSource {
  const ValueSource(this.kind, this.description, {this.resettable = false});

  static const ValueSource own = ValueSource(ValueSourceKind.own, '');

  final ValueSourceKind kind;

  /// "Mobile override", "Token: Brand/Primary", …; the tooltip text.
  final String description;
  final bool resettable;

  bool get isOverride =>
      kind == ValueSourceKind.breakpointOverride ||
      kind == ValueSourceKind.instanceOverride;

  @override
  bool operator ==(Object other) =>
      other is ValueSource &&
      other.kind == kind &&
      other.description == description &&
      other.resettable == resettable;

  @override
  int get hashCode => Object.hash(kind, description, resettable);
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
      _ => null,
    };
    if (s != null && (best == null || rank(s.kind) >= rank(best.kind))) {
      best = s;
    }
  }
  return best ?? ValueSource.own;
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

/// Whether [node] could have a source other than its own value, so the
/// (comparatively costly) explain is worth running.
bool _mayHaveSource(String id, ir.Node? node) {
  if (id.contains('/')) return true;
  if (node == null) return false;
  final c = node.common;
  return c.breakpointOverrides.isNotEmpty ||
      c.bindings.isNotEmpty ||
      c.componentBindings.isNotEmpty;
}

/// The value source of [ReadKey.path] across [ReadKey.ids] at the edited
/// breakpoint: the strongest of the nodes'. Most nodes (no patches,
/// bindings or instance) cost one map lookup.
final valueSourceProvider = Provider.autoDispose.family<ValueSource, ReadKey>((
  ref,
  key,
) {
  final doc = ref.watch(
    editorControllerProvider.select((s) => Identity(s.document)),
  );
  // Sources differ per breakpoint (a patch is a source only there).
  ref.watch(editorControllerProvider.select((s) => s.breakpointId));
  final ctl = ref.read(editorControllerProvider.notifier);
  final docIndex = ir.DocumentIndex.of(doc.value);
  ValueSource? best;
  for (final id in key.ids) {
    final node = docIndex.node(id.split('/').first);
    final styled = node != null && _hasStyleRef(node, key.path);
    if (!_mayHaveSource(id, node) && !styled) continue;
    final s = summariseProvenance(doc.value, ctl.provenanceFor(id, key.path));
    if (s.kind == ValueSourceKind.own) continue;
    if (best == null || s.isOverride && !best.isOverride) best = s;
  }
  return best ?? ValueSource.own;
}, dependencies: [editorControllerProvider]);

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
