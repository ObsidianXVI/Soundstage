// The rig for the M1 acceptance test (static_demo_rebuild_test.dart): the
// real EditorShell over the app's in-memory persistence stack, plus helpers
// that drive the editor through its own surfaces (toolbar, canvas, layers,
// scenes and assets panels, inspector, on-canvas text input).
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/persistence/db_story_repository.dart';
import 'package:soundstage_platform/app/persistence/editor_asset_service.dart';
import 'package:soundstage_platform/app/persistence/local_asset_store.dart';
import 'package:soundstage_platform/app/persistence/records.dart';
import 'package:soundstage_platform/app/persistence/story_database.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/panels/layers_panel.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/editor/shell/toolbar.dart';
import 'package:soundstage_platform/editor/shortcuts/shortcut_map.dart'
    show isMacPlatform;
import 'package:soundstage_platform/editor/text/text_edit_controller.dart';
import 'package:soundstage_platform/editor/text/text_edit_session.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Reads a PNG's IHDR for its size (what the browser analyzer reports).
class PngHeaderAnalyzer implements AssetAnalyzer {
  @override
  Future<AssetAnalysis> analyze(Uint8List bytes, String mime) async {
    if (mime == 'image/png' && bytes.length > 24) {
      final d = ByteData.sublistView(bytes);
      return AssetAnalysis(
        width: d.getUint32(16),
        height: d.getUint32(20),
        dominantColor: 0xFF808080,
      );
    }
    return const AssetAnalysis();
  }
}

class FakeObjectUrls implements ObjectUrlFactory {
  var _n = 0;
  @override
  String create(Uint8List bytes, String mime) => 'blob:test/${_n++}';
  @override
  void revoke(String url) {}
}

/// A file from disk, as the browser picker would hand it over.
EditorFile diskFile(String path, String mime) => (
  name: path.split('/').last,
  bytes: File(path).readAsBytesSync(),
  mime: mime,
);

class Rig {
  Rig(this.tester, this.db, this.store, this.repository);

  final WidgetTester tester;
  final MemoryStoryDatabase db;
  final LocalAssetStore store;

  /// The app's repository over the same database and asset store.
  final DbStoryRepository repository;

  /// The story's id in [repository] (set by [pumpNewStory]).
  String? storyId;

  /// What the next picker call returns.
  List<EditorFile> nextPick = const [];
  final List<String> pickedAccepts = [];
  ir.StageDocument? lastReported;

  late ProviderContainer container;

  EditorController get ctl => container.read(editorControllerProvider.notifier);
  EditorState get st => container.read(editorControllerProvider);
  ir.StageDocument get doc => st.document;
  CanvasController get canvas => container.read(canvasControllerProvider);
  ir.Node node(String id) => ir.DocumentIndex.of(doc).node(id)!;

  String bp(String name) =>
      doc.breakpoints.firstWhere((b) => b.name == name).id;

