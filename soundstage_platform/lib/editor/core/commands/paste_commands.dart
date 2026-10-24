import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';
import 'scoped_insert.dart';

/// What a paste brings into the document besides the nodes: the assets,
/// font families and named styles they use (already stored and with ids
/// valid in the target document), and the nodes as IR JSON whose
/// references already use those ids. Node ids are still the source's: the
/// command gives every node a fresh one.
class PastePayload {
  const PastePayload({
    required this.nodes,
    this.sourceDocId = '',
    this.assets = const {},
    this.fonts = const {},
    this.textStyles = const {},
    this.paintStyles = const {},
    this.effectStyles = const {},
  });

  final List<Map<String, dynamic>> nodes;

  /// The story the nodes came from; the same story keeps components,
  /// clocks and breakpoint patches, another story drops what it lacks.
  final String sourceDocId;
  final Map<String, ir.Asset> assets;
  final Map<String, ir.FontFamily> fonts;
  final Map<String, ir.TextStyleDef> textStyles;
  final Map<String, ir.PaintStyleDef> paintStyles;
  final Map<String, ir.EffectStyleDef> effectStyles;
}

/// Pastes [payload] into frame [parentId] at child [index] (null: on top)
/// and selects the new nodes, in one undo step.
///
/// - Every pasted node gets a new id (`IdGenerator.forDocument`).
/// - [dx]/[dy] move the nodes that are placed by constraints (not those in
///   an auto-layout flow): the "paste in the same place" offset.
/// - [replaceIds] are removed in the same step ("paste to replace"); the
///   new nodes take the first replaced node's parent and place.
/// - Nodes pasted into another story lose what only exists in the source:
///   behaviours, clock and audio interactions, token bindings, patches
///   for breakpoints the story lacks, and instances (components do not
///   travel).
class PasteNodes extends EditCommand {
  PasteNodes(
    this.payload,
    this.parentId, {
    this.index,
    this.dx = 0,
    this.dy = 0,
    this.replaceIds = const [],
    this.ids,
  });

  final PastePayload payload;
  final String parentId;
  final int? index;
  final double dx, dy;
  final List<String> replaceIds;
  final ir.IdGenerator? ids;

  @override
  String get label => replaceIds.isEmpty ? 'Paste' : 'Paste to replace';

  @override
  CommandResult apply(EditorState state) {
    var doc = state.document;
    final same = payload.sourceDocId == doc.id;
    doc = doc.copyWith(
      assets: {...doc.assets, ...payload.assets},
      fonts: {...doc.fonts, ...payload.fonts},
      tokens: doc.tokens.copyWith(
        textStyles: {...doc.tokens.textStyles, ...payload.textStyles},
        paintStyles: {...doc.tokens.paintStyles, ...payload.paintStyles},
        effectStyles: {...doc.tokens.effectStyles, ...payload.effectStyles},
      ),
    );
    final gen = ids ?? ir.IdGenerator.forDocument(doc);
    final idMap = <String, String>{};
    final bps = {for (final b in doc.breakpoints) b.id};
    final nodes = <ir.Node>[];
    for (final j in payload.nodes) {
      final n = ir.Node.fromJson(j);
      _assign(n, idMap, gen);
      final copy = _copy(n, idMap, same: same, breakpoints: bps);
      if (copy != null) nodes.add(copy);
    }
    if (nodes.isEmpty) {
      return failedCommand(state, label, [
        commandError('Nothing in the clipboard can be pasted here.'),
      ]);
    }
    final parent = ir.DocumentIndex.of(doc).node(parentId);
    final inFlow =
        parent is ir.FrameNode &&
        parent.grid == null &&
        parent.autoLayout != null;
    final placed = [
      for (final n in nodes)
        if (!inFlow && (dx != 0 || dy != 0))
          n.copyWith(
            common: n.common.copyWith(x: n.common.x + dx, y: n.common.y + dy),
          )
        else
          n,
    ];
    final at = index ?? (parent is ir.FrameNode ? parent.children.length : 0);
    var r = ir.insertNodes(doc, parentId, at, placed);
    if (replaceIds.isEmpty) {
      r = scopeInsert(state, r, [for (final n in placed) n.id]);
    }
    if (r.ok && replaceIds.isNotEmpty) {
      final removed = ir.removeNodes(r.document, replaceIds);
      r = removed.ok
          ? r.copyWith(document: removed.document)
          : r.copyWith(diagnostics: [...r.diagnostics, ...removed.diagnostics]);
    }
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: {for (final n in placed) n.id},
    );
  }

  static void _assign(ir.Node n, Map<String, String> map, ir.IdGenerator gen) {
    map[n.id] = gen.next();
    if (n is ir.FrameNode) {
      for (final c in n.children) {
        _assign(c, map, gen);
      }
    }
  }

  /// A copy of [n] with new ids; null for a node that cannot travel.
  static ir.Node? _copy(
    ir.Node n,
    Map<String, String> map, {
    required bool same,
    required Set<String> breakpoints,
  }) {
    if (!same && n is ir.InstanceNode) return null;
    final c = n.common;
    final interactions = [
      for (final i in c.interactions) ?_interaction(i, map, same: same),
    ];
    final common = c.copyWith(
      id: map[c.id]!,
      interactions: interactions,
      breakpointOverrides: same
          ? c.breakpointOverrides
          : {
              for (final e in c.breakpointOverrides.entries)
                if (breakpoints.contains(e.key)) e.key: e.value,
            },
      bindings: same ? c.bindings : const {},
      componentBindings: same ? c.componentBindings : const {},
    );
    if (n is ir.FrameNode) {
      return n.copyWith(
        common: common,
        behavior: same ? n.behavior : null,
        modeOverrides: same ? n.modeOverrides : const {},
        children: [
          for (final k in n.children)
            ?_copy(k, map, same: same, breakpoints: breakpoints),
        ],
      );
    }
    return n.copyWith(common: common);
  }

  static ir.Interaction? _interaction(
    ir.Interaction i,
    Map<String, String> map, {
    required bool same,
  }) {
    final actions = <ir.Action>[];
    for (final a in i.actions) {
      switch (a) {
        case ir.OpenLightboxAction(:final nodeId):
          if (map.containsKey(nodeId)) {
            actions.add(ir.Action.openLightbox(nodeId: map[nodeId]!));
          } else if (same) {
            actions.add(a);
          }
        case ir.OpenUrlAction():
          actions.add(a);
        default:
          if (same) actions.add(a);
      }
    }
    final trigger = i.trigger;
    final portable =
        trigger is ir.TapTrigger ||
        trigger is ir.HoverEnterTrigger ||
        trigger is ir.HoverLeaveTrigger ||
        same;
    if (actions.isEmpty || !portable) return null;
    return i.copyWith(actions: actions);
  }
}
