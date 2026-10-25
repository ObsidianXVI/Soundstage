import 'dart:collection';

import '../animation/track_eval.dart';
import '../breakpoint.dart';
import '../components.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../edit/document_index.dart';
import '../motion.dart';
import '../nodes/appearance.dart';
import '../nodes/effect.dart';
import '../nodes/node.dart';
import '../nodes/node_common.dart';
import '../nodes/paint.dart';
import '../nodes/text.dart';
import '../registry/patch.dart';
import '../registry/property_registry.dart';
import '../scene.dart';
import '../tokens.dart';
import '../values/ir_value.dart';
import '../values/property_path.dart';
import 'breakpoints.dart';
import 'provenance.dart';
import 'resolved_tree.dart';

/// Resolves [doc] for [context] with the standard registry.
ResolvedDocument resolveDocument(
  StageDocument doc, [
  ResolveContext context = const ResolveContext(),
]) => Resolver().resolve(doc, context);

/// Resolves documents (architecture §11.3 steps 2–5).
///
/// Resolution is a composition of per-node steps — breakpoint patches,
/// component prop bindings, instance placement and overrides, instance
/// expansion, modes, token bindings, styles — each a function of the node
/// and an immutable scope (namespace, active modes, the enclosing instance's
/// props and overrides). Nothing is threaded through the pass except the
/// diagnostic sink, so per-node memoisation keyed by the identity of those
/// inputs (architecture §17.1) can be added without restructuring. Caches
/// compare with `identical`, never with freezed's deep `==`.
///
/// Never throws on a broken document: problems become
/// `ResolvedDocument.diagnostics`, and output is deterministic for the same
/// inputs.
///
/// **Incremental resolution.** A long-lived `Resolver` remembers the previous
/// pass. A scene-level subtree whose root node is the *same object*
/// (`identical`) as in the previous pass, resolved under equal modes, is not
/// resolved again: its `ResolvedNode` (and diagnostics) are reused, so
/// unchanged subtrees keep their output identity. Edits that copy only the
/// path from the root to the changed node (structural sharing) therefore
/// re-resolve only that path. Memoised results are valid while the shared
/// inputs are unchanged (the document's tokens, assets, components, variant
/// sets, default text style, breakpoints, and the `ResolveContext`); when any
/// of those changes the memo is dropped and the next pass is a full one.
/// Results are attached to the authored nodes (and tracks) themselves, by
/// identity and weakly (an `Expando`): a subtree reused for many passes stays
/// memoised even when a pass hit at an ancestor and never visited it (a
/// motion-only edit keeps the scene root), and results go away with their
/// nodes, so memory stays proportional to the documents still alive (the
/// current one and the undo history's edited paths). At most
/// [_Memo.maxModeEntries] mode variants are kept per node. Not thread-safe;
/// use one `Resolver` per owner.
class Resolver {
  Resolver({PropertyRegistry? registry})
    : registry = registry ?? PropertyRegistry.standard;

  final PropertyRegistry registry;

  final _Memo _memo = _Memo();

  ResolvedDocument resolve(
    StageDocument doc, [
    ResolveContext context = const ResolveContext(),
  ]) {
    _memo.prepare(doc, context);
    final pass = _Pass(doc, context, registry, _memo);
    final out = pass.run();
    return out;
  }

  /// How property [path] of node [nodeId] gets its value when [doc] is
  /// resolved for [context]: every contributing layer in pipeline order
  /// (base or component default → breakpoint patches along the chain →
  /// component bindings → instance placement → instance overrides → tokens
  /// → styles), each with the value it produced, and the final value. See
  /// [Provenance].
  ///
  /// With [clockValues] (clock id → value; absent clocks at 0, the editor's
  /// playheads), the tracks that animate the property at this breakpoint
  /// add `animated` entries on top, valued at those clock values, and the
  /// final value is the animated one (m2.md: the inspector shows the value
  /// at the playhead). Without it, tracks are ignored, as in the resolved
  /// document (animation is pipeline step 6, after resolution).
  ///
  /// [nodeId] is a resolved id: a scene or overlay node, or
  /// `<instanceId>/<innerId>[/…]` inside instances. Only the path to the
  /// node is resolved afresh; when [doc] and [context] match this
  /// resolver's last pass, everything else is reused from the memo (and
  /// subtrees it had to resolve are added to it; the traced path is not). Never throws: an unknown node gives no
  /// entries, a null `finalValue` and a `missingNode` diagnostic.
  Provenance explain(
    StageDocument doc,
    String nodeId,
    PropertyPath path, [
    ResolveContext context = const ResolveContext(),
  ]) => _explain(doc, nodeId, path, context, null);

  /// [explain] with the `animated` layer at [clockValues] (see [explain]).
  Provenance explainAt(
    StageDocument doc,
    String nodeId,
    PropertyPath path,
    Map<String, double> clockValues, [
    ResolveContext context = const ResolveContext(),
  ]) => _explain(doc, nodeId, path, context, clockValues);

  Provenance _explain(
    StageDocument doc,
    String nodeId,
    PropertyPath path,
    ResolveContext context,
    Map<String, double>? clockValues,
  ) {
    final p = path.value;
    Provenance missing() => Provenance(
      nodeId: nodeId,
      path: p,
      entries: const [],
      diagnostics: [
        IrDiagnostic(
          IrDiagnosticKind.missingNode,
          'Node "$nodeId" does not exist.',
          nodeId: nodeId,
          path: p,
        ),
      ],
    );
    final slash = nodeId.indexOf('/');
    final head = slash < 0 ? nodeId : nodeId.substring(0, slash);
    final index = DocumentIndex.of(doc);
    final loc = index.locate(head);
    if (loc == null) return missing();
    final bypass = LinkedHashSet<Node>.identity();
    Node n = index.rootOf(loc);
    bypass.add(n);
    for (final i in loc.childPath) {
      n = (n as FrameNode).children[i];
      bypass.add(n);
    }
    final tracer = _Tracer(nodeId, p, registry, bypass);
    final pass = _Pass(
      doc,
      context,
      registry,
      _memo.isValidFor(doc, context) ? _memo : _Memo(),
      tracer,
    );
    final scene = pass.explainRun(loc.sceneIndex);
    final resolved = tracer.resolved;
    if (resolved == null) return missing();
    IrValue? finalValue;
    List<ProvenanceEntry> entries;
    if (tracer.textEntries case final te?) {
      entries = te;
      finalValue = tracer.textFinal;
    } else {
      entries = tracer.entries;
      finalValue = _styleRefPaths.contains(p)
          ? (entries.isEmpty ? null : entries.last.value)
          : resolvedPropertyValue(resolved, p, registry: registry);
    }
    if (clockValues != null && scene != null && finalValue != null) {
      final animated = _animatedEntries(scene, resolved, p, clockValues);
      if (animated.isNotEmpty) {
        entries = [...entries, ...animated];
        finalValue = animated.last.value;
      }
    }
    return Provenance(
      nodeId: nodeId,
      path: p,
      entries: List.unmodifiable(entries),
      finalValue: finalValue,
      diagnostics: List.unmodifiable(
        pass.diagnostics.where((d) => d.nodeId == nodeId),
      ),
    );
  }
}

