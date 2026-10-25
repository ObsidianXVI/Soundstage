import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'harness.dart';

Widget _field({
  double? value = 100,
  bool mixed = false,
  double? min,
  double? max,
  double step = 1,
  String? unit,
  required List<double> log,
  List<String>? events,
}) {
  return SizedBox(
    width: 120,
    child: SsNumberField(
      label: 'X',
      value: value,
      mixed: mixed,
      min: min,
      max: max,
      step: step,
      unit: unit,
      onChanged: log.add,
      onChangeStart: () => events?.add('start'),
      onChangeEnd: () => events?.add('end'),
    ),
  );
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(textFieldIn(SsNumberField), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

String _text(WidgetTester tester) =>
    tester.widget<TextField>(textFieldIn(SsNumberField)).controller!.text;

void main() {
  testWidgets('shows the value and the unit', (tester) async {
    await pumpChrome(tester, _field(unit: 'px', log: []));
    expect(_text(tester), '100');
    expect(find.text('px'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
  });

  testWidgets('arithmetic on Enter: 120/2 and +8', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(log: log));
    await _type(tester, '120/2');
    expect(log, [60]);
    expect(_text(tester), '60');
    await _type(tester, '+8'); // relative to the widget's value (100)
    expect(log.last, 108);
  });

  testWidgets('invalid text reverts without a change', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(log: log));
    await _type(tester, '1/0');
    expect(log, isEmpty);
    expect(_text(tester), '100');
  });

  testWidgets('clamps to min and max and rounds', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(min: 0, max: 200, log: log));
    await _type(tester, '999');
    expect(log.last, 200);
    await _type(tester, '-50');
    expect(log.last, 0);
    await _type(tester, '1.23456');
    expect(log.last, 1.23);
  });

  testWidgets('Escape cancels and drops focus', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(log: log));
    await tester.enterText(textFieldIn(SsNumberField), '77');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_text(tester), '100');
    expect(log, isEmpty);
    expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);
    expect(
      tester.widget<TextField>(textFieldIn(SsNumberField)).focusNode!.hasFocus,
      isFalse,
    );
  });

  testWidgets('blur commits', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(log: log));
    await tester.enterText(textFieldIn(SsNumberField), '33');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(log, [33]);
  });

  testWidgets('arrow keys step; Shift x10; Alt x0.1', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(log: log));
    await tester.tap(textFieldIn(SsNumberField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(log.last, 101);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(log.last, 99); // 101 -> 100 -> 99 (text is the live base)

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(log.last, 109);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(log.last, 109.1);
  });

  testWidgets('the Mixed state shows a hint and any entry replaces it', (
    tester,
  ) async {
    final log = <double>[];
    await pumpChrome(tester, _field(value: null, mixed: true, log: log));
    expect(find.text('Mixed'), findsOneWidget);
    expect(_text(tester), '');
    await _type(tester, '12');
    expect(log, [12]);
  });

  testWidgets('arrow keys from Mixed start at zero', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(value: null, mixed: true, log: log));
    await tester.tap(textFieldIn(SsNumberField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(log, [1]);
  });

  Future<double> scrub(WidgetTester tester, {LogicalKeyboardKey? mod}) async {
    final log = <double>[];
    final events = <String>[];
    await pumpChrome(tester, _field(log: log, events: events));
    if (mod != null) await tester.sendKeyDownEvent(mod);
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('ss-number-scrub'))),
    );
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    if (mod != null) await tester.sendKeyUpEvent(mod);
    expect(events.first, 'start');
    expect(events.last, 'end');
    return log.isEmpty ? 0 : log.last - 100;
  }

  testWidgets('dragging the label scrubs; Shift scrubs faster, Alt finer', (
    tester,
  ) async {
    final plain = await scrub(tester);
    expect(plain, inInclusiveRange(20, 60));
    final shift = await scrub(tester, mod: LogicalKeyboardKey.shiftLeft);
    expect(shift, greaterThan(plain * 5));
    final alt = await scrub(tester, mod: LogicalKeyboardKey.altLeft);
    expect(alt.abs(), lessThan(plain / 5));
  });

  testWidgets('scrubbing respects min and max', (tester) async {
    final log = <double>[];
    await pumpChrome(tester, _field(max: 105, log: log));
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('ss-number-scrub'))),
    );
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(10, 0));
    }
    await g.up();
    expect(log.last, 105);
  });

  testWidgets('disabled field ignores input and exposes semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpChrome(
      tester,
      const SizedBox(
        width: 120,
        child: SsNumberField(label: 'X', value: 5, onChanged: null),
      ),
    );
    expect(
      tester.widget<TextField>(textFieldIn(SsNumberField)).enabled,
      isFalse,
    );
    expect(find.bySemanticsLabel('X'), findsWidgets);
    handle.dispose();
  });

  testWidgets('after Enter, a new value while still focused shows; blur '
      'does not write the old number to the new target', (tester) async {
    final log = <double>[];
    late StateSetter set;
    double? value = 100;
    await pumpChrome(
      tester,
      StatefulBuilder(
        builder: (context, s) {
          set = s;
          return _field(value: value, log: log);
        },
      ),
    );
    await tester.tap(textFieldIn(SsNumberField));
    await tester.pump();
    await _type(tester, '32');
    expect(log, [32]);
    // The target changes (another selection) while the field has focus.
    set(() => value = 0);
    await tester.pump();
    expect(_text(tester), '0');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(log, [32], reason: 'no stale write on blur');

    // Typed but not committed: blur still commits.
    await tester.tap(textFieldIn(SsNumberField));
    await tester.pump();
    await tester.enterText(textFieldIn(SsNumberField), '7');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(log, [32, 7]);
  });
}
