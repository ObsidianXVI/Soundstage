// M1 acceptance (T1.12): rebuild the T0.4 static demo
// (assets/demo/static.stage.json) in the editor, starting from an empty
// story created through the app's repository, through the editor's own
// surfaces; then compare it with the hand-written demo at 390, 834 and
// 1440 (rects within 1 px, text, span styles, image fit and focal point,
// text boxes, appearance, visibility), check roles, save and reopen it
// through the repository (`loadDocument`), and round-trip it through
// `.stage.zip`.
//
// Every edit is a UI gesture: toolbar tools and the shape menu, drags and
// clicks on the canvas (Cmd-click deep select, artboard labels for scene
// roots, the width handle for tablet), the Layers panel (select, F2
// rename), the Scenes panel (add, rename, scroll length), the Assets panel
// (upload media and fonts through the file picker, tap a tile to fill the
// selection), inspector fields, segments, menus and colour pickers, the
// edit-scope toggle, and keyboard shortcuts (Shift+1, Shift+2, Cmd+D,
// Enter, Esc).
//
// COMMAND-DISPATCH SHORTCUTS: none. The test never calls a command or a
// controller method to edit. What it does instead of a literal gesture:
//   - Typing on the canvas sends text-input deltas to the edit session
//     (`updateEditingValueWithDeltas`), as the browser IME does; text
//     selections are set the same way (a non-text delta).
//   - Keyboard focus is handed back to the editor shell
//     (`Focus.requestFocus`) before shortcuts, and an inspector hex field
//     is blurred (`unfocus`) after a colour, where a user would click on
//     the chrome.
//   - The lazily built inspector list is scrolled programmatically
//     (`ensureVisible` / `jumpTo`), where a user would use the wheel.
//   - Files come from a fake picker returning the demo's PNG and font
//     bytes; the asset store is the app's `LocalAssetStore` over the
//     in-memory database, with a PNG-header analyzer instead of the
//     browser's decoder.
//
// WORKAROUNDS (editor gaps found here; see CURRENT_TASK.md):
//   - FINDING-1: committing a colour in the picker while editing text
//     ends the edit session in this test; Enter on the text resumes it.
//
// NORMALISATIONS for the comparison (both documents get the same):
//   - Font faces are dropped (`forComparison`): the test environment has
//     no web fonts, so both render with the fallback and only layout is
//     compared. Families are compared by name ("Fraunces", "Inter").
//   - Auto-sized text has its stored size brought in line with its
//     measured size (`syncTextSizes`, what the editor does on every edit;
//     DECISIONS 25/10/26 T1.12-1). The hand-written demo predates that and
//     stores arbitrary heights (20 for a 14 px line), which move bottom-
//     and centre-pinned text.
//   - Nodes are matched by layer name path; assets by file name.
//   - Roles are checked against `_roles` (the demo predates roles).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/persistence/story_package.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart'
    show stageTextMeasurer, syncTextSizes;
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../editor/insert/fakes.dart';
import 'acceptance_rig.dart';
import 'compare.dart';

const _images = 'assets/demo/images';

/// Builds scene 1, "Hero": a pinned scene with a full-bleed image, a
/// gradient scrim pinned to the bottom, and three constrained texts with
/// tablet and mobile patches.
Future<void> buildHero(Rig r, Map<String, String> assets, Fonts fonts) async {
  final desktop = r.bp('Desktop');
  final mobile = r.bp('Mobile');
  final tablet = r.bp('Tablet');
  // A new story starts with one blank pinned scene.
  expect(r.doc.scenes, hasLength(1));
  await renameActiveScene(r, 'Hero');
  await r.zoomToFit();

  // The root: image fill (the asset tile applies to the selection), focal
  // point typed in %.
  await r.selectRoot();
  await noFill(r, r.rootId); // a new scene's root is white
  await r.tab('Assets');
  await r.tester.tap(
    find.byKey(ValueKey<String>('asset-tile:${assets['hero']}')),
  );
  await r.pump();
  final rootFill = imageFillOf(r, r.rootId);
  await r.tapKey('paint-swatch:${rootFill.id}');
  await r.type('fills.${rootFill.id}.focalPoint.x', '68');
  await r.type('fills.${rootFill.id}.focalPoint.y', '42');
  await r.escape();

  // Scrim: a frame drawn at the bottom, made exact in the inspector, pinned
  // left and right and to the bottom, filled with a linear gradient.
  final scrim = await r.draw(
    'Frame',
    desktop,
    const Offset(100, 500),
    const Offset(700, 850),
  );
  await r.rename(scrim, 'Scrim');
  await geometry(r, x: 0, y: 450, w: 1440, h: 450);
  await r.constraints(h: 'Both', v: 'Bottom');
  await toLinearGradient(r, scrim, from: ('000000', '0'), to: ('0a0514', '82'));

  final kicker = await addText(
    r,
    desktop,
    120,
    100,
    'A Soundstage demo · Chapter one',
  );
  await r.rename(kicker, 'Kicker');
  await textBox(r, autoHeight: true);
  await geometry(r, x: 120, y: 560, w: 600);
  await r.constraints(h: 'Left', v: 'Bottom');
  await textStyle(
    r,
    family: fonts.sans,
    weight: '600',
    size: '14',
    letterSpacingPercent: '20',
    textCase: 'UPPERCASE',
    colour: ('ffffff', '85'),
  );

  final title = await addText(
    r,
    desktop,
    120,
    200,
    'The light that stays after the sun',
  );
  await r.rename(title, 'Title');
  await textBox(r, autoHeight: true);
  await geometry(r, x: 120, y: 596, w: 1000);
  await r.constraints(h: 'Left', v: 'Bottom');
  await textStyle(
    r,
    family: fonts.serif,
    weight: '700',
    size: '88',
    lineHeightPercent: '100',
    letterSpacingPercent: '-2',
    colour: ('ffffff', '100'),
  );

  final credit = await addText(
    r,
    desktop,
    920,
    300,
    'Illustration: procedural, tool/gen_demo_images.dart',
  );
  await r.rename(credit, 'Credit');
  await textBox(r, autoHeight: true, align: 'Right');
  await geometry(r, x: 920, y: 860, w: 480);
  await r.constraints(h: 'Right', v: 'Bottom');
  await textStyle(
    r,
    family: fonts.sans,
    weight: '400',
    size: '12',
    letterSpacingPercent: '0',
    colour: ('ffffff', '60'),
  );

  // Breakpoint overrides, "This breakpoint" scope. Mobile on its artboard;
  // tablet by dragging the desktop artboard to 834 px (tablet in effect).
  await r.setScope(thisBreakpoint: true);
  await r.zoomToFit();
  await r.selectLayer(scrim);
  await clickArtboard(r, mobile);
  await geometry(r, y: 422, w: 390, h: 422);
  await r.selectLayer(kicker);
  await geometry(r, x: 24, y: 470, w: 342);
  await r.selectLayer(title);
  await geometry(r, x: 24, y: 520, w: 342);
  await r.type('style.fontSize', '44');
  await r.selectLayer(credit);
  await geometry(r, x: 24, y: 800, w: 342);

  await r.freeWidth(desktop, 834);
  await r.selectLayer(scrim);
  await clickArtboard(r, desktop);
  expect(r.st.breakpointId, tablet);
  await geometry(r, y: 556, w: 834, h: 556);
  await r.selectLayer(kicker);
  await geometry(r, x: 48, y: 784, w: 700);
  await r.selectLayer(title);
  await geometry(r, x: 48, y: 820, w: 700);
  await r.type('style.fontSize', '64');
  await r.selectLayer(credit);
  await geometry(r, x: 306, y: 1072);
  await r.resetWidth(desktop);
  await r.setScope(thisBreakpoint: false);
}

