import '../assets.dart';
import '../audio.dart';
import '../behaviors.dart';
import '../components.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../interactions.dart';
import '../motion.dart';
import '../nodes/appearance.dart';
import '../nodes/effect.dart';
import '../nodes/node.dart';
import '../nodes/paint.dart';
import '../nodes/text.dart';
import '../registry/property_registry.dart';
import '../scene.dart';
import '../tokens.dart';
import '../values/ir_value.dart';

/// Checks the referential integrity of [doc] (architecture §13, §17.3).
///
/// Never throws. Returns every problem found: dangling ids, duplicate ids,
/// map keys that disagree with their value's `id`, component cycles, alias
/// cycles and unresolvable track targets. Each diagnostic has a severity, a
/// stable `code` (the kind's name) and a `location` path such as
/// `scenes[0].root.children[2].common.interactions[0]`.
///
/// Errors mean the reference is broken; warnings (unknown property paths,
/// assets of an unexpected kind) are tolerated by the resolver. A document
/// produced by the editor or the generators validates clean.
List<IrDiagnostic> validateDocument(
  StageDocument doc, {
  PropertyRegistry? registry,
}) {
  final v = _Validator(doc, registry ?? PropertyRegistry.standard);
  v.run();
  return v.out;
}

/// True when [diagnostics] contain at least one error.
bool hasErrors(Iterable<IrDiagnostic> diagnostics) =>
    diagnostics.any((d) => d.severity == IrSeverity.error);

class _Validator {
  _Validator(this.doc, this.registry);

  final StageDocument doc;
  final PropertyRegistry registry;
  final List<IrDiagnostic> out = [];

  final Set<String> _breakpointIds = {};
  final Set<String> _sceneIds = {};
  final Set<String> _clockIds = {};
  final Set<String> _audioIds = {};
  final Set<String> _nodeIds = {};
  final Map<String, Variable> _variables = {};
  final Map<String, VariableCollection> _collections = {};

  void _d(
    IrDiagnosticKind kind,
    String message,
    String location, {
    String? nodeId,
    String? path,
    IrSeverity severity = IrSeverity.error,
  }) {
    out.add(
      IrDiagnostic(
        kind,
        message,
        nodeId: nodeId,
        path: path,
        severity: severity,
        location: location,
      ),
    );
  }

  void run() {
    _prepass();
    _breakpoints();
    _assetsAndFonts();
    _tokens();
    _textStyle(doc.defaultTextStyle, 'defaultTextStyle');
    _audioTracks();
    _unique(doc.scenes.map((s) => s.id), 'scenes', 'scene');
    _unique(
      doc.scenes.expand((s) => s.clocks).map((c) => c.id),
      'scenes.clocks',
      'clock',
    );
    final seen = <String>{};
    for (final (i, s) in doc.scenes.indexed) {
      _scene(s, 'scenes[$i]', seen);
    }
    final overlay = doc.overlay;
    if (overlay != null) _node(overlay, 'overlay', seen, null);
    _components();
    _componentCycles();
  }

  // ---- Pre-pass: id universes -------------------------------------------------

  void _prepass() {
    for (final b in doc.breakpoints) {
      _breakpointIds.add(b.id);
    }
    for (final s in doc.scenes) {
      _sceneIds.add(s.id);
      for (final c in s.clocks) {
        _clockIds.add(c.id);
      }
      _collectNodeIds(s.root);
    }
    for (final t in doc.audioTracks) {
      _audioIds.add(t.id);
    }
    final overlay = doc.overlay;
    if (overlay != null) _collectNodeIds(overlay);
    for (final c in doc.components.values) {
      _collectNodeIds(c.root);
    }
    for (final col in doc.tokens.collections) {
      _collections[col.id] = col;
      for (final v in col.variables) {
        _variables[v.id] = v;
      }
    }
  }

  void _collectNodeIds(Node n) {
    _nodeIds.add(n.id);
    if (n is FrameNode) n.children.forEach(_collectNodeIds);
  }

