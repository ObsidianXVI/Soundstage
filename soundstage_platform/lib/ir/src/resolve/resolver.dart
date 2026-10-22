import 'dart:collection';

import '../breakpoint.dart';
import '../components.dart';
import '../diagnostics.dart';
import '../document.dart';
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
import 'breakpoints.dart';
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
class Resolver {
  Resolver({PropertyRegistry? registry})
    : registry = registry ?? PropertyRegistry.standard;

  final PropertyRegistry registry;

  ResolvedDocument resolve(
    StageDocument doc, [
    ResolveContext context = const ResolveContext(),
  ]) {
    final pass = _Pass(doc, context, registry);
    return pass.run();
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
  /// application order (the instance's own first, then enclosing instances').
  final Map<String, List<Patch>> overrides;

  /// Components being expanded, outermost first (cycle detection).
  final List<String> componentStack;
}

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
  _Pass(this.doc, this.ctx, this.registry);

  final StageDocument doc;
  final ResolveContext ctx;
  final PropertyRegistry registry;
  final List<IrDiagnostic> diagnostics = [];

  late final Breakpoint? breakpoint = _pickBreakpoint();
  late final List<Breakpoint> cascade = breakpoint == null
      ? const []
      : breakpointCascade(
          doc.breakpoints,
          doc.baseBreakpointId,
          breakpoint!.id,
        );

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
    final index = <String, ResolvedNode>{};
    for (final s in scenes) {
      _index(s.root, index);
    }
    if (overlay != null) _index(overlay, index);
    return ResolvedDocument(
      breakpoint: breakpoint,
      scenes: scenes,
      overlay: overlay,
      nodeIndex: index,
      diagnostics: List.unmodifiable(diagnostics),
    );
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
    for (final b in bps) {
      if (b.id == doc.baseBreakpointId) return b;
    }
    _diag(
      IrDiagnosticKind.missingBreakpoint,
      'Base breakpoint "${doc.baseBreakpointId}" does not exist.',
      path: doc.baseBreakpointId,
    );
    return bps.first;
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
    });
    return out.copyWith(common: out.common.copyWith(bindings: const {}));
  }

  // ---- Scenes ------------------------------------------------------------------

  ResolvedScene _resolveScene(Scene scene, Map<String, String> baseModes) {
    final modes = _withOverrides(baseModes, scene.modeOverrides, scene.id);
    final root = _resolveNode(scene.root, _Scope(prefix: '', modes: modes));
    final index = <String, ResolvedNode>{};
    _index(root, index);
    final tracks = <Track>[];
    for (final t in scene.tracks) {
      final r = _resolveTrack(t, index);
      if (r != null) tracks.add(r);
    }
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
    );
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
    if (match == null || match.get(target.node) == null) {
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

  // ---- Nodes -------------------------------------------------------------------

  /// Applies [patch] to [n], reporting against [id] and recording written
  /// `style.*` paths in [touched].
  Node _patch(Node n, Patch patch, String id, Set<String> touched) {
    final local = <IrDiagnostic>[];
    final out = applyPatch(
      n,
      patch,
      diagnostics: local,
      registry: registry,
      onApplied: touched.add,
    );
    for (final d in local) {
      diagnostics.add(d.copyWith(nodeId: id));
    }
    return out;
  }

  /// Resolves one node and its subtree. [forcedId] and [placement] are set
  /// for a component root being instantiated by [placement].
  ResolvedNode _resolveNode(
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
    final touched = <String>{};
    var n = node;

    // 1. Breakpoint patches (§3.1).
    for (final bp in cascade) {
      final patch = n.common.breakpointOverrides[bp.id];
      if (patch != null) n = _patch(n, patch, id, touched);
    }

    // 2. Component prop bindings (§9).
    if (inst != null && n.common.componentBindings.isNotEmpty) {
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
      n = _patch(n, patch, id, touched);
    }

    // 3. Instance placement (component root only), then overrides.
    if (placement != null && n is FrameNode) n = _place(n, placement);
    if (inst != null) {
      for (final patch in inst.overrides[key] ?? const <Patch>[]) {
        n = _patch(n, patch, id, touched);
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
    for (final p in n.common.bindings.keys) {
      if (p.startsWith('style.')) touched.add(p);
    }
    n = _bindTokens(n, modes, id);

    // 7. Styles.
    List<ResolvedParagraph>? paragraphs;
    n = _applyPaintAndEffectStyles(n, id);
    if (n is TextNode) {
      final base = _textBaseStyle(n, modes, id, touched);
      n = n.copyWith(style: base, textStyleId: null);
      paragraphs = _paragraphs(n);
    }

    _checkAssets(n, id);

    // 8. Children.
    final childScope = scope.withModes(modes);
    final children = n is FrameNode
        ? [for (final c in n.children) _resolveNode(c, childScope)]
        : const <ResolvedNode>[];

    return ResolvedNode(
      id: id,
      node: _concrete(n, id),
      children: children,
      sourceComponentId: inst?.component.id,
      instanceId: inst?.instanceId,
      paragraphs: paragraphs,
      modes: modes,
    );
  }

  /// The component root [root] placed by [inst]: the instance supplies its
  /// name (when set), visibility, geometry, transforms, layout-child settings,
  /// mask and blend mode (when set); opacities multiply; interactions of
  /// both apply. Everything else comes from the component.
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
    final overrides = <String, List<Patch>>{};
    n.overrides.forEach((k, p) => (overrides[k] ??= []).add(p));
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

  ResolvedNode _placeholder(InstanceNode n, String id, _Scope scope) =>
      ResolvedNode(
        id: id,
        node: _concrete(FrameNode(common: n.common), id),
        sourceComponentId: null,
        instanceId: scope.instance?.instanceId,
        modes: scope.modes,
        isPlaceholder: true,
      );

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

  /// The node's base text style. Without a `textStyleId` it is the node's
  /// own `style`. With one, it is the named style (its token bindings
  /// resolved in this node's modes) with the node's *local* style values on
  /// top: the `style.*` paths written by breakpoint patches, prop bindings,
  /// instance overrides and token bindings at this node.
  TextStyle _textBaseStyle(
    TextNode n,
    Map<String, String> modes,
    String id,
    Set<String> touched,
  ) {
    final styleId = n.textStyleId;
    if (styleId == null) return n.style;
    final def = doc.tokens.textStyles[styleId];
    if (def == null) {
      _diag(
        IrDiagnosticKind.missingStyle,
        'Text style "$styleId" does not exist; using the node style.',
        nodeId: id,
        path: 'textStyleId',
      );
      return n.style;
    }
    var carrier = TextNode(
      common: NodeCommon(id: id),
      style: def.style,
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
        carrier = next as TextNode;
      }
    });
    for (final path in touched) {
      if (!path.startsWith('style.')) continue;
      final value = registry.get(n, path);
      Node? next = value == null ? null : registry.trySet(carrier, path, value);
      if (next == null) {
        // E.g. `style.fills.<id>.color` where the named style has no such
        // paint: take the whole top-level field from the node.
        final top = path.split('.').take(2).join('.');
        final whole = registry.get(n, top);
        next = whole == null ? null : registry.trySet(carrier, top, whole);
      }
      if (next != null) carrier = next as TextNode;
    }
    return carrier.style;
  }

  List<ResolvedParagraph> _paragraphs(TextNode n) => [
    for (final p in n.content)
      () {
        final ps = p.style;
        final base = n.style.copyWith(
          paragraphSpacing: ps?.paragraphSpacing ?? n.style.paragraphSpacing,
          paragraphIndent: ps?.paragraphIndent ?? n.style.paragraphIndent,
          listStyle: ps?.listStyle ?? n.style.listStyle,
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

  void _checkAssets(Node n, String id) {
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
        paints(n.style.fills, 'style.fills');
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