const _ink = '1c1a17';
const _rust = 'c2410c';

/// The point at fractions ([fx], [fy]) of node [id]'s box on the desktop
/// artboard, on screen.
Offset inside(Rig r, String id, double fx, double fy) {
  final desktop = r.bp('Desktop');
  final origin = r.tester.getTopLeft(find.byType(EditorCanvas));
  final b = r.canvas.overlay.rectFor(id, desktop)!.bounds;
  return origin + Offset(b.left + b.width * fx, b.top + b.height * fy);
}

/// Places a text with the Text tool at [screen] and types [text]; leaves
/// it selected. Then names it.
Future<String> textAt(Rig r, Offset screen, String text, String name) async {
  await r.tool('Text');
  await r.click(screen);
  expect(r.st.textEditId, isNotNull, reason: 'text tool starts editing');
  final id = r.st.textEditId!;
  await r.typeText(text);
  await r.escape();
  await r.rename(id, name);
  return id;
}

/// Draws a frame with the Frame tool between fractions of [parent]'s box
/// and names it.
Future<String> frameIn(
  Rig r,
  String parent,
  Rect fractions,
  String name,
) async {
  await r.tool('Frame');
  await r.drag(
    inside(r, parent, fractions.left, fractions.top),
    inside(r, parent, fractions.right, fractions.bottom),
  );
  final id = r.st.selection.single;
  expect(r.doc.scenes.isNotEmpty, isTrue);
  await r.rename(id, name);
  return id;
}

/// Layout-child sizing of the selection ("Fixed", "Hug", "Fill").
Future<void> sizing(Rig r, {String? h, String? v}) async {
  if (h != null) await r.segment('layoutChild.horizontalSizing', h);
  if (v != null) await r.segment('layoutChild.verticalSizing', v);
}

/// Adds a min/max limit from the "+" menu and types it.
Future<void> limit(Rig r, String label, String path, String value) async {
  await r.tapKey('min-max:add');
  await r.settleAnimations();
  await r.tester.tap(find.text(label).last);
  await r.settleAnimations();
  await r.type(path, value);
}

/// A caption: sans 700 13, 12 % tracking, uppercase, ink at 55 %; fills
/// its row up to 720.
Future<void> captionStyle(Rig r, Fonts fonts) async {
  await sizing(r, h: 'Fill');
  await textBox(r, autoHeight: true);
  await limit(r, 'Max width', 'layoutChild.maxWidth', '720');
  await textStyle(
    r,
    family: fonts.sans,
    weight: '700',
    size: '13',
    letterSpacingPercent: '12',
    textCase: 'UPPERCASE',
    colour: (_ink, '55'),
  );
}

/// Builds scene 2, "Essay": a flow scene whose root is a vertical auto
/// layout of five groups (text column, tags, cards, baselines, shapes).
Future<void> buildEssay(Rig r, Map<String, String> assets, Fonts fonts) async {
  // After Hero: activate it, then "+" adds the new scene after it.
  await r.tab('Scenes');
  await r.tester.tap(find.widgetWithText(SsTreeRow, 'Hero'));
  await r.pump();
  await addScene(r, 'Flow scene');
  await renameActiveScene(r, 'Essay');
  expect(r.doc.scenes.map((s) => s.name), ['Hero', 'Essay', 'Quote']);
  await r.zoomToFit();
  final desktop = r.bp('Desktop');

  // Five empty groups, stacked, then auto layout on the root.
  final names = [
    'Column',
    'Tags group',
    'Cards group',
    'Baseline group',
    'Shapes group',
  ];
  final groups = <String>[];
  for (var i = 0; i < names.length; i++) {
    final y = 30.0 + i * 170;
    groups.add(
      await r.draw('Frame', desktop, Offset(120, y), Offset(1320, y + 150)),
    );
    await r.rename(groups.last, names[i]);
    await noFill(r, groups.last);
  }
  await r.selectRoot();
  final root = r.rootId;
  if ((ir.PropertyRegistry.standard.get(r.node(root), 'fills')!
          as ir.PaintsValue)
      .value
      .isEmpty) {
    await r.tapKey('add-paint:fills');
  }
  await solidFill(r, root, 'f4efe6', '100');
  await r.tapKey('field:clipContent'); // a blank root clips; this one not
  await r.tapKey('auto-layout:add');
  await autoLayout(
    r,
    vertical: true,
    gap: '72',
    sides: ['120', '120', '140', '120'],
  );
  await r.tapLabel('Top center');
  await sizing(r, v: 'Hug');
  for (final g in groups) {
    await r.selectNode(g);
    await sizing(r, h: 'Fill');
    await limit(
      r,
      'Max width',
      'layoutChild.maxWidth',
      g == groups[2] ? '1200' : '720',
    );
  }

  await buildColumn(r, groups[0], fonts);
  await buildTags(r, groups[1], fonts);
  await buildCards(r, groups[2], assets, fonts);
  await buildBaselines(r, groups[3], fonts);
  await buildShapes(r, groups[4], fonts);
  await essayBreakpoints(r, root);
}

/// Selects [id] and zooms to it on the desktop artboard (fit, click it
/// there so desktop is the edited artboard, Shift+2).
Future<void> focusOn(Rig r, String id) async {
  await r.selectNode(id);
  await r.zoomToFit();
  await clickArtboard(r, r.bp('Desktop'));
  await r.zoomToSelection();
}

/// The child of [parent] (in order) at [i].
String childOf(Rig r, String parent, int i) =>
    (r.node(parent) as ir.FrameNode).children[i].common.id;

