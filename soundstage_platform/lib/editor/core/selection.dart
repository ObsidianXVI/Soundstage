import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

part 'selection.freezed.dart';

// Figma's selection rules (architecture §15, m1.md "Selection rules") as
// pure functions over a hit list the canvas supplies (ids under the
// pointer, topmost first) and a [SelectionTree] for structure.

/// The selection and its context.
///
/// - `selection`: selected ids in selection order.
/// - `context`: the frame whose children a plain click selects; null means
///   the scene root.
/// - `textEditId`: the text node being edited in place.
@freezed
abstract class SelectionState with _$SelectionState {
  const factory SelectionState({
    @Default(<String>{}) Set<String> selection,
    String? context,
    String? textEditId,
  }) = _SelectionState;
}

/// Modifier keys of a pointer gesture. [deep] is Cmd on macOS and Ctrl
/// elsewhere.
@freezed
abstract class SelectionModifiers with _$SelectionModifiers {
  const factory SelectionModifiers({
    @Default(false) bool shift,
    @Default(false) bool deep,
    @Default(false) bool alt,
  }) = _SelectionModifiers;
}

/// The structure selection works over: one scene's tree, by resolved ids
/// (instance inner nodes are `<instanceId>/<innerId>`).
abstract class SelectionTree {
  String get rootId;

  bool contains(String id);

  /// The parent's id; null for the root or an unknown id.
  String? parentOf(String id);

  /// Child ids in paint order (later on top).
  List<String> childrenOf(String id);

  /// Whether [id] can be selected on the canvas: visible and not locked,
  /// with no locked or hidden ancestor.
  bool isSelectable(String id);

  bool isText(String id);

  /// Ancestor ids, root first, excluding [id].
  List<String> ancestorsOf(String id) {
    final out = <String>[];
    var p = parentOf(id);
    while (p != null) {
      out.add(p);
      p = parentOf(p);
    }
    return out.reversed.toList();
  }
}

/// A [SelectionTree] over a resolved scene root (the tree the canvas
/// shows, instances expanded). Cached per root object.
class ResolvedSelectionTree extends SelectionTree {
  ResolvedSelectionTree._(ir.ResolvedNode root) : rootId = root.id {
    void walk(ir.ResolvedNode n, String? parent, bool selectable) {
      final c = n.node.common;
      final ok = selectable && c.visible && !c.locked;
      _nodes[n.id] = (
        parent: parent,
        children: [for (final k in n.children) k.id],
        selectable: ok,
        text: n.node is ir.TextNode,
      );
      for (final k in n.children) {
        walk(k, n.id, ok);
      }
    }

    walk(root, null, true);
  }

  factory ResolvedSelectionTree.of(ir.ResolvedNode root) =>
      _cache[root] ??= ResolvedSelectionTree._(root);

  static final Expando<ResolvedSelectionTree> _cache = Expando();

  @override
  final String rootId;
  final Map<
    String,
    ({String? parent, List<String> children, bool selectable, bool text})
  >
  _nodes = {};

  @override
  bool contains(String id) => _nodes.containsKey(id);

  @override
  String? parentOf(String id) => _nodes[id]?.parent;

  @override
  List<String> childrenOf(String id) => _nodes[id]?.children ?? const [];

  @override
  bool isSelectable(String id) => _nodes[id]?.selectable ?? false;

  @override
  bool isText(String id) => _nodes[id]?.text ?? false;
}

String? _ctx(SelectionTree t, String? parent) =>
    parent == null || parent == t.rootId ? null : parent;

String? _firstHit(SelectionTree t, List<String> hits) {
  for (final h in hits) {
    if (t.contains(h) && t.isSelectable(h)) return h;
  }
  return null;
}

/// The node a plain click on [hit] selects with context [context]: the
/// child of the context on the path to the hit. When the hit is outside the
/// context, the level is that of the deepest common ancestor (a click in a
/// sibling frame selects that frame). A hit on the context itself (or one
/// of its ancestors: empty space) selects that frame. Null for the root.
String? clickTarget(SelectionTree t, String hit, String? context) {
  final chain = [...t.ancestorsOf(hit), hit];
  final ctx = context != null && t.contains(context) ? context : t.rootId;
  final ctxChain = {...t.ancestorsOf(ctx), ctx};
  var i = -1;
  for (var k = 0; k < chain.length; k++) {
    if (ctxChain.contains(chain[k])) i = k;
  }
  if (i < 0) return null;
  final target = i == chain.length - 1 ? hit : chain[i + 1];
  return target == t.rootId ? null : target;
}

/// A click (Figma):
///
/// - plain: selects [clickTarget] of the topmost selectable hit;
/// - [SelectionModifiers.deep] (Cmd/Ctrl): selects the hit itself;
/// - [SelectionModifiers.shift]: adds the target, or removes it when it is
///   already selected (with deep, the deep target);
/// - on nothing (or only the root): clears the selection (Shift keeps it).
///
/// The context becomes the target's parent. Locked and hidden nodes are
/// clicked through. Ends text editing.
SelectionState clickSelect(
  SelectionTree t,
  List<String> hits,
  SelectionModifiers modifiers,
  SelectionState current,
) {
  final hit = _firstHit(t, hits);
  final target = hit == null
      ? null
      : modifiers.deep
      ? (hit == t.rootId ? null : hit)
      : clickTarget(t, hit, current.context);
  if (target == null) {
    return modifiers.shift
        ? current.copyWith(textEditId: null)
        : const SelectionState();
  }
  final context = _ctx(t, t.parentOf(target));
  if (!modifiers.shift) {
    return SelectionState(selection: {target}, context: context);
  }
  final next = {...current.selection};
  if (!next.remove(target)) next.add(target);
  return SelectionState(
    selection: next,
    context: current.selection.isEmpty ? context : current.context,
  );
}

