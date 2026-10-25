import '../components.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../interactions.dart';
import '../nodes/node.dart';
import '../nodes/node_common.dart';
import '../registry/property_registry.dart';
import '../scene.dart';
import '../tokens.dart';
import '../values/ir_value.dart';
import 'edit_core.dart';
import 'edit_result.dart';
import 'node_edits.dart';

// Pure edits of the token system (architecture §8; m3.md T3.1): variable
// collections, modes, variables (with aliases), named styles, and mode
// overrides on scenes and frames. Binding a property to a token is not here:
// it is an ordinary property write of `IrValue.tokenRef` (see `applyPatch`).
// Deleting a variable or style that is in use first replaces every use with
// its value, so nothing is left dangling. Errors leave the document
// unchanged (see [EditResult]).

/// The kinds of named style.
enum StyleKind { text, paint, effect }

// ---------------------------------------------------------------------------
// Collections and modes

/// Adds collection [c] (with its modes and variables) to the document.
EditResult addCollection(StageDocument doc, VariableCollection c) {
  if (doc.tokens.collections.any((x) => x.id == c.id)) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.duplicateId,
        'Collection id "${c.id}" is already used.',
      ),
    ]);
  }
  return _putCollection(doc, c, null);
}

/// Replaces collection [collectionId] by `change(collection)` (its id cannot
/// change). Modes, breakpoint modes, names, value types and aliases are
/// checked; use [removeMode] to drop a mode in use elsewhere.
EditResult updateCollection(
  StageDocument doc,
  String collectionId,
  VariableCollection Function(VariableCollection c) change,
) {
  final i = doc.tokens.collections.indexWhere((c) => c.id == collectionId);
  if (i < 0) return failed(doc, [_missingCollection(collectionId)]);
  final old = doc.tokens.collections[i];
  final next = change(old);
  if (identical(next, old) || next == old) return unchanged(doc);
  if (next.id != old.id) {
    return failed(doc, [
      editError(IrDiagnosticKind.invalidEdit, 'A collection id cannot change.'),
    ]);
  }
  return _putCollection(doc, next, i);
}

/// Removes collection [collectionId]. Every use of its variables is first
/// replaced by the variable's value (see [removeVariable]), and mode
/// overrides naming the collection are dropped.
EditResult removeCollection(StageDocument doc, String collectionId) {
  final c = _collection(doc, collectionId);
  if (c == null) return failed(doc, [_missingCollection(collectionId)]);
  var next = doc;
  for (final v in c.variables) {
    next = _inlineVariable(next, v.id);
  }
  next = _dropModeOverrides(next, collectionId, null);
  return EditResult(
    document: next.copyWith(
      tokens: next.tokens.copyWith(
        collections: [
          for (final x in next.tokens.collections)
            if (x.id != collectionId) x,
        ],
      ),
    ),
    changed: true,
  );
}

/// Adds [mode] to collection [collectionId]. Every variable's value in the
/// new mode starts as its value in [copyFrom] (default: the default mode).
EditResult addMode(
  StageDocument doc,
  String collectionId,
  TokenMode mode, {
  String? copyFrom,
}) => updateCollection(doc, collectionId, (c) {
  final from = copyFrom ?? c.defaultModeId;
  return c.copyWith(
    modes: [...c.modes, mode],
    variables: [
      for (final v in c.variables)
        v.copyWith(
          valuesByMode: {...v.valuesByMode, mode.id: ?v.valuesByMode[from]},
        ),
    ],
  );
});

/// Removes mode [modeId] of collection [collectionId] with its values.
///
/// The last mode cannot be removed. When it is the default, the first
/// remaining mode becomes the default. Breakpoint modes and mode overrides
/// (scenes, frames) that name it are dropped, falling back to the default.
EditResult removeMode(StageDocument doc, String collectionId, String modeId) {
  final c = _collection(doc, collectionId);
  if (c == null) return failed(doc, [_missingCollection(collectionId)]);
  if (!c.modes.any((m) => m.id == modeId)) {
    return failed(doc, [_missingMode(collectionId, modeId)]);
  }
  if (c.modes.length == 1) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        'A collection needs at least one mode.',
      ),
    ]);
  }
  final modes = [
    for (final m in c.modes)
      if (m.id != modeId) m,
  ];
  final r = updateCollection(
    doc,
    collectionId,
    (c) => c.copyWith(
      modes: modes,
      defaultModeId: c.defaultModeId == modeId
          ? modes.first.id
          : c.defaultModeId,
      breakpointModes: {
        for (final e in c.breakpointModes.entries)
          if (e.value != modeId) e.key: e.value,
      },
      variables: [
        for (final v in c.variables)
          v.copyWith(
            valuesByMode: {
              for (final e in v.valuesByMode.entries)
                if (e.key != modeId) e.key: e.value,
            },
          ),
      ],
    ),
  );
  if (!r.ok) return r;
  return r.copyWith(
    document: _dropModeOverrides(r.document, collectionId, modeId),
  );
}