/// Gives a group its caption and a row frame, then vertical auto layout.
Future<(String, String)> captionAndRow(
  Rig r,
  String group,
  String caption,
  String rowName,
  Fonts fonts,
) async {
  await focusOn(r, group);
  final cap = await textAt(r, inside(r, group, 0.02, 0.1), caption, 'Caption');
  final row = await frameIn(
    r,
    group,
    const Rect.fromLTRB(0.02, 0.35, 0.98, 0.97),
    rowName,
  );
  await noFill(r, row);
  await r.selectNode(group);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: true, gap: '16', padding: '0');
  await sizing(r, v: 'Hug');
  await r.selectNode(cap);
  await captionStyle(r, fonts);
  return (cap, row);
}

const _tagWords = [
  'auto layout',
  'constraints',
  'hug',
  'fill',
  'min / max',
  'baseline',
  'wrap',
  'breakpoints',
  'focal point',
  'rich text',
  'rotation',
  'paint-only motion',
];

/// A wrapping row of hug-sized tags: one built, eleven duplicated.
Future<void> buildTags(Rig r, String group, Fonts fonts) async {
  final (_, tags) = await captionAndRow(
    r,
    group,
    'Hug-sized tags in a wrapping row',
    'Tags',
    fonts,
  );
  await focusOn(r, tags);
  final tag = await frameIn(
    r,
    tags,
    const Rect.fromLTRB(0.02, 0.1, 0.3, 0.8),
    'Tag 0',
  );
  final label = await textAt(
    r,
    inside(r, tag, 0.1, 0.3),
    _tagWords[0],
    'Label',
  );
  await r.selectNode(tag);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: false, gap: '0', paddingH: '14', paddingV: '6');
  await sizing(r, h: 'Hug', v: 'Hug');
  await solidFill(r, tag, _rust, '10');
  await r.type('cornerRadius', '999');
  await addStroke(r, tag, _rust, '35', weight: '1', align: 'Inside');
  await r.selectNode(label);
  await textStyle(
    r,
    family: fonts.sans,
    weight: '600',
    size: '14',
    letterSpacingPercent: '0',
    colour: (_rust, '100'),
  );

  await r.selectNode(tags);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: false, gap: '8', padding: '0');
  await r.tapKey('field:autoLayout.wrap');
  await r.type('autoLayout.counterAxisGap', '10');
  await sizing(r, h: 'Fill', v: 'Hug');
  await limit(r, 'Max width', 'layoutChild.maxWidth', '720');

  await r.selectNode(tag);
  for (var i = 1; i < _tagWords.length; i++) {
    await r.duplicate();
  }
  for (var i = 1; i < _tagWords.length; i++) {
    final t = childOf(r, tags, i);
    await r.rename(t, 'Tag $i');
    await r.retype(childOf(r, t, 0), _tagWords[i]);
  }
}

/// Adds a stroke to [id] from the Stroke section, coloured [hex]/[alpha].
Future<void> addStroke(
  Rig r,
  String id,
  String hex,
  String alpha, {
  String? weight,
  String? align,
}) async {
  await r.tapKey('add-paint:strokes.paints');
  final paint =
      (ir.PropertyRegistry.standard.get(r.node(id), 'strokes.paints')!
              as ir.PaintsValue)
          .value
          .single;
  await r.colour('strokes.paints.${paint.id}.color', hex, alpha: alpha);
  if (weight != null) await r.type('strokes.weight', weight);
  if (align != null) await r.segment('strokes.align', align);
}

const _cards = [
  (
    'forest',
    'Card forest',
    'Fill, minimum 220',
    'This card fills its share of the row and never shrinks below 220 '
        'pixels.',
  ),
  (
    'sea',
    'Card sea',
    'Fill, maximum 320',
    'This one fills too, but freezes at 320 pixels; the others take what '
        'it leaves.',
  ),
  (
    'dunes',
    'Card dunes',
    'Image focal point',
    'Each image fills its frame and keeps its focal point in view as the '
        'card resizes.',
  ),
];

/// A row of three cards (image, title, body) that fill with min and max
/// widths: one built, two duplicated and changed.
Future<void> buildCards(
  Rig r,
  String group,
  Map<String, String> assets,
  Fonts fonts,
) async {
  final (_, row) = await captionAndRow(
    r,
    group,
    'A card row: fill children with min and max widths',
    'Card row',
    fonts,
  );
  await focusOn(r, row);
  final card = await frameIn(
    r,
    row,
    const Rect.fromLTRB(0.02, 0.05, 0.3, 0.95),
    _cards[0].$2,
  );
  final image = await frameIn(
    r,
    card,
    const Rect.fromLTRB(0.05, 0.05, 0.95, 0.35),
    'Image',
  );
  final title = await textAt(
    r,
    inside(r, card, 0.06, 0.5),
    _cards[0].$3,
    'Title',
  );
  final body = await textAt(
    r,
    inside(r, card, 0.06, 0.75),
    _cards[0].$4,
    'Body',
  );

  await r.selectNode(image);
  await noFill(r, image);
  await r.tab('Assets');
  await r.tester.tap(
    find.byKey(ValueKey<String>('asset-tile:${assets['forest']}')),
  );
  await r.pump();
  final fill = imageFillOf(r, image);
  await r.tapKey('paint-swatch:${fill.id}');
  await r.type('fills.${fill.id}.focalPoint.y', '60');
  await r.type('cornerRadius', '10');

  await r.selectNode(card);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: true, gap: '12', padding: '16');
  await r.type('cornerRadius', '16');
  await addStroke(r, card, 'e2d9cb', '100', weight: '1', align: 'Inside');
  await r.tapKey('field:clipContent');

  await r.selectNode(image);
  await sizing(r, h: 'Fill');
  await r.type('height', '180');
  await r.selectNode(title);
  await sizing(r, h: 'Fill');
  await textBox(r, autoHeight: true);
  await textStyle(
    r,
    family: fonts.serif,
    weight: '600',
    size: '22',
    lineHeightPercent: '125',
    letterSpacingPercent: '0',
    colour: (_ink, '100'),
  );
  await r.selectNode(body);
  await sizing(r, h: 'Fill');
  await textBox(r, autoHeight: true);
  await textStyle(
    r,
    family: fonts.sans,
    weight: '400',
    size: '15',
    lineHeightPercent: '150',
    letterSpacingPercent: '0',
    colour: (_ink, '75'),
  );

  await r.selectNode(row);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: false, gap: '24', padding: '0');
  await sizing(r, h: 'Fill', v: 'Hug');
  await limit(r, 'Max width', 'layoutChild.maxWidth', '1200');
  await r.selectNode(card);
  await sizing(r, h: 'Fill', v: 'Hug');
  await limit(r, 'Min width', 'layoutChild.minWidth', '220');

  await r.duplicate();
  await r.duplicate();
  for (var i = 1; i < 3; i++) {
    final c = childOf(r, row, i);
    await r.rename(c, _cards[i].$2);
    final img = childOf(r, c, 0);
    await r.selectNode(img);
    await r.tab('Assets');
    await r.tester.tap(
      find.byKey(ValueKey<String>('asset-tile:${assets[_cards[i].$1]}')),
    );
    await r.pump();
    await r.retype(childOf(r, c, 1), _cards[i].$3);
    await r.retype(childOf(r, c, 2), _cards[i].$4);
  }
  await r.selectNode(childOf(r, row, 1));
  await limit(r, 'Max width', 'layoutChild.maxWidth', '320');
}