extension on Resolver {
  /// The `animated` layer of [path] on [node] in [scene] at [clocks]: one
  /// entry per track of the scene (already filtered for the breakpoint, with
  /// breakpoint-specific tracks winning) that animates [path], a path under
  /// it, or a path containing it. Text style paths are only matched
  /// exactly (their value is the merged cascade).
  List<ProvenanceEntry> _animatedEntries(
    ResolvedScene scene,
    ResolvedNode node,
    String path,
    Map<String, double> clocks,
  ) {
    final out = <ProvenanceEntry>[];
    var animated = node.node;
    final textPath = path.startsWith('style.') || path.startsWith('content.');
    for (final t in scene.tracks) {
      if (t.target != node.id) continue;
      final prop = t.property;
      final exact = prop == path;
      if (!exact &&
          (textPath ||
              !(prop.startsWith('$path.') || path.startsWith('$prop.')))) {
        continue;
      }
      final v = evaluateTrack(t, clocks[t.clockId] ?? 0, registry: registry);
      if (v == null) continue;
      IrValue? value = v;
      if (!exact) {
        final match = registry.lookup(prop);
        final next = match?.trySet(animated, v);
        if (next == null) continue;
        animated = next;
        value = registry.get(animated, path);
        if (value == null) continue;
      }
      out.add(
        ProvenanceEntry(
          source: ProvenanceSource.animated(t.id),
          value: value,
          nodeId: t.target.split('/').last,
          keys: [prop],
        ),
      );
    }
    return out;
  }
}

const Set<String> _styleRefPaths = {
  'textStyleId',
  'fillStyleId',
  'strokeStyleId',
  'effectStyleId',
};

final RegExp _spanStylePath = RegExp(
  r'^content\.(\d+)\.spans\.(\d+)\.style\.(.+)$',
);

/// Property [path] of a resolved node, as the inspector and `explain` see
/// it: through the registry, except that text style paths read the merged
/// cascade (`style.*` from [ResolvedNode.textStyle], span style paths
/// `content.<p>.spans.<s>.style.*` from the span's merged style), since
/// the resolved node's own style overrides are emptied. Null when the
/// property does not exist on the node.
IrValue? resolvedPropertyValue(
  ResolvedNode node,
  String path, {
  PropertyRegistry? registry,
}) {
  final reg = registry ?? PropertyRegistry.standard;
  final n = node.node;
  if (n is TextNode) {
    if (path.startsWith('style.')) {
      final s = node.textStyle;
      if (s != null) return reg.get(_styleCarrier(s), path);
    }
    final m = _spanStylePath.firstMatch(path);
    final paras = node.paragraphs;
    if (m != null && paras != null) {
      final pi = int.parse(m.group(1)!), si = int.parse(m.group(2)!);
      if (pi >= paras.length || si >= paras[pi].spans.length) return null;
      return reg.get(
        _styleCarrier(paras[pi].spans[si].style),
        'style.${m.group(3)}',
      );
    }
  }
  return reg.get(n, path);
}

/// A text node whose override holds every field of [s], for registry
/// reads of merged styles.
TextNode _styleCarrier(TextStyle s) => TextNode(
  common: const NodeCommon(id: ''),
  style: _fullOverride(s),
);

TextStyleOverride _fullOverride(TextStyle s) => TextStyleOverride(
  fontFamilyId: s.fontFamilyId,
  fontWeight: s.fontWeight,
  italic: s.italic,
  fontVariations: s.fontVariations,
  fontSize: s.fontSize,
  lineHeight: s.lineHeight,
  letterSpacing: s.letterSpacing,
  paragraphSpacing: s.paragraphSpacing,
  paragraphIndent: s.paragraphIndent,
  textCase: s.textCase,
  decoration: s.decoration,
  fills: s.fills,
  openType: s.openType,
  baselineShift: s.baselineShift,
  listStyle: s.listStyle,
);

bool _overlaps(String a, String b) =>
    a == b || a.startsWith('$b.') || b.startsWith('$a.');

/// Records the provenance of one property of one node during a traced pass
/// (`Resolver.explain`). Only the target node's steps record anything.
class _Tracer {
  _Tracer(this.targetId, this.path, this.registry, this.bypass) {
    final m = _spanStylePath.firstMatch(path);
    if (m != null) {
      spanParagraph = int.parse(m.group(1)!);
      spanIndex = int.parse(m.group(2)!);
      styleField = m.group(3);
      nodeStylePath = 'style.$styleField';
    } else if (path.startsWith('style.')) {
      styleField = path.substring(6);
      nodeStylePath = path;
    }
  }

  final String targetId;
  final String path;
  final PropertyRegistry registry;

  /// Scene-level nodes on the path to the target: never served from the
  /// memo, so their steps run (and record).
  final Set<Node> bypass;

  /// Text style paths: the style field (`fontSize`, `fills.p.color`).
  String? styleField;

  /// `style.<field>`: the node-level override path of a text style path.
  String? nodeStylePath;
  int? spanParagraph;
  int? spanIndex;

  List<ProvenanceEntry> entries = [];

  /// Node-level override layers of a span style path.
  List<ProvenanceEntry> nodeStyleEntries = [];
  final Map<String, IrValue?> _last = {};

  /// The instance node's own chain, held until its placement.
  List<ProvenanceEntry>? _instanceChain;
  InstanceNode? _instance;

  ResolvedNode? resolved;

  /// The composed chain and final value of a text style path.
  List<ProvenanceEntry>? textEntries;
  IrValue? textFinal;

  bool get _styleRef => _styleRefPaths.contains(path);

  /// Records [source] if the step on [id] overlapped the path (one of
  /// [keys]) or changed its value, or [always] (base values).
  void step(
    String id,
    Node n,
    ProvenanceSource source, {
    required String nodeId,
    Iterable<String> keys = const [],
    bool always = false,
  }) {
    if (id != targetId) return;
    _record(path, entries, n, source, nodeId, keys, always);
    final ns = nodeStylePath;
    if (ns != null && ns != path) {
      _record(ns, nodeStyleEntries, n, source, nodeId, keys, always);
    }
  }

  void _record(
    String w,
    List<ProvenanceEntry> out,
    Node n,
    ProvenanceSource source,
    String nodeId,
    Iterable<String> keys,
    bool always,
  ) {
    final v = registry.get(n, w);
    final touched = [
      for (final k in keys)
        if (_overlaps(k, w)) k,
    ];
    final changed = !_last.containsKey(w) || _last[w] != v;
    _last[w] = v;
    if (v == null) return;
    if (always || touched.isNotEmpty || changed) {
      out.add(
        ProvenanceEntry(
          source: source,
          value: v,
          nodeId: nodeId,
          keys: touched,
        ),
      );
    }
  }

  /// The target is an instance about to be expanded: its chain so far is
  /// held back until the component root is placed.
  void enterInstance(String id, InstanceNode inst) {
    if (id != targetId) return;
    _instanceChain = entries;
    _instance = inst;
    entries = [];
    nodeStyleEntries = [];
    _last.clear();
  }

  /// The component root of the target instance was placed.
  void placed(String id, Node n, String instanceId, String rootId) {
    if (id != targetId) return;
    final chain = _instanceChain, inst = _instance;
    _instanceChain = null;
    _instance = null;
    if (chain != null &&
        inst != null &&
        _placedPath(path, inst) &&
        chain.isNotEmpty) {
      entries.addAll(chain);
      _last[path] = chain.last.value;
    }
    step(
      id,
      n,
      ProvenanceSource.instancePlacement(instanceId),
      nodeId: inst?.id ?? instanceId,
    );
  }

  /// Whether `_place` takes [p] from [inst].
  static bool _placedPath(String p, InstanceNode inst) {
    final c = inst.common;
    return switch (p) {
      'visible' ||
      'locked' ||
      'opacity' ||
      'x' ||
      'y' ||
      'width' ||
      'height' ||
      'rotation' ||
      'flipX' ||
      'flipY' ||
      'mask' => true,
      'name' => c.name.isNotEmpty,
      'blendMode' => c.blendMode != null,
      'role' => c.role != NodeRole.none,
      'readingOrder' => c.readingOrder != null,
      'altText' => c.altText != null,
      _ => p.startsWith('motion.') || p.startsWith('layoutChild.'),
    };
  }