/// Sets the mode override of collection [collectionId] on scene [sceneId]
/// (exactly one of [sceneId] and [nodeId]) or on frame [nodeId]. A null
/// [modeId] removes it (Auto: inherit).
EditResult setModeOverride(
  StageDocument doc,
  String collectionId,
  String? modeId, {
  String? sceneId,
  String? nodeId,
}) {
  assert((sceneId == null) != (nodeId == null));
  final c = _collection(doc, collectionId);
  if (c == null) return failed(doc, [_missingCollection(collectionId)]);
  if (modeId != null && !c.modes.any((m) => m.id == modeId)) {
    return failed(doc, [_missingMode(collectionId, modeId)]);
  }
  Map<String, String> apply(Map<String, String> m) => {
    for (final e in m.entries)
      if (e.key != collectionId) e.key: e.value,
    collectionId: ?modeId,
  };
  if (sceneId != null) {
    final i = doc.scenes.indexWhere((s) => s.id == sceneId);
    if (i < 0) {
      return failed(doc, [
        editError(
          IrDiagnosticKind.missingScene,
          'Scene "$sceneId" does not exist.',
        ),
      ]);
    }
    final s = doc.scenes[i];
    if (s.modeOverrides[collectionId] == modeId) return unchanged(doc);
    return EditResult(
      document: doc.copyWith(
        scenes: [...doc.scenes]
          ..[i] = s.copyWith(modeOverrides: apply(s.modeOverrides)),
      ),
      changed: true,
    );
  }
  final failures = <IrDiagnostic>[];
  final r = updateNode(doc, nodeId!, (n) {
    if (n is! FrameNode) {
      failures.add(
        editError(
          IrDiagnosticKind.invalidEdit,
          'Only frames carry mode overrides.',
          nodeId: nodeId,
        ),
      );
      return n;
    }
    if (n.modeOverrides[collectionId] == modeId) return n;
    return n.copyWith(modeOverrides: apply(n.modeOverrides));
  });
  return failures.isEmpty ? r : failed(doc, failures);
}

// ---------------------------------------------------------------------------
// Variables

/// Adds variable [v] to collection [collectionId].
EditResult addVariable(StageDocument doc, String collectionId, Variable v) {
  if (_variable(doc, v.id) != null) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.duplicateId,
        'Variable id "${v.id}" is already used.',
      ),
    ]);
  }
  return updateCollection(
    doc,
    collectionId,
    (c) => c.copyWith(variables: [...c.variables, v]),
  );
}

/// Replaces variable [variableId] by `change(variable)` (its id cannot
/// change). Names stay unique in the collection, values fit the type,
/// aliases point at existing variables of the same type without cycles.
EditResult updateVariable(
  StageDocument doc,
  String variableId,
  Variable Function(Variable v) change,
) {
  final c = _collectionOf(doc, variableId);
  if (c == null) return failed(doc, [_missingVariable(variableId)]);
  return updateCollection(
    doc,
    c.id,
    (c) => c.copyWith(
      variables: [
        for (final v in c.variables) v.id == variableId ? change(v) : v,
      ],
    ),
  );
}

/// Sets variable [variableId]'s value in mode [modeId] (a concrete value or
/// an alias `IrValue.tokenRef`).
EditResult setVariableValue(
  StageDocument doc,
  String variableId,
  String modeId,
  IrValue value,
) => updateVariable(
  doc,
  variableId,
  (v) => v.copyWith(valuesByMode: {...v.valuesByMode, modeId: value}),
);