/// Texts of three sizes and a nested frame on one baseline, in a wrapping
/// row, with a square that has no text.
Future<void> buildBaselines(Rig r, String group, Fonts fonts) async {
  final (_, row) = await captionAndRow(
    r,
    group,
    'Baselines across sizes and a nested frame',
    'Baseline row',
    fonts,
  );
  await focusOn(r, row);
  final big = await textAt(r, inside(r, row, 0.02, 0.2), 'Big', 'Big');
  final medium = await textAt(r, inside(r, row, 0.2, 0.2), 'medium', 'Medium');
  final small = await textAt(r, inside(r, row, 0.4, 0.2), 'small', 'Small');
  final nested = await frameIn(
    r,
    row,
    const Rect.fromLTRB(0.55, 0.05, 0.85, 0.95),
    'Nested frame',
  );
  final nestedText = await textAt(
    r,
    inside(r, nested, 0.08, 0.15),
    'nested 24',
    'Nested text',
  );
  final note = await textAt(
    r,
    inside(r, nested, 0.08, 0.6),
    'first text sets the baseline',
    'Nested note',
  );
  await r.tool('Rectangle');
  await r.drag(inside(r, row, 0.9, 0.3), inside(r, row, 0.95, 0.6));
  final rect = r.st.selection.single;
  await r.rename(rect, 'No text: bottom on baseline');
  await geometry(r, w: 24, h: 24);
  await solidFill(r, rect, _ink, '100');

  await r.selectNode(nested);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: true, gap: '2', paddingH: '12', paddingV: '10');
  await sizing(r, h: 'Hug', v: 'Hug');
  await solidFill(r, nested, _rust, '12');
  await r.type('cornerRadius', '8');

  await r.selectNode(row);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: false, gap: '20', padding: '0');
  await r.tapKey('field:autoLayout.wrap');
  await r.type('autoLayout.counterAxisGap', '12');
  await r.tapKey('field:baseline');
  await sizing(r, h: 'Fill', v: 'Hug');
  await limit(r, 'Max width', 'layoutChild.maxWidth', '720');

  for (final (id, family, weight, size, lh, hex, alpha) in [
    (big, fonts.serif, '700', '72', '100', _ink, '100'),
    (medium, fonts.serif, '400', '36', null, _ink, '100'),
    (small, fonts.sans, '400', '16', null, _ink, '100'),
    (nestedText, fonts.sans, '600', '24', null, _rust, '100'),
    (note, fonts.sans, '400', '11', null, _ink, '60'),
  ]) {
    await r.selectNode(id);
    await textStyle(
      r,
      family: family,
      weight: weight,
      size: size,
      lineHeightPercent: lh,
      letterSpacingPercent: '0',
      colour: (hex, alpha),
    );
  }
}

/// Shapes and a rotated, hugging frame in a wrapping row.
Future<void> buildShapes(Rig r, String group, Fonts fonts) async {
  final (_, row) = await captionAndRow(
    r,
    group,
    'Shapes, and a rotated frame in auto layout',
    'Shapes and rotation',
    fonts,
  );
  await focusOn(r, row);
  Future<String> shape(String tool, double x0, double x1, String name) async {
    await r.tool(tool);
    await r.drag(inside(r, row, x0, 0.2), inside(r, row, x1, 0.8));
    final id = r.st.selection.single;
    await r.rename(id, name);
    return id;
  }

  final pie = await shape('Ellipse', 0.02, 0.1, 'Pie');
  await r.type('geometry.arcEnd', '270');
  await geometry(r, w: 64, h: 64);
  await solidFill(r, pie, _rust, '100');

  final sticker = await frameIn(
    r,
    row,
    const Rect.fromLTRB(0.15, 0.1, 0.35, 0.9),
    'Sticker (rotated)',
  );
  final label = await textAt(
    r,
    inside(r, sticker, 0.1, 0.3),
    'rotated −8°',
    'Label',
  );

  final star = await shape('Star', 0.4, 0.48, 'Star');
  await r.type('geometry.innerRatio', '45');
  await geometry(r, w: 64, h: 64);
  await solidFill(r, star, 'd4a017', '100');
  final hex = await shape('Polygon', 0.52, 0.6, 'Hexagon');
  await r.type('geometry.pointCount', '6');
  await geometry(r, w: 64, h: 64);
  await solidFill(r, hex, '0f766e', '100');
  final ring = await shape('Ellipse', 0.64, 0.72, 'Ring');
  await r.type('geometry.innerRadius', '60');
  await geometry(r, w: 64, h: 64);
  await solidFill(r, ring, '1d4ed8', '100');
  await r.tool('Line');
  await r.drag(inside(r, row, 0.78, 0.5), inside(r, row, 0.9, 0.5));
  final line = r.st.selection.single;
  await r.rename(line, 'Line');
  await r.type('width', '80');
  final stroke =
      (ir.PropertyRegistry.standard.get(r.node(line), 'strokes.paints')!
              as ir.PaintsValue)
          .value
          .single;
  await r.colour('strokes.paints.${stroke.id}.color', _ink, alpha: '100');
  await r.type('strokes.weight', '3');
  await r.segment('strokes.align', 'Center');

  await r.selectNode(sticker);
  await r.tapKey('auto-layout:add');
  await autoLayout(
    r,
    vertical: false,
    gap: '0',
    paddingH: '16',
    paddingV: '10',
  );
  await sizing(r, h: 'Hug', v: 'Hug');
  await solidFill(r, sticker, _ink, '100');
  await r.type('cornerRadius', '8');
  await r.selectNode(label);
  await textStyle(
    r,
    family: fonts.sans,
    weight: '600',
    size: '15',
    letterSpacingPercent: '0',
    colour: ('ffffff', '100'),
  );

  await r.selectNode(row);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: false, gap: '32', padding: '0');
  await r.tapKey('field:autoLayout.wrap');
  await r.type('autoLayout.counterAxisGap', '24');
  await r.tapLabel('Middle left');
  await sizing(r, h: 'Fill', v: 'Hug');
  await limit(r, 'Max width', 'layoutChild.maxWidth', '720');
  await r.selectNode(sticker);
  await r.type('rotation', '-8');
}