  Future<void> pump([int frames = 2]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Runs implicit animations (expanding editors, menus) to their end.
  Future<void> settleAnimations() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lets real async work (asset store, decoding) finish.
  Future<void> settleAsync() async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await pump();
    }
  }

  // ---- Finding ids by layer name ---------------------------------------------

  /// The id of the node named [name] in the active scene (the [index]th in
  /// tree order), optionally under the node named [under].
  String idOf(String name, {String? under, int index = 0}) {
    final scene = doc.scenes.firstWhere((s) => s.id == st.activeSceneId);
    final hits = <String>[];
    void walk(ir.Node n, bool inside) {
      final here = inside || under == null || n.common.name == under;
      if (here && n.common.name == name) hits.add(n.common.id);
      if (n is ir.FrameNode) {
        for (final c in n.children) {
          walk(c, here && (under == null || n.common.name == under || inside));
        }
      }
    }

    walk(scene.root, under == null);
    expect(hits.length, greaterThan(index), reason: 'no layer "$name"');
    return hits[index];
  }

  /// Selects the active scene's root by clicking artboard [bpId]'s name
  /// label (the root has no layer row and a click inside the artboard
  /// selects its children).
  Future<void> selectRoot([String? bpId]) async {
    final b = bpId ?? doc.breakpoints.firstWhere((x) => x.primary).id;
    final r = canvas.camera.value.rectToScreen(canvas.artboards[b]!.worldRect);
    await click(_canvasOrigin + Offset(r.left + 20, r.top - 12));
    expect(st.selection, {rootId}, reason: 'root selected from the label');
  }

  String get rootId =>
      doc.scenes.firstWhere((s) => s.id == st.activeSceneId).root.common.id;

  // ---- Canvas geometry -------------------------------------------------------

  Offset get _canvasOrigin => tester.getTopLeft(find.byType(EditorCanvas));

  /// The global position of design point ([x], [y]) on the artboard of
  /// breakpoint [bpId].
  Offset at(String bpId, double x, double y) {
    final world = canvas.artboards[bpId]!.worldRect.topLeft + Offset(x, y);
    return _canvasOrigin + canvas.camera.value.toScreen(world);
  }

  /// The global centre of the part of node [id] that shows on artboard
  /// [bpId] (a node wider than the artboard is clipped by it).
  Offset centreOf(String id, String bpId) {
    final board = canvas.camera.value.rectToScreen(
      canvas.artboards[bpId]!.worldRect,
    );
    final r = canvas.overlay.rectFor(id, bpId)!.bounds.intersect(board);
    // A point where [id] itself is the topmost node (others may cover it).
    for (var j = 1; j < 8; j++) {
      for (var i = 1; i < 8; i++) {
        final p = Offset(
          r.left + r.width * i / 8,
          r.top + r.height * (j.isOdd ? 8 - j : j) / 8,
        );
        final hits = canvas.overlay.hitTest(p);
        if (hits.isNotEmpty && hits.first.nodeId == id) {
          return _canvasOrigin + p;
        }
      }
    }
    return _canvasOrigin + r.center;
  }

  Duration _now = const Duration(seconds: 10);

  Future<TestGesture> _press(Offset at) async {
    _now += const Duration(seconds: 1);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.down(at, timeStamp: _now);
    await tester.pump();
    return g;
  }

  Future<void> click(Offset at) async {
    final g = await _press(at);
    await g.up(timeStamp: _now);
    await pump();
  }

  Future<void> doubleClick(Offset at) async {
    final g = await _press(at);
    await g.up(timeStamp: _now);
    await tester.pump(const Duration(milliseconds: 50));
    _now += const Duration(milliseconds: 150);
    await g.down(at, timeStamp: _now);
    await g.up(timeStamp: _now);
    await pump();
  }

  Future<void> drag(Offset from, Offset to, {int steps = 6}) async {
    final g = await _press(from);
    for (var i = 1; i <= steps; i++) {
      await g.moveTo(Offset.lerp(from, to, i / steps)!, timeStamp: _now);
      await tester.pump();
    }
    await g.up(timeStamp: _now);
    await pump();
  }

  /// Shift+1 (zoom to fit): every artboard on screen.
  Future<void> zoomToFit() async {
    await _keys([LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.digit1);
    final c = tester.getRect(find.byType(EditorCanvas));
    for (final a in canvas.artboards.values) {
      final r = canvas.camera.value.rectToScreen(a.worldRect).shift(c.topLeft);
      expect(
        c.inflate(1).contains(r.topLeft) &&
            c.inflate(1).contains(r.bottomRight),
        isTrue,
        reason: 'artboard ${a.breakpointId} on screen after zoom to fit',
      );
    }
  }

  // ---- Toolbar ---------------------------------------------------------------

  /// Picks a toolbar tool; shape tools come from the shape menu.
  Future<void> tool(String label) async {
    const shapes = {'Rectangle', 'Line', 'Ellipse', 'Polygon', 'Star'};
    if (shapes.contains(label)) {
      await tester.tap(find.bySemanticsLabel('Shape tools').first);
      await settleAnimations();
      await tester.tap(find.text(label).last);
      await settleAnimations();
      return;
    }
    await tester.tap(find.bySemanticsLabel(label).first);
    await pump();
  }

  /// Draws with tool [label] on artboard [bpId] from design point [a] to
  /// [b]; returns the new node's id (the selection).
  Future<String> draw(String label, String bpId, Offset a, Offset b) async {
    await tool(label);
    await drag(at(bpId, a.dx, a.dy), at(bpId, b.dx, b.dy));
    expect(st.selection, hasLength(1), reason: 'drew a $label');
    return st.selection.single;
  }

  /// The toolbar's edit-scope toggle: "Both" or "This breakpoint: …".
  Future<void> setScope({required bool thisBreakpoint}) async {
    final want = thisBreakpoint ? EditScope.thisBreakpoint : EditScope.both;
    if (st.editScope == want) return;
    final seg = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (thisBreakpoint
              ? (w.data ?? '').startsWith('This breakpoint') ||
                    (w.data ?? '').startsWith('Only ')
              : w.data == 'Both'),
    );
    expect(seg, findsWidgets, reason: 'scope segment');
    await tester.tap(seg.first);
    await pump();
    expect(st.editScope, want);
  }

  // ---- Left panel ------------------------------------------------------------

  Future<void> tab(String name) async {
    await tester.tap(find.text(name).first);
    await pump();
  }

  /// Selects [id] by clicking its row in the Layers panel.
  Future<void> selectLayer(String id, {bool shift = false}) async {
    await tab('Layers');
    final row = find.descendant(
      of: find.byType(LayersPanel),
      matching: find.byKey(ValueKey<String>(id)),
    );
    if (row.evaluate().isEmpty) {
      // Collapsed parents: reveal through the canvas selection (the panel
      // scrolls to and expands the selection's row).
      fail('layer row $id is not shown');
    }
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(row);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await pump();
  }

  /// Selects [id]: its Layers row when shown, else a Cmd-click (deep
  /// select) on the desktop artboard.
  Future<void> selectNode(String id, {String? bpId}) async {
    await tab('Layers');
    final row = find.descendant(
      of: find.byType(LayersPanel),
      matching: find.byKey(ValueKey<String>(id)),
    );
    if (row.evaluate().isNotEmpty) {
      await tester.tap(row);
      await pump();
    } else {
      final b = bpId ?? doc.breakpoints.firstWhere((x) => x.primary).id;
      final at = centreOf(id, b);
      await tester.sendKeyDownEvent(mod);
      await click(at);
      await tester.sendKeyUpEvent(mod);
      await pump();
    }
    expect(st.selection, {id}, reason: 'selected $id');
  }

  /// Gives keyboard focus back to the editor shell (out of any inspector
  /// field), so its shortcut table receives the keys.
  Future<void> focusEditor() async {
    Focus.of(tester.element(find.byType(EditorToolbar))).requestFocus();
    await pump();
  }

  Future<void> _keys(
    List<LogicalKeyboardKey> mods,
    LogicalKeyboardKey key,
  ) async {
    await focusEditor();
    for (final m in mods) {
      await tester.sendKeyDownEvent(m);
    }
    await tester.sendKeyEvent(key);
    for (final m in mods.reversed) {
      await tester.sendKeyUpEvent(m);
    }
    await settleAnimations();
  }

  /// Shift+2: zoom to the selection.
  Future<void> zoomToSelection() =>
      _keys([LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.digit2);

  /// Cmd (Ctrl off Apple platforms, as the shortcut table binds it).
  LogicalKeyboardKey get mod => isMacPlatform()
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;

  /// Cmd+D: duplicate the selection (the copy is selected).
  Future<void> duplicate() => _keys([mod], LogicalKeyboardKey.keyD);

  /// Replaces the text of [id]: select it, Enter to edit, select all
  /// through the input client, type, Esc.
  Future<void> retype(String id, String text) async {
    await selectNode(id);
    await _keys(const [], LogicalKeyboardKey.enter);
    expect(st.textEditId, id, reason: 'Enter edits $id');
    await selectText(0, session.text.length);
    await typeText(text);
    await escape();
  }

  /// Renames the selection with F2 (the layers panel's inline field).
  Future<void> rename(String id, String name) async {
    if (st.selection.length != 1 || st.selection.single != id) {
      await selectLayer(id);
    }
    await tab('Layers');
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await pump(3);
    final field = find.descendant(
      of: find.byType(SsTreeRow),
      matching: find.byType(EditableText),
    );
    expect(field, findsOneWidget, reason: 'rename field for $id');
    await tester.enterText(field, name);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pump();
    expect(node(id).common.name, name);
  }

  // ---- Inspector -------------------------------------------------------------

  Finder field(String path) => find.descendant(
    of: find.byKey(ValueKey<String>('field:$path')),
    matching: find.byType(EditableText),
  );

  /// The inspector's scrollable (the section list).
  ScrollableState? get _inspectorScroll {
    final list = find.descendant(
      of: find.byKey(const ValueKey<String>('inspector')),
      matching: find.byType(Scrollable),
    );
    if (list.evaluate().isEmpty) return null;
    return tester.state<ScrollableState>(list.first);
  }

  /// Builds [f] if the lazy inspector list has it off-screen: scans the
  /// list from the top until it appears.
  Future<void> reveal(Finder f) async {
    if (f.evaluate().isNotEmpty) return;
    final s = _inspectorScroll;
    if (s == null) return;
    s.position.jumpTo(0);
    await pump();
    while (f.evaluate().isEmpty &&
        s.position.pixels < s.position.maxScrollExtent) {
      s.position.jumpTo(
        (s.position.pixels + s.position.viewportDimension * 0.6).clamp(
          0,
          s.position.maxScrollExtent,
        ),
      );
      await pump();
    }
  }

  /// Scrolls every scrollable around [f] until it is inside the outermost
  /// one's viewport (the inspector is a lazy list whose extent grows as it
  /// scrolls, so one `ensureVisible` can stop short).
  Future<void> scrollInspectorTo(Finder f) async {
    for (var i = 0; i < 6; i++) {
      if (f.evaluate().isEmpty) return;
      final e = f.evaluate().first;
      ScrollableState? outer;
      e.visitAncestorElements((a) {
        if (a is StatefulElement && a.state is ScrollableState) {
          outer = a.state as ScrollableState;
        }
        return true;
      });
      final o = outer;
      if (o == null) return;
      final box = e.renderObject! as RenderBox;
      final r = box.localToGlobal(Offset.zero) & box.size;
      final vb = o.context.findRenderObject()! as RenderBox;
      final v = vb.localToGlobal(Offset.zero) & vb.size;
      // A margin: a field a few pixels under the viewport's top edge is
      // not reliably hit (it sits in the scroll view's edge band).
      if (r.top >= v.top + 24 && r.bottom <= v.bottom - 24) {
        if (_hits(box, r.center)) return;
        // In the viewport but covered (a lazily laid out neighbour): move
        // the list a little and look again.
        o.position.jumpTo(
          (o.position.pixels + (i.isEven ? 120 : -240)).clamp(
            0,
            o.position.maxScrollExtent,
          ),
        );
        await settleAnimations();
        continue;
      }
      await Scrollable.ensureVisible(e, alignment: 0.5);
      await settleAnimations();
    }
  }

  /// Whether a pointer at [at] reaches [box].
  bool _hits(RenderBox box, Offset at) {
    final result = HitTestResult();
    tester.binding.hitTestInView(result, at, tester.view.viewId);
    return result.path.any((e) => e.target == box);
  }

  /// Types [text] into the inspector number/text field at [path] + Enter.
  Future<void> type(String path, String text) async {
    final f = field(path);
    await reveal(f);
    expect(f, findsOneWidget, reason: 'field:$path');
    await scrollInspectorTo(f);
    await tester.tap(f);
    await pump();
    await tester.enterText(f, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pump();
  }

  /// Taps the segment labelled [label] of the control keyed `field:[path]`.
  Future<void> segment(String path, String label) async {
    final f = find.descendant(
      of: find.byKey(ValueKey<String>('field:$path')),
      matching: find.text(label),
    );
    await reveal(f);
    expect(f, findsWidgets, reason: 'field:$path / $label');
    await scrollInspectorTo(f);
    await tester.tap(f.first);
    await pump();
  }

  /// Taps the icon segment [icon] of the control keyed `field:[path]`.
  Future<void> iconSegment(String path, IconData icon) async {
    final f = find.descendant(
      of: find.byKey(ValueKey<String>('field:$path')),
      matching: find.byWidgetPredicate((w) => w is SsIcon && w.icon == icon),
    );
    await reveal(f);
    expect(f, findsWidgets, reason: 'field:$path icon');
    await scrollInspectorTo(f);
    await tester.tap(f.first);
    await pump();
  }

  /// Opens the dropdown keyed [key] and picks [label].
  Future<void> pick(String key, String label) async {
    final f = find.byKey(ValueKey<String>(key));
    await reveal(f);
    expect(f, findsOneWidget, reason: key);
    await scrollInspectorTo(f);
    await tester.tap(f);
    await settleAnimations();
    var item = find.text(label);
    if (item.evaluate().isEmpty) {
      // Menu entries may carry a detail ("Fraunces (variable)").
      item = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('$label '),
      );
    }
    expect(item, findsWidgets, reason: '$key menu item $label');
    await tester.tap(item.last);
    await settleAnimations();
  }

  Future<void> tapKey(String key) async {
    final f = find.byKey(ValueKey<String>(key));
    await reveal(f);
    expect(f, findsWidgets, reason: key);
    await scrollInspectorTo(f);
    await tester.tap(f.first);
    await pump(3);
  }

  Future<void> tapLabel(String semantics) async {
    final f = find.bySemanticsLabel(semantics);
    expect(f, findsWidgets, reason: semantics);
    await scrollInspectorTo(f);
    await tester.tap(f.first);
    await pump(3);
  }

  /// Sets the constraints through the constraints widget's segmented
  /// controls ([h]: Left, Right, Both, Center, Scale; [v]: Top, Bottom,
  /// Both, Center, Scale).
  Future<void> constraints({String? h, String? v}) async {
    Future<void> seg(String label, String value) async {
      final f = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is SsSegmented && w.semanticLabel == label,
        ),
        matching: find.text(value),
      );
      await reveal(f);
      expect(f, findsWidgets, reason: '$label $value');
      await scrollInspectorTo(f);
      await tester.tap(f.first);
      await pump();
    }

    if (h != null) await seg('Horizontal constraint', h);
    if (v != null) await seg('Vertical constraint', v);
  }

  /// Types a colour (`rrggbb`, and [alpha] in %) into the colour picker
  /// of the colour at [path]: a colour field's own picker (its swatch), or
  /// for a paint row (`<stack>.<paintId>.color`) the paint's detail.
  Future<void> colour(String path, String hex, {String? alpha}) async {
    final sel = st.selection;
    final swatch = find.descendant(
      of: find.byKey(ValueKey<String>('field:$path')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            (w.properties.label ?? '').endsWith('open colour picker'),
      ),
    );
    await reveal(find.byKey(ValueKey<String>('field:$path')));
    Finder scope;
    Future<void> Function() close;
    if (swatch.evaluate().isNotEmpty) {
      await scrollInspectorTo(swatch);
      await tester.tap(swatch.first);
      await settleAnimations();
      scope = find.byKey(ValueKey<String>('field:$path'));
      close = () async {
        await scrollInspectorTo(swatch);
        await tester.tap(swatch.first);
        await settleAnimations();
      };
    } else {
      final parts = path.split('.');
      final pid = parts[parts.length - 2];
      final detail = find.byKey(ValueKey<String>('paint-detail:$pid'));
      final wasOpen = detail.evaluate().isNotEmpty;
      if (!wasOpen) await tapKey('paint-swatch:$pid');
      await settleAnimations();
      scope = detail;
      close = () async {
        // A span edit can rebuild the row (and close its detail).
        final sw = find.byKey(ValueKey<String>('paint-swatch:$pid'));
        if (!wasOpen && detail.evaluate().isNotEmpty) {
          await reveal(sw);
          if (sw.evaluate().isNotEmpty) await tapKey('paint-swatch:$pid');
        }
        await settleAnimations();
      };
    }
    final f = find.descendant(
      of: scope,
      matching: find.descendant(
        of: find.bySemanticsLabel('Hex colour'),
        matching: find.byType(EditableText),
      ),
    );
    expect(f, findsWidgets, reason: 'picker hex for $path');
    await scrollInspectorTo(f);
    await tester.enterText(f.last, hex.substring(0, 6));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pump();
    final current = ir.PropertyRegistry.standard.get(
      node(st.selection.first),
      path,
    );
    final opaque =
        current is ir.ColorValue && (current.value.a - 1).abs() < 1e-9;
    if (alpha != null && !(alpha == '100' && opaque)) {
      final a = find.descendant(
        of: scope,
        matching: find.descendant(
          of: find.bySemanticsLabel('Alpha percent'),
          matching: find.byType(EditableText),
        ),
      );
      expect(a, findsWidgets, reason: 'alpha for $path');
      await scrollInspectorTo(a);
      await tester.tap(a.last);
      await pump();
      await tester.enterText(a.last, alpha);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pump();
    }
    // Click away from the hex entry (it keeps its caret scrolled into
    // view while focused), then close the picker. While text is being
    // edited, focus stays with the edit session.
    if (st.textEditId == null) FocusManager.instance.primaryFocus?.unfocus();
    await settleAnimations();
    await close();
    expect(st.selection, sel);
  }

  /// Drags artboard [bpId]'s width handle until the artboard is [width]
  /// wide (free width; the breakpoint in effect follows it).
  Future<void> freeWidth(String bpId, double width) async {
    final handle = find.byKey(ValueKey<String>('width-handle-$bpId'));
    for (var i = 0; i < 3; i++) {
      final current =
          canvas.previewWidthOf(bpId) ??
          doc.breakpoints.firstWhere((b) => b.id == bpId).designSize.width;
      if ((current - width).abs() < 0.01) break;
      final dx = (width - current) * canvas.camera.value.zoom;
      final from = tester.getCenter(handle);
      await drag(from, from + Offset(dx, 0), steps: 8);
    }
    expect(canvas.previewWidthOf(bpId), closeTo(width, 0.01));
  }

  /// Double-clicks artboard [bpId]'s width handle: back to its design width.
  Future<void> resetWidth(String bpId) async {
    final handle = find.byKey(ValueKey<String>('width-handle-$bpId'));
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(handle);
    await pump(4);
    expect(canvas.previewWidthOf(bpId), isNull);
  }

  // ---- Text ------------------------------------------------------------------

  TextEditSession get session => container.read(textEditProvider).session!;

  /// Types [s] through the session's text input client (the delta model
  /// the browser IME drives).
  Future<void> typeText(String s) async {
    final session = this.session;
    for (final ch in s.characters) {
      final sel = session.selection;
      session.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: session.text,
          replacementText: ch,
          replacedRange: TextRange(start: sel.start, end: sel.end),
          selection: TextSelection.collapsed(offset: sel.start + ch.length),
          composing: TextRange.empty,
        ),
      ]);
    }
    await pump();
  }

  /// Selects [start, end) of the edited text as the input client would.
  /// When an inspector field has focus, first clicks into the text (as a
  /// user does), so that field commits before the selection moves.
  Future<void> selectText(int start, int end) async {
    final focused = FocusManager.instance.primaryFocus?.context;
    var inInspector = false;
    focused?.visitAncestorElements((e) {
      if (e.widget.key == const ValueKey<String>('inspector')) {
        inInspector = true;
        return false;
      }
      return true;
    });
    if (inInspector) {
      final id = st.textEditId!;
      await click(centreOf(id, this.session.breakpointId));
      expect(st.textEditId, id);
    }
    final session = this.session;
    session.updateEditingValueWithDeltas([
      TextEditingDeltaNonTextUpdate(
        oldText: session.text,
        selection: TextSelection(baseOffset: start, extentOffset: end),
        composing: TextRange.empty,
      ),
    ]);
    await pump();
  }

  /// Selects the first occurrence of [phrase] in the edited text.
  Future<void> selectPhrase(String phrase) async {
    final i = session.text.indexOf(phrase);
    expect(i, isNonNegative, reason: phrase);
    await selectText(i, i + phrase.length);
  }

  Future<void> escape() async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pump();
  }
}

