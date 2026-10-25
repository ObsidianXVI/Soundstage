import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/easing/easing_curve.dart';
import 'package:soundstage_platform/editor/easing/easing_editor.dart';
import 'package:soundstage_platform/editor/easing/easing_preview.dart';
import 'package:soundstage_platform/ir/ir.dart';

// The easing editor widget (m2.md "Easing editor"): modes, presets, bezier
// handles and fields, copy/paste, spring, steps, hold, Mixed and the
// preview, driven through a host that records what it was told.

class _Host extends StatefulWidget {
  const _Host({required this.initial, this.log});

  final List<Easing> initial;
  final _Log? log;

  @override
  State<_Host> createState() => _HostState();
}

class _Log {
  final List<Easing> changes = [];
  int starts = 0, ends = 0;
}

class _HostState extends State<_Host> {
  late List<Easing> easings = widget.initial;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 276,
      child: EasingEditor(
        easings: easings,
        onGestureStart: () => widget.log?.starts++,
        onGestureEnd: () => widget.log?.ends++,
        onChanged: (e) {
          widget.log?.changes.add(e);
          setState(() => easings = [for (final _ in easings) e]);
        },
      ),
    ),
  );
}

Future<_Log> _pump(WidgetTester tester, List<Easing> initial) async {
  tester.view.physicalSize = const Size(700, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final log = _Log();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (c, child) => SsScope(theme: SsThemeData.dark(), child: child!),
      home: Scaffold(
        body: _Host(initial: initial, log: log),
      ),
    ),
  );
  await tester.pump();
  return log;
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

EasingCurvePainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_key('easing-curve')).painter!
        as EasingCurvePainter;

/// The global position of bezier handle [i] (0: x1/y1, 1: x2/y2).
Offset _handle(WidgetTester tester, int i) {
  final p = _painter(tester);
  final c = p.controls!;
  final box = tester.getTopLeft(_key('easing-curve'));
  final size = tester.getSize(_key('easing-curve'));
  return box + (i == 0 ? p.toPx(size, c.$1, c.$2) : p.toPx(size, c.$3, c.$4));
}