  // ---- Reference helpers ------------------------------------------------------

  void _asset(
    String? id,
    String loc, {
    AssetKind? kind,
    Set<AssetKind>? kinds,
    String? nodeId,
  }) {
    if (id == null) return;
    final a = doc.assets[id];
    if (a == null) {
      _d(
        IrDiagnosticKind.missingAsset,
        'Asset "$id" does not exist.',
        loc,
        nodeId: nodeId,
      );
      return;
    }
    final ok = kinds ?? (kind == null ? null : {kind});
    if (ok != null && !ok.contains(a.kind)) {
      _d(
        IrDiagnosticKind.wrongAssetKind,
        'Asset "$id" is ${a.kind.name}, expected ${ok.map((k) => k.name).join('/')}.',
        loc,
        nodeId: nodeId,
        severity: IrSeverity.warning,
      );
    }
  }

  void _font(String? id, String loc) {
    if (id == null || doc.fonts.containsKey(id)) return;
    _d(IrDiagnosticKind.missingFont, 'Font family "$id" does not exist.', loc);
  }

  void _variable(String id, String loc, {String? nodeId}) {
    if (_variables.containsKey(id)) return;
    _d(
      IrDiagnosticKind.missingToken,
      'Variable "$id" does not exist.',
      loc,
      nodeId: nodeId,
    );
  }

  void _clock(String id, String loc) {
    if (_clockIds.contains(id)) return;
    _d(IrDiagnosticKind.missingClock, 'Clock "$id" does not exist.', loc);
  }

  void _audio(String id, String loc) {
    if (_audioIds.contains(id)) return;
    _d(
      IrDiagnosticKind.missingAudioTrack,
      'Audio track "$id" does not exist.',
      loc,
    );
  }

  void _sceneRef(String id, String loc) {
    if (_sceneIds.contains(id)) return;
    _d(IrDiagnosticKind.missingScene, 'Scene "$id" does not exist.', loc);
  }

  void _breakpointRef(String id, String loc) {
    if (_breakpointIds.contains(id)) return;
    _d(
      IrDiagnosticKind.missingBreakpoint,
      'Breakpoint "$id" does not exist.',
      loc,
    );
  }

  void _modeMap(Map<String, String> modes, String loc) {
    modes.forEach((collectionId, modeId) {
      final col = _collections[collectionId];
      if (col == null) {
        _d(
          IrDiagnosticKind.missingToken,
          'Variable collection "$collectionId" does not exist.',
          '$loc.$collectionId',
        );
      } else if (!col.modes.any((m) => m.id == modeId)) {
        _d(
          IrDiagnosticKind.missingMode,
          'Mode "$modeId" is not in collection "$collectionId".',
          '$loc.$collectionId',
        );
      }
    });
  }

  void _unique(Iterable<String> ids, String loc, String what) {
    final seen = <String>{};
    for (final (i, id) in ids.indexed) {
      if (!seen.add(id)) {
        _d(
          IrDiagnosticKind.duplicateId,
          'Duplicate $what id "$id".',
          '$loc[$i]',
        );
      }
    }
  }

  // ---- Document-level ---------------------------------------------------------

  void _breakpoints() {
    _unique(doc.breakpoints.map((b) => b.id), 'breakpoints', 'breakpoint');
    if (!_breakpointIds.contains(doc.baseBreakpointId)) {
      _d(
        IrDiagnosticKind.missingBreakpoint,
        'baseBreakpointId "${doc.baseBreakpointId}" does not exist.',
        'baseBreakpointId',
      );
    }
    if (doc.breakpoints.isEmpty) {
      _d(
        IrDiagnosticKind.missingBreakpoint,
        'A document needs at least one breakpoint.',
        'breakpoints',
      );
    }
  }