/// The Essay's tablet and mobile overrides.
Future<void> essayBreakpoints(Rig r, String root) async {
  final desktop = r.bp('Desktop');
  final mobile = r.bp('Mobile');
  final tablet = r.bp('Tablet');
  await r.setScope(thisBreakpoint: true);
  await r.zoomToFit();
  await r.selectRoot(mobile);
  expect(r.st.breakpointId, mobile);
  await autoLayout(r, sides: ['64', '24', '80', '24'], gap: '48');
  final heading = r.idOf('Heading');
  await r.selectNode(heading);
  await clickArtboard(r, mobile);
  await r.type('style.fontSize', '34');
  final cardRow = r.idOf('Card row');
  await r.selectNode(cardRow);
  await clickArtboard(r, mobile);
  await autoLayout(r, gap: '16', vertical: true);

  // The free-width badge covers the label at this zoom: select the root,
  // then narrow the artboard (the edited breakpoint follows the width).
  await r.selectRoot(desktop);
  await r.freeWidth(desktop, 834);
  expect(r.st.breakpointId, tablet);
  await autoLayout(r, sides: ['96', '48', '120', '48']);
  await r.selectNode(cardRow);
  await clickArtboard(r, desktop);
  expect(r.st.breakpointId, tablet);
  await autoLayout(r, gap: '16');
  await r.resetWidth(desktop);
  await r.setScope(thisBreakpoint: false);
}

/// The selection's fills removed (a new frame is white).
Future<void> noFill(Rig r, String id) async {
  final fills =
      (ir.PropertyRegistry.standard.get(r.node(id), 'fills')! as ir.PaintsValue)
          .value;
  for (final p in fills) {
    await r.tapKey('paint-remove:${p.id}');
  }
}

/// Eyebrow, heading and the rich body text in a vertical auto layout.
Future<void> buildColumn(Rig r, String column, Fonts fonts) async {
  await focusOn(r, column);
  final eyebrow = await textAt(
    r,
    inside(r, column, 0.05, 0.1),
    'Part one — the essay',
    'Eyebrow',
  );
  final heading = await textAt(
    r,
    inside(r, column, 0.05, 0.4),
    'Layout is a sentence, not a shape',
    'Heading',
  );
  final body = await textAt(r, inside(r, column, 0.05, 0.75), 'Body', 'Body');
  await r.selectNode(column);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: true, gap: '24', padding: '0');
  await sizing(r, v: 'Hug');

  await r.selectNode(eyebrow);
  await sizing(r, h: 'Fill');
  await textBox(r, autoHeight: true);
  await textStyle(
    r,
    family: fonts.sans,
    weight: '700',
    size: '13',
    letterSpacingPercent: '14',
    textCase: 'UPPERCASE',
    colour: (_rust, '100'),
  );
  await r.selectNode(heading);
  await sizing(r, h: 'Fill');
  await textBox(r, autoHeight: true);
  await textStyle(
    r,
    family: fonts.serif,
    weight: '700',
    size: '48',
    lineHeightPercent: '110',
    letterSpacingPercent: '-1',
    colour: (_ink, '100'),
  );
  await r.selectNode(body);
  await sizing(r, h: 'Fill');
  await textBox(r, autoHeight: true);
  await textStyle(
    r,
    family: fonts.serif,
    weight: '400',
    size: '19',
    lineHeightPercent: '160',
    letterSpacingPercent: '0',
    colour: (_ink, '100'),
  );
  await r.type('style.paragraphSpacing', '16');
  await writeBody(r, body);
}

const _bodyParagraphs = [
  'Every scene in Soundstage is laid out by the rules a designer already '
      'knows: hug, fill and fixed, minimum and maximum widths, and '
      'constraints against a reference size. This span is larger, italic '
      'and blue.',
  'Paragraph spacing separates paragraphs, and the first line of this one '
      'is indented by thirty-two pixels, the way a printed book would set '
      'it. The rest of the paragraph wraps back to the margin.',
  'Hug sizes a frame to its content.',
  'Fill shares the free space equally, freezing at min and max.',
  'Fixed keeps the size you set.',
  'Measure.',
  'Distribute.',
  'Align.',
  'The rows below exercise wrapping, fill, baselines and rotation. Small '
      'caps and an underlined phrase close the column.',
];

/// Types the body on the canvas (Enter between paragraphs), then styles
/// ranges with the text inspector while editing: span styles on selected
/// phrases, paragraph styles on selected paragraphs.
Future<void> writeBody(Rig r, String body) async {
  await r.selectNode(body);
  await r.focusEditor();
  await r.tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await r.pump();
  expect(r.st.textEditId, body);
  await r.selectText(0, r.session.text.length);
  for (var i = 0; i < _bodyParagraphs.length; i++) {
    if (i > 0) await r.typeText('\n');
    await r.typeText(_bodyParagraphs[i]);
  }
  expect(r.session.text, _bodyParagraphs.join('\n'));

  // FINDING-1: a colour committed in the picker while editing ends the
  // edit session in this test; Enter on the selected text resumes it.
  Future<void> resume() async {
    if (r.st.textEditId == body) return;
    await r.selectNode(body);
    await r.focusEditor();
    await r.tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await r.pump();
    expect(r.st.textEditId, body);
  }

  Future<void> paragraphs(int from, int to) async {
    await resume();
    final text = r.session.text;
    final start = text.indexOf(_bodyParagraphs[from]);
    final end = text.indexOf(_bodyParagraphs[to]) + _bodyParagraphs[to].length;
    await r.selectText(start, end);
  }

  await r.selectPhrase('hug, fill and fixed');
  await r.type('style.fontWeight', '700');
  await textColour(r, (_rust, '100'));
  await resume();
  await r.selectPhrase('This span is larger, italic and blue.');
  await r.type('style.fontSize', '24');
  await r.tapKey('field:style.italic');
  await textColour(r, ('1d4ed8', '100'));
  await paragraphs(1, 1);
  await r.type('style.paragraphIndent', '32');
  await paragraphs(2, 4);
  await r.iconSegment('style.listStyle', SsIcons.list);
  await paragraphs(2, 3);
  await r.type('style.paragraphSpacing', '6');
  await paragraphs(5, 7);
  await r.iconSegment('style.listStyle', SsIcons.listOrdered);
  await paragraphs(5, 6);
  await r.type('style.paragraphSpacing', '6');
  await resume();
  await r.selectPhrase('Small caps');
  await r.pick('field:style.textCase', 'Small caps');
  await r.selectPhrase('underlined phrase');
  await r.tapKey('field:style.decoration.kind:underline');
  // Done: a click on the layer row leaves edit mode.
  await r.selectNode(body);
  expect(r.st.textEditId, isNull);
}