Future<void> _type(WidgetTester tester, String field, String text) async {
  final f = find.descendant(
    of: _key('easing-field:$field'),
    matching: find.byType(EditableText),
  );
  await tester.tap(f);
  await tester.pump();
  await tester.enterText(f, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  const ease = Easing.preset(EasingPreset.ease);

  group('modes', () {
    testWidgets(
      'each tab writes a default of its kind and shows its controls',
      (tester) async {
        final log = await _pump(tester, [const Easing.linear()]);
        expect(_key('easing-preset:easeInBack'), findsOneWidget);

        await tester.tap(find.text('Bezier'));
        await tester.pump();
        // Seeded from the previous curve (linear: 0,0,1,1) with handles shown.
        expect(log.changes.last, const Easing.cubicBezier(0, 0, 1, 1));
        expect(_key('easing-field:x1'), findsOneWidget);
        expect(_painter(tester).controls, isNotNull);

        await tester.tap(find.text('Spring'));
        await tester.pump();
        expect(log.changes.last, const Easing.spring());
        expect(_key('spring-mass'), findsOneWidget);
        expect(_key('spring-settle'), findsOneWidget);
        expect(_painter(tester).controls, isNull);

        await tester.tap(find.text('Steps'));
        await tester.pump();
        expect(log.changes.last, const Easing.steps(4));
        expect(_key('steps-count'), findsOneWidget);

        await tester.tap(find.text('Hold'));
        await tester.pump();
        expect(log.changes.last, const Easing.hold());
        expect(find.textContaining('Holds the start value'), findsOneWidget);

        await tester.tap(find.text('Preset'));
        await tester.pump();
        expect(log.changes.last, ease);
        expect(log.changes, hasLength(5));
        // Re-selecting the current mode writes nothing.
        await tester.tap(find.text('Preset'));
        await tester.pump();
        expect(log.changes, hasLength(5));
      },
    );

    testWidgets('switching from a preset to Bezier keeps its shape', (
      tester,
    ) async {
      final log = await _pump(tester, [
        const Easing.preset(EasingPreset.easeOutBack),
      ]);
      await tester.tap(find.text('Bezier'));
      await tester.pump();
      expect(log.changes.single, const Easing.cubicBezier(0.34, 1.56, 0.64, 1));
    });

    testWidgets('the preset grid offers linear, the CSS family and Back', (
      tester,
    ) async {
      final log = await _pump(tester, [const Easing.linear()]);
      for (final k in [
        'linear',
        'ease',
        'easeIn',
        'easeOut',
        'easeInOut',
        'easeInBack',
        'easeOutBack',
        'easeInOutBack',
      ]) {
        expect(_key('easing-preset:$k'), findsOneWidget, reason: k);
      }
      await tester.tap(_key('easing-preset:easeInOutBack'));
      await tester.pump();
      expect(
        log.changes.single,
        const Easing.preset(EasingPreset.easeInOutBack),
      );
      // The curve overshoots, and the plot makes room for it.
      final p = _painter(tester);
      expect(p.lo, lessThan(0));
      expect(p.hi, greaterThan(1));
      await tester.tap(_key('easing-preset:linear'));
      await tester.pump();
      expect(log.changes.last, const Easing.linear());
    });
  });

  group('cubic bezier', () {
    testWidgets('dragging a handle moves it, y may overshoot, one gesture', (
      tester,
    ) async {
      final log = await _pump(tester, [
        const Easing.cubicBezier(0.25, 0.1, 0.25, 1),
      ]);
      final from = _handle(tester, 0);
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      // Up to above the 0-1 band, to the right.
      for (var i = 1; i <= 6; i++) {
        await g.moveBy(const Offset(6, -22));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(log.starts, 1);
      expect(log.ends, 1);
      expect(log.changes.length, greaterThan(3));
      final e = log.changes.last as CubicBezierEasing;
      expect(e.x1, greaterThan(0.25));
      expect(e.y1, greaterThan(1), reason: 'y overshoots 1');
      // The second handle did not move.
      expect((e.x2, e.y2), (0.25, 1));
      // The plot grew to show the overshoot, and its field shows it.
      expect(_painter(tester).hi, greaterThan(e.y1));
      expect(_key('easing-field:y1'), findsOneWidget);
      // A drag below 0 undershoots.
      final g2 = await tester.startGesture(
        _handle(tester, 1),
        kind: PointerDeviceKind.mouse,
      );
      await g2.moveBy(const Offset(0, 400));
      await tester.pump();
      await g2.up();
      await tester.pump();
      final f = log.changes.last as CubicBezierEasing;
      expect(f.y2, lessThan(0));
      expect(f.y2, greaterThanOrEqualTo(kMinHandleY));
      expect((f.x1, f.y1), (e.x1, e.y1));
      expect(log.starts, 2);
    });

    testWidgets('x stays within 0 and 1', (tester) async {
      final log = await _pump(tester, [
        const Easing.cubicBezier(0.25, 0.1, 0.75, 1),
      ]);
      final g = await tester.startGesture(
        _handle(tester, 1),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(900, 0));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect((log.changes.last as CubicBezierEasing).x2, 1);
      final g2 = await tester.startGesture(
        _handle(tester, 0),
        kind: PointerDeviceKind.mouse,
      );
      await g2.moveBy(const Offset(-900, 0));
      await tester.pump();
      await g2.up();
      await tester.pump();
      expect((log.changes.last as CubicBezierEasing).x1, 0);
    });

    testWidgets('numeric entry: fields clamp x, allow y to overshoot', (
      tester,
    ) async {
      final log = await _pump(tester, [
        const Easing.cubicBezier(0.25, 0.1, 0.25, 1),
      ]);
      await _type(tester, 'y1', '1.8');
      expect(log.changes.last, const Easing.cubicBezier(0.25, 1.8, 0.25, 1));
      await _type(tester, 'x2', '5');
      expect(log.changes.last, const Easing.cubicBezier(0.25, 1.8, 1, 1));
      await _type(tester, 'y2', '-0.5');
      expect(log.changes.last, const Easing.cubicBezier(0.25, 1.8, 1, -0.5));
      await _type(tester, 'x1', '0.5');
      expect(log.changes.last, const Easing.cubicBezier(0.5, 1.8, 1, -0.5));
      // The curve is redrawn from the new numbers.
      expect(_painter(tester).controls, (0.5, 1.8, 1.0, -0.5));
    });

    testWidgets('copy writes cubic-bezier(...); paste reads it back', (
      tester,
    ) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
            return null;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': clipboard};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final log = await _pump(tester, [
        const Easing.cubicBezier(0.34, 1.56, 0.64, 1),
      ]);
      await tester.tap(_key('easing-copy'));
      await tester.pump();
      expect(clipboard, 'cubic-bezier(0.34, 1.56, 0.64, 1)');

      clipboard = 'cubic-bezier(0.1, -0.6, 0.9, 1.7)';
      await tester.tap(_key('easing-paste'));
      await tester.pump();
      await tester.pump();
      expect(log.changes.last, const Easing.cubicBezier(0.1, -0.6, 0.9, 1.7));

      clipboard = 'something else';
      await tester.tap(_key('easing-paste'));
      await tester.pump();
      await tester.pump();
      expect(_key('easing-notice'), findsOneWidget);
      expect(
        log.changes,
        hasLength(1),
        reason: 'an invalid paste writes nothing',
      );
    });

    testWidgets('the cubic-bezier text field accepts a typed value', (
      tester,
    ) async {
      final log = await _pump(tester, [const Easing.cubicBezier(0, 0, 1, 1)]);
      final f = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('easing-css:'),
      );
      final text = find.descendant(of: f, matching: find.byType(EditableText));
      await tester.tap(text);
      await tester.pump();
      await tester.enterText(text, 'cubic-bezier(0.2, 0.8, 0.4, 1.4)');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.changes.last, const Easing.cubicBezier(0.2, 0.8, 0.4, 1.4));
    });
  });

  group('spring, steps and hold', () {
    testWidgets('spring fields edit the parameters and show the settle time', (
      tester,
    ) async {
      final log = await _pump(tester, [const Easing.spring()]);
      final settle = springSettleTime(1, 100, 15);
      expect(
        find.text('Settle time ${settle.toStringAsFixed(2)} s'),
        findsOneWidget,
      );
      Future<void> type(String key, String text) async {
        final f = find.descendant(
          of: _key(key),
          matching: find.byType(EditableText),
        );
        await tester.tap(f);
        await tester.pump();
        await tester.enterText(f, text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      await type('spring-damping', '4');
      expect(log.changes.last, const Easing.spring(damping: 4));
      // Under-damped: the response overshoots 1.
      expect(_painter(tester).hi, greaterThan(1.2));
      await type('spring-mass', '2');
      await type('spring-stiffness', '300');
      expect(
        log.changes.last,
        const Easing.spring(mass: 2, stiffness: 300, damping: 4),
      );
      final next = springSettleTime(2, 300, 4);
      expect(
        find.text('Settle time ${next.toStringAsFixed(2)} s'),
        findsOneWidget,
      );
    });

    testWidgets('steps: count and jump position', (tester) async {
      final log = await _pump(tester, [const Easing.steps(4)]);
      final f = find.descendant(
        of: _key('steps-count'),
        matching: find.byType(EditableText),
      );
      await tester.tap(f);
      await tester.pump();
      await tester.enterText(f, '6');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.changes.last, const Easing.steps(6));
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(
        log.changes.last,
        const Easing.steps(6, position: StepPosition.jumpStart),
      );
      await tester.tap(find.text('End'));
      await tester.pump();
      expect(log.changes.last, const Easing.steps(6));
    });
  });

  group('Mixed', () {
    testWidgets('different easings show Mixed; picking one sets them all', (
      tester,
    ) async {
      final log = await _pump(tester, [
        const Easing.linear(),
        const Easing.spring(),
        ease,
      ]);
      expect(_key('easing-mixed'), findsOneWidget);
      expect(find.text('Easing · 3 segments'), findsOneWidget);
      expect(_key('easing-curve'), findsNothing);
      expect(_key('easing-preview'), findsNothing);
      // The presets are offered, and nothing is selected.
      await tester.tap(_key('easing-preset:easeIn'));
      await tester.pump();
      expect(log.changes.single, const Easing.preset(EasingPreset.easeIn));
      expect(_key('easing-mixed'), findsNothing);
      expect(_key('easing-curve'), findsOneWidget);
    });

    testWidgets('equal easings are not Mixed', (tester) async {
      await _pump(tester, [ease, ease]);
      expect(_key('easing-mixed'), findsNothing);
      expect(find.text('Easing · 2 segments'), findsOneWidget);
    });

    testWidgets('a mode tab on Mixed seeds every segment', (tester) async {
      final log = await _pump(tester, [const Easing.linear(), ease]);
      await tester.tap(find.text('Hold'));
      await tester.pump();
      expect(log.changes.single, const Easing.hold());
    });
  });

  group('preview', () {
    testWidgets('the dot travels along the curve while the preview loops', (
      tester,
    ) async {
      await _pump(tester, [const Easing.linear()]);
      double dotX() => tester.getCenter(_key('easing-preview-dot')).dx;
      final x0 = dotX();
      await tester.pump(kPreviewLoop * 0.42);
      final mid = dotX();
      await tester.pump(kPreviewLoop * 0.4);
      final end = dotX();
      expect(mid, greaterThan(x0));
      expect(end, greaterThan(mid));
      // After the loop it returns to the start.
      await tester.pump(kPreviewLoop * 0.19);
      expect(dotX(), lessThan(end));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('previewProgress rests at both ends', (tester) async {
      expect(previewProgress(0), 0);
      expect(previewProgress(0.05), 0);
      expect(previewProgress(0.42), closeTo(0.5, 1e-9));
      expect(previewProgress(0.9), 1);
      expect(previewProgress(1), 1);
    });

    testWidgets('an overshooting easing carries the dot past the end', (
      tester,
    ) async {
      await _pump(tester, [const Easing.preset(EasingPreset.easeOutBack)]);
      final rail = tester.getTopRight(_key('easing-preview')).dx;
      var max = 0.0;
      for (var i = 0; i < 20; i++) {
        await tester.pump(kPreviewLoop * 0.05);
        final x = tester.getCenter(_key('easing-preview-dot')).dx;
        if (x > max) max = x;
      }
      // The rail's end marker sits at 86 % of the width; the dot passes it.
      final endMarker =
          rail - (rail - tester.getTopLeft(_key('easing-preview')).dx) * 0.14;
      expect(max, greaterThan(endMarker));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion: the dot does not move', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pump(tester, [const Easing.linear()]);
      final x0 = tester.getCenter(_key('easing-preview-dot')).dx;
      await tester.pump(kPreviewLoop * 0.4);
      expect(tester.getCenter(_key('easing-preview-dot')).dx, x0);
      await tester.pump(kPreviewLoop);
      expect(tester.getCenter(_key('easing-preview-dot')).dx, x0);
      // (and it rests at the end value, not the start)
      expect(
        find.bySemanticsLabel('Preview (paused: reduced motion)'),
        findsOneWidget,
      );
      // A pump to idle settles: nothing is animating.
      await tester.pumpAndSettle();
    });
  });
}