  void _assetsAndFonts() {
    _asset(doc.meta.coverAssetId, 'meta.coverAssetId', kind: AssetKind.image);
    doc.assets.forEach((key, a) {
      if (a.id != key) {
        _d(
          IrDiagnosticKind.idMismatch,
          'Asset key "$key" differs from its id "${a.id}".',
          'assets.$key',
        );
      }
    });
    doc.fonts.forEach((key, f) {
      if (f.id != key) {
        _d(
          IrDiagnosticKind.idMismatch,
          'Font key "$key" differs from its id "${f.id}".',
          'fonts.$key',
        );
      }
      for (final (i, face) in f.faces.indexed) {
        _asset(
          face.assetId,
          'fonts.$key.faces[$i].assetId',
          kind: AssetKind.font,
        );
      }
    });
  }

  void _audioTracks() {
    _unique(doc.audioTracks.map((t) => t.id), 'audioTracks', 'audio track');
    for (final (i, t) in doc.audioTracks.indexed) {
      final loc = 'audioTracks[$i]';
      _asset(t.assetId, '$loc.assetId', kind: AssetKind.audio);
      final scope = t.scope;
      if (scope is SceneAudioScope) _sceneRef(scope.sceneId, '$loc.scope');
    }
  }

  // ---- Tokens -----------------------------------------------------------------

  void _tokens() {
    final t = doc.tokens;
    _unique(t.collections.map((c) => c.id), 'tokens.collections', 'collection');
    final seenVars = <String>{};
    for (final (ci, col) in t.collections.indexed) {
      final cl = 'tokens.collections[$ci]';
      _unique(col.modes.map((m) => m.id), '$cl.modes', 'mode');
      final modeIds = {for (final m in col.modes) m.id};
      if (!modeIds.contains(col.defaultModeId)) {
        _d(
          IrDiagnosticKind.missingMode,
          'defaultModeId "${col.defaultModeId}" is not a mode of "${col.id}".',
          '$cl.defaultModeId',
        );
      }
      col.breakpointModes.forEach((bp, mode) {
        _breakpointRef(bp, '$cl.breakpointModes.$bp');
        if (!modeIds.contains(mode)) {
          _d(
            IrDiagnosticKind.missingMode,
            'Mode "$mode" is not in collection "${col.id}".',
            '$cl.breakpointModes.$bp',
          );
        }
      });
      for (final (vi, v) in col.variables.indexed) {
        final vl = '$cl.variables[$vi]';
        if (!seenVars.add(v.id)) {
          _d(
            IrDiagnosticKind.duplicateId,
            'Duplicate variable id "${v.id}".',
            vl,
          );
        }
        v.valuesByMode.forEach((mode, value) {
          final ml = '$vl.valuesByMode.$mode';
          if (!modeIds.contains(mode)) {
            _d(
              IrDiagnosticKind.missingMode,
              'Mode "$mode" is not in collection "${col.id}".',
              ml,
            );
          }
          _irValue(value, ml);
          if (v.type == VariableType.fontFamily && value is StringValue) {
            _font(value.value, ml);
          }
        });
      }
    }
    _aliasCycles();
    t.textStyles.forEach((id, def) {
      final loc = 'tokens.textStyles.$id';
      _textStyle(def.style, '$loc.style');
      def.bindings.forEach((path, ref) {
        _variable(ref.variableId, '$loc.bindings.$path');
      });
    });
    t.paintStyles.forEach((id, def) {
      _paints(def.paints, 'tokens.paintStyles.$id.paints');
    });
    t.effectStyles.forEach((id, def) {
      _effects(def.effects, 'tokens.effectStyles.$id.effects');
    });
  }

  void _aliasCycles() {
    final state = <String, int>{}; // 1 = in progress, 2 = done
    void visit(String id, List<String> stack) {
      final v = _variables[id];
      if (v == null) return;
      if (state[id] == 2) return;
      if (state[id] == 1) {
        _d(
          IrDiagnosticKind.tokenCycle,
          'Variable aliases form a cycle: ${[...stack, id].join(' -> ')}.',
          'tokens.variables.$id',
        );
        return;
      }
      state[id] = 1;
      for (final value in v.valuesByMode.values) {
        if (value is TokenRefValue) {
          visit(value.value.variableId, [...stack, id]);
        }
      }
      state[id] = 2;
    }

    for (final id in _variables.keys) {
      visit(id, const []);
    }
  }