  /// Records paint and effect styles applied to the target.
  void styles(String id, Node before, Node after, StageDocument doc) {
    if (id != targetId || _styleRef) return;
    final (fill, stroke, effect) = switch (before) {
      FrameNode(:final appearance) ||
      ShapeNode(:final appearance) ||
      VideoNode(:final appearance) => (
        appearance.fillStyleId,
        appearance.strokeStyleId,
        appearance.effectStyleId,
      ),
      TextNode(:final appearance) => (
        null,
        appearance.strokeStyleId,
        appearance.effectStyleId,
      ),
      _ => (null, null, null),
    };
    final tokens = doc.tokens;
    if (fill != null && tokens.paintStyles.containsKey(fill)) {
      step(
        id,
        after,
        ProvenanceSource.paintStyle(fill),
        nodeId: before.id,
        keys: const ['fills'],
      );
    }
    if (stroke != null && tokens.paintStyles.containsKey(stroke)) {
      step(
        id,
        after,
        ProvenanceSource.paintStyle(stroke),
        nodeId: before.id,
        keys: const ['strokes.paints'],
      );
    }
    if (effect != null && tokens.effectStyles.containsKey(effect)) {
      step(
        id,
        after,
        ProvenanceSource.effectStyle(effect),
        nodeId: before.id,
        keys: const ['effects'],
      );
    }
  }

  /// Composes the chain of a text style path for the target text node:
  /// document default → named style (and its tokens) → the node's override
  /// layers → paragraph style → the span's override layers.
  void text(
    String id,
    TextNode n,
    TextStyle defaultStyle,
    TextStyleDef? named,
    TextStyle namedMerged,
    TextStyle merged,
    List<ResolvedParagraph> paragraphs,
    String? Function(String variableId) modeOf,
  ) {
    final field = styleField;
    if (id != targetId || field == null) return;
    final w = 'style.$field';
    IrValue? read(TextStyle s) => registry.get(_styleCarrier(s), w);
    final out = <ProvenanceEntry>[];
    void add(ProvenanceSource src, IrValue? v, {List<String> keys = const []}) {
      if (v != null && v is! NoneValue) {
        out.add(
          ProvenanceEntry(source: src, value: v, nodeId: n.id, keys: keys),
        );
      }
    }

    add(const ProvenanceSource.documentDefault(), read(defaultStyle));
    if (named != null && n.textStyleId != null) {
      final own = registry.get(
        TextNode(common: n.common, style: named.style),
        w,
      );
      final bound = [
        for (final k in named.bindings.keys)
          if (_overlaps(k, field)) k,
      ];
      final v = read(namedMerged);
      if ((own != null && own is! NoneValue) || bound.isNotEmpty) {
        add(ProvenanceSource.textStyle(n.textStyleId!), v);
        for (final k in bound) {
          final ref = named.bindings[k]!;
          add(
            ProvenanceSource.token(ref.variableId, modeOf(ref.variableId)),
            v,
            keys: [k],
          );
        }
      }
    }
    final span = spanParagraph != null;
    for (final e in span ? nodeStyleEntries : entries) {
      if (e.value is! NoneValue) out.add(e);
    }
    if (span) {
      final pi = spanParagraph!, si = spanIndex!;
      if (pi < n.content.length && pi < paragraphs.length) {
        final ps = n.content[pi].style;
        final pv = switch (field) {
          'paragraphSpacing' => ps?.paragraphSpacing,
          'paragraphIndent' => ps?.paragraphIndent,
          _ => null,
        };
        if (pv != null) {
          add(ProvenanceSource.paragraphStyle(pi), IrValue.number(pv));
        } else if (field == 'listStyle' && ps?.listStyle != null) {
          add(
            ProvenanceSource.paragraphStyle(pi),
            IrValue.enumValue(ps!.listStyle!.name),
          );
        }
        for (final e in entries) {
          if (e.value is! NoneValue) out.add(e);
        }
        textFinal = si < paragraphs[pi].spans.length
            ? read(paragraphs[pi].spans[si].style)
            : null;
      } else {
        textFinal = null;
      }
    } else {
      textFinal = read(merged);
    }
    textEntries = out;
  }
}

/// One memoised scene-level subtree.
class _MemoEntry {
  const _MemoEntry(this.modes, this.result, this.diagnostics);

  /// The (input) modes the subtree was resolved under.
  final Map<String, String> modes;
  final ResolvedNode result;

  /// Diagnostics the subtree produced, replayed on reuse.
  final List<IrDiagnostic> diagnostics;
}

/// A resolved track and the resolved target it was checked against. The
/// resolved track keeps its identity across passes while the source track
/// and its target do, so the runtime recompiles only edited tracks.
class _TrackMemo {
  const _TrackMemo(this.target, this.result);

  final ResolvedNode target;
  final Track result;
}

/// The memoised results of a [Resolver] and the inputs they are valid for.
class _Memo {
  StageDocument? _doc;
  ResolveContext? _ctx;

  /// Memoised subtrees by authored node (identity, weak).
  Expando<List<_MemoEntry>> nodes = Expando<List<_MemoEntry>>('resolved');

  /// Resolved tracks by source track (identity, weak).
  Expando<_TrackMemo> tracks = Expando<_TrackMemo>('resolvedTrack');

  /// The last document node index and the resolved roots it was built from.
  Map<String, ResolvedNode>? nodeIndex;
  List<ResolvedNode> indexRoots = const [];

  /// Mode variants kept per node (oldest dropped first).
  static const int maxModeEntries = 4;

  /// Whether the memo is valid for [doc] and [ctx] (see [prepare]).
  bool isValidFor(StageDocument doc, ResolveContext ctx) {
    final d = _doc;
    return d != null &&
        identical(d.tokens, doc.tokens) &&
        identical(d.defaultTextStyle, doc.defaultTextStyle) &&
        d.breakpoints == doc.breakpoints &&
        d.assets == doc.assets &&
        d.variantSets == doc.variantSets &&
        d.components == doc.components &&
        _ctx == ctx;
  }

  /// Drops the memo unless the shared inputs are unchanged.
  void prepare(StageDocument doc, ResolveContext ctx) {
    // freezed collection getters return fresh read-only views, so `identical`
    // never holds for them; `==` is cheap here because freezed values
    // short-circuit on identity and these inputs are small or unchanged.
    if (!isValidFor(doc, ctx)) {
      nodes = Expando<List<_MemoEntry>>('resolved');
      tracks = Expando<_TrackMemo>('resolvedTrack');
      nodeIndex = null;
      indexRoots = const [];
    }
    _doc = doc;
    _ctx = ctx;
  }

  static bool sameModes(Map<String, String> a, Map<String, String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}

/// The enclosing instance of the nodes being resolved.
class _InstanceFrame {
  const _InstanceFrame({
    required this.instanceId,
    required this.component,
    required this.props,
    required this.overrides,
    required this.componentStack,
  });

  /// Namespaced id of the instance (= id of the component root).
  final String instanceId;
  final ComponentDef component;

  /// Effective prop values: the instance's, else the prop defaults.
  final Map<String, IrValue> props;

  /// Override patches by inner path (relative to this instance), in
  /// application order (the instance's own first, then enclosing
  /// instances'), each with the namespaced id of the instance holding it and
  /// its inner path there.
  final Map<String, List<_Override>> overrides;

