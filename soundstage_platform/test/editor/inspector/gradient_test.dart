import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/sections/paint_gradient_editor.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';
import 'paint_test_utils.dart';

const _red = ir.StageColor(r: 1, g: 0, b: 0);
const _blue = ir.StageColor(r: 0, g: 0, b: 1);

ir.StageDocument _doc({
  ir.GradientKind kind = ir.GradientKind.linear,
  List<ir.ColorStop> stops = const [
    ir.ColorStop(position: 0, color: _red),
    ir.ColorStop(position: 1, color: _blue),
  ],
}) => inspectorDoc([
  rect(
    'a',
    appearance: ir.Appearance(
      fills: [ir.Paint.gradient(id: 'g', kind: kind, stops: stops)],
    ),
  ),
]);

ir.GradientPaint _g(ProviderContainer c) =>
    fillsOf(c, 'a').single as ir.GradientPaint;

int _undo(ProviderContainer c) =>
    c.read(editorControllerProvider.notifier).history.undoDepth;

Future<ProviderContainer> _open(
  WidgetTester tester,
  ir.StageDocument doc, {
  double width = 288,
}) async {
  final c = await pumpPaints(tester, doc, select: {'a'}, width: width);
  await tapKey(tester, 'paint-swatch:g');
  return c;
}

/// The global point of position [p] on the stops bar.
Offset _barAt(WidgetTester tester, double p) {
  final bar = find.byKey(const ValueKey('gradient-bar:g'));
  final tl = tester.getTopLeft(bar);
  final size = tester.getSize(bar);
  return Offset(tl.dx + 6 + p * (size.width - 12), tl.dy + size.height / 2);
}