  // ---- Styles, paints, effects ------------------------------------------------

  void _textStyle(TextStyle s, String loc) {
    _font(s.fontFamilyId, '$loc.fontFamilyId');
    _paints(s.fills, '$loc.fills');
  }

  void _textOverride(TextStyleOverride s, String loc) {
    _font(s.fontFamilyId, '$loc.fontFamilyId');
    final fills = s.fills;
    if (fills != null) _paints(fills, '$loc.fills');
  }

  void _paints(List<Paint> paints, String loc) {
    _unique(paints.map((p) => p.id), loc, 'paint');
    for (final (i, p) in paints.indexed) {
      if (p is ImagePaint) {
        _asset(
          p.assetId,
          '$loc[$i].assetId',
          kinds: {AssetKind.image, AssetKind.imageSequence},
        );
      }
    }
  }

  void _effects(List<Effect> effects, String loc) {
    _unique(effects.map((e) => e.id), loc, 'effect');
  }

  void _styleRefs(
    String loc, {
    String? fill,
    String? stroke,
    String? effect,
    String? text,
    String? nodeId,
  }) {
    void check(String? id, Map<String, Object?> map, String field, String w) {
      if (id == null || map.containsKey(id)) return;
      _d(
        IrDiagnosticKind.missingStyle,
        '$w style "$id" does not exist.',
        '$loc.$field',
        nodeId: nodeId,
      );
    }

    check(fill, doc.tokens.paintStyles, 'fillStyleId', 'Paint');
    check(stroke, doc.tokens.paintStyles, 'strokeStyleId', 'Paint');
    check(effect, doc.tokens.effectStyles, 'effectStyleId', 'Effect');
    check(text, doc.tokens.textStyles, 'textStyleId', 'Text');
  }

  void _appearance(Appearance a, String loc, String nodeId) {
    _paints(a.fills, '$loc.appearance.fills');
    _paints(a.strokes.paints, '$loc.appearance.strokes.paints');
    _effects(a.effects, '$loc.appearance.effects');
    _styleRefs(
      '$loc.appearance',
      fill: a.fillStyleId,
      stroke: a.strokeStyleId,
      effect: a.effectStyleId,
      nodeId: nodeId,
    );
  }

  // ---- Values, patches --------------------------------------------------------

  void _irValue(IrValue value, String loc) {
    switch (value) {
      case TokenRefValue(:final value):
        _variable(value.variableId, loc);
      case PaintValue(:final value):
        _paints([value], loc);
      case PaintsValue(:final value):
        _paints(value, loc);
      case EffectsValue(:final value):
        _effects(value, loc);
      default:
        break;
    }
  }

  void _patch(Patch patch, String loc, String nodeId) {
    patch.forEach((path, value) {
      final pl = '$loc.$path';
      if (registry.lookup(path) == null) {
        _d(
          IrDiagnosticKind.unknownPath,
          'No property is registered at "$path".',
          pl,
          nodeId: nodeId,
          path: path,
          severity: IrSeverity.warning,
        );
      }
      _irValue(value, pl);
      if (value is StringValue) {
        final last = path.split('.').last;
        switch (last) {
          case 'fontFamilyId':
            _font(value.value, pl);
          case 'assetId' || 'posterAssetId':
            _asset(value.value, pl, nodeId: nodeId);
          case 'textStyleId' ||
                'fillStyleId' ||
                'strokeStyleId' ||
                'effectStyleId':
            _styleRefs(
              loc,
              text: last == 'textStyleId' ? value.value : null,
              fill: last == 'fillStyleId' ? value.value : null,
              stroke: last == 'strokeStyleId' ? value.value : null,
              effect: last == 'effectStyleId' ? value.value : null,
              nodeId: nodeId,
            );
        }
      }
    });
  }