/// Removes variable [variableId]. Every use is first replaced by its value:
/// bindings and patch values by its default-mode value, aliases by its value
/// in the same mode (or the default), `setVariable` actions dropped. See
/// [variableUseCount].
EditResult removeVariable(StageDocument doc, String variableId) {
  final c = _collectionOf(doc, variableId);
  if (c == null) return failed(doc, [_missingVariable(variableId)]);
  final next = _inlineVariable(doc, variableId);
  return EditResult(
    document: next.copyWith(
      tokens: next.tokens.copyWith(
        collections: [
          for (final x in next.tokens.collections)
            x.id == c.id
                ? x.copyWith(
                    variables: [
                      for (final v in x.variables)
                        if (v.id != variableId) v,
                    ],
                  )
                : x,
        ],
      ),
    ),
    changed: true,
  );
}

/// How many places use variable [variableId]: node and text-style bindings,
/// patch and override values, instance prop values, keyframes, component
/// prop defaults, aliases of other variables and `setVariable` actions.
int variableUseCount(StageDocument doc, String variableId) {
  var n = 0;
  bool isRef(IrValue v) =>
      v is TokenRefValue && v.value.variableId == variableId;
  void countPatch(Patch p) => n += p.values.where(isRef).length;
  _forEachNode(doc, (node) {
    final c = node.common;
    n += c.bindings.values.where((r) => r.variableId == variableId).length;
    c.breakpointOverrides.values.forEach(countPatch);
    for (final i in c.interactions) {
      n += i.actions
          .where((a) => a is SetVariableAction && a.variableId == variableId)
          .length;
    }
    if (node is InstanceNode) {
      node.overrides.values.forEach(countPatch);
      countPatch(node.propValues);
    }
  });
  for (final s in doc.scenes) {
    for (final t in s.tracks) {
      n += t.keyframes.where((k) => isRef(k.value)).length;
    }
  }
  for (final def in doc.tokens.textStyles.values) {
    n += def.bindings.values.where((r) => r.variableId == variableId).length;
  }
  for (final comp in doc.components.values) {
    n += comp.properties.values.where((p) => isRef(p.defaultValue)).length;
  }
  for (final col in doc.tokens.collections) {
    for (final v in col.variables) {
      if (v.id != variableId) n += v.valuesByMode.values.where(isRef).length;
    }
  }
  return n;
}

// ---------------------------------------------------------------------------
// Styles

/// Adds or replaces text style [id]. Names are unique among text styles;
/// its token bindings must name existing variables.
EditResult setTextStyle(StageDocument doc, String id, TextStyleDef def) {
  final diags = [
    ..._checkStyleName(doc.tokens.textStyles, id, def.name),
    for (final ref in def.bindings.values)
      if (_variable(doc, ref.variableId) == null)
        _missingVariable(ref.variableId),
  ];
  if (diags.isNotEmpty) return failed(doc, diags);
  if (doc.tokens.textStyles[id] == def) return unchanged(doc);
  return _withTokens(
    doc,
    doc.tokens.copyWith(textStyles: {...doc.tokens.textStyles, id: def}),
  );
}

/// Adds or replaces paint style [id] (names unique among paint styles).
EditResult setPaintStyle(StageDocument doc, String id, PaintStyleDef def) {
  final diags = _checkStyleName(doc.tokens.paintStyles, id, def.name);
  if (diags.isNotEmpty) return failed(doc, diags);
  if (doc.tokens.paintStyles[id] == def) return unchanged(doc);
  return _withTokens(
    doc,
    doc.tokens.copyWith(paintStyles: {...doc.tokens.paintStyles, id: def}),
  );
}

/// Adds or replaces effect style [id] (names unique among effect styles).
EditResult setEffectStyle(StageDocument doc, String id, EffectStyleDef def) {
  final diags = _checkStyleName(doc.tokens.effectStyles, id, def.name);
  if (diags.isNotEmpty) return failed(doc, diags);
  if (doc.tokens.effectStyles[id] == def) return unchanged(doc);
  return _withTokens(
    doc,
    doc.tokens.copyWith(effectStyles: {...doc.tokens.effectStyles, id: def}),
  );
}

/// The registry paths that reference a style of [kind].
List<String> styleRefPaths(StyleKind kind) => switch (kind) {
  StyleKind.text => const ['textStyleId'],
  StyleKind.paint => const ['fillStyleId', 'strokeStyleId'],
  StyleKind.effect => const ['effectStyleId'],
};