/// A double-click (Figma): on a text node that a click would select,
/// starts editing it; otherwise enters the clicked frame (or instance) and
/// selects its child under the pointer. Nothing under the pointer: no
/// change.
SelectionState doubleClickSelect(
  SelectionTree t,
  List<String> hits,
  SelectionState current,
) {
  final hit = _firstHit(t, hits);
  if (hit == null) return current;
  final target = clickTarget(t, hit, current.context);
  if (target == null) return current;
  final parent = _ctx(t, t.parentOf(target));
  if (t.isText(target)) {
    return SelectionState(
      selection: {target},
      context: parent,
      textEditId: target,
    );
  }
  final chain = [...t.ancestorsOf(hit), hit];
  final i = chain.indexOf(target);
  if (i < 0 || i == chain.length - 1) {
    return SelectionState(selection: {target}, context: parent);
  }
  return SelectionState(selection: {chain[i + 1]}, context: target);
}

/// Esc: stops text editing (keeping the text selected); otherwise selects
/// the parents of the selection. At the top level it clears the selection.
SelectionState selectParent(SelectionTree t, SelectionState current) {
  if (current.textEditId != null) return current.copyWith(textEditId: null);
  final parents = <String>{
    for (final id in current.selection)
      if (t.parentOf(id) case final p? when p != t.rootId) p,
  };
  if (parents.isEmpty) return const SelectionState();
  return SelectionState(
    selection: parents,
    context: _ctx(t, t.parentOf(parents.first)),
  );
}

/// Enter: on one selected text node, starts editing it; otherwise selects
/// the selectable children of the selected frames (no change when there
/// are none).
SelectionState selectChildren(SelectionTree t, SelectionState current) {
  final sel = current.selection;
  if (sel.length == 1 && t.isText(sel.single)) {
    return current.copyWith(textEditId: sel.single);
  }
  final kids = <String>{
    for (final id in sel) ...t.childrenOf(id).where(t.isSelectable),
  };
  if (kids.isEmpty) return current;
  return SelectionState(
    selection: kids,
    context: _ctx(t, t.parentOf(kids.first)),
  );
}

/// Tab / Shift-Tab: selects the next / previous selectable sibling of the
/// last selected node, in child order, wrapping around. With nothing
/// selected, the first (last) selectable child of the context.
SelectionState selectSibling(
  SelectionTree t,
  SelectionState current, {
  bool backwards = false,
}) {
  if (current.selection.isEmpty) {
    final kids = t
        .childrenOf(current.context ?? t.rootId)
        .where(t.isSelectable)
        .toList();
    if (kids.isEmpty) return current;
    return SelectionState(
      selection: {backwards ? kids.last : kids.first},
      context: current.context,
    );
  }
  final anchor = current.selection.last;
  final parent = t.parentOf(anchor);
  if (parent == null) return current;
  final sibs = t.childrenOf(parent);
  final i = sibs.indexOf(anchor);
  final n = sibs.length;
  for (var step = 1; step <= n; step++) {
    final id = sibs[((i + (backwards ? -step : step)) % n + n) % n];
    if (t.isSelectable(id)) {
      return SelectionState(selection: {id}, context: _ctx(t, parent));
    }
  }
  return current;
}

/// A marquee: selects the selectable children of the context whose boxes
/// lie fully inside [rect] (Figma: in the current context only). [boxes]
/// and [rect] share one space. Shift adds to the selection.
SelectionState marqueeSelect(
  SelectionTree t,
  ir.StageRect rect,
  Map<String, ir.StageRect> boxes,
  SelectionModifiers modifiers,
  SelectionState current,
) {
  bool inside(ir.StageRect b) =>
      b.x >= rect.x &&
      b.y >= rect.y &&
      b.x + b.width <= rect.x + rect.width &&
      b.y + b.height <= rect.y + rect.height;
  final picked = <String>{
    for (final id in t.childrenOf(current.context ?? t.rootId))
      if (t.isSelectable(id) && boxes[id] != null && inside(boxes[id]!)) id,
  };
  return SelectionState(
    selection: modifiers.shift ? {...current.selection, ...picked} : picked,
    context: current.context,
  );
}

/// Select all (Cmd+A): the selectable siblings of the selection, or the
/// context's children when nothing is selected.
SelectionState selectAll(SelectionTree t, SelectionState current) {
  final parent = current.selection.isEmpty
      ? (current.context ?? t.rootId)
      : t.parentOf(current.selection.first);
  if (parent == null) return current;
  return SelectionState(
    selection: t.childrenOf(parent).where(t.isSelectable).toSet(),
    context: _ctx(t, parent),
  );
}

/// Select none.
SelectionState selectNone(SelectionState current) =>
    SelectionState(context: current.context);