  // ---- Scenes and animation ---------------------------------------------------

  void _scene(Scene s, String loc, Set<String> seen) {
    _modeMap(s.modeOverrides, '$loc.modeOverrides');
    _paints(s.background, '$loc.background');
    for (final (i, c) in s.clocks.indexed) {
      final cl = '$loc.clocks[$i]';
      switch (c) {
        case SceneScrollClock(:final sceneId):
          _sceneRef(sceneId, '$cl.sceneId');
        case AudioClock(:final audioTrackId):
          _audio(audioTrackId, '$cl.audioTrackId');
        case PointerClock(:final frameId):
          if (!_nodeIds.contains(frameId)) {
            _d(
              IrDiagnosticKind.missingNode,
              'Pointer clock frame "$frameId" does not exist.',
              '$cl.frameId',
            );
          }
        case BehaviorClock(:final nodeId):
          if (!_nodeIds.contains(nodeId)) {
            _d(
              IrDiagnosticKind.missingNode,
              'Behavior clock node "$nodeId" does not exist.',
              '$cl.nodeId',
            );
          }
        case TimelineClock():
          break;
      }
    }
    _node(s.root, '$loc.root', seen, null);
    _tracks(s, loc);
  }

  void _tracks(Scene s, String loc) {
    final index = <String, Node>{};
    _indexNodes(s.root, index);
    final overlay = doc.overlay;
    if (overlay != null) _indexNodes(overlay, index);
    final sceneClocks = {for (final c in s.clocks) c.id};
    _unique(s.tracks.map((t) => t.id), '$loc.tracks', 'track');
    for (final (i, t) in s.tracks.indexed) {
      final tl = '$loc.tracks[$i]';
      if (!sceneClocks.contains(t.clockId)) {
        _d(
          IrDiagnosticKind.missingClock,
          'Track clock "${t.clockId}" is not a clock of scene "${s.id}".',
          '$tl.clockId',
        );
      }
      if (!_targetResolves(t.target, index)) {
        _d(
          IrDiagnosticKind.missingTrackTarget,
          'Track target "${t.target}" does not exist.',
          '$tl.target',
          path: t.property,
        );
      }
      if (registry.lookup(t.property) == null) {
        _d(
          IrDiagnosticKind.unknownPath,
          'No property is registered at "${t.property}".',
          '$tl.property',
          path: t.property,
          severity: IrSeverity.warning,
        );
      }
      for (final (bi, bp) in (t.breakpoints ?? const <String>[]).indexed) {
        _breakpointRef(bp, '$tl.breakpoints[$bi]');
      }
      _unique(t.keyframes.map((k) => k.id), '$tl.keyframes', 'keyframe');
      for (final (ki, k) in t.keyframes.indexed) {
        _irValue(k.value, '$tl.keyframes[$ki].value');
      }
    }
  }

  void _indexNodes(Node n, Map<String, Node> out) {
    out.putIfAbsent(n.id, () => n);
    if (n is FrameNode) {
      for (final c in n.children) {
        _indexNodes(c, out);
      }
    }
  }

  /// Components an instance of [src] may expand to (all variants of a set).
  List<ComponentDef> _componentsOf(InstanceSource src) {
    switch (src) {
      case ComponentSource(:final componentId):
        final c = doc.components[componentId];
        return c == null ? const [] : [c];
      case VariantSource(:final variantSetId):
        final set = doc.variantSets[variantSetId];
        if (set == null) return const [];
        return [
          for (final v in set.variants)
            if (doc.components[v.componentId] != null)
              doc.components[v.componentId]!,
        ];
    }
  }

  Node? _findIn(Node root, String id) {
    if (root.id == id) return root;
    if (root is FrameNode) {
      for (final c in root.children) {
        final f = _findIn(c, id);
        if (f != null) return f;
      }
    }
    return null;
  }