/// How many nodes (and breakpoint patches or instance overrides) apply
/// style [id] of [kind].
int styleUseCount(StageDocument doc, StyleKind kind, String id) {
  final reg = PropertyRegistry.standard;
  final paths = styleRefPaths(kind);
  var n = 0;
  bool isRef(IrValue? v) => v is StringValue && v.value == id;
  void countPatch(Patch p) {
    for (final path in paths) {
      if (isRef(p[path])) n++;
    }
  }

  _forEachNode(doc, (node) {
    for (final path in paths) {
      if (isRef(reg.get(node, path))) n++;
    }
    node.common.breakpointOverrides.values.forEach(countPatch);
    if (node is InstanceNode) node.overrides.values.forEach(countPatch);
  });
  return n;
}

/// Removes style [id] of [kind]. Nodes that apply it are detached first:
/// they get the style's values as local values (a text node's own
/// overrides keep winning, and the style's token bindings move onto the
/// node). Breakpoint patches and instance overrides that select it are
/// dropped, so those breakpoints show the detached base.
EditResult removeStyle(StageDocument doc, StyleKind kind, String id) {
  final t = doc.tokens;
  final exists = switch (kind) {
    StyleKind.text => t.textStyles.containsKey(id),
    StyleKind.paint => t.paintStyles.containsKey(id),
    StyleKind.effect => t.effectStyles.containsKey(id),
  };
  if (!exists) {
    return failed(doc, [
      editError(IrDiagnosticKind.missingStyle, 'Style "$id" does not exist.'),
    ]);
  }
  final reg = PropertyRegistry.standard;
  final paths = styleRefPaths(kind);
  bool isRef(String key, IrValue v) =>
      paths.contains(key) && v is StringValue && v.value == id;
  Patch dropRefs(Patch p) {
    if (!p.entries.any((e) => isRef(e.key, e.value))) return p;
    return {
      for (final e in p.entries)
        if (!isRef(e.key, e.value)) e.key: e.value,
    };
  }

  Map<String, Patch> dropAll(Map<String, Patch> m) {
    var changed = false;
    final out = <String, Patch>{};
    for (final e in m.entries) {
      final p = dropRefs(e.value);
      changed |= !identical(p, e.value);
      if (p.isNotEmpty) out[e.key] = p;
    }
    return changed ? out : m;
  }

  final next = _mapNodes(doc, (node) {
    var n = node;
    for (final path in paths) {
      final v = reg.get(n, path);
      if (v is StringValue && v.value == id) {
        n = detachStyle(doc, n, path);
      }
    }
    final bo = dropAll(n.common.breakpointOverrides);
    if (!identical(bo, n.common.breakpointOverrides)) {
      n = n.copyWith(common: n.common.copyWith(breakpointOverrides: bo));
    }
    if (n is InstanceNode) {
      final o = dropAll(n.overrides);
      if (!identical(o, n.overrides)) n = n.copyWith(overrides: o);
    }
    return n;
  });
  final nt = next.tokens;
  return _withTokens(next, switch (kind) {
    StyleKind.text => nt.copyWith(textStyles: {...nt.textStyles}..remove(id)),
    StyleKind.paint => nt.copyWith(
      paintStyles: {...nt.paintStyles}..remove(id),
    ),
    StyleKind.effect => nt.copyWith(
      effectStyles: {...nt.effectStyles}..remove(id),
    ),
  });
}