  /// Components being expanded, outermost first (cycle detection).
  final List<String> componentStack;
}

/// An instance override patch and where it is authored.
typedef _Override = ({String instanceId, String innerPath, Patch patch});

/// Immutable per-subtree context.
class _Scope {
  const _Scope({required this.prefix, required this.modes, this.instance});

  /// Prepended to node ids: '' at scene level, `<instanceId>/` inside one.
  final String prefix;

  /// Active mode per collection, state applied. Shared by identity down the
  /// tree until a frame overrides a mode.
  final Map<String, String> modes;
  final _InstanceFrame? instance;

  _Scope withModes(Map<String, String> m) => identical(m, modes)
      ? this
      : _Scope(prefix: prefix, modes: m, instance: instance);
}

class _VarEntry {
  const _VarEntry(this.variable, this.collection);
  final Variable variable;
  final VariableCollection collection;
}

/// A token lookup result: a value, or the problem to report at each use.
class _TokenResult {
  const _TokenResult.value(IrValue this.value) : kind = null, message = null;
  const _TokenResult.error(IrDiagnosticKind this.kind, String this.message)
    : value = null;

  final IrValue? value;
  final IrDiagnosticKind? kind;
  final String? message;
}

/// One resolution of one document for one context.
class _Pass {
  _Pass(this.doc, this.ctx, this.registry, this.memo, [this.trace]);

  /// Set for `Resolver.explain`.
  final _Tracer? trace;

  final StageDocument doc;
  final ResolveContext ctx;
  final PropertyRegistry registry;
  final List<IrDiagnostic> diagnostics = [];

  final _Memo memo;

  late final Breakpoint? breakpoint = _pickBreakpoint();

  /// The breakpoints whose patches apply, root first (§3.1).
  late final List<Breakpoint> cascade = _chain();

  List<Breakpoint> _chain() {
    final bp = breakpoint;
    if (bp == null) return const [];
    final r = breakpointChain(doc.breakpoints, bp.id);
    switch (r.problem) {
      case BreakpointChainProblem.unknownParent:
        _diag(
          IrDiagnosticKind.missingBreakpoint,
          'Breakpoint "${bp.id}" inherits from "${r.problemId}", which does '
          'not exist; its chain stops there.',
          path: r.problemId,
        );
      case BreakpointChainProblem.cycle:
        _diag(
          IrDiagnosticKind.breakpointCycle,
          'The inheritsFrom chain of breakpoint "${bp.id}" loops at '
          '"${r.problemId}"; its chain stops there.',
          path: r.problemId,
        );
      case null:
        break;
    }
    return r.chain;
  }

  late final Map<String, VariableCollection> collections = {
    for (final c in doc.tokens.collections) c.id: c,
  };
  late final Map<String, _VarEntry> variables = {
    for (final c in doc.tokens.collections)
      for (final v in c.variables) v.id: _VarEntry(v, c),
  };

  /// Token results per modes map (by identity) per variable id.
  final Map<Map<String, String>, Map<String, _TokenResult>> _tokenCache =
      LinkedHashMap.identity();

  void _diag(
    IrDiagnosticKind kind,
    String message, {
    String? nodeId,
    String? path,
  }) =>
      diagnostics.add(IrDiagnostic(kind, message, nodeId: nodeId, path: path));

  // ---- Document ----------------------------------------------------------------