/// Builds scene 3, "Quote": a pinned scene (half a screen of scroll) with
/// a full-bleed image and a centred, hugging quote card in auto layout.
Future<void> buildQuote(Rig r, Map<String, String> assets, Fonts fonts) async {
  final desktop = r.bp('Desktop');
  final mobile = r.bp('Mobile');
  final tablet = r.bp('Tablet');
  await addScene(r, 'Pinned scene');
  await renameActiveScene(r, 'Quote');
  await sceneScrollLength(r, '0.5');
  await r.zoomToFit();

  await r.selectRoot();
  await noFill(r, r.rootId); // a new scene's root is white
  await r.tab('Assets');
  await r.tester.tap(
    find.byKey(ValueKey<String>('asset-tile:${assets['sea']}')),
  );
  await r.pump();
  final rootFill = imageFillOf(r, r.rootId);
  await r.tapKey('paint-swatch:${rootFill.id}');
  await r.type('fills.${rootFill.id}.focalPoint.y', '75');

  final card = await r.draw(
    'Frame',
    desktop,
    const Offset(370, 300),
    const Offset(1070, 600),
  );
  await r.rename(card, 'Quote card');
  await solidFill(r, card, 'ffffff', '90');
  await r.type('cornerRadius', '20');

  final quote = await addText(
    r,
    desktop,
    400,
    330,
    '“A story is a sequence of rooms you walk through, not a page you '
    'read.”',
  );
  await r.rename(quote, 'Quote');
  final by = await addText(r, desktop, 400, 500, '— the Soundstage brief');
  await r.rename(by, 'Attribution');

  // Auto layout on the card: vertical, gap 16, padding 40; it hugs its
  // height, keeps its width, and is centred both ways.
  await r.selectLayer(card);
  await r.tapKey('auto-layout:add');
  await autoLayout(r, vertical: true, gap: '16', padding: '40');
  await geometry(r, x: 370, y: 300, w: 700);
  await r.segment('layoutChild.verticalSizing', 'Hug');
  await r.constraints(h: 'Center', v: 'Center');

  await r.selectLayer(quote);
  await r.segment('layoutChild.horizontalSizing', 'Fill');
  await textBox(r, autoHeight: true, align: 'Centre');
  await textStyle(
    r,
    family: fonts.serif,
    weight: '500',
    size: '30',
    lineHeightPercent: '135',
    colour: ('1c1a17', '100'),
  );
  await r.selectLayer(by);
  await r.segment('layoutChild.horizontalSizing', 'Fill');
  await textBox(r, autoHeight: true, align: 'Centre');
  await textStyle(
    r,
    family: fonts.sans,
    weight: '600',
    size: '14',
    colour: ('1c1a17', '60'),
  );

  await r.setScope(thisBreakpoint: true);
  await r.zoomToFit();
  await r.selectLayer(card);
  await clickArtboard(r, mobile);
  await geometry(r, x: 24, y: 272, w: 342);
  await autoLayout(r, paddingH: '24', paddingV: '28');
  await r.selectLayer(quote);
  await clickArtboard(r, mobile);
  await r.type('style.fontSize', '22');

  await r.freeWidth(desktop, 834);
  await r.selectLayer(card);
  await clickArtboard(r, desktop);
  expect(r.st.breakpointId, tablet);
  await geometry(r, x: 117, y: 406, w: 600);
  await r.resetWidth(desktop);
  await r.setScope(thisBreakpoint: false);
}

/// Adds a scene after the active one from the Scenes panel's "+" menu.
Future<void> addScene(Rig r, String kind) async {
  await r.tab('Scenes');
  final before = r.doc.scenes.length;
  await r.tester.tap(find.bySemanticsLabel('Add scene').first);
  await r.settleAnimations();
  if (r.doc.scenes.length == before) {
    await r.tester.tap(find.text(kind).last);
    await r.settleAnimations();
  }
  expect(r.doc.scenes.length, before + 1);
}

/// The Scenes panel's scroll length for the active scene.
Future<void> sceneScrollLength(Rig r, String value) async {
  await r.tab('Scenes');
  final f = find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is SsNumberField && w.semanticLabel == 'Scroll length',
    ),
    matching: find.byType(EditableText),
  );
  expect(f, findsWidgets);
  await r.tester.tap(f.first);
  await r.pump();
  await r.tester.enterText(f.first, value);
  await r.tester.testTextInput.receiveAction(TextInputAction.done);
  await r.pump();
}

/// The selection's first solid fill set to [hex] at [alpha] %.
Future<void> solidFill(Rig r, String id, String hex, String alpha) async {
  final paint =
      (ir.PropertyRegistry.standard.get(r.node(id), 'fills')! as ir.PaintsValue)
          .value
          .first;
  await r.colour('fills.${paint.id}.color', hex, alpha: alpha);
}

/// Auto layout fields of the selection (after "+" added it).
Future<void> autoLayout(
  Rig r, {
  bool? vertical,
  bool? wrap,
  String? gap,
  String? counterGap,
  String? padding,
  String? paddingH,
  String? paddingV,
  List<String>? sides,
}) async {
  if (vertical != null) {
    await r.iconSegment(
      'autoLayout.direction',
      vertical ? SsIcons.arrowDown : SsIcons.arrowRight,
    );
  }
  if (wrap != null) await r.tapKey('field:autoLayout.wrap');
  if (gap != null) await r.type('autoLayout.gap', gap);
  if (counterGap != null) await r.type('autoLayout.counterAxisGap', counterGap);
  if (padding != null) {
    await paddingMode(r, 'autoLayout.padding');
    await r.type('autoLayout.padding', padding);
  }
  if (paddingH != null) {
    await paddingMode(r, 'autoLayout.padding.h');
    await r.type('autoLayout.padding.h', paddingH);
  }
  if (paddingV != null) {
    await paddingMode(r, 'autoLayout.padding.v');
    await r.type('autoLayout.padding.v', paddingV);
  }
  if (sides != null) {
    await paddingMode(r, 'autoLayout.padding.top');
    final names = ['top', 'right', 'bottom', 'left'];
    for (var i = 0; i < 4; i++) {
      await r.type('autoLayout.padding.${names[i]}', sides[i]);
    }
  }
}

/// Cycles the padding mode button until the field [path] shows.
Future<void> paddingMode(Rig r, String path) async {
  for (var i = 0; i < 3 && r.field(path).evaluate().isEmpty; i++) {
    await r.tapKey('padding-mode');
  }
  await r.reveal(r.field(path));
  expect(r.field(path), findsOneWidget, reason: 'padding field $path');
}

/// The families uploaded for the story: font family ids.
class Fonts {
  Fonts(this.serif, this.sans);
  final String serif;
  final String sans;
}

ir.ImagePaint imageFillOf(Rig r, String id) {
  final fills = ir.PropertyRegistry.standard.get(r.node(id), 'fills');
  return (fills! as ir.PaintsValue).value.whereType<ir.ImagePaint>().single;
}