/// [node] with the style it applies at [stylePath] (`textStyleId`,
/// `fillStyleId`, `strokeStyleId` or `effectStyleId`) replaced by the
/// style's values as local values. A text style's fields fill only the
/// fields the node does not override itself, and its token bindings move
/// onto the node. Unchanged when the path holds no known style.
Node detachStyle(StageDocument doc, Node node, String stylePath) {
  final reg = PropertyRegistry.standard;
  final v = reg.get(node, stylePath);
  if (v is! StringValue) return node;
  final id = v.value;
  final t = doc.tokens;
  Node set(Node n, String path, IrValue value) =>
      reg.lookup(path)?.trySet(n, value) ?? n;
  var n = set(node, stylePath, const IrValue.none());
  switch (stylePath) {
    case 'textStyleId':
      final def = t.textStyles[id];
      if (def == null || n is! TextNode) return n;
      final carrier = TextNode(common: n.common, style: def.style);
      final bindings = {...n.common.bindings};
      for (final MapEntry(:key, :value) in def.style.toJson().entries) {
        if (value == null) continue;
        final path = 'style.$key';
        final own = reg.get(n, path);
        if (own != null && own is! NoneValue) continue;
        final styleValue = reg.get(carrier, path);
        if (styleValue != null) n = set(n, path, styleValue);
      }
      for (final MapEntry(:key, :value) in def.bindings.entries) {
        final path = 'style.$key';
        final own = node is TextNode ? reg.get(node, path) : null;
        if (own == null || own is NoneValue) bindings[path] = value;
      }
      return n.copyWith(common: n.common.copyWith(bindings: bindings));
    case 'fillStyleId':
      final def = t.paintStyles[id];
      return def == null ? n : set(n, 'fills', IrValue.paints(def.paints));
    case 'strokeStyleId':
      final def = t.paintStyles[id];
      return def == null
          ? n
          : set(n, 'strokes.paints', IrValue.paints(def.paints));
    case 'effectStyleId':
      final def = t.effectStyles[id];
      return def == null ? n : set(n, 'effects', IrValue.effects(def.effects));
  }
  return n;
}

// ---------------------------------------------------------------------------
// Internals

VariableCollection? _collection(StageDocument doc, String id) {
  for (final c in doc.tokens.collections) {
    if (c.id == id) return c;
  }
  return null;
}

VariableCollection? _collectionOf(StageDocument doc, String variableId) {
  for (final c in doc.tokens.collections) {
    if (c.variables.any((v) => v.id == variableId)) return c;
  }
  return null;
}

Variable? _variable(StageDocument doc, String id) {
  for (final c in doc.tokens.collections) {
    for (final v in c.variables) {
      if (v.id == id) return v;
    }
  }
  return null;
}

IrDiagnostic _missingCollection(String id) => editError(
  IrDiagnosticKind.missingToken,
  'Collection "$id" does not exist.',
);

IrDiagnostic _missingVariable(String id) =>
    editError(IrDiagnosticKind.missingToken, 'Variable "$id" does not exist.');

IrDiagnostic _missingMode(String collectionId, String modeId) => editError(
  IrDiagnosticKind.missingMode,
  'Collection "$collectionId" has no mode "$modeId".',
);

EditResult _withTokens(StageDocument doc, TokenSystem tokens) =>
    EditResult(document: doc.copyWith(tokens: tokens), changed: true);

List<IrDiagnostic> _checkStyleName<T>(
  Map<String, T> styles,
  String id,
  String name,
) {
  String nameOf(T s) => switch (s) {
    TextStyleDef(:final name) => name,
    PaintStyleDef(:final name) => name,
    EffectStyleDef(:final name) => name,
    _ => '',
  };
  if (name.trim().isEmpty) {
    return [editError(IrDiagnosticKind.invalidEdit, 'A style needs a name.')];
  }
  for (final MapEntry(:key, :value) in styles.entries) {
    if (key != id && nameOf(value) == name) {
      return [
        editError(
          IrDiagnosticKind.invalidEdit,
          'A style named "$name" already exists.',
        ),
      ];
    }
  }
  return const [];
}

/// Whether [value] fits a variable of [type] (aliases are checked apart).
bool valueFitsVariable(VariableType type, IrValue value) => switch (type) {
  VariableType.color => value is ColorValue,
  VariableType.number => value is NumberValue,
  VariableType.string || VariableType.fontFamily => value is StringValue,
  VariableType.boolean => value is BoolValue,
};

