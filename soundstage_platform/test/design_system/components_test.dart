import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'harness.dart';

void main() {
  group('SsButton', () {
    testWidgets('taps, activates with Enter and Space, and disables', (
      tester,
    ) async {
      var n = 0;
      await pumpChrome(
        tester,
        SsButton(label: 'Go', autofocus: true, onPressed: () => n++),
      );
      await tester.tap(find.text('Go'));
      expect(n, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(n, 3);
    });

    testWidgets('disabled does not fire and is not enabled in semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpChrome(tester, const SsButton(label: 'Nope'));
      await tester.tap(find.text('Nope'), warnIfMissed: false);
      final node = tester.getSemantics(find.byType(SsButton));
      expect(node.label, 'Nope');
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('hover changes the fill', (tester) async {
      await pumpChrome(tester, SsButton(label: 'Hover', onPressed: () {}));
      Color fill() =>
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: find.byType(SsButton),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      final before = fill();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Hover')));
      await tester.pumpAndSettle();
      expect(fill(), isNot(before));
    });
  });

  group('SsIconButton', () {
    testWidgets('has a semantic label, selected state, and a tooltip', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var n = 0;
      await pumpChrome(
        tester,
        SsIconButton(
          icon: SsIcons.type,
          semanticLabel: 'Text',
          selected: true,
          shortcut: 'T',
          onPressed: () => n++,
        ),
      );
      expect(find.bySemanticsLabel('Text'), findsWidgets);
      await tester.tap(find.byType(SsIconButton));
      expect(n, 1);
      // Hover shows the tooltip after the delay.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(SsIconButton)));
      await tester.pump(
        SsMotion.tooltipDelay + const Duration(milliseconds: 50),
      );
      await tester.pump();
      expect(find.text('Text'), findsWidgets);
      expect(find.text('T'), findsOneWidget);
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(find.text('T'), findsNothing);
      handle.dispose();
    });
  });

  group('SsToggle and SsCheckbox', () {
    testWidgets('toggle flips and reports its value', (tester) async {
      final handle = tester.ensureSemantics();
      var v = false;
      await pumpChrome(
        tester,
        StatefulBuilder(
          builder: (c, set) => SsToggle(
            value: v,
            label: 'Snap',
            onChanged: (x) => set(() => v = x),
          ),
        ),
      );
      await tester.tap(find.text('Snap'));
      await tester.pump();
      expect(v, isTrue);
      final node = tester.getSemantics(find.byType(SsToggle));
      expect(node.label, 'Snap');
      expect(node.value, 'On');
      expect(node.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('toggle works with the keyboard', (tester) async {
      var v = false;
      await pumpChrome(
        tester,
        StatefulBuilder(
          builder: (c, set) => SsToggle(
            value: v,
            label: 'Snap',
            onChanged: (x) => set(() => v = x),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(v, isTrue);
    });

    testWidgets('disabled toggle does nothing', (tester) async {
      await pumpChrome(
        tester,
        const SsToggle(value: false, onChanged: null, label: 'Off'),
      );
      await tester.tap(find.text('Off'), warnIfMissed: false);
    });

    testWidgets('checkbox: mixed resolves to checked; reports mixed', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final log = <bool>[];
      await pumpChrome(
        tester,
        SsCheckbox(value: null, label: 'All', onChanged: log.add),
      );
      expect(find.byIcon(Icons.check), findsNothing);
      expect(tester.getSemantics(find.byType(SsCheckbox)).value, 'Mixed');
      await tester.tap(find.text('All'));
      expect(log, [true]);
      handle.dispose();
    });

    testWidgets('checkbox: checked unchecks', (tester) async {
      final log = <bool>[];
      await pumpChrome(
        tester,
        SsCheckbox(value: true, label: 'A', onChanged: log.add),
      );
      await tester.tap(find.text('A'));
      expect(log, [false]);
    });
  });

  group('SsSegmented', () {
    Widget build(List<String> log, {String selected = 'a'}) =>
        SsSegmented<String>(
          semanticLabel: 'Scope',
          selected: selected,
          onChanged: log.add,
          segments: const [
            SsSegment(value: 'a', label: 'A'),
            SsSegment(value: 'b', label: 'B'),
            SsSegment(value: 'c', label: 'C', enabled: false),
          ],
        );

    testWidgets('tap selects; disabled segment does not', (tester) async {
      final log = <String>[];
      await pumpChrome(tester, build(log));
      await tester.tap(find.text('B'));
      await tester.tap(find.text('C'), warnIfMissed: false);
      expect(log, ['b']);
    });

    testWidgets('arrow keys move selection and skip disabled', (tester) async {
      final log = <String>[];
      await pumpChrome(tester, build(log));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(log, ['b', 'a']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(log.last, 'b');
    });

    testWidgets('segments report selected semantics', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChrome(tester, build([], selected: 'b'));
      expect(
        tester.getSemantics(find.text('B')).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      handle.dispose();
    });
  });

  group('SsTextField', () {
    testWidgets('types, submits, and shows an error message', (tester) async {
      final changes = <String>[];
      final submits = <String>[];
      await pumpChrome(
        tester,
        SizedBox(
          width: 200,
          child: SsTextField(
            placeholder: 'Name',
            errorText: 'Required',
            onChanged: changes.add,
            onSubmitted: submits.add,
          ),
        ),
      );
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Required'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(changes, ['abc']);
      expect(submits, ['abc']);
    });

    testWidgets('revertOnEscape restores the text from focus', (tester) async {
      await pumpChrome(
        tester,
        const SizedBox(
          width: 200,
          child: SsTextField(initialValue: 'start', revertOnEscape: true),
        ),
      );
      await tester.enterText(find.byType(TextField), 'changed');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('start'), findsOneWidget);
    });

    testWidgets('disabled field is disabled', (tester) async {
      await pumpChrome(
        tester,
        const SizedBox(width: 200, child: SsTextField(enabled: false)),
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    });
  });

  group('SsDropdown', () {
    Widget build(List<int> log, {bool mixed = false, int? value = 2}) =>
        SizedBox(
          width: 160,
          child: SsDropdown<int>(
            semanticLabel: 'Pick',
            value: value,
            mixed: mixed,
            onChanged: log.add,
            items: const [
              SsDropdownItem(value: 1, label: 'One'),
              SsDropdownItem(value: 2, label: 'Two'),
              SsDropdownItem(value: 3, label: 'Three'),
            ],
          ),
        );

    testWidgets('opens, picks, and closes', (tester) async {
      final log = <int>[];
      await pumpChrome(tester, build(log));
      expect(find.text('Two'), findsOneWidget);
      await tester.tap(find.byType(SsDropdown<int>));
      await tester.pumpAndSettle();
      expect(find.text('Three'), findsOneWidget);
      await tester.tap(find.text('Three'));
      await tester.pumpAndSettle();
      expect(log, [3]);
      expect(find.text('Three'), findsNothing);
    });

    testWidgets('keyboard: Arrow Down opens, arrows move, Enter picks', (
      tester,
    ) async {
      final log = <int>[];
      await pumpChrome(tester, build(log));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(log, [2]);
    });

    testWidgets('Escape closes without choosing', (tester) async {
      final log = <int>[];
      await pumpChrome(tester, build(log));
      await tester.tap(find.byType(SsDropdown<int>));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('One'), findsNothing);
      expect(log, isEmpty);
    });

    testWidgets('mixed shows Mixed', (tester) async {
      await pumpChrome(tester, build([], mixed: true));
      expect(find.text('Mixed'), findsOneWidget);
    });
  });

  group('menus', () {
    testWidgets('showSsMenu runs the item after closing; disabled is inert', (
      tester,
    ) async {
      var picked = 0;
      late BuildContext ctx;
      await pumpChrome(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      );
      showSsMenu(
        ctx,
        anchor: const Rect.fromLTWH(10, 10, 40, 20),
        entries: [
          const SsMenuLabel('Group'),
          SsMenuItem(label: 'Do it', shortcut: 'D', onSelected: () => picked++),
          const SsMenuItem(label: 'Disabled'),
          const SsMenuDivider(),
          SsMenuItem(label: 'Checked', checked: true, onSelected: () {}),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Group'), findsOneWidget);
      await tester.tap(find.text('Disabled'));
      await tester.pumpAndSettle();
      expect(find.text('Do it'), findsOneWidget); // still open
      await tester.tap(find.text('Do it'));
      await tester.pumpAndSettle();
      expect(picked, 1);
      expect(find.text('Do it'), findsNothing);
    });

    testWidgets('context menu opens on secondary tap, outside press closes', (
      tester,
    ) async {
      await pumpChrome(
        tester,
        SsContextMenuRegion(
          entries: () => [SsMenuItem(label: 'Rename', onSelected: () {})],
          child: const SizedBox(width: 200, height: 100, child: Text('Region')),
        ),
      );
      await tester.tap(find.text('Region'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
    });

    testWidgets('menu keyboard navigation skips disabled items', (
      tester,
    ) async {
      final picked = <String>[];
      late BuildContext ctx;
      await pumpChrome(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      );
      showSsMenu(
        ctx,
        anchor: const Rect.fromLTWH(10, 10, 40, 20),
        entries: [
          SsMenuItem(label: 'A', onSelected: () => picked.add('A')),
          const SsMenuItem(label: 'B'),
          SsMenuItem(label: 'C', onSelected: () => picked.add('C')),
        ],
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, ['C']);
    });
  });

  group('SsTabs and SsPanel', () {
    testWidgets('tabs select by tap and arrow keys', (tester) async {
      final log = <String>[];
      await pumpChrome(
        tester,
        SizedBox(
          width: 400,
          child: SsTabs(
            selectedId: 'a',
            onChanged: log.add,
            tabs: const [
              SsTab(id: 'a', label: 'Alpha'),
              SsTab(id: 'b', label: 'Beta'),
              SsTab(id: 'c', label: 'Gamma'),
            ],
          ),
        ),
      );
      await tester.tap(find.text('Beta'));
      expect(log, ['b']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(log.last, 'c');
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      expect(log.last, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      expect(log.last, 'c');
    });

    testWidgets('panel collapses and expands from the header', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChrome(
        tester,
        const SizedBox(
          width: 300,
          child: SsPanel(title: 'Layout', child: Text('Body')),
        ),
      );
      expect(find.text('Body'), findsOneWidget);
      await tester.tap(find.text('Layout'));
      await tester.pumpAndSettle();
      expect(find.text('Body'), findsNothing);
      expect(find.bySemanticsLabel('Layout'), findsWidgets);
      // The tap focused the header, so Enter re-expands it.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Body'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('controlled panel reports changes', (tester) async {
      final log = <bool>[];
      await pumpChrome(
        tester,
        SizedBox(
          width: 300,
          child: SsPanel(
            title: 'P',
            expanded: true,
            onExpandedChanged: log.add,
            child: const Text('Body'),
          ),
        ),
      );
      await tester.tap(find.text('P'));
      await tester.pump();
      expect(log, [false]);
      expect(find.text('Body'), findsOneWidget); // parent owns the state
    });
  });

  group('SsTreeRow', () {
    Widget row({
      List<String>? log,
      bool expanded = false,
      bool visible = true,
      bool locked = false,
    }) {
      return SizedBox(
        width: 300,
        child: SsTreeRow(
          label: 'Title',
          depth: 2,
          hasChildren: true,
          expanded: expanded,
          visible: visible,
          locked: locked,
          icon: SsIcons.type,
          onTap: () => log?.add('tap'),
          onExpandedChanged: (v) => log?.add('expand:$v'),
          onRename: (v) => log?.add('rename:$v'),
          onVisibleChanged: (v) => log?.add('visible:$v'),
          onLockedChanged: (v) => log?.add('locked:$v'),
        ),
      );
    }

    testWidgets('indents by depth', (tester) async {
      await pumpChrome(tester, row());
      final x = tester.getTopLeft(find.text('Title')).dx;
      await pumpChrome(
        tester,
        const SizedBox(
          width: 300,
          child: SsTreeRow(
            label: 'Title',
            depth: 0,
            hasChildren: true,
            icon: SsIcons.type,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(x - tester.getTopLeft(find.text('Title')).dx, 32);
    });

    testWidgets('tap, disclosure and keyboard expand/collapse', (tester) async {
      final log = <String>[];
      await pumpChrome(tester, row(log: log));
      await tester.tap(find.text('Title'));
      await tester.pump(const Duration(milliseconds: 400)); // double-tap window
      expect(log, ['tap']);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(log.last, 'expand:true');
    });

    testWidgets('inline rename: F2, edit, Enter commits', (tester) async {
      final log = <String>[];
      await pumpChrome(tester, row(log: log));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'Heading');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(log, contains('rename:Heading'));
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('double-tap renames; Escape cancels', (tester) async {
      final log = <String>[];
      await pumpChrome(tester, row(log: log));
      await tester.tap(find.text('Title'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Title'));
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'Nope');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsNothing);
      expect(log.where((e) => e.startsWith('rename')), isEmpty);
    });

    testWidgets('a locked row cannot be renamed', (tester) async {
      await pumpChrome(tester, row(locked: true));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('visibility and lock toggles', (tester) async {
      final log = <String>[];
      await pumpChrome(tester, row(log: log, visible: false, locked: true));
      await tester.tap(find.bySemanticsLabel('Unlock Title'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.bySemanticsLabel('Show Title'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(log, containsAll(['visible:true', 'locked:false']));
    }, skip: false);
  });

  group('SsTooltip', () {
    testWidgets('shows on keyboard focus and hides on Escape', (tester) async {
      await pumpChrome(
        tester,
        SsTooltip(
          message: 'Helpful',
          child: SsButton(label: 'Target', onPressed: () {}),
        ),
      );
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.text('Helpful'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Helpful'), findsNothing);
    });
  });

  group('dialog and toast', () {
    testWidgets(
      'confirm dialog: Escape cancels, Enter confirms, focus trapped',
      (tester) async {
        late BuildContext ctx;
        await pumpChrome(
          tester,
          Builder(
            builder: (c) {
              ctx = c;
              return const Text('Page');
            },
          ),
        );
        var result = <bool>[];
        unawaited(
          showSsConfirm(
            ctx,
            title: 'Sure?',
            message: 'Really',
            confirmLabel: 'Yes',
          ).then(result.add),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sure?'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(result, [false]);
        expect(find.text('Sure?'), findsNothing);

        result = <bool>[];
        unawaited(
          showSsConfirm(
            ctx,
            title: 'Sure?',
            message: 'Really',
            confirmLabel: 'Yes',
          ).then(result.add),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter); // autofocus: Yes
        await tester.pumpAndSettle();
        expect(result, [true]);
      },
    );

    testWidgets('scrim tap dismisses a dismissible dialog', (tester) async {
      late BuildContext ctx;
      await pumpChrome(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      );
      unawaited(
        showSsDialog<void>(
          ctx,
          builder: (_) => const SsDialog(title: 'Hi', content: Text('Body')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Hi'), findsNothing);
    });

    testWidgets('toast shows, runs its action, and auto-dismisses', (
      tester,
    ) async {
      late BuildContext ctx;
      await pumpChrome(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      );
      var acted = 0;
      SsToast.show(
        ctx,
        'Saved',
        kind: SsToastKind.success,
        actionLabel: 'Undo',
        onAction: () => acted++,
      );
      await tester.pump();
      expect(find.text('Saved'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(acted, 1);
      expect(find.text('Saved'), findsNothing);

      SsToast.show(ctx, 'Gone soon', duration: const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Gone soon'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Gone soon'), findsNothing);
    });

    testWidgets('toasts stack and can be dismissed', (tester) async {
      late BuildContext ctx;
      await pumpChrome(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      );
      SsToast.show(ctx, 'One');
      final dismiss = SsToast.show(ctx, 'Two');
      await tester.pump();
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      dismiss();
      await tester.pump();
      expect(find.text('Two'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
