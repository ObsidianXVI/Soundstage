import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/editor/overlay/canvas_overlay.dart';
import 'package:soundstage_platform/editor/panels/layers_panel.dart';
import 'package:soundstage_platform/editor/shell/breakpoint_manager.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../interaction/interaction_harness.dart';
import '../panels/panels_harness.dart' as panels;

const _half = ir.IrValue.number(0.5);

/// [doc] with node [id]'s patch on [bp] set to opacity 0.5.
ir.StageDocument _patch(ir.StageDocument doc, String id, String bp) =>
    ir.setBreakpointPatchValue(doc, id, bp, 'opacity', _half).document;

void main() {
  group('canvas', () {
    testWidgets('a selected node with a patch is marked on that artboard '
        'only; a free width shows the breakpoint in effect', (tester) async {
      final h = await pumpCanvas(
        tester,
        doc: _patch(interactionDoc(), 'a', 'mobile'),
      );
      h.ctl.select({'a', 'b'});
      await tester.pump();
      expect(OverlayPainter.debugOverrideMarkers, [('a', 'mobile')]);

      // The desktop artboard dragged into mobile's range shows mobile.
      h.canvas.setPreviewWidth('desktop', 500, designWidth: 1000);
      await tester.pump();
      await tester.pump();
      expect(OverlayPainter.debugOverrideMarkers.toSet(), {
        ('a', 'desktop'),
        ('a', 'mobile'),
      });
      // ...and the edit state follows it once desktop is edited.
      h.ctl.setEditingBreakpoint('desktop');
      expect(h.st.breakpointId, 'mobile');
      h.ctl.setEditScope(EditScope.thisBreakpoint);
      h.ctl.execute(
        SetProperty(['b'], 'opacity', const ir.IrValue.number(0.3)),
      );
      expect(
        h.node('b').common.breakpointOverrides['mobile']!['opacity'],
        const ir.IrValue.number(0.3),
      );
      expect(h.node('b').common.breakpointOverrides['desktop'], isNull);
    });

    testWidgets('right-click resets the node\'s overrides on the artboard\'s '
        'breakpoint', (tester) async {
      var doc = _patch(interactionDoc(), 'a', 'mobile');
      doc = _patch(doc, 'a', 'desktop');
      final h = await pumpCanvas(tester, doc: doc);
      final g = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.down(h.mob(150, 150));
      await g.up();
      await tester.pumpAndSettle();
      expect(h.st.selection, {'a'});
      expect(h.st.artboardId, 'mobile');
      final item = find.text('Reset overrides on Mobile');
      expect(item, findsOneWidget);
      await tester.tap(item);
      await tester.pumpAndSettle();
      final o = h.node('a').common.breakpointOverrides;
      expect(o['mobile'], isNull);
      expect(o['desktop'], isNotNull);
      expect(h.st.history.undoLabel, 'Reset overrides on Mobile');
      h.ctl.undo();
      expect(h.node('a').common.breakpointOverrides['mobile'], isNotNull);
    });
  });

  testWidgets('layers: rows with any breakpoint patch get a dot', (
    tester,
  ) async {
    await panels.pumpPanel(
      tester,
      const LayersPanel(),
      doc: _patch(panels.panelsDoc(), 'B', 'mobile'),
    );
    final dot = find.byKey(const ValueKey<String>('layer-override-dot'));
    expect(dot, findsOneWidget);
    expect(
      find.ancestor(of: dot, matching: find.byKey(const ValueKey('B'))),
      findsOneWidget,
    );
  });

  testWidgets('inspector: the header resets the overrides on the breakpoint '
      'in effect; fields keep their override tint', (tester) async {
    final c = await _pumpInspector(
      tester,
      _patch(_patch(interactionDoc(), 'a', 'mobile'), 'a', 'desktop'),
    );
    c.read(editorControllerProvider.notifier)
      ..setEditingBreakpoint('mobile')
      ..select({'a'});
    await tester.pump();
    expect(find.byKey(const ValueKey('override-tint')), findsWidgets);
    final reset = find.byKey(const ValueKey('reset-breakpoint-overrides'));
    expect(reset, findsOneWidget);
    await tester.tap(reset);
    await tester.pump();
    final a = ir.DocumentIndex.of(
      c.read(editorControllerProvider).document,
    ).node('a')!;
    expect(a.common.breakpointOverrides.keys, ['desktop']);
    expect(reset, findsNothing);
  });

  group('breakpoint manager', () {
    Future<ProviderContainer> pumpManager(
      WidgetTester tester,
      ir.StageDocument doc,
    ) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(
        overrides: [initialDocumentProvider.overrideWithValue(doc)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            builder: (context, w) =>
                SsScope(theme: SsThemeData.dark(), child: w!),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: BreakpointManagerButton(),
              ),
            ),
          ),
        ),
      );
      return c;
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('breakpoint-manager')));
      await tester.pumpAndSettle();
    }

    testWidgets('adds a tablet artboard, undoably', (tester) async {
      final c = await pumpManager(tester, interactionDoc());
      await open(tester);
      await tester.tap(find.text('Add tablet'));
      await tester.pumpAndSettle();
      final doc = c.read(editorControllerProvider).document;
      final tablet = tabletOf(doc)!;
      expect(tablet.primary, isTrue);
      expect(tablet.inheritsFrom, 'desktop');
      expect(doc.primaryBreakpoints, hasLength(3));
      c.read(editorControllerProvider.notifier).undo();
      expect(
        c.read(editorControllerProvider).document.breakpoints,
        hasLength(2),
      );
    });

    testWidgets('the edit dialog blocks cycles and saves valid edits', (
      tester,
    ) async {
      final doc = interactionDoc().copyWith(
        breakpoints: [
          ...kBps,
          const ir.Breakpoint(
            id: 'tablet',
            name: 'Tablet',
            minWidth: 600,
            designSize: ir.StageSize(width: 700, height: 800),
            inheritsFrom: 'desktop',
          ),
        ],
      );
      final c = await pumpManager(tester, doc);
      await open(tester);
      await tester.tap(find.text('Desktop'));
      await tester.pumpAndSettle();
      // Desktop → inherits from Tablet: a cycle.
      await tester.tap(find.byKey(const ValueKey('bp-inherits')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tablet').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bp-error')), findsOneWidget);
      final save = tester.widget<SsButton>(
        find.byKey(const ValueKey('bp-save')),
      );
      expect(save.onPressed, isNull);
      // Back to the shared base, rename, save.
      await tester.tap(find.byKey(const ValueKey('bp-inherits')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shared base only').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('bp-name')), 'Laptop');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bp-save')));
      await tester.pumpAndSettle();
      final b = c.read(editorControllerProvider).document.breakpoints.first;
      expect(b.name, 'Laptop');
      expect(b.inheritsFrom, isNull);
    });

    testWidgets('remove asks first, then drops the breakpoint and its '
        'patches', (tester) async {
      var doc = interactionDoc().copyWith(
        breakpoints: [
          ...kBps,
          const ir.Breakpoint(
            id: 'tablet',
            name: 'Tablet',
            minWidth: 600,
            designSize: ir.StageSize(width: 700, height: 800),
            inheritsFrom: 'desktop',
            primary: true,
          ),
        ],
      );
      doc = _patch(doc, 'a', 'tablet');
      final c = await pumpManager(tester, doc);
      await open(tester);
      await tester.tap(find.text('Tablet'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bp-remove')));
      await tester.pumpAndSettle();
      expect(find.textContaining('on 1 layer'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      final after = c.read(editorControllerProvider).document;
      expect(after.breakpoints.map((b) => b.id), ['desktop', 'mobile']);
      expect(
        ir.DocumentIndex.of(after).node('a')!.common.breakpointOverrides,
        isEmpty,
      );
      c.read(editorControllerProvider.notifier).undo();
      expect(
        c.read(editorControllerProvider).document.breakpoints,
        hasLength(3),
      );
    });
  });
}

Future<ProviderContainer> _pumpInspector(
  WidgetTester tester,
  ir.StageDocument doc,
) async {
  tester.view.physicalSize = const Size(330, 940);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialDocumentProvider.overrideWithValue(doc)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, c) => SsScope(theme: SsThemeData.dark(), child: c!),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 288, height: 900, child: Inspector()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}