  /// Whether [parts] (`innerId/innerId/...`) address a node inside one of
  /// [comps], descending through nested instances.
  bool _resolvesIn(List<ComponentDef> comps, List<String> parts) {
    for (final c in comps) {
      final n = _findIn(c.root, parts.first);
      if (n == null) continue;
      if (parts.length == 1) return true;
      if (n is InstanceNode) {
        final inner = _componentsOf(n.source);
        // An unresolvable nested component is reported on its own.
        if (inner.isEmpty || _resolvesIn(inner, parts.sublist(1))) return true;
      }
    }
    return false;
  }

  bool _targetResolves(String target, Map<String, Node> index) {
    final parts = target.split('/');
    final first = index[parts.first];
    if (first == null) return false;
    if (parts.length == 1) return true;
    if (first is! InstanceNode) return false;
    final comps = _componentsOf(first.source);
    if (comps.isEmpty) return true; // reported on the instance itself
    return _resolvesIn(comps, parts.sublist(1));
  }

  // ---- Nodes ------------------------------------------------------------------

  /// [owner]: the component whose tree [n] belongs to, if any.
  void _node(Node n, String loc, Set<String> seen, ComponentDef? owner) {
    final id = n.id;
    if (!seen.add(id)) {
      _d(
        IrDiagnosticKind.duplicateNodeId,
        owner == null
            ? 'Node id "$id" is used more than once in the document.'
            : 'Node id "$id" is used more than once in component '
                  '"${owner.id}".',
        loc,
        nodeId: id,
      );
    }
    final c = n.common;
    c.breakpointOverrides.forEach((bp, patch) {
      _breakpointRef(bp, '$loc.common.breakpointOverrides.$bp');
      _patch(patch, '$loc.common.breakpointOverrides.$bp', id);
    });
    c.bindings.forEach((path, ref) {
      _variable(ref.variableId, '$loc.common.bindings.$path', nodeId: id);
    });
    if (owner != null) {
      c.componentBindings.forEach((path, propId) {
        if (!owner.properties.containsKey(propId)) {
          _d(
            IrDiagnosticKind.missingComponentProp,
            'Component "${owner.id}" has no prop "$propId".',
            '$loc.common.componentBindings.$path',
            nodeId: id,
            path: path,
          );
        }
      });
    }
    _interactions(c.interactions, '$loc.common.interactions', id);

    switch (n) {
      case FrameNode():
        _appearance(n.appearance, loc, id);
        _modeMap(n.modeOverrides, '$loc.modeOverrides');
        final b = n.behavior;
        if (b != null) _behavior(b, '$loc.behavior', id);
        for (final (i, child) in n.children.indexed) {
          _node(child, '$loc.children[$i]', seen, owner);
        }
      case TextNode():
        _paints(n.appearance.strokes.paints, '$loc.appearance.strokes.paints');
        _effects(n.appearance.effects, '$loc.appearance.effects');
        _styleRefs(
          loc,
          text: n.textStyleId,
          stroke: n.appearance.strokeStyleId,
          effect: n.appearance.effectStyleId,
          nodeId: id,
        );
        _textOverride(n.style, '$loc.style');
        for (final (pi, p) in n.content.indexed) {
          for (final (si, s) in p.spans.indexed) {
            final sl = '$loc.content[$pi].spans[$si]';
            _textOverride(s.style, '$sl.style');
            final link = s.link;
            if (link is SceneLink) _sceneRef(link.sceneId, '$sl.link');
          }
        }
      case ShapeNode():
        _appearance(n.appearance, loc, id);
      case VideoNode():
        _appearance(n.appearance, loc, id);
        _asset(n.assetId, '$loc.assetId', kind: AssetKind.video, nodeId: id);
        _asset(
          n.posterAssetId,
          '$loc.posterAssetId',
          kind: AssetKind.image,
          nodeId: id,
        );
      case EmbedNode():
        _asset(
          n.assetId,
          '$loc.assetId',
          kinds: {AssetKind.lottie, AssetKind.rive, AssetKind.imageSequence},
          nodeId: id,
        );
        n.inputBindings.forEach((input, clockId) {
          _clock(clockId, '$loc.inputBindings.$input');
        });
        n.inputs.forEach((input, value) {
          _irValue(value, '$loc.inputs.$input');
        });
      case InstanceNode():
        _instance(n, loc);
    }
  }