/// Makes artboard [bpId] the edited one by clicking the selected node on
/// it (a press on the selection keeps it and edits that artboard).
Future<void> clickArtboard(Rig r, String bpId) async {
  final sel = r.st.selection;
  await r.click(r.centreOf(sel.first, bpId));
  expect(r.st.selection, sel);
}

/// Types the frame fields that are given (X, Y, W, H, rotation).
Future<void> geometry(
  Rig r, {
  double? x,
  double? y,
  double? w,
  double? h,
  double? rotation,
}) async {
  String n(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';
  if (w != null) await r.type('width', n(w));
  if (h != null) await r.type('height', n(h));
  if (x != null) await r.type('x', n(x));
  if (y != null) await r.type('y', n(y));
  if (rotation != null) await r.type('rotation', n(rotation));
}

/// Places a text with the Text tool at ([x], [y]) of artboard [bpId] and
/// types [text] on the canvas; leaves it selected (not editing).
Future<String> addText(
  Rig r,
  String bpId,
  double x,
  double y,
  String text,
) async {
  await r.tool('Text');
  await r.click(r.at(bpId, x, y));
  expect(r.st.textEditId, isNotNull, reason: 'text tool starts editing');
  final id = r.st.textEditId!;
  await r.typeText(text);
  await r.escape();
  expect(r.st.textEditId, isNull);
  expect(r.st.selection, {id});
  return id;
}

/// Auto-resize and alignment of the selected text.
Future<void> textBox(
  Rig r, {
  bool autoHeight = false,
  bool autoWidth = false,
  String? align,
}) async {
  if (autoHeight) await r.iconSegment('autoResize', SsIcons.arrowUpDown);
  if (autoWidth) await r.iconSegment('autoResize', SsIcons.arrowLeftRight);
  if (align != null) {
    await r.iconSegment('alignHorizontal', switch (align) {
      'Left' => SsIcons.alignLeft,
      'Centre' => SsIcons.alignCenter,
      'Right' => SsIcons.alignRight,
      _ => SsIcons.alignJustify,
    });
  }
}

/// The text section's style fields for the selection (or, while editing,
/// for the selected range).
Future<void> textStyle(
  Rig r, {
  String? family,
  String? weight,
  String? size,
  String? lineHeightPercent,
  String? letterSpacingPercent,
  String? textCase,
  (String, String)? colour,
  bool? italic,
}) async {
  if (family != null) await r.pick('field:style.fontFamilyId', family);
  if (weight != null) await r.type('style.fontWeight', weight);
  if (size != null) await r.type('style.fontSize', size);
  if (lineHeightPercent != null) {
    await r.pick('field:style.lineHeight:unit', '%');
    await r.type('style.lineHeight', lineHeightPercent);
  }
  if (letterSpacingPercent != null) {
    await r.pick('field:style.letterSpacing:unit', '%');
    await r.type('style.letterSpacing', letterSpacingPercent);
  }
  if (textCase != null) await r.pick('field:style.textCase', textCase);
  if (italic != null) await r.tapKey('field:style.italic');
  if (colour != null) await textColour(r, colour);
}

/// The text's fill colour: the first paint of `style.fills` (added when the
/// text has none of its own).
Future<void> textColour(Rig r, (String, String) c) async {
  var paints = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('paint-row:'),
  );
  if (paints.evaluate().isEmpty) {
    await r.tapKey('add-paint:style.fills');
    paints = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('paint-row:'),
    );
  }
  final key = (paints.evaluate().first.widget.key! as ValueKey<String>).value;
  final pid = key.substring('paint-row:'.length);
  await r.colour('style.fills.$pid.color', c.$1, alpha: c.$2);
}

/// Switches the selection's first fill to a linear gradient (top to bottom)
/// from colour [from] to [to] (hex with alpha).
Future<void> toLinearGradient(
  Rig r,
  String id, {
  required (String, String) from,
  required (String, String) to,
}) async {
  final paint =
      (ir.PropertyRegistry.standard.get(r.node(id), 'fills')! as ir.PaintsValue)
          .value
          .first;
  await r.tapKey('paint-swatch:${paint.id}');
  await r.pick('paint-kind-detail:${paint.id}', 'Linear');
  await r.colour('fills.${paint.id}.stops.0.color', from.$1, alpha: from.$2);
  await selectStop(r, paint.id, 1);
  await r.colour('fills.${paint.id}.stops.1.color', to.$1, alpha: to.$2);
  await r.escape();
}

/// Clicks stop [i]'s handle on the gradient bar of paint [pid].
Future<void> selectStop(Rig r, String pid, int i) async {
  final stop = find.byKey(ValueKey<String>('gradient-stop:$i'));
  await r.scrollInspectorTo(stop);
  // The bar's own recogniser takes presses on its stop markers.
  await r.tester.tapAt(r.tester.getCenter(stop));
  await r.pump();
}

Future<void> renameActiveScene(Rig r, String name) async {
  await r.tab('Scenes');
  final current = r.doc.scenes.firstWhere((s) => s.id == r.st.activeSceneId);
  final label = current.name.isEmpty
      ? 'Scene ${r.doc.scenes.indexOf(current) + 1}'
      : current.name;
  final row = find.widgetWithText(SsTreeRow, label);
  await r.tester.tap(row);
  await r.tester.pump(const Duration(milliseconds: 40));
  await r.tester.tap(row);
  await r.pump(3);
  final editor = find.descendant(
    of: find.byType(SsTreeRow),
    matching: find.byType(EditableText),
  );
  await r.tester.enterText(editor, name);
  await r.tester.testTextInput.receiveAction(TextInputAction.done);
  await r.pump();
  expect(r.doc.scenes.firstWhere((s) => s.id == r.st.activeSceneId).name, name);
}

/// Uploads the four demo images through the Assets panel; returns the new
/// asset ids by demo asset id.
Future<Map<String, String>> uploadImages(Rig r) async {
  await r.tab('Assets');
  const files = {
    'hero': 'hero_dusk.png',
    'forest': 'card_forest.png',
    'sea': 'card_sea.png',
    'dunes': 'card_dunes.png',
  };
  r.nextPick = [
    for (final f in files.values) diskFile('$_images/$f', 'image/png'),
  ];
  await r.tester.tap(find.byKey(const ValueKey<String>('assets-upload')));
  await r.settleAsync();
  final byName = {for (final a in r.doc.assets.values) a.name: a.id};
  return {for (final e in files.entries) e.key: byName[e.value]!};
}