void main() {
  group('angle maths', () {
    test('0° is top → bottom; 90° is right → left', () {
      const h = ir.GradientHandles();
      expect(gradientAngle(h, 100, 50), 0);
      final r = handlesForAngle(h, 90, 100, 50);
      // Length 50 px kept: half a 100 px width.
      expect(r.start, const ir.StagePoint(x: 0.75, y: 0.5));
      expect(r.end, const ir.StagePoint(x: 0.25, y: 0.5));
      final back = ir.GradientHandles(start: r.start, end: r.end);
      expect(gradientAngle(back, 100, 50), closeTo(90, 1e-6));
    });

    test('colour interpolation between stops', () {
      final c = gradientColorAt(const [
        ir.ColorStop(position: 0, color: _red),
        ir.ColorStop(position: 1, color: _blue),
      ], 0.25);
      expect(c.r, closeTo(0.75, 1e-6));
      expect(c.b, closeTo(0.25, 1e-6));
    });
  });

  testWidgets('clicking the bar adds an interpolated stop, sorted', (
    tester,
  ) async {
    final c = await _open(tester, _doc());
    final before = _undo(c);
    await tester.tapAt(_barAt(tester, 0.5));
    await tester.pump();
    final g = _g(c);
    expect(g.stops.length, 3);
    expect([for (final s in g.stops) s.position], [0, 0.5, 1]);
    expect(g.stops[1].color.r, closeTo(0.5, 1e-3));
    expect(_undo(c), before + 1);
    // The new stop is selected.
    expect(find.text('Stop 2'), findsOneWidget);
  });

  testWidgets('dragging a stop moves it live, clamped, in one undo step', (
    tester,
  ) async {
    final c = await _open(
      tester,
      _doc(
        stops: const [
          ir.ColorStop(position: 0, color: _red),
          ir.ColorStop(position: 0.5, color: _red),
          ir.ColorStop(position: 1, color: _blue),
        ],
      ),
    );
    final before = _undo(c);
    final g = await tester.startGesture(_barAt(tester, 0));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(4, 0));
      await tester.pump();
    }
    final mid = _g(c).stops.first.position;
    expect(mid, greaterThan(0));
    // Past its neighbour at 50 %: held there, order kept.
    await g.moveTo(_barAt(tester, 0.9));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(_g(c).stops.first.position, 0.5);
    expect(_g(c).stops[1].position, 0.5);
    expect(_undo(c), before + 1);
  });

  testWidgets('delete by button and Backspace, never below two stops', (
    tester,
  ) async {
    final c = await _open(
      tester,
      _doc(
        stops: const [
          ir.ColorStop(position: 0, color: _red),
          ir.ColorStop(position: 0.5, color: _red),
          ir.ColorStop(position: 1, color: _blue),
          ir.ColorStop(position: 1, color: _blue),
        ],
      ),
    );
    await tester.tapAt(_barAt(tester, 0.5));
    await tester.pump();
    expect(find.text('Stop 2'), findsOneWidget);
    await tapKey(tester, 'gradient-stop-delete');
    expect(_g(c).stops.length, 3);
    // Select the first and delete with the keyboard.
    await tester.tapAt(_barAt(tester, 0));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect([for (final s in _g(c).stops) s.position], [1, 1]);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(_g(c).stops.length, 2, reason: 'two stops minimum');
    final del = tester.widget<SsIconButton>(
      find.byKey(const ValueKey('gradient-stop-delete')),
    );
    expect(del.onPressed, isNull);
  });

  testWidgets('the selected stop edits its colour and position', (
    tester,
  ) async {
    final c = await _open(tester, _doc());
    await typeInto(tester, 'fills.g.stops.0.color', '00ff00');
    expect(_g(c).stops.first.color, const ir.StageColor(r: 0, g: 1, b: 0));
    await typeInto(tester, 'fills.g.stops.0.position', '30');
    expect(_g(c).stops.first.position, closeTo(0.3, 1e-9));
  });

  testWidgets('typing a position past a neighbour re-sorts the stops', (
    tester,
  ) async {
    final c = await _open(tester, _doc());
    await typeInto(tester, 'fills.g.stops.0.position', '80');
    // Within its neighbours (0..1): a plain move.
    expect([for (final s in _g(c).stops) s.position], [0.8, 1]);
    await tester.tapAt(_barAt(tester, 1));
    await tester.pump();
    await typeInto(tester, 'fills.g.stops.1.position', '10');
    expect([for (final s in _g(c).stops) s.position], [0.1, 0.8]);
    expect(_g(c).stops.first.color, _blue);
  });

  testWidgets('angle rewrites both handles; reverse flips the stops', (
    tester,
  ) async {
    final c = await _open(tester, _doc());
    final angle = find.descendant(
      of: find.byKey(const ValueKey('gradient-angle:g')),
      matching: find.byType(EditableText),
    );
    await tester.tap(angle);
    await tester.pump();
    await tester.enterText(angle, '90');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    final h = _g(c).handles;
    expect(h.start, const ir.StagePoint(x: 0.75, y: 0.5));
    expect(h.end, const ir.StagePoint(x: 0.25, y: 0.5));
    await tapKey(tester, 'gradient-swap:g');
    expect(_g(c).stops.first.color, _blue);
    expect(_g(c).stops.last.color, _red);
  });

  testWidgets('radial gradients edit their handles numerically', (
    tester,
  ) async {
    final c = await _open(tester, _doc(kind: ir.GradientKind.radial));
    expect(find.byKey(const ValueKey('gradient-angle:g')), findsNothing);
    await typeInto(tester, 'fills.g.handles.start.x', '25');
    expect(_g(c).handles.start, const ir.StagePoint(x: 0.25, y: 0));
    await typeInto(tester, 'fills.g.handles.width.y', '40');
    expect(_g(c).handles.width.y, closeTo(0.4, 1e-9));
  });

  for (final width in [288.0, 240.0]) {
    for (final kind in [ir.GradientKind.linear, ir.GradientKind.diamond]) {
      testWidgets('${kind.name} editor fits at $width px', (tester) async {
        await _open(tester, _doc(kind: kind), width: width);
        expect(find.byKey(const ValueKey('gradient-bar:g')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
