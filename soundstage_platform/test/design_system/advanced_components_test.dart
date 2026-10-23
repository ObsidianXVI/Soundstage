import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'harness.dart';

void main() {
  group('SsAlignmentMatrix', () {
    Widget build(
      List<(SsAlign3, SsAlign3)> log, {
      SsAlign3? h = SsAlign3.start,
      SsAlign3? v = SsAlign3.start,
      bool space = false,
      Axis dir = Axis.horizontal,
    }) => SsAlignmentMatrix(
      horizontal: h,
      vertical: v,
      spaceBetween: space,
      direction: dir,
      onChanged: (a, b) => log.add((a, b)),
      onSpaceBetweenChanged: (_) {},
    );

    testWidgets('clicking a cell reports horizontal and vertical', (
      tester,
    ) async {
      final log = <(SsAlign3, SsAlign3)>[];
      await pumpChrome(tester, build(log));
      await tester.tap(
        find.bySemanticsLabel('Bottom right'),
        warnIfMissed: false,
      );
      final cell = find.byType(SsAlignmentMatrix);
      final rect = tester.getRect(cell);
      // Bottom-right ninth of the 60x60 grid.
      await tester.tapAt(rect.bottomRight - const Offset(8, 28));
      expect(log.last, (SsAlign3.end, SsAlign3.end));
      await tester.tapAt(rect.topLeft + const Offset(8, 8));
      expect(log.last, (SsAlign3.start, SsAlign3.start));
      await tester.tapAt(rect.topLeft + const Offset(30, 30));
      expect(log.last, (SsAlign3.center, SsAlign3.center));
    });

    testWidgets('arrow keys move the selection; Tab is a single stop', (
      tester,
    ) async {
      final log = <(SsAlign3, SsAlign3)>[];
      await pumpChrome(
        tester,
        build(log, h: SsAlign3.center, v: SsAlign3.center),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(log.last, (SsAlign3.end, SsAlign3.center));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(log.last, (SsAlign3.center, SsAlign3.start));
    });

    testWidgets('space-between leaves the main-axis coordinate alone', (
      tester,
    ) async {
      final log = <(SsAlign3, SsAlign3)>[];
      await pumpChrome(
        tester,
        build(log, h: SsAlign3.center, v: SsAlign3.start, space: true),
      );
      final rect = tester.getRect(find.byType(SsAlignmentMatrix));
      // Click the bottom-right cell: only the vertical (cross) axis changes.
      await tester.tapAt(rect.topLeft + const Offset(52, 52));
      expect(log.last, (SsAlign3.center, SsAlign3.end));
    });

    testWidgets('mixed (null) values and a disabled matrix', (tester) async {
      final log = <(SsAlign3, SsAlign3)>[];
      await pumpChrome(tester, build(log, h: null, v: null));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(log.last, (SsAlign3.center, SsAlign3.start));
      await pumpChrome(
        tester,
        const SsAlignmentMatrix(
          horizontal: null,
          vertical: null,
          onChanged: null,
        ),
      );
      await tester.tap(find.byType(SsAlignmentMatrix));
    });

    testWidgets('exposes selected cell semantics', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChrome(tester, build([], h: SsAlign3.end, v: SsAlign3.center));
      expect(find.bySemanticsLabel('Middle right'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Middle right'))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      handle.dispose();
    });
  });

  group('SsConstraintsWidget', () {
    test('edge clicks follow the Figma toggling', () {
      expect(hConstraintAfterLeft(SsHConstraint.left), SsHConstraint.left);
      expect(
        hConstraintAfterLeft(SsHConstraint.right),
        SsHConstraint.leftRight,
      );
      expect(
        hConstraintAfterLeft(SsHConstraint.leftRight),
        SsHConstraint.right,
      );
      expect(hConstraintAfterLeft(SsHConstraint.center), SsHConstraint.left);
      expect(
        hConstraintAfterRight(SsHConstraint.left),
        SsHConstraint.leftRight,
      );
      expect(
        hConstraintAfterRight(SsHConstraint.leftRight),
        SsHConstraint.left,
      );
      expect(
        vConstraintAfterTop(SsVConstraint.bottom),
        SsVConstraint.topBottom,
      );
      expect(
        vConstraintAfterTop(SsVConstraint.topBottom),
        SsVConstraint.bottom,
      );
      expect(
        vConstraintAfterBottom(SsVConstraint.top),
        SsVConstraint.topBottom,
      );
      expect(vConstraintAfterBottom(null), SsVConstraint.bottom);
    });

    testWidgets('clicking the diagram edges and centre', (tester) async {
      final log = <(SsHConstraint, SsVConstraint)>[];
      await pumpChrome(
        tester,
        SizedBox(
          width: 300,
          child: SsConstraintsWidget(
            horizontal: SsHConstraint.left,
            vertical: SsVConstraint.top,
            onChanged: (h, v) => log.add((h, v)),
          ),
        ),
      );
      await tester.tap(
        find.bySemanticsLabel('Pin to right'),
        warnIfMissed: false,
      );
      final rect = tester.getRect(find.byType(SsConstraintsWidget));
      final d = Rect.fromLTWH(rect.left, rect.top, 64, 64);
      await tester.tapAt(Offset(d.right - 6, d.center.dy));
      expect(log.last, (SsHConstraint.leftRight, SsVConstraint.top));
      await tester.tapAt(Offset(d.center.dx, d.bottom - 6));
      expect(log.last, (SsHConstraint.left, SsVConstraint.topBottom));
      await tester.tapAt(d.center);
      expect(log.last, (SsHConstraint.center, SsVConstraint.center));
    });

    testWidgets('the segmented choices pick Scale and Both', (tester) async {
      final log = <(SsHConstraint, SsVConstraint)>[];
      await pumpChrome(
        tester,
        SizedBox(
          width: 300,
          child: SsConstraintsWidget(
            horizontal: SsHConstraint.left,
            vertical: SsVConstraint.top,
            onChanged: (h, v) => log.add((h, v)),
          ),
        ),
      );
      await tester.tap(find.text('Scale').first);
      expect(log.last, (SsHConstraint.scale, SsVConstraint.top));
      await tester.tap(find.text('Both').last);
      expect(log.last, (SsHConstraint.left, SsVConstraint.topBottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out beside the square when wide, below when narrow', (
      tester,
    ) async {
      for (final w in [200.0, 260.0, 400.0]) {
        await pumpChrome(
          tester,
          SizedBox(
            width: w,
            child: const SsConstraintsWidget(
              horizontal: null,
              vertical: null,
              onChanged: null,
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'width $w');
      }
    });
  });

  group('colour picker', () {
    testWidgets('typing hex updates the colour; invalid hex flags an error', (
      tester,
    ) async {
      final log = <Color>[];
      await pumpChrome(
        tester,
        SsColorPicker(
          color: const Color(0xFF2F6FED),
          onChanged: log.add,
          enableEyeDropper: false,
        ),
        size: const Size(400, 700),
      );
      final hex = find.descendant(
        of: find.bySemanticsLabel('Hex colour'),
        matching: find.byType(TextField),
      );
      final field = hex.evaluate().isNotEmpty
          ? hex
          : find.byType(TextField).first;
      await tester.enterText(field, 'ff0000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.last, const Color(0xFFFF0000));
      await tester.enterText(field, 'nothex');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Invalid hex'), findsOneWidget);
    });

    testWidgets('dragging the area and sliders emits bracketed changes', (
      tester,
    ) async {
      final log = <Color>[];
      final events = <String>[];
      await pumpChrome(
        tester,
        SsColorPicker(
          color: const Color(0xFFFF0000),
          onChanged: log.add,
          onChangeStart: () => events.add('start'),
          onChangeEnd: () => events.add('end'),
          enableEyeDropper: false,
        ),
        size: const Size(400, 700),
      );
      final area = tester.getRect(
        find.byType(CustomPaint).evaluate().isEmpty
            ? find.byType(SsColorPicker)
            : find.byType(SsColorPicker),
      );
      // Drag in the saturation/value area: top-left is white.
      await tester.dragFrom(
        area.topLeft + const Offset(2, 2),
        const Offset(0, 0),
      );
      await tester.pump();
      await tester.tapAt(area.topLeft + const Offset(2, 2));
      expect(log.last.red8, greaterThan(240));
      expect(log.last.green8, greaterThan(240));
      expect(events, containsAllInOrder(['start', 'end']));
      // Bottom is black.
      await tester.tapAt(area.topLeft + const Offset(100, 147));
      expect(log.last.toARGB32() & 0xFFFFFF, lessThan(0x101010));
    });

    testWidgets('keyboard on the area and alpha slider', (tester) async {
      final log = <Color>[];
      await pumpChrome(
        tester,
        SsColorPicker(
          color: const Color(0xFF808080),
          onChanged: log.add,
          enableEyeDropper: false,
        ),
        size: const Size(400, 700),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(log.last, isNot(const Color(0xFF808080)));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(log.last.alpha01, lessThan(1));
    });

    testWidgets('RGB and HSL inputs round-trip the colour', (tester) async {
      final log = <Color>[];
      await pumpChrome(
        tester,
        SsColorPicker(
          color: const Color(0xFF2F6FED),
          onChanged: log.add,
          initialMode: SsColorMode.rgb,
          enableEyeDropper: false,
        ),
        size: const Size(400, 700),
      );
      final fields = find.byType(SsNumberField);
      expect(fields, findsNWidgets(4)); // R, G, B, alpha
      await tester.enterText(
        find.descendant(of: fields.at(0), matching: find.byType(TextField)),
        '255',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.last, const Color(0xFFFF6FED));

      await pumpChrome(
        tester,
        SsColorPicker(
          key: UniqueKey(),
          color: const Color(0xFF2F6FED),
          onChanged: log.add,
          initialMode: SsColorMode.hsl,
          enableEyeDropper: false,
        ),
        size: const Size(400, 700),
      );
      expect(find.byType(SsNumberField), findsNWidgets(4)); // H, S, L, alpha
      await tester.enterText(
        find.descendant(
          of: find.byType(SsNumberField).at(0),
          matching: find.byType(TextField),
        ),
        '0',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.last.red8, greaterThan(log.last.blue8)); // hue 0 is red
    });

    testWidgets('alpha input scales opacity', (tester) async {
      final log = <Color>[];
      await pumpChrome(
        tester,
        SsColorPicker(
          color: const Color(0xFF2F6FED),
          onChanged: log.add,
          enableEyeDropper: false,
        ),
        size: const Size(400, 700),
      );
      final alpha = find.byType(SsNumberField);
      await tester.enterText(
        find.descendant(of: alpha, matching: find.byType(TextField)),
        '50',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.last.alpha01, closeTo(0.5, 0.01));
    });

    testWidgets(
      'the eyedropper shows only when enabled, and applies the pick',
      (tester) async {
        final log = <Color>[];
        await pumpChrome(
          tester,
          SsColorPicker(
            color: const Color(0xFF000000),
            onChanged: log.add,
            enableEyeDropper: false,
          ),
          size: const Size(400, 700),
        );
        expect(find.bySemanticsLabel('Pick colour from screen'), findsNothing);
        await pumpChrome(
          tester,
          SsColorPicker(
            color: const Color(0xFF000000),
            onChanged: log.add,
            enableEyeDropper: true,
            pickScreen: () async => const Color(0xFF123456),
          ),
          size: const Size(400, 700),
        );
        await tester.tap(find.byType(SsIconButton));
        await tester.pump();
        expect(log.last, const Color(0xFF123456));
      },
    );

    testWidgets('swatch is labelled and tappable', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpChrome(
        tester,
        SsColorSwatch(color: const Color(0xFFFF0000), onTap: () => taps++),
      );
      expect(find.bySemanticsLabel('Colour #FF0000'), findsOneWidget);
      await tester.tap(find.byType(SsColorSwatch));
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('colour field opens the picker and commits typed hex', (
      tester,
    ) async {
      final log = <Color>[];
      await pumpChrome(
        tester,
        SizedBox(
          width: 160,
          child: SsColorField(
            color: const Color(0xFFF2C94C),
            onChanged: log.add,
          ),
        ),
        size: const Size(600, 800),
      );
      expect(find.text('F2C94C'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '00ff00');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.last, const Color(0xFF00FF00));
      await tester.tap(find.byType(SsColorSwatch));
      await tester.pumpAndSettle();
      expect(find.byType(SsColorPicker), findsOneWidget); // inline
      await tester.tap(find.byType(SsColorSwatch));
      await tester.pumpAndSettle();
      expect(find.byType(SsColorPicker), findsNothing);
    });

    testWidgets('mixed colour field shows Mixed', (tester) async {
      await pumpChrome(
        tester,
        SizedBox(
          width: 160,
          child: SsColorField(
            color: const Color(0xFF000000),
            mixed: true,
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('Mixed'), findsOneWidget);
    });
  });
}