/// Writes collection [c] at index [at] (or appends it), checking it against
/// the rest of the document.
EditResult _putCollection(StageDocument doc, VariableCollection c, int? at) {
  final diags = <IrDiagnostic>[];
  final others = [
    for (final (i, x) in doc.tokens.collections.indexed)
      if (i != at) x,
  ];
  if (c.name.trim().isEmpty) {
    diags.add(
      editError(IrDiagnosticKind.invalidEdit, 'A collection needs a name.'),
    );
  }
  if (others.any((x) => x.name == c.name)) {
    diags.add(
      editError(
        IrDiagnosticKind.invalidEdit,
        'A collection named "${c.name}" already exists.',
      ),
    );
  }
  final modeIds = {for (final m in c.modes) m.id};
  if (c.modes.isEmpty || modeIds.length != c.modes.length) {
    diags.add(
      editError(
        IrDiagnosticKind.invalidEdit,
        'A collection needs at least one mode, with unique ids.',
      ),
    );
  }
  if (!modeIds.contains(c.defaultModeId)) {
    diags.add(_missingMode(c.id, c.defaultModeId));
  }
  final bps = {for (final b in doc.breakpoints) b.id};
  for (final MapEntry(:key, :value) in c.breakpointModes.entries) {
    if (!bps.contains(key)) {
      diags.add(
        editError(
          IrDiagnosticKind.missingBreakpoint,
          'Breakpoint "$key" does not exist.',
        ),
      );
    }
    if (!modeIds.contains(value)) diags.add(_missingMode(c.id, value));
  }
  // Variables: ids unique document-wide, names unique in the collection.
  final all = <String, Variable>{
    for (final x in others)
      for (final v in x.variables) v.id: v,
  };
  final names = <String>{};
  for (final v in c.variables) {
    if (all.containsKey(v.id)) {
      diags.add(
        editError(
          IrDiagnosticKind.duplicateId,
          'Variable id "${v.id}" is already used.',
        ),
      );
    }
    all[v.id] = v;
    if (v.name.trim().isEmpty || !names.add(v.name)) {
      diags.add(
        editError(
          IrDiagnosticKind.invalidEdit,
          v.name.trim().isEmpty
              ? 'A variable needs a name.'
              : 'A variable named "${v.name}" already exists in '
                    '"${c.name}".',
        ),
      );
    }
  }
  for (final v in c.variables) {
    for (final MapEntry(key: mode, :value) in v.valuesByMode.entries) {
      if (!modeIds.contains(mode)) {
        diags.add(_missingMode(c.id, mode));
      } else if (value is TokenRefValue) {
        final target = all[value.value.variableId];
        if (target == null) {
          diags.add(_missingVariable(value.value.variableId));
        } else if (target.type != v.type) {
          diags.add(
            editError(
              IrDiagnosticKind.invalidEdit,
              '"${v.name}" (${v.type.name}) cannot alias "${target.name}" '
              '(${target.type.name}).',
            ),
          );
        }
      } else if (!valueFitsVariable(v.type, value)) {
        diags.add(
          editError(
            IrDiagnosticKind.invalidEdit,
            'A ${v.type.name} variable cannot hold this value.',
          ),
        );
      }
    }
  }
  if (diags.isEmpty) {
    final cycle = _aliasCycle(all);
    if (cycle != null) {
      diags.add(
        editError(
          IrDiagnosticKind.tokenCycle,
          'Variable aliases would form a cycle: ${cycle.join(' -> ')}.',
        ),
      );
    }
  }
  if (diags.isNotEmpty) return failed(doc, diags);
  final list = [...doc.tokens.collections];
  if (at == null) {
    list.add(c);
  } else {
    list[at] = c;
  }
  return _withTokens(doc, doc.tokens.copyWith(collections: list));
}

/// The first alias cycle among [vars] (as variable names), or null.
List<String>? _aliasCycle(Map<String, Variable> vars) {
  final state = <String, int>{};
  List<String>? visit(String id, List<String> stack) {
    final v = vars[id];
    if (v == null || state[id] == 2) return null;
    if (state[id] == 1) return [...stack, v.name];
    state[id] = 1;
    for (final value in v.valuesByMode.values) {
      if (value is TokenRefValue) {
        final c = visit(value.value.variableId, [...stack, v.name]);
        if (c != null) return c;
      }
    }
    state[id] = 2;
    return null;
  }

  for (final id in vars.keys) {
    final c = visit(id, const []);
    if (c != null) return c;
  }
  return null;
}

