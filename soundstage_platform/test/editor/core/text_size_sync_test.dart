import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

// DECISIONS 25/10/26 "T1.12-1 stored size of auto-sized text": the stored
// size of auto-sized text follows its measured size, per primary
// breakpoint, in the same undo step.

/// 10 px per character on one line; wraps at [width] into 20 px lines.
Size _measure(ResolvedNode rn, double? width) {
  final t = rn.node as TextNode;
  final chars = t.content
      .map((p) => p.spans.map((s) => s.text).join())
      .join()
      .length
      .toDouble();
  final natural = chars * 10;
  if (width == null) return Size(natural, 20);
  final lines = (natural / width).ceil().clamp(1, 1000);
  return Size(width, lines * 20.0);
}

TextNode _text(String id, {TextAutoResize mode = TextAutoResize.height}) =>
    TextNode(
      common: NodeCommon(id: id, name: id, x: 10, y: 600, width: 100),
      autoResize: mode,
      content: const [
        Paragraph(spans: [Span(text: 'abc')]),
      ],
    );

StageDocument _doc(List<Node> extra) => updateScene(
  fixtureDoc(),
  's1',
  (s) => s.copyWith(
    root: s.root.copyWith(children: [...s.root.children, ...extra]),
  ),
).document;

void _attach(ProviderContainer c) => c.ctl.textMeasurer = _measure;

void main() {
  test('an edit writes the measured height into the base, one undo step', () {
    final c = editorContainer(_doc([_text('t')]));
    _attach(c);
    final before = c.doc;
    c.ctl.execute(SetProperty(['t'], 'x', const IrValue.number(20)));
    expect(c.node('t').common.height, 20);
    expect(c.node('t').common.breakpointOverrides, isEmpty);
    expect(c.ctl.undo(), isTrue);
    expect(identical(c.doc, before), isTrue);
  });

  test('a wider text than its width wraps: the stored height follows', () {
    final c = editorContainer(_doc([_text('t')]));
    _attach(c);
    c.ctl.execute(SetProperty(['t'], 'width', const IrValue.number(20)));
    // 3 chars × 10 px at 20 px wide: 2 lines.
    expect(c.node('t').common.height, 40);
  });

  test('auto width and height stores both', () {
    final c = editorContainer(
      _doc([_text('t', mode: TextAutoResize.widthAndHeight)]),
    );
    _attach(c);
    c.ctl.execute(SetProperty(['t'], 'x', const IrValue.number(20)));
    expect(c.node('t').common.width, 30);
    expect(c.node('t').common.height, 20);
  });

  test('breakpoints that measure differently get their own patch', () {
    final c = editorContainer(
      _doc([
        _text('t').copyWith(
          common: _text('t').common.copyWith(
            breakpointOverrides: {
              'mobile': {'width': const IrValue.number(10)},
            },
          ),
        ),
      ]),
    );
    _attach(c);
    c.ctl.execute(SetProperty(['t'], 'x', const IrValue.number(20)));
    final n = c.node('t').common;
    expect(n.height, 20, reason: 'desktop: one line at 100');
    expect(n.breakpointOverrides['mobile'], {
      'width': const IrValue.number(10),
      'height': const IrValue.number(60),
    });
  });

  test('a height supplied by a patch is written into that patch', () {
    final c = editorContainer(
      _doc([
        _text('t').copyWith(
          common: _text('t').common.copyWith(
            breakpointOverrides: {
              'mobile': {
                'width': const IrValue.number(10),
                'height': const IrValue.number(5),
              },
            },
          ),
        ),
      ]),
    );
    _attach(c);
    c.ctl.execute(SetProperty(['t'], 'x', const IrValue.number(20)));
    expect(
      c.node('t').common.breakpointOverrides['mobile']!['height'],
      const IrValue.number(60),
    );
  });

  test('text placed by an auto-layout flow and fixed text are left alone', () {
    final c = editorContainer(
      _doc([
        FrameNode(
          common: const NodeCommon(id: 'col', width: 200, height: 200),
          autoLayout: const AutoLayout(direction: LayoutDirection.vertical),
          children: [_text('flow')],
        ),
        _text('fixed', mode: TextAutoResize.fixed),
      ]),
    );
    _attach(c);
    c.ctl.execute(
      SetProperty(['flow', 'fixed'], 'opacity', const IrValue.number(0.5)),
    );
    expect(c.node('flow').common.height, 0);
    expect(c.node('fixed').common.height, 0);
  });

  test('without a measurer nothing is written', () {
    final c = editorContainer(_doc([_text('t')]));
    c.ctl.execute(SetProperty(['t'], 'x', const IrValue.number(20)));
    expect(c.node('t').common.height, 0);
  });

  test('measured dimensions are not shown as overrides', () {
    final t = _text('t').copyWith(
      common: _text('t').common.copyWith(
        breakpointOverrides: {
          'mobile': {'height': const IrValue.number(60)},
        },
      ),
    );
    expect(hasShownOverride(t, 'mobile'), isFalse);
    expect(hasAnyShownOverride(t), isFalse);
    expect(isShownOverrideKey(t, 'mobile', 'width'), isTrue);
    final both = t.copyWith(
      common: t.common.copyWith(
        breakpointOverrides: {
          'mobile': {
            'height': const IrValue.number(60),
            'x': const IrValue.number(4),
          },
        },
      ),
    );
    expect(hasShownOverride(both, 'mobile'), isTrue);
    // A fixed-size text's height is the author's.
    final fixed = t.copyWith(autoResize: TextAutoResize.fixed);
    expect(hasShownOverride(fixed, 'mobile'), isTrue);
  });
}