/// Creates a story through the app's repository, opens it (the repository
/// runs `loadDocument`) and pumps the editor on it, as `/edit/:id` does.
Future<Rig> pumpNewStory(
  WidgetTester tester, {
  required String title,
  Size size = const Size(1600, 1000),
}) async {
  final db = MemoryStoryDatabase();
  final store = LocalAssetStore(
    db,
    analyzer: PngHeaderAnalyzer(),
    urls: FakeObjectUrls(),
    ids: ir.IdGenerator.seeded(99),
  );
  final repository = DbStoryRepository(db, assets: store);
  final opened = (await tester.runAsync(() async {
    final summary = await repository.create(title: title);
    return (summary.id, await repository.open(summary.id));
  }))!;
  final (id, load) = opened;
  expect(load!.document, isNotNull);
  final rig = await pumpEditor(
    tester,
    load.document!,
    size: size,
    db: db,
    store: store,
    repository: repository,
  );
  rig.storyId = id;
  return rig;
}

Future<Rig> pumpEditor(
  WidgetTester tester,
  ir.StageDocument document, {
  Size size = const Size(1600, 1000),
  MemoryStoryDatabase? db,
  LocalAssetStore? store,
  DbStoryRepository? repository,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  db ??= MemoryStoryDatabase();
  store ??= LocalAssetStore(
    db,
    analyzer: PngHeaderAnalyzer(),
    urls: FakeObjectUrls(),
    ids: ir.IdGenerator.seeded(99),
  );
  final rig = Rig(
    tester,
    db,
    store,
    repository ?? DbStoryRepository(db, assets: store),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (c, child) => SsScope(theme: SsThemeData.dark(), child: child!),
      home: Scaffold(
        body: EditorShell(
          document: document,
          assetService: LocalEditorAssetService(store),
          filePicker: ({String accept = '', bool multiple = false}) async {
            rig.pickedAccepts.add(accept);
            final files = rig.nextPick;
            rig.nextPick = const [];
            return files;
          },
          onBack: () {},
          onPreview: () {},
          onDocumentChanged: (d) => rig.lastReported = d,
          saveStatus: const Text('Saved'),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  rig.container = ProviderScope.containerOf(
    tester.element(find.byType(EditorCanvas)),
  );
  return rig;
}