  void _instance(InstanceNode n, String loc) {
    final id = n.id;
    final src = n.source;
    switch (src) {
      case ComponentSource(:final componentId):
        if (!doc.components.containsKey(componentId)) {
          _d(
            IrDiagnosticKind.missingComponent,
            'Component "$componentId" does not exist.',
            '$loc.source',
            nodeId: id,
          );
        }
      case VariantSource(:final variantSetId, :final variantValues):
        final set = doc.variantSets[variantSetId];
        if (set == null) {
          _d(
            IrDiagnosticKind.missingVariantSet,
            'Variant set "$variantSetId" does not exist.',
            '$loc.source',
            nodeId: id,
          );
        } else {
          variantValues.forEach((axis, value) {
            if (!(set.axes[axis]?.contains(value) ?? false)) {
              _d(
                IrDiagnosticKind.missingVariant,
                'Variant set "$variantSetId" has no "$axis = $value".',
                '$loc.source.variantValues.$axis',
                nodeId: id,
              );
            }
          });
        }
    }
    final comps = _componentsOf(src);
    n.propValues.forEach((propId, value) {
      final pl = '$loc.propValues.$propId';
      _irValue(value, pl);
      ComponentPropDef? def;
      for (final c in comps) {
        def ??= c.properties[propId];
      }
      if (comps.isNotEmpty && def == null) {
        _d(
          IrDiagnosticKind.missingComponentProp,
          'No component of this instance has prop "$propId".',
          pl,
          nodeId: id,
        );
      }
      if (def != null &&
          def.type == ComponentPropType.instanceSwap &&
          value is StringValue &&
          !doc.components.containsKey(value.value)) {
        _d(
          IrDiagnosticKind.missingComponent,
          'Instance swap component "${value.value}" does not exist.',
          pl,
          nodeId: id,
        );
      }
      if (def != null &&
          def.type == ComponentPropType.asset &&
          value is StringValue) {
        _asset(value.value, pl, nodeId: id);
      }
    });
    n.overrides.forEach((key, patches) {
      final ol = '$loc.overrides.$key';
      if (comps.isNotEmpty && !_resolvesIn(comps, key.split('/'))) {
        _d(
          IrDiagnosticKind.missingNode,
          'Override target "$key" does not exist in the component.',
          ol,
          nodeId: id,
        );
      }
      _patch(patches, ol, id);
    });
  }

  void _interactions(List<Interaction> list, String loc, String nodeId) {
    _unique(list.map((i) => i.id), loc, 'interaction');
    for (final (i, it) in list.indexed) {
      final il = '$loc[$i]';
      switch (it.trigger) {
        case AudioCueTrigger(:final audioTrackId):
          _audio(audioTrackId, '$il.trigger');
        case ClockReachTrigger(:final clockId):
          _clock(clockId, '$il.trigger');
        default:
          break;
      }
      for (final (ai, a) in it.actions.indexed) {
        final al = '$il.actions[$ai]';
        switch (a) {
          case PlayTimelineAction(:final clockId) ||
                PauseTimelineAction(:final clockId) ||
                ReverseTimelineAction(:final clockId) ||
                SeekTimelineAction(:final clockId):
            _clock(clockId, al);
          case PlayAudioAction(:final audioTrackId) ||
                PauseAudioAction(:final audioTrackId) ||
                SeekAudioAction(:final audioTrackId):
            _audio(audioTrackId, al);
          case SetVariableAction(:final variableId, :final value):
            _variable(variableId, al, nodeId: nodeId);
            _irValue(value, al);
          case ScrollToSceneAction(:final sceneId):
            _sceneRef(sceneId, al);
          case OpenLightboxAction(nodeId: final target):
            if (!_nodeIds.contains(target)) {
              _d(
                IrDiagnosticKind.missingNode,
                'Lightbox node "$target" does not exist.',
                al,
                nodeId: nodeId,
              );
            }
          case OpenUrlAction():
            break;
        }
      }
    }
  }

