import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../../bench/bench_document.dart';
import '../interaction/interaction_harness.dart';

/// The 5,000-node bench story as one scene, image fills made solid (the
/// test bundle has no such asset).
ir.StageDocument _scene5k() {
  final doc = documentOfNodes(5000, scenes: 1, freeLayer: true);
  Object? solid(Object? j) {
    if (j is Map<String, dynamic>) {
      if (j['type'] == 'image' && j.containsKey('assetId')) {
        return {
          'type': 'solid',
          'id': j['id'],
          'color': {'r': 0.8, 'g': 0.8, 'b': 0.8, 'a': 1.0},
        };
      }
      return {for (final e in j.entries) e.key: solid(e.value)};
    }
    if (j is List) return [for (final e in j) solid(e)];
    return j;
  }

  return ir.StageDocument.fromJson(
    solid(jsonDecode(jsonEncode(doc.toJson()))) as Map<String, dynamic>,
  );
}

/// The deepest authored leaf of [root] and its depth (root = 0).
(String, int) _deepestLeaf(ir.ResolvedNode root) {
  var best = (root.id, 0);
  void walk(ir.ResolvedNode n, int d) {
    if (n.id.contains('/') || n.instanceId != null) return;
    if (n.children.isEmpty && d > best.$2) best = (n.id, d);
    for (final c in n.children) {
      walk(c, d + 1);
    }
  }

  walk(root, 0);
  return best;
}

void main() {
  testWidgets('an edit rebuilds only the edited path on each artboard', (
    tester,
  ) async {
    final doc = _scene5k();
    final h = await pumpCanvas(tester, doc: doc);
    final scene = h.ctl.resolvedFor('desktop').scene(h.st.activeSceneId)!;
    expect(
      h.ctl.resolvedFor('desktop').resolved.nodeIndex.length,
      greaterThan(4500),
    );
    final (leaf, depth) = _deepestLeaf(scene.root);
    expect(depth, greaterThan(2));

    final before = StageNodeWidget.debugBuildCount;
    h.ctl.execute(SetProperty([leaf], 'opacity', const ir.IrValue.number(0.5)));
    await tester.pump();
    final rebuilt = StageNodeWidget.debugBuildCount - before;
    // Root → leaf on both artboards (depth + 1 widgets each).
    expect(rebuilt, lessThanOrEqualTo(2 * (depth + 1)));
    expect(rebuilt, greaterThanOrEqualTo(2));

    // A second edit of the same leaf costs the same.
    final again = StageNodeWidget.debugBuildCount;
    h.ctl.execute(SetProperty([leaf], 'opacity', const ir.IrValue.number(0.4)));
    await tester.pump();
    expect(
      StageNodeWidget.debugBuildCount - again,
      lessThanOrEqualTo(2 * (depth + 1)),
    );
  });

  testWidgets('an unrelated state change rebuilds no node widget', (
    tester,
  ) async {
    final h = await pumpCanvas(tester);
    final before = StageNodeWidget.debugBuildCount;
    h.ctl.select({'a'});
    h.ctl.hover('b');
    await tester.pump();
    expect(StageNodeWidget.debugBuildCount - before, 0);
  });
}