  ResolvedDocument run() {
    final baseModes = _baseModes();
    final scenes = [for (final s in doc.scenes) _resolveScene(s, baseModes)];
    final overlay = doc.overlay == null
        ? null
        : _resolveNode(doc.overlay!, _Scope(prefix: '', modes: baseModes));
    // The document index is rebuilt only when a root changed (a motion-only
    // edit keeps every resolved root).
    final roots = [for (final s in scenes) s.root, ?overlay];
    var index = memo.nodeIndex;
    final last = memo.indexRoots;
    var same = index != null && last.length == roots.length;
    for (var i = 0; same && i < roots.length; i++) {
      same = identical(last[i], roots[i]);
    }
    if (!same || index == null) {
      index = <String, ResolvedNode>{};
      for (final r in roots) {
        _index(r, index);
      }
      memo
        ..nodeIndex = index
        ..indexRoots = roots;
    }
    return ResolvedDocument(
      breakpoint: breakpoint,
      scenes: scenes,
      overlay: overlay,
      nodeIndex: index,
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  /// Resolves only the tree holding the traced node: scene [sceneIndex], or
  /// the overlay when null.
  /// Returns the resolved scene (null for the overlay).
  ResolvedScene? explainRun(int? sceneIndex) {
    final baseModes = _baseModes();
    if (sceneIndex == null) {
      _resolveNode(doc.overlay!, _Scope(prefix: '', modes: baseModes));
      return null;
    }
    return _resolveScene(doc.scenes[sceneIndex], baseModes);
  }

  /// The active mode of [variableId]'s collection under [modes].
  String? _modeOf(String variableId, Map<String, String> modes) {
    final e = variables[variableId];
    if (e == null) return null;
    return modes[e.collection.id] ?? e.collection.defaultModeId;
  }

  Breakpoint? _pickBreakpoint() {
    final bps = doc.breakpoints;
    if (bps.isEmpty) return null;
    final wanted = ctx.breakpointId;
    if (wanted != null) {
      for (final b in bps) {
        if (b.id == wanted) return b;
      }
      _diag(
        IrDiagnosticKind.missingBreakpoint,
        'Breakpoint "$wanted" does not exist; using the viewport width or base.',
        path: wanted,
      );
    }
    final width = ctx.viewportWidth;
    if (width != null) return activeBreakpoint(bps, width);
    // Neither given: the first primary breakpoint, else the first one.
    for (final b in bps) {
      if (b.primary) return b;
    }
    return bps.first;
  }

  /// Node indexes of resolved scene roots (a reused root reuses its index).
  static final Expando<Map<String, ResolvedNode>> _sceneIndexes =
      Expando<Map<String, ResolvedNode>>('sceneIndex');

  static Map<String, ResolvedNode> _indexOf(ResolvedNode root) {
    final out = <String, ResolvedNode>{};
    _index(root, out);
    return out;
  }

  static void _index(ResolvedNode n, Map<String, ResolvedNode> out) {
    out[n.id] = n;
    for (final c in n.children) {
      _index(c, out);
    }
  }

  // ---- Modes (§8) --------------------------------------------------------------

  /// Collection default → `breakpointModes` → state.
  Map<String, String> _baseModes() {
    final m = <String, String>{};
    for (final c in doc.tokens.collections) {
      final bpMode = breakpoint == null
          ? null
          : c.breakpointModes[breakpoint!.id];
      if (bpMode != null && c.modes.any((x) => x.id == bpMode)) {
        m[c.id] = bpMode;
      } else {
        if (bpMode != null) {
          _diag(
            IrDiagnosticKind.missingMode,
            'Collection "${c.id}" has no mode "$bpMode" (breakpointModes).',
            path: '${c.id}/$bpMode',
          );
        }
        m[c.id] = c.defaultModeId;
      }
    }
    return _withOverrides(m, ctx.modeState, null);
  }

  /// [modes] with the valid entries of [overrides] applied, then state on
  /// top again (state has the highest priority at every level). Returns
  /// [modes] itself when nothing changes, so identity-keyed caches keep
  /// hitting.
  Map<String, String> _withOverrides(
    Map<String, String> modes,
    Map<String, String> overrides,
    String? nodeId,
  ) {
    if (overrides.isEmpty) return modes;
    Map<String, String>? out;
    bool valid(String col, String mode) =>
        collections[col]?.modes.any((x) => x.id == mode) ?? false;
    overrides.forEach((col, mode) {
      if (!valid(col, mode)) {
        _diag(
          IrDiagnosticKind.missingMode,
          'Mode "$mode" of collection "$col" does not exist.',
          nodeId: nodeId,
          path: '$col/$mode',
        );
        return;
      }
      if ((out ?? modes)[col] != mode) (out ??= Map.of(modes))[col] = mode;
    });
    if (out == null) return modes;
    ctx.modeState.forEach((col, mode) {
      if (valid(col, mode)) out![col] = mode;
    });
    return Map.unmodifiable(out!);
  }

  // ---- Tokens (§8) -------------------------------------------------------------

  /// The concrete value of [variableId] under [modes], following aliases.
  _TokenResult _token(String variableId, Map<String, String> modes) {
    final perModes = _tokenCache.putIfAbsent(modes, () => {});
    final hit = perModes[variableId];
    if (hit != null) return hit;
    final result = _lookupToken(variableId, modes);
    perModes[variableId] = result;
    return result;
  }

  _TokenResult _lookupToken(String variableId, Map<String, String> modes) {
    final seen = <String>[];
    var id = variableId;
    while (true) {
      if (seen.contains(id)) {
        return _TokenResult.error(
          IrDiagnosticKind.tokenCycle,
          'Token alias cycle: ${[...seen, id].join(' → ')}.',
        );
      }
      seen.add(id);
      final state = ctx.variableState[id];
      IrValue? value = state;
      if (value == null) {
        final e = variables[id];
        if (e == null) {
          return _TokenResult.error(
            IrDiagnosticKind.missingToken,
            seen.length == 1
                ? 'Token "$id" does not exist.'
                : 'Token "$id" (aliased from "$variableId") does not exist.',
          );
        }
        final byMode = e.variable.valuesByMode;
        value =
            byMode[modes[e.collection.id] ?? e.collection.defaultModeId] ??
            byMode[e.collection.defaultModeId];
        if (value == null) {
          return _TokenResult.error(
            IrDiagnosticKind.missingToken,
            'Token "$id" has no value for the active or default mode.',
          );
        }
      }
      if (value is TokenRefValue) {
        id = value.value.variableId;
        continue;
      }
      return _TokenResult.value(value);
    }
  }

  /// The concrete value of [ref] (reported against [nodeId]/[path]), or null.
  IrValue? _tokenValue(
    TokenRef ref,
    Map<String, String> modes,
    String nodeId,
    String path,
  ) {
    final r = _token(ref.variableId, modes);
    if (r.value != null) return r.value;
    _diag(r.kind!, r.message!, nodeId: nodeId, path: path);
    return null;
  }

  /// Writes every token binding of [n] (`common.bindings`) through the
  /// registry, and clears the bindings.
  Node _bindTokens(Node n, Map<String, String> modes, String id) {
    final bindings = n.common.bindings;
    if (bindings.isEmpty) return n;
    var out = n;
    bindings.forEach((path, ref) {
      final value = _tokenValue(ref, modes, id, path);
      if (value == null) return;
      final match = registry.lookup(path);
      if (match == null) {
        _diag(
          IrDiagnosticKind.unknownPath,
          'Token binding at unknown property "$path".',
          nodeId: id,
          path: path,
        );
        return;
      }
      final next = match.trySet(out, value);
      if (next == null) {
        _diag(
          IrDiagnosticKind.inapplicablePath,
          'Token "${ref.variableId}" cannot be written to "$path" (missing '
          'property or wrong value type).',
          nodeId: id,
          path: path,
        );
        return;
      }
      out = next;
      trace?.step(
        id,
        out,
        ProvenanceSource.token(ref.variableId, _modeOf(ref.variableId, modes)),
        nodeId: n.id,
        keys: [path],
      );
    });
    return out.copyWith(common: out.common.copyWith(bindings: const {}));
  }

  // ---- Scenes ------------------------------------------------------------------

  ResolvedScene _resolveScene(Scene scene, Map<String, String> baseModes) {
    final modes = _withOverrides(baseModes, scene.modeOverrides, scene.id);
    final root = _resolveNode(scene.root, _Scope(prefix: '', modes: modes));
    final index = _sceneIndexes[root] ??= _indexOf(root);
    // Tracks that apply at the active breakpoint. A breakpoint-specific
    // track wins over an all-breakpoints track on the same target and
    // property (m2.md "Tracks and breakpoints"); the runtime evaluates
    // exactly these.
    final applied = <Track>[];
    Set<String>? specific;
    for (final t in scene.tracks) {
      final r = _resolveTrackMemo(t, index);
      if (r == null) continue;
      applied.add(r);
      if (r.breakpoints != null) {
        (specific ??= {}).add('${r.target}\u0000${r.property}');
      }
    }
    final tracks = specific == null
        ? applied
        : [
            for (final r in applied)
              if (r.breakpoints != null ||
                  !specific.contains('${r.target}\u0000${r.property}'))
                r,
          ];
    return ResolvedScene(
      id: scene.id,
      name: scene.name,
      kind: scene.kind,
      scrollLength: scene.scrollLength,
      root: root,
      clocks: scene.clocks,
      tracks: tracks,
      background: scene.background,
      transitionIn: scene.transitionIn,
      modes: modes,
      exportAs: scene.exportAs,
      posterClock: scene.posterClock,
    );
  }

  /// [_resolveTrack], reusing the previous pass's result while the source
  /// track and its resolved target keep their identity. Only results that
  /// produced no diagnostics are memoised (diagnostics must be replayed).
  Track? _resolveTrackMemo(Track t, Map<String, ResolvedNode> index) {
    final only = t.breakpoints;
    if (only != null &&
        (breakpoint == null || !only.contains(breakpoint!.id))) {
      return null;
    }
    final target = index[t.target];
    final prev = memo.tracks[t];
    if (prev != null && target != null && identical(prev.target, target)) {
      return prev.result;
    }
    final before = diagnostics.length;
    final r = _resolveTrack(t, index);
    if (r != null && target != null && diagnostics.length == before) {
      memo.tracks[t] = _TrackMemo(target, r);
    }
    return r;
  }

  Track? _resolveTrack(Track t, Map<String, ResolvedNode> index) {
    final only = t.breakpoints;
    if (only != null &&
        (breakpoint == null || !only.contains(breakpoint!.id))) {
      return null;
    }
    final target = index[t.target];
    if (target == null) {
      _diag(
        IrDiagnosticKind.missingTrackTarget,
        'Track "${t.id}" targets "${t.target}", which is not in its scene.',
        nodeId: t.target,
        path: t.property,
      );
      return null;
    }
    final match = registry.lookup(t.property);
    if (match == null ||
        (match.get(target.node) == null &&
            match.get(_textStyleCarrier(target)) == null)) {
      _diag(
        match == null
            ? IrDiagnosticKind.unknownPath
            : IrDiagnosticKind.inapplicablePath,
        'Track "${t.id}" animates "${t.property}", which does not exist on '
        '"${t.target}".',
        nodeId: target.id,
        path: t.property,
      );
      return null;
    }
    final keyframes = <Keyframe>[];
    for (final k in t.keyframes) {
      final v = k.value;
      if (v is TokenRefValue) {
        final concrete = _tokenValue(
          v.value,
          target.modes,
          target.id,
          t.property,
        );
        if (concrete == null) continue;
        keyframes.add(k.copyWith(value: concrete));
      } else {
        keyframes.add(k);
      }
    }
    final indexed =
        [for (var i = 0; i < keyframes.length; i++) (i, keyframes[i])]
          ..sort((x, y) {
            final c = x.$2.t.compareTo(y.$2.t);
            return c != 0 ? c : x.$1.compareTo(y.$1);
          });
    return t.copyWith(
      target: target.id,
      keyframes: [for (final (_, k) in indexed) k],
    );
  }

  /// For a text target: the node with its merged styles written back as
  /// complete overrides (node style from the first span, every span's
  /// merged style on the span), so `style.*` and span-style tracks address
  /// fields the merge supplies (e.g. the default `text` fill) and not only
  /// fields the node overrides itself. Other nodes are returned as is.
  Node _textStyleCarrier(ResolvedNode target) {
    final n = target.node;
    final paras = target.paragraphs;
    if (n is! TextNode || paras == null) return n;
    TextStyle? first;
    for (final p in paras) {
      if (p.spans.isNotEmpty) {
        first = p.spans.first.style;
        break;
      }
    }
    return n.copyWith(
      style: _fullOverride(first ?? doc.defaultTextStyle),
      content: [
        for (final (pi, p) in n.content.indexed)
          p.copyWith(
            spans: [
              for (final (si, sp) in p.spans.indexed)
                pi < paras.length && si < paras[pi].spans.length
                    ? sp.copyWith(
                        style: _fullOverride(paras[pi].spans[si].style),
                      )
                    : sp,
            ],
          ),
      ],
    );
  }

  // ---- Nodes -------------------------------------------------------------------

  /// Applies [patch] to [n], reporting against [id].
  Node _patch(Node n, Patch patch, String id) {
    final local = <IrDiagnostic>[];
    final out = applyPatch(n, patch, diagnostics: local, registry: registry);
    for (final d in local) {
      diagnostics.add(d.copyWith(nodeId: id));
    }
    return out;
  }

  /// Resolves one node and its subtree, reusing the previous pass's result
  /// for an unchanged scene-level subtree (see [Resolver]).
  ResolvedNode _resolveNode(
    Node node,
    _Scope scope, {
    String? forcedId,
    InstanceNode? placement,
  }) {
    // Only scene-level nodes are memoised; an instance's expansion is
    // memoised as a whole at the instance node.
    if (scope.instance != null || forcedId != null || placement != null) {
      return _resolveNodeUncached(
        node,
        scope,
        forcedId: forcedId,
        placement: placement,
      );
    }
    final t = trace;
    if (t != null && t.bypass.contains(node)) {
      return _resolveNodeUncached(node, scope);
    }
    final hits = memo.nodes[node];
    if (hits != null) {
      for (final e in hits) {
        if (_Memo.sameModes(e.modes, scope.modes)) {
          diagnostics.addAll(e.diagnostics);
          return e.result;
        }
      }
    }
    final start = diagnostics.length;
    final result = _resolveNodeUncached(node, scope);
    final entries = memo.nodes[node] ??= [];
    if (entries.length >= _Memo.maxModeEntries) entries.removeAt(0);
    entries.add(
      _MemoEntry(
        scope.modes,
        result,
        diagnostics.length == start
            ? const []
            : List.unmodifiable(diagnostics.sublist(start)),
      ),
    );
    return result;
  }

  ResolvedNode _resolveNodeUncached(
    Node node,
    _Scope scope, {
    String? forcedId,
    InstanceNode? placement,
  }) {
    final id = forcedId ?? '${scope.prefix}${node.id}';
    final inst = scope.instance;
    // Override key relative to the enclosing instance: the root is addressed
    // by its own (component) id.
    final key = placement != null ? node.id : id.substring(scope.prefix.length);
    var n = node;
    final t = trace;
    t?.step(
      id,
      n,
      inst == null
          ? const ProvenanceSource.base()
          : ProvenanceSource.componentDefault(inst.component.id),
      nodeId: node.id,
      always: true,
    );

    // 1. Breakpoint patches (§3.1).
    for (final bp in cascade) {
      final patch = n.common.breakpointOverrides[bp.id];
      if (patch != null) {
        n = _patch(n, patch, id);
        t?.step(
          id,
          n,
          ProvenanceSource.breakpointPatch(bp.id),
          nodeId: node.id,
          keys: patch.keys,
        );
      }
    }

    // 2. Component prop bindings (§9).
    if (inst != null &&
        t != null &&
        id == t.targetId &&
        n.common.componentBindings.isNotEmpty) {
      // Traced: one binding at a time, so each is attributed to its prop
      // (the same writes, in the same order, as the whole patch below).
      for (final MapEntry(key: path, value: propId)
          in n.common.componentBindings.entries) {
        final v = inst.props[propId];
        if (v == null) {
          _diag(
            IrDiagnosticKind.missingComponentProp,
            'Component "${inst.component.id}" has no prop "$propId".',
            nodeId: id,
            path: path,
          );
          continue;
        }
        n = _patch(n, {path: v}, id);
        t.step(
          id,
          n,
          ProvenanceSource.componentBinding(propId, inst.instanceId),
          nodeId: node.id,
          keys: [path],
        );
      }
    } else if (inst != null && n.common.componentBindings.isNotEmpty) {
      final patch = <String, IrValue>{};
      n.common.componentBindings.forEach((path, propId) {
        final v = inst.props[propId];
        if (v == null) {
          _diag(
            IrDiagnosticKind.missingComponentProp,
            'Component "${inst.component.id}" has no prop "$propId".',
            nodeId: id,
            path: path,
          );
        } else {
          patch[path] = v;
        }
      });
      n = _patch(n, patch, id);
    }

    // 3. Instance placement (component root only), then overrides.
    if (placement != null && n is FrameNode) {
      n = _place(n, placement);
      t?.placed(id, n, id, node.id);
    }
    if (inst != null) {
      for (final o in inst.overrides[key] ?? const <_Override>[]) {
        n = _patch(n, o.patch, id);
        t?.step(
          id,
          n,
          ProvenanceSource.instanceOverride(o.instanceId, o.innerPath),
          nodeId: o.instanceId.split('/').last,
          keys: o.patch.keys,
        );
      }
    }

    // 4. Instance expansion.
    if (n is InstanceNode) return _expand(n, id, key, scope);

    // 5. Modes (frame scope, inherited by descendants).
    var modes = scope.modes;
    if (n is FrameNode && n.modeOverrides.isNotEmpty) {
      modes = _withOverrides(modes, n.modeOverrides, id);
    }

    // 6. Token bindings.
    n = _bindTokens(n, modes, id);

    // 7. Styles.
    List<ResolvedParagraph>? paragraphs;
    List<Paint>? textFills;
    TextStyle? textStyle;
    final unstyled = n;
    n = _applyPaintAndEffectStyles(n, id);
    t?.styles(id, unstyled, n, doc);
    if (n is TextNode) {
      final named = _namedTextStyle(n, modes, id);
      final merged = mergeTextStyle(named, n.style);
      paragraphs = _paragraphs(n, merged);
      textFills = merged.fills;
      textStyle = merged;
      t?.text(
        id,
        n,
        doc.defaultTextStyle,
        n.textStyleId == null ? null : doc.tokens.textStyles[n.textStyleId],
        named,
        merged,
        paragraphs,
        (v) => _modeOf(v, modes),
      );
      // Consumers read the merged result from `paragraphs`.
      n = n.copyWith(style: const TextStyleOverride(), textStyleId: null);
    }

    _checkAssets(n, id, textFills);

    // 8. Children.
    final childScope = scope.withModes(modes);
    final children = n is FrameNode
        ? [for (final c in n.children) _resolveNode(c, childScope)]
        : const <ResolvedNode>[];

    final result = ResolvedNode(
      id: id,
      node: _concrete(n, id),
      children: children,
      sourceComponentId: inst?.component.id,
      instanceId: inst?.instanceId,
      paragraphs: paragraphs,
      textStyle: textStyle,
      modes: modes,
    );
    if (t != null && id == t.targetId) t.resolved = result;
    return result;
  }

  /// The component root [root] placed by [inst]: the instance supplies its
  /// name (when set), visibility, geometry, transforms, layout-child settings,
  /// mask, blend mode, role, reading order and alt text (each when set);
  /// opacities multiply; interactions of both apply. Everything else comes from the component.
  FrameNode _place(FrameNode root, InstanceNode inst) {
    final r = root.common, i = inst.common;
    return root.copyWith(
      common: r.copyWith(
        name: i.name.isEmpty ? r.name : i.name,
        visible: i.visible,
        locked: i.locked,
        opacity: r.opacity * i.opacity,
        blendMode: i.blendMode ?? r.blendMode,
        x: i.x,
        y: i.y,
        width: i.width,
        height: i.height,
        rotation: i.rotation,
        flipX: i.flipX,
        flipY: i.flipY,
        motion: i.motion,
        layoutChild: i.layoutChild,
        mask: i.mask,
        role: i.role == NodeRole.none ? r.role : i.role,
        readingOrder: i.readingOrder ?? r.readingOrder,
        altText: i.altText ?? r.altText,
        interactions: [...r.interactions, ...i.interactions],
      ),
    );
  }

  ResolvedNode _expand(InstanceNode inst, String id, String key, _Scope scope) {
    // Token bindings on the instance itself (opacity, prop values, …) resolve
    // in the instance's scope before expansion.
    final n = _bindTokens(inst, scope.modes, id) as InstanceNode;
    final outer = scope.instance;

    final componentId = _componentIdFor(n, id);
    final def = componentId == null ? null : doc.components[componentId];
    if (componentId != null && def == null) {
      _diag(
        IrDiagnosticKind.missingComponent,
        'Component "$componentId" does not exist.',
        nodeId: id,
        path: componentId,
      );
    }
    if (def == null) return _placeholder(n, id, scope);
    final stack = outer?.componentStack ?? const <String>[];
    if (stack.contains(def.id)) {
      _diag(
        IrDiagnosticKind.componentCycle,
        'Component cycle: ${[...stack, def.id].join(' → ')}.',
        nodeId: id,
        path: def.id,
      );
      return _placeholder(n, id, scope);
    }

    final props = <String, IrValue>{
      for (final MapEntry(key: p, value: d) in def.properties.entries)
        p: n.propValues[p] ?? d.defaultValue,
    };
    // Own overrides first, then the enclosing instance's overrides that reach
    // into this one (`<thisKey>/<inner path>`), which win.
    trace?.enterInstance(id, n);
    final overrides = <String, List<_Override>>{};
    n.overrides.forEach(
      (k, p) =>
          (overrides[k] ??= []).add((instanceId: id, innerPath: k, patch: p)),
    );
    if (outer != null) {
      final prefix = '$key/';
      outer.overrides.forEach((k, ps) {
        if (k.startsWith(prefix)) {
          (overrides[k.substring(prefix.length)] ??= []).addAll(ps);
        }
      });
    }
    final frame = _InstanceFrame(
      instanceId: id,
      component: def,
      props: props,
      overrides: overrides,
      componentStack: [...stack, def.id],
    );
    return _resolveNode(
      def.root,
      _Scope(prefix: '$id/', modes: scope.modes, instance: frame),
      forcedId: id,
      placement: n,
    );
  }

  String? _componentIdFor(InstanceNode n, String id) {
    switch (n.source) {
      case ComponentSource(:final componentId):
        return componentId;
      case VariantSource(:final variantSetId, :final variantValues):
        final set = doc.variantSets[variantSetId];
        if (set == null) {
          _diag(
            IrDiagnosticKind.missingVariant,
            'Variant set "$variantSetId" does not exist.',
            nodeId: id,
            path: variantSetId,
          );
          return null;
        }
        final picked = selectVariant(set, variantValues);
        if (picked == null) {
          _diag(
            IrDiagnosticKind.missingVariant,
            'Variant set "$variantSetId" has no variants.',
            nodeId: id,
            path: variantSetId,
          );
          return null;
        }
        if (!picked.exact) {
          _diag(
            IrDiagnosticKind.missingVariant,
            'No variant of "$variantSetId" matches $variantValues exactly; '
            'using the closest.',
            nodeId: id,
            path: variantSetId,
          );
        }
        return picked.variant.componentId;
    }
  }

  ResolvedNode _placeholder(InstanceNode n, String id, _Scope scope) {
    final result = ResolvedNode(
      id: id,
      node: _concrete(FrameNode(common: n.common), id),
      sourceComponentId: null,
      instanceId: scope.instance?.instanceId,
      modes: scope.modes,
      isPlaceholder: true,
    );
    final t = trace;
    if (t != null && id == t.targetId) t.resolved = result;
    return result;
  }

  // ---- Styles (§8) -------------------------------------------------------------

  List<Paint>? _paintStyle(String styleId, String id, String path) {
    final s = doc.tokens.paintStyles[styleId];
    if (s == null) {
      _diag(
        IrDiagnosticKind.missingStyle,
        'Paint style "$styleId" does not exist; keeping the local paints.',
        nodeId: id,
        path: path,
      );
    }
    return s?.paints;
  }

  /// Replaces stacks by their referenced paint/effect styles and clears the
  /// style ids.
  Node _applyPaintAndEffectStyles(Node n, String id) {
    switch (n) {
      case FrameNode(:final appearance):
        return n.copyWith(appearance: _appearanceStyles(appearance, id));
      case ShapeNode(:final appearance):
        return n.copyWith(appearance: _appearanceStyles(appearance, id));
      case VideoNode(:final appearance):
        return n.copyWith(appearance: _appearanceStyles(appearance, id));
      case TextNode(:final appearance):
        var a = appearance;
        if (a.strokeStyleId case final s?) {
          final paints = _paintStyle(s, id, 'strokeStyleId');
          if (paints != null) {
            a = a.copyWith(strokes: a.strokes.copyWith(paints: paints));
          }
        }
        if (a.effectStyleId case final s?) {
          final effects = _effectStyle(s, id);
          if (effects != null) a = a.copyWith(effects: effects);
        }
        return n.copyWith(
          appearance: a.copyWith(strokeStyleId: null, effectStyleId: null),
        );
      case InstanceNode() || EmbedNode():
        return n;
    }
  }

  Appearance _appearanceStyles(Appearance a, String id) {
    var out = a;
    if (a.fillStyleId case final s?) {
      final paints = _paintStyle(s, id, 'fillStyleId');
      if (paints != null) out = out.copyWith(fills: paints);
    }
    if (a.strokeStyleId case final s?) {
      final paints = _paintStyle(s, id, 'strokeStyleId');
      if (paints != null) {
        out = out.copyWith(strokes: out.strokes.copyWith(paints: paints));
      }
    }
    if (a.effectStyleId case final s?) {
      final effects = _effectStyle(s, id);
      if (effects != null) out = out.copyWith(effects: effects);
    }
    if (identical(out, a) &&
        a.fillStyleId == null &&
        a.strokeStyleId == null &&
        a.effectStyleId == null) {
      return a;
    }
    return out.copyWith(
      fillStyleId: null,
      strokeStyleId: null,
      effectStyleId: null,
    );
  }

  List<Effect>? _effectStyle(String styleId, String id) {
    final s = doc.tokens.effectStyles[styleId];
    if (s == null) {
      _diag(
        IrDiagnosticKind.missingStyle,
        'Effect style "$styleId" does not exist; keeping the local effects.',
        nodeId: id,
        path: 'effectStyleId',
      );
    }
    return s?.effects;
  }

  /// The base of a text node's cascade: the document's default text style
  /// with the named style (`textStyleId`) layered over it. A named style is
  /// partial: unset fields inherit the default. Its token bindings are
  /// resolved in this node's [modes]. The node's `style` override and the
  /// spans are layered on top.
  TextStyle _namedTextStyle(TextNode n, Map<String, String> modes, String id) {
    final styleId = n.textStyleId;
    if (styleId == null) return doc.defaultTextStyle;
    final def = doc.tokens.textStyles[styleId];
    if (def == null) {
      _diag(
        IrDiagnosticKind.missingStyle,
        'Text style "$styleId" does not exist; using the document default.',
        nodeId: id,
        path: 'textStyleId',
      );
      return doc.defaultTextStyle;
    }
    if (def.bindings.isEmpty) {
      return mergeTextStyle(doc.defaultTextStyle, def.style);
    }
    // Bound fields are written (through the registry) into a carrier that
    // holds the style's own overrides.
    final needsFills =
        def.style.fills == null &&
        def.bindings.keys.any((k) => k.startsWith('fills.'));
    Node carrier = TextNode(
      common: NodeCommon(id: id),
      style: needsFills
          ? def.style.copyWith(fills: doc.defaultTextStyle.fills)
          : def.style,
    );
    def.bindings.forEach((rel, ref) {
      final value = _tokenValue(ref, modes, id, 'textStyles.$styleId.$rel');
      if (value == null) return;
      final next = registry.trySet(carrier, 'style.$rel', value);
      if (next == null) {
        _diag(
          IrDiagnosticKind.inapplicablePath,
          'Text style "$styleId" binds unknown or mistyped field "$rel".',
          nodeId: id,
          path: 'textStyles.$styleId.$rel',
        );
      } else {
        carrier = next;
      }
    });
    return mergeTextStyle(doc.defaultTextStyle, (carrier as TextNode).style);
  }

  List<ResolvedParagraph> _paragraphs(TextNode n, TextStyle merged) => [
    for (final p in n.content)
      () {
        final ps = p.style;
        final base = merged.copyWith(
          paragraphSpacing: ps?.paragraphSpacing ?? merged.paragraphSpacing,
          paragraphIndent: ps?.paragraphIndent ?? merged.paragraphIndent,
          listStyle: ps?.listStyle ?? merged.listStyle,
        );
        return ResolvedParagraph(
          alignHorizontal: ps?.alignHorizontal ?? n.alignHorizontal,
          paragraphSpacing: base.paragraphSpacing,
          paragraphIndent: base.paragraphIndent,
          listStyle: base.listStyle,
          spans: [
            for (final s in p.spans)
              ResolvedSpan(
                text: s.text,
                style: mergeTextStyle(base, s.style),
                link: s.link,
              ),
          ],
        );
      }(),
  ];

  // ---- Output ------------------------------------------------------------------

  void _checkAssets(Node n, String id, List<Paint>? textFills) {
    void check(String? assetId, String path) {
      if (assetId == null || doc.assets.containsKey(assetId)) return;
      _diag(
        IrDiagnosticKind.missingAsset,
        'Asset "$assetId" does not exist.',
        nodeId: id,
        path: path,
      );
    }

    void paints(List<Paint>? ps, String prefix) {
      for (final p in ps ?? const <Paint>[]) {
        if (p is ImagePaint) check(p.assetId, '$prefix.${p.id}.assetId');
      }
    }

    switch (n) {
      case FrameNode(:final appearance) || ShapeNode(:final appearance):
        paints(appearance.fills, 'fills');
        paints(appearance.strokes.paints, 'strokes.paints');
      case VideoNode(:final appearance):
        check(n.assetId, 'assetId');
        check(n.posterAssetId, 'posterAssetId');
        paints(appearance.fills, 'fills');
        paints(appearance.strokes.paints, 'strokes.paints');
      case TextNode():
        paints(textFills, 'style.fills');
        paints(n.appearance.strokes.paints, 'strokes.paints');
        for (final (pi, p) in n.content.indexed) {
          for (final (si, s) in p.spans.indexed) {
            paints(s.style.fills, 'content.$pi.spans.$si.style.fills');
          }
        }
      case EmbedNode():
        check(n.assetId, 'assetId');
      case InstanceNode():
        break;
    }
  }

  /// [n] with its namespaced id and every authoring-only reference cleared.
  Node _concrete(Node n, String id) {
    final c = n.common;
    final common =
        c.id == id &&
            c.breakpointOverrides.isEmpty &&
            c.bindings.isEmpty &&
            c.componentBindings.isEmpty
        ? c
        : c.copyWith(
            id: id,
            breakpointOverrides: const {},
            bindings: const {},
            componentBindings: const {},
          );
    return switch (n) {
      FrameNode() => n.copyWith(common: common, children: const []),
      _ => identical(common, c) ? n : n.copyWith(common: common),
    };
  }
}

/// [base] with every non-null field of [o] applied. Map fields
/// (`fontVariations`, `openType`) merge key-wise, the override winning.
TextStyle mergeTextStyle(TextStyle base, TextStyleOverride o) {
  if (identical(o, const TextStyleOverride())) return base;
  return base.copyWith(
    fontFamilyId: o.fontFamilyId ?? base.fontFamilyId,
    fontWeight: o.fontWeight ?? base.fontWeight,
    italic: o.italic ?? base.italic,
    fontVariations: o.fontVariations == null
        ? base.fontVariations
        : {...base.fontVariations, ...o.fontVariations!},
    fontSize: o.fontSize ?? base.fontSize,
    lineHeight: o.lineHeight ?? base.lineHeight,
    letterSpacing: o.letterSpacing ?? base.letterSpacing,
    paragraphSpacing: o.paragraphSpacing ?? base.paragraphSpacing,
    paragraphIndent: o.paragraphIndent ?? base.paragraphIndent,
    textCase: o.textCase ?? base.textCase,
    decoration: o.decoration ?? base.decoration,
    fills: o.fills ?? base.fills,
    openType: o.openType == null
        ? base.openType
        : {...base.openType, ...o.openType!},
    baselineShift: o.baselineShift ?? base.baselineShift,
    listStyle: o.listStyle ?? base.listStyle,
  );
}

/// The picked variant and whether it matched every requested axis value.
typedef VariantPick = ({Variant variant, bool exact});

/// Selects the variant of [set] for [values] (architecture §9). Axes not in
/// [values] take their first listed value (Figma's default variant). An
/// exact match wins; otherwise the variant matching the most axes, earliest
/// first. Null when the set has no variants.
VariantPick? selectVariant(VariantSet set, Map<String, String> values) {
  if (set.variants.isEmpty) return null;
  final wanted = <String, String>{
    for (final MapEntry(key: axis, value: options) in set.axes.entries)
      if (options.isNotEmpty) axis: options.first,
    ...values,
  };
  Variant? best;
  var bestScore = -1;
  for (final v in set.variants) {
    var score = 0;
    wanted.forEach((axis, value) {
      if (v.values[axis] == value) score++;
    });
    if (score > bestScore) {
      best = v;
      bestScore = score;
    }
  }
  final exact = wanted.entries.every((e) => best!.values[e.key] == e.value);
  return (variant: best!, exact: exact);
}