/// The concrete value of variable [id] in [modeId] (default: its default
/// mode), following aliases at their collections' default modes. Null when
/// it has none.
IrValue? concreteVariableValue(StageDocument doc, String id, [String? modeId]) {
  final seen = <String>{};
  var mode = modeId;
  var cur = id;
  while (seen.add(cur)) {
    final c = _collectionOf(doc, cur);
    if (c == null) return null;
    final v = c.variables.firstWhere((v) => v.id == cur);
    final value =
        v.valuesByMode[mode ?? c.defaultModeId] ??
        v.valuesByMode[c.defaultModeId];
    if (value is! TokenRefValue) return value;
    cur = value.value.variableId;
    mode = null;
  }
  return null;
}

/// [doc] with every use of variable [id] replaced by its value (see
/// [removeVariable]). The variable itself stays.
StageDocument _inlineVariable(StageDocument doc, String id) {
  final reg = PropertyRegistry.standard;
  final lit = concreteVariableValue(doc, id) ?? const IrValue.none();
  IrValue sub(IrValue v) =>
      v is TokenRefValue && v.value.variableId == id ? lit : v;
  Patch subPatch(Patch p) => p.values.any((v) => !identical(sub(v), v))
      ? {for (final e in p.entries) e.key: sub(e.value)}
      : p;
  Map<String, Patch> subPatches(Map<String, Patch> m) =>
      m.values.any((p) => !identical(subPatch(p), p))
      ? {for (final e in m.entries) e.key: subPatch(e.value)}
      : m;

  var next = _mapNodes(doc, (node) {
    var n = node;
    final bound = [
      for (final e in n.common.bindings.entries)
        if (e.value.variableId == id) e.key,
    ];
    if (bound.isNotEmpty) {
      n = n.copyWith(
        common: n.common.copyWith(
          bindings: {...n.common.bindings}
            ..removeWhere((k, _) => bound.contains(k)),
        ),
      );
      if (lit is! NoneValue) {
        for (final path in bound) {
          n = reg.lookup(path)?.trySet(n, lit) ?? n;
        }
      }
    }
    final bo = subPatches(n.common.breakpointOverrides);
    final acts = n.common.interactions.any(
      (i) => i.actions.any((a) => a is SetVariableAction && a.variableId == id),
    );
    if (!identical(bo, n.common.breakpointOverrides) || acts) {
      n = n.copyWith(
        common: n.common.copyWith(
          breakpointOverrides: bo,
          interactions: acts
              ? [
                  for (final i in n.common.interactions)
                    i.copyWith(
                      actions: [
                        for (final a in i.actions)
                          if (!(a is SetVariableAction && a.variableId == id))
                            a,
                      ],
                    ),
                ]
              : n.common.interactions,
        ),
      );
    }
    if (n is InstanceNode) {
      final o = subPatches(n.overrides);
      final pv = subPatch(n.propValues);
      if (!identical(o, n.overrides) || !identical(pv, n.propValues)) {
        n = n.copyWith(overrides: o, propValues: pv);
      }
    }
    return n;
  });

  // Keyframes.
  if (next.scenes.any(
    (s) => s.tracks.any(
      (t) => t.keyframes.any((k) => !identical(sub(k.value), k.value)),
    ),
  )) {
    next = next.copyWith(
      scenes: [
        for (final s in next.scenes)
          s.copyWith(
            tracks: [
              for (final t in s.tracks)
                t.keyframes.any((k) => !identical(sub(k.value), k.value))
                    ? t.copyWith(
                        keyframes: [
                          for (final k in t.keyframes)
                            k.copyWith(value: sub(k.value)),
                        ],
                      )
                    : t,
            ],
          ),
      ],
    );
  }

  // Text style bindings: the style takes the value as its own.
  final styles = <String, TextStyleDef>{};
  for (final MapEntry(key: sid, value: def) in next.tokens.textStyles.entries) {
    final keys = [
      for (final e in def.bindings.entries)
        if (e.value.variableId == id) e.key,
    ];
    if (keys.isEmpty) {
      styles[sid] = def;
      continue;
    }
    Node carrier = TextNode(
      common: const NodeCommon(id: '_'),
      style: def.style,
    );
    if (lit is! NoneValue) {
      for (final k in keys) {
        carrier = reg.lookup('style.$k')?.trySet(carrier, lit) ?? carrier;
      }
    }
    styles[sid] = def.copyWith(
      style: (carrier as TextNode).style,
      bindings: {...def.bindings}..removeWhere((k, _) => keys.contains(k)),
    );
  }

  // Component prop defaults.
  final comps = {
    for (final MapEntry(:key, :value) in next.components.entries)
      key:
          value.properties.values.any(
            (p) => !identical(sub(p.defaultValue), p.defaultValue),
          )
          ? value.copyWith(
              properties: {
                for (final e in value.properties.entries)
                  e.key: e.value.copyWith(
                    defaultValue: sub(e.value.defaultValue),
                  ),
              },
            )
          : value,
  };

  // Aliases: the value in the same mode when the alias shares the
  // collection, else the default-mode value.
  final owner = _collectionOf(next, id);
  final collections = [
    for (final c in next.tokens.collections)
      c.copyWith(
        variables: [
          for (final v in c.variables)
            v.valuesByMode.values.any((x) => !identical(sub(x), x))
                ? v.copyWith(
                    valuesByMode: {
                      for (final MapEntry(key: m, value: x)
                          in v.valuesByMode.entries)
                        m: identical(sub(x), x)
                            ? x
                            : (c.id == owner?.id
                                      ? _rawValue(next, id, m)
                                      : null) ??
                                  lit,
                    },
                  )
                : v,
        ],
      ),
  ];
  return next.copyWith(
    components: comps,
    tokens: next.tokens.copyWith(collections: collections, textStyles: styles),
  );
}

