import 'package:soundstage_platform/ir/ir.dart' as ir;

// What the agent may do unasked (DECISIONS 26/10/26 #12): without being
// asked it only suggests; its suggestions can be anything. The author can
// let suggestions of chosen kinds apply themselves (auto-act), within
// boundaries the author sets. Asked in the chat, the agent acts.

/// The kinds of change an action makes.
enum AgentActionKind {
  text('Rewrite text'),
  style('Restyle (colour, type, opacity, corners)'),
  layout('Move and resize'),
  structure('Add or delete layers and scenes'),
  notes('Leave notes'),
  illustration('Draw illustrations');

  const AgentActionKind(this.label);

  final String label;
}

/// Where auto-applied changes may land.
enum AgentScope {
  selection('The selection only'),
  scene('The active scene'),
  story('Anywhere in the story');

  const AgentScope(this.label);

  final String label;
}

/// The author's rules for the agent's unasked help.
class AgentPolicy {
  const AgentPolicy({
    this.watch = false,
    this.autoAct = const {},
    this.scope = AgentScope.scene,
    this.maxChanges = 5,
  });

  factory AgentPolicy.fromJson(Map<String, Object?> m) => AgentPolicy(
    watch: m['watch'] == true,
    autoAct: {
      for (final n in (m['autoAct'] as List?) ?? const [])
        ...AgentActionKind.values.where((k) => k.name == n),
    },
    scope: AgentScope.values.firstWhere(
      (s) => s.name == m['scope'],
      orElse: () => AgentScope.scene,
    ),
    maxChanges: (m['maxChanges'] as num?)?.toInt() ?? 5,
  );

  /// Review the story while the author works and suggest.
  final bool watch;

  /// Kinds of change a suggestion may apply without a click.
  final Set<AgentActionKind> autoAct;

  /// Where an auto-applied change may land.
  final AgentScope scope;

  /// The most changes one suggestion may auto-apply.
  final int maxChanges;

  AgentPolicy copyWith({
    bool? watch,
    Set<AgentActionKind>? autoAct,
    AgentScope? scope,
    int? maxChanges,
  }) => AgentPolicy(
    watch: watch ?? this.watch,
    autoAct: autoAct ?? this.autoAct,
    scope: scope ?? this.scope,
    maxChanges: maxChanges ?? this.maxChanges,
  );

  Map<String, Object?> toJson() => {
    'watch': watch,
    'autoAct': [for (final k in autoAct) k.name],
    'scope': scope.name,
    'maxChanges': maxChanges,
  };

  /// Whether a suggestion made of [actions] may apply itself in [state]'s
  /// document with [selection] and [activeSceneId].
  bool allowsAuto(
    List<AgentAction> actions, {
    required ir.StageDocument document,
    required Set<String> selection,
    required String? activeSceneId,
  }) {
    if (actions.isEmpty || actions.length > maxChanges) return false;
    for (final a in actions) {
      final kind = kindOf(a.tool, a.input);
      if (kind == null) continue; // a read
      if (!autoAct.contains(kind)) return false;
      if (!_inScope(a, document, selection, activeSceneId)) return false;
    }
    return true;
  }

  bool _inScope(
    AgentAction a,
    ir.StageDocument doc,
    Set<String> selection,
    String? activeSceneId,
  ) {
    if (scope == AgentScope.story) return true;
    final index = ir.DocumentIndex.of(doc);
    final targets = targetsOf(a.input);
    if (a.tool == 'add_scene') return false; // a new scene is outside both
    if (targets.isEmpty) {
      // Adds to the active stage by default.
      return scope == AgentScope.scene;
    }
    for (final id in targets) {
      final nodeId = id.split('/').first;
      if (scope == AgentScope.scene) {
        final scene = index.sceneIndexOf(id) != null
            ? id
            : index.locate(nodeId)?.sceneId;
        if (scene == null || scene != activeSceneId) return false;
      } else {
        final at = index.locate(nodeId);
        final inside =
            selection.contains(nodeId) ||
            (at?.ancestorIds.any(selection.contains) ?? false);
        if (!inside) return false;
      }
    }
    return true;
  }
}

/// One action a suggestion proposes: a tool and its input.
class AgentAction {
  const AgentAction(this.tool, this.input);

  final String tool;
  final Map<String, Object?> input;

  Map<String, Object?> toJson() => {'tool': tool, 'input': input};
}

/// The ids an action's input names (layers, scenes, parents).
List<String> targetsOf(Map<String, Object?> input) => [
  for (final key in const ['node_id', 'id', 'parent_id'])
    if (input[key] case final String v) v,
  if (input['node_ids'] case final List<Object?> ids)
    for (final v in ids)
      if (v is String) v,
];

/// The kind of change [tool] makes with [input]; null for reads.
AgentActionKind? kindOf(String tool, Map<String, Object?> input) =>
    switch (tool) {
      'set_text' => AgentActionKind.text,
      'set_properties' =>
        const ['x', 'y', 'width', 'height', 'rotation'].any(input.containsKey)
            ? AgentActionKind.layout
            : (input.keys.every((k) => k == 'node_ids' || k == 'name')
                  ? AgentActionKind.text
                  : AgentActionKind.style),
      'add_layer' ||
      'delete_layers' ||
      'add_scene' => AgentActionKind.structure,
      'set_note' => AgentActionKind.notes,
      'add_illustration' => AgentActionKind.illustration,
      _ => null,
    };