  void _behavior(Behavior b, String loc, String nodeId) {
    switch (b) {
      case TextRevealBehavior(:final clockId):
        _clock(clockId, loc);
      case LyricsBehavior(
        :final audioTrackId,
        :final activeStyle,
        :final inactiveStyle,
      ):
        _audio(audioTrackId, loc);
        _textOverride(activeStyle, '$loc.activeStyle');
        _textOverride(inactiveStyle, '$loc.inactiveStyle');
      case AudioControlsBehavior(:final audioTrackId):
        _audio(audioTrackId, loc);
      default:
        break;
    }
  }

  // ---- Components -------------------------------------------------------------

  void _components() {
    doc.components.forEach((key, c) {
      final loc = 'components.$key';
      if (c.id != key) {
        _d(
          IrDiagnosticKind.idMismatch,
          'Component key "$key" differs from its id "${c.id}".',
          loc,
        );
      }
      _node(c.root, '$loc.root', <String>{}, c);
    });
    doc.variantSets.forEach((key, set) {
      final loc = 'variantSets.$key';
      if (set.id != key) {
        _d(
          IrDiagnosticKind.idMismatch,
          'Variant set key "$key" differs from its id "${set.id}".',
          loc,
        );
      }
      for (final (i, v) in set.variants.indexed) {
        if (!doc.components.containsKey(v.componentId)) {
          _d(
            IrDiagnosticKind.missingComponent,
            'Variant component "${v.componentId}" does not exist.',
            '$loc.variants[$i].componentId',
          );
        }
        v.values.forEach((axis, value) {
          if (!(set.axes[axis]?.contains(value) ?? false)) {
            _d(
              IrDiagnosticKind.missingVariant,
              'Axis "$axis" has no value "$value".',
              '$loc.variants[$i].values.$axis',
            );
          }
        });
      }
    });
    doc.components.forEach((key, c) {
      c.properties.forEach((propId, def) {
        final v = def.defaultValue;
        final pl = 'components.$key.properties.$propId.default';
        _irValue(v, pl);
        if (def.type == ComponentPropType.instanceSwap &&
            v is StringValue &&
            !doc.components.containsKey(v.value)) {
          _d(
            IrDiagnosticKind.missingComponent,
            'Instance swap default "${v.value}" does not exist.',
            pl,
          );
        }
      });
    });
  }

  void _componentCycles() {
    final deps = <String, Set<String>>{};
    void gather(Node n, Set<String> into) {
      if (n is InstanceNode) {
        for (final c in _componentsOf(n.source)) {
          into.add(c.id);
        }
      } else if (n is FrameNode) {
        for (final c in n.children) {
          gather(c, into);
        }
      }
    }

    doc.components.forEach((key, c) {
      gather(c.root, deps.putIfAbsent(key, () => {}));
    });
    final state = <String, int>{};
    void visit(String id, List<String> stack) {
      if (state[id] == 2) return;
      if (state[id] == 1) {
        _d(
          IrDiagnosticKind.componentCycle,
          'Components contain each other: ${[...stack, id].join(' -> ')}.',
          'components.$id',
        );
        return;
      }
      state[id] = 1;
      for (final d in deps[id] ?? const <String>{}) {
        if (doc.components.containsKey(d)) visit(d, [...stack, id]);
      }
      state[id] = 2;
    }

    for (final id in deps.keys) {
      visit(id, const []);
    }
  }
}
