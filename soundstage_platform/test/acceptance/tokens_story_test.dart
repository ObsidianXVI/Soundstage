// T3.1 acceptance: a small design system built in the editor from a new
// story, through the Tokens tab and the inspector:
//   - a Theme collection (Default, Dark) with a colour `brand/accent`;
//   - a Spacing collection (Default, Compact) with a number `gap`, the
//     mobile breakpoint mapped to Compact;
//   - a frame whose width binds to `gap` and fill to `brand/accent`, with
//     its Theme mode set to Dark;
//   - a text style created from a text layer;
// then saved, reopened and resolved: each breakpoint shows its mode's
// values.
//
// COMMAND-DISPATCH SHORTCUTS: none.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'acceptance_rig.dart';

extension on Rig {
  Future<void> key(String k) async {
    await tester.tap(find.byKey(ValueKey<String>(k)).first);
    await settleAnimations();
  }

  Future<void> text(String label) async {
    await tester.tap(find.text(label).last);
    await settleAnimations();
  }

  /// Fills the open prompt with [value] and confirms with [button].
  Future<void> prompt(String value, String button) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(SsDialog),
        matching: find.byType(EditableText),
      ),
      value,
    );
    await tester.tap(find.widgetWithText(SsButton, button));
    await settleAnimations();
  }

  /// Types [value] into the first editable text under the widget keyed [k]
  /// and commits it.
  Future<void> enter(String k, String value) async {
    final f = find.descendant(
      of: find.byKey(ValueKey<String>(k)),
      matching: find.byType(EditableText),
    );
    await tester.enterText(f.first, value);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleAnimations();
  }

  ir.Variable variable(String name) => doc.tokens.collections
      .expand((c) => c.variables)
      .singleWhere((v) => v.name == name);

  ir.VariableCollection collection(String name) =>
      doc.tokens.collections.singleWhere((c) => c.name == name);

  /// A collection named [name] with a second mode [mode].
  Future<ir.VariableCollection> addCollection(String name, String mode) async {
    final before = doc.tokens.collections.length;
    if (before == 0) {
      await text('New collection');
    } else {
      await key('tokens-add-collection');
    }
    await key('tokens-collection-menu');
    await text('Rename collection…');
    await prompt(name, 'Save');
    await key('tokens-mode-menu');
    await text('Add mode…');
    await prompt(mode, 'Add');
    return collection(name);
  }

  /// Adds a variable of [type] (menu label) named [name] to the shown
  /// collection.
  Future<ir.Variable> addVariable(String type, String name) async {
    await key('tokens-add-variable');
    await text(type);
    final v = doc.tokens.collections
        .expand((c) => c.variables)
        .firstWhere(
          (v) => !v.name.contains('/') && v.name == type.toLowerCase(),
        );
    await enter('variable-${v.id}', name);
    return variable(name);
  }

  /// Right-clicks the field at [path] and binds it to [variableId].
  Future<void> bind(String path, String variableId) async {
    final f = find.byKey(ValueKey<String>('field:$path'));
    await reveal(f);
    await scrollInspectorTo(f);
    final g = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await g.down(tester.getCenter(f));
    await g.up();
    await settleAnimations();
    await text('Bind to variable…');
    await key('pick-variable-$variableId');
  }
}

void main() {
  testWidgets('a design system is built in the Tokens tab and bound in the '
      'inspector; breakpoints and frames pick their modes', (tester) async {
    final r = await pumpNewStory(tester, title: 'Systems');
    await r.zoomToFit();
    final bps = [...r.doc.breakpoints]
      ..sort((a, b) => a.designSize.width.compareTo(b.designSize.width));
    final mobile = bps.first.id, desk = bps.last.id;

    final card = await r.draw(
      'Frame',
      desk,
      const Offset(200, 200),
      const Offset(500, 400),
    );

    // Tokens.
    await r.tab('Tokens');
    final theme = await r.addCollection('Theme', 'Dark');
    final dark = theme.modes.last.id;
    final accent = await r.addVariable('Colour', 'brand/accent');
    // The new mode is shown: set its value, then the default's.
    await r.enter('variable-value-${accent.id}-$dark', '0000FF');
    await r.key('tokens-mode');
    await r.text('Default (default)');
    await r.enter(
      'variable-value-${accent.id}-${theme.defaultModeId}',
      'FF0000',
    );

    final spacing = await r.addCollection('Spacing', 'Compact');
    final compact = spacing.modes.last.id;
    final gap = await r.addVariable('Number', 'gap');
    await r.enter('variable-value-${gap.id}-$compact', '120');
    await r.key('tokens-mode');
    await r.text('Default (default)');
    await r.enter('variable-value-${gap.id}-${spacing.defaultModeId}', '320');
    await r.key('tokens-bp-mode-$mobile');
    await r.text('Compact');
    expect(r.collection('Spacing').breakpointModes, {mobile: compact});

    // Bind the frame.
    await r.tab('Layers');
    await r.selectLayer(card);
    await r.bind('width', gap.id);
    await r.bind('fills.fill.color', accent.id);
    await r.pick('mode-override-${theme.id}', 'Dark');
    final node = ir.DocumentIndex.of(r.doc).node(card)! as ir.FrameNode;
    expect(node.common.bindings, {
      'width': ir.TokenRef(variableId: gap.id),
      'fills.fill.color': ir.TokenRef(variableId: accent.id),
    });
    expect(node.modeOverrides, {theme.id: dark});

    // A text style from a text layer.
    final title = await r.draw(
      'Text',
      desk,
      const Offset(600, 200),
      const Offset(900, 260),
    );
    await r.typeText('Hello');
    await r.escape();
    await r.selectLayer(title);
    await r.tapKey('style-picker-textStyleId');
    await r.settleAnimations();
    await r.text('Create text style…');
    await r.prompt('Heading', 'Create');
    final heading = r.doc.tokens.textStyles.entries.single;
    expect(heading.value.name, 'Heading');
    expect(
      (ir.DocumentIndex.of(r.doc).node(title)! as ir.TextNode).textStyleId,
      heading.key,
    );

    // Saved, reopened, resolved per breakpoint.
    final built = r.doc;
    expect(
      ir
          .validateDocument(built)
          .where((d) => d.severity == ir.IrSeverity.error),
      isEmpty,
    );
    final reopened = (await tester.runAsync(() async {
      await r.repository.save(r.storyId!, built);
      return r.repository.open(r.storyId!);
    }))!;
    expect(reopened.document!.toJson(), built.toJson());
    ir.FrameNode at(String bp) =>
        ir
                .resolveDocument(
                  reopened.document!,
                  ir.ResolveContext(breakpointId: bp),
                )
                .nodeIndex[card]!
                .node
            as ir.FrameNode;
    expect(at(desk).common.width, 320);
    expect(at(mobile).common.width, 120);
    // The frame is in Dark at every breakpoint.
    for (final bp in [desk, mobile]) {
      expect(
        (at(bp).appearance.fills.single as ir.SolidPaint).color,
        const ir.StageColor(r: 0, g: 0, b: 1),
      );
    }
  });
}