/// Uploads Fraunces (serif) and Inter (sans) through the Assets panel's
/// Fonts section; returns their family names as the font menu lists them.
Future<Fonts> uploadFonts(Rig r) async {
  await r.tab('Assets');
  await r.tester.tap(find.text('Fonts').first);
  await r.pump();
  r.nextPick = [
    diskFile('assets/demo/fonts/Fraunces-Variable.ttf', 'font/ttf'),
    diskFile('assets/fonts/inter/Inter-Variable.ttf', 'font/ttf'),
  ];
  await r.tester.tap(find.byKey(const ValueKey<String>('assets-upload')));
  await r.settleAsync();
  final names = [for (final f in r.doc.fonts.values) f.name];
  // ignore: avoid_print
  print('font families: $names');
  await r.tester.tap(find.text('Media').first);
  await r.pump();
  return Fonts(
    names.firstWhere((n) => n.startsWith('Fraunces')),
    names.firstWhere((n) => n.startsWith('Inter')),
  );
}

/// Both documents render with the runtime's fallback faces (the test
/// environment has no web fonts), so only layout logic is compared, and
/// every auto-sized text stores its measured size (see the header).
ir.StageDocument forComparison(ir.StageDocument d) {
  final noFaces = d.copyWith(fonts: noFacesOf(d));
  return syncTextSizes(
    noFaces.copyWith(scenes: const [], overlay: null),
    noFaces,
    measure: stageTextMeasurer(() => StageFontTable.none),
    resolve: (doc, bp) =>
        ir.resolveDocument(doc, ir.ResolveContext(breakpointId: bp)).nodeIndex,
  );
}

Map<String, ir.FontFamily> noFacesOf(ir.StageDocument d) => {
  for (final MapEntry(:key, :value) in d.fonts.entries)
    key: value.copyWith(faces: const []),
};

/// Roles the rebuilt story gives its text (the demo predates roles and has
/// none). Every other text keeps the Text tool's default, Paragraph.
const _roles = {
  'Title': ir.NodeRole.heading1,
  'Heading': ir.NodeRole.heading2,
  'Quote': ir.NodeRole.quote,
  'Kicker': ir.NodeRole.caption,
  'Credit': ir.NodeRole.caption,
  'Attribution': ir.NodeRole.caption,
  'Caption': ir.NodeRole.caption,
};

/// The Hero title is the one "Title" outside a card; card titles stay
/// paragraphs.
bool _isCardTitle(ir.StageDocument doc, String id) {
  var inCard = false;
  void walk(ir.Node n, bool card) {
    if (n.common.id == id) inCard = card;
    if (n is ir.FrameNode) {
      for (final c in n.children) {
        walk(c, card || n.common.name.startsWith('Card '));
      }
    }
  }

  for (final s in doc.scenes) {
    walk(s.root, false);
  }
  return inCard;
}

ir.NodeRole _expectedRole(ir.StageDocument doc, ir.TextNode t) {
  if (t.common.name == 'Title' && _isCardTitle(doc, t.common.id)) {
    return ir.NodeRole.paragraph;
  }
  return _roles[t.common.name] ?? ir.NodeRole.paragraph;
}

/// Sets roles with the inspector's Role menu, scene by scene.
Future<void> assignRoles(Rig r) async {
  for (final name in ['Hero', 'Essay', 'Quote']) {
    await r.tab('Scenes');
    await r.tester.tap(find.widgetWithText(SsTreeRow, name));
    await r.pump();
    await r.zoomToFit();
    final scene = r.doc.scenes.firstWhere((s) => s.name == name);
    final texts = <ir.TextNode>[];
    void walk(ir.Node n) {
      if (n is ir.TextNode) texts.add(n);
      if (n is ir.FrameNode) n.children.forEach(walk);
    }

    walk(scene.root);
    for (final t in texts) {
      final want = _expectedRole(r.doc, t);
      if (t.common.role == want) continue;
      await r.selectNode(t.common.id);
      await r.pick('field:role', switch (want) {
        ir.NodeRole.heading1 => 'Heading 1',
        ir.NodeRole.heading2 => 'Heading 2',
        ir.NodeRole.quote => 'Quote',
        ir.NodeRole.caption => 'Caption',
        _ => 'Paragraph',
      });
    }
  }
}

void expectRoles(ir.StageDocument doc) {
  for (final s in doc.scenes) {
    void walk(ir.Node n) {
      if (n is ir.TextNode) {
        expect(
          n.common.role,
          _expectedRole(doc, n),
          reason: '${s.name}/${n.common.name}',
        );
      }
      if (n is ir.FrameNode) n.children.forEach(walk);
    }

    walk(s.root);
  }
}

void main() {
  setUp(() => StageAssetResolver.defaultLocal = StubPngLoader());
  tearDown(() => StageAssetResolver.defaultLocal = null);

  testWidgets('the static demo is rebuilt in the editor', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    final r = await pumpNewStory(tester, title: 'Static demo (rebuilt)');
    final assets = await uploadImages(r);
    expect(assets, hasLength(4));
    final fonts = await uploadFonts(r);
    await buildHero(r, assets, fonts);
    await buildQuote(r, assets, fonts);
    await buildEssay(r, assets, fonts);
    await assignRoles(r);

    final built = r.doc;
    expectRoles(built);

    // Save (what autosave writes), then reopen through loadDocument.
    final id = r.storyId!;
    final reopened = (await tester.runAsync(() async {
      await r.repository.save(id, built);
      return r.repository.open(id);
    }))!;
    expect(reopened.diagnostics, isEmpty);
    expect(reopened.document!.toJson(), built.toJson());

    // Export .stage.zip with the stored asset bytes; import it into the
    // same asset store (identical bytes keep their ids) and open the copy.
    final imported = (await tester.runAsync(() async {
      final zip = await exportStageZip(built, r.repository.assetBytes);
      final story = await importStoryFile(zip, r.store);
      final copy = await r.repository.createFrom(story.document!);
      return (story, await r.repository.open(copy.id));
    }))!;
    final (story, copy) = imported;
    expect(story.diagnostics, isEmpty);
    expect(story.warnings, isEmpty);
    expect(story.assetCount, built.assets.length);
    expect(story.document!.toJson(), built.toJson());
    final copied = copy!.document!;
    expect(
      copied.copyWith(id: built.id).toJson(),
      built.toJson(),
      reason: 'the imported story equals the built one (apart from its id)',
    );
    for (final a in built.assets.values) {
      final bytes = await tester.runAsync(() => r.repository.assetBytes(a));
      expect(bytes, isNotNull, reason: 'stored bytes of ${a.name}');
    }

    final demo = ir.StageDocument.fromJsonMigrating(
      jsonDecode(File('assets/demo/static.stage.json').readAsStringSync())
          as Map<String, Object?>,
    );
    final diffs = <String>[];
    for (final scene in ['Hero', 'Essay', 'Quote']) {
      for (final width in [390.0, 834.0, 1440.0]) {
        diffs.addAll(
          await diffScene(
            tester,
            forComparison(copied),
            forComparison(demo),
            scene,
            width,
          ),
        );
      }
    }
    expect(diffs, isEmpty, reason: diffs.join('\n'));
  });
}