/// Variable [id]'s own value in [modeId] (possibly an alias), or null.
IrValue? _rawValue(StageDocument doc, String id, String modeId) =>
    _variable(doc, id)?.valuesByMode[modeId];

/// Drops mode overrides of collection [collectionId] (only those selecting
/// [modeId], when given) from scenes and frames.
StageDocument _dropModeOverrides(
  StageDocument doc,
  String collectionId,
  String? modeId,
) {
  bool hit(Map<String, String> m) =>
      m.containsKey(collectionId) &&
      (modeId == null || m[collectionId] == modeId);
  Map<String, String> drop(Map<String, String> m) =>
      {...m}..remove(collectionId);
  final next = _mapNodes(
    doc,
    (n) => n is FrameNode && hit(n.modeOverrides)
        ? n.copyWith(modeOverrides: drop(n.modeOverrides))
        : n,
  );
  if (!next.scenes.any((s) => hit(s.modeOverrides))) return next;
  return next.copyWith(
    scenes: [
      for (final s in next.scenes)
        hit(s.modeOverrides)
            ? s.copyWith(modeOverrides: drop(s.modeOverrides))
            : s,
    ],
  );
}

/// Calls [f] on every authored node: scene trees, the overlay and
/// component roots.
void _forEachNode(StageDocument doc, void Function(Node n) f) {
  void visit(Node n) {
    f(n);
    if (n is FrameNode) n.children.forEach(visit);
  }

  for (final s in doc.scenes) {
    visit(s.root);
  }
  if (doc.overlay case final o?) visit(o);
  for (final c in doc.components.values) {
    visit(c.root);
  }
}

/// [doc] with every authored node (scene trees, overlay, component roots)
/// mapped bottom-up through [f]. Untouched subtrees, scenes and components
/// keep their identity.
StageDocument _mapNodes(StageDocument doc, Node Function(Node n) f) {
  Node visit(Node n) {
    var out = n;
    if (n is FrameNode) {
      final kids = [for (final c in n.children) visit(c)];
      if (!sameElements(kids, n.children)) out = n.copyWith(children: kids);
    }
    return f(out);
  }

  var changed = false;
  final scenes = <Scene>[];
  for (final s in doc.scenes) {
    final r = visit(s.root);
    if (identical(r, s.root)) {
      scenes.add(s);
    } else {
      changed = true;
      scenes.add(s.copyWith(root: r as FrameNode));
    }
  }
  final overlay = doc.overlay == null ? null : visit(doc.overlay!);
  changed |= !identical(overlay, doc.overlay);
  final comps = <String, ComponentDef>{};
  for (final MapEntry(:key, :value) in doc.components.entries) {
    final r = visit(value.root);
    if (identical(r, value.root)) {
      comps[key] = value;
    } else {
      changed = true;
      comps[key] = value.copyWith(root: r as FrameNode);
    }
  }
  if (!changed) return doc;
  return doc.copyWith(
    scenes: scenes,
    overlay: overlay as FrameNode?,
    components: comps,
  );
}
