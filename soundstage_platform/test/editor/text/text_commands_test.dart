import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/text/rich_text_model.dart';
import 'package:soundstage_platform/ir/ir.dart';

import '../core/fixtures.dart';

/// A document with one text node `t` ("Hello bold" / "world") whose second
/// span is bold and has a mobile-only colour patch.
StageDocument _textDoc({Map<String, Patch> patches = const {}}) {
  final base = fixtureDoc();
  final s = base.scenes.first;
  return base.copyWith(
    scenes: [
      s.copyWith(
        root: s.root.copyWith(
          children: [
            ...s.root.children,
            TextNode(
              common: NodeCommon(
                id: 't',
                x: 10,
                y: 700,
                width: 300,
                breakpointOverrides: patches,
              ),
              autoResize: TextAutoResize.height,
              content: const [
                Paragraph(
                  spans: [
                    Span(text: 'Hello '),
                    Span(
                      text: 'bold',
                      style: TextStyleOverride(fontWeight: 700),
                    ),
                  ],
                ),
                Paragraph(spans: [Span(text: 'world')]),
              ],
            ),
          ],
        ),
      ),
      ...base.scenes.skip(1),
    ],
  );
}

const _red = IrValue.enumValue('upper');

extension on ProviderContainer {
  TextNode get t => node('t') as TextNode;
  String get text =>
      t.content.map((p) => p.spans.map((s) => s.text).join('|')).join('/');
  List<ResolvedParagraph> paras(String bp) => resolved('t', bp).paragraphs!;
}

void main() {
  group('ReplaceText', () {
    test('content edits go to the base whatever the scope; undoable', () {
      final c = editorContainer(_textDoc());
      c.ctl
        ..select({'t'})
        ..setEditScope(EditScope.thisBreakpoint);
      expectRoundTrip(c, ReplaceText('t', 10, 10, '!'));
      expect(c.text, 'Hello |bold!/world');
      expect(c.t.common.breakpointOverrides, isEmpty);
      expect(c.st.selection, {'t'});
    });

    test(
      'text-content patches are dropped, style patches follow their span',
      () {
        final c = editorContainer(
          _textDoc(
            patches: {
              'mobile': {
                'content.0.spans.1.style.textCase': _red,
                'content.0.spans.0.text': const IrValue.string('Hi '),
                'content.1.style.paragraphIndent': const IrValue.number(4),
              },
            },
          ),
        );
        // Enter before "Hello": every index shifts by a paragraph.
        c.ctl.execute(ReplaceText('t', 0, 0, '\n'));
        expect(c.text, '/Hello |bold/world');
        expect(c.t.common.breakpointOverrides['mobile'], {
          'content.1.spans.1.style.textCase': _red,
          'content.2.style.paragraphIndent': const IrValue.number(4),
        });
        expect(c.paras('mobile')[1].spans[1].style.textCase, TextCase.upper);
        expect(c.paras('desktop')[1].spans[1].style.textCase, TextCase.none);
      },
    );

    test('a split span carries its patch to both halves; a deleted one drops '
        'it', () {
      final c = editorContainer(
        _textDoc(
          patches: {
            'mobile': {'content.0.spans.1.style.textCase': _red},
          },
        ),
      );
      c.ctl.execute(ReplaceText('t', 8, 8, '\n')); // "bo" / "ld"
      expect(c.t.common.breakpointOverrides['mobile']!.keys.toSet(), {
        'content.0.spans.1.style.textCase',
        'content.1.spans.0.style.textCase',
      });
      c.ctl.execute(ReplaceText('t', 6, 8, '')); // delete "bo"
      expect(c.t.common.breakpointOverrides['mobile']!.keys.toSet(), {
        'content.1.spans.0.style.textCase',
      });
    });

    test('pending typing styles apply to the inserted text by scope', () {
      final c = editorContainer(_textDoc());
      c.ctl.execute(
        ReplaceText(
          't',
          5,
          5,
          'X',
          styleWrites: const {'italic': IrValue.boolean(true)},
        ),
      );
      expect(c.text, 'Hello|X| |bold/world');
      expect(c.t.content.first.spans[1].style.italic, isTrue);
    });

    test('instance inner text is refused', () {
      final c = editorContainer(_textDoc());
      final r = c.ctl.execute(ReplaceText('inst/cmpT', 0, 0, 'x'));
      expect(r.ok, isFalse);
    });
  });

  group('StyleTextRange', () {
    test('Both: splits base spans and writes the base, clearing primary '
        'patches', () {
      final c = editorContainer(
        _textDoc(
          patches: {
            'mobile': {
              'content.0.spans.0.style.fontWeight': const IrValue.number(300),
            },
          },
        ),
      );
      expectRoundTrip(
        c,
        StyleTextRange('t', 1, 3, const {'italic': IrValue.boolean(true)}),
      );
      expect(c.text, 'H|el|lo |bold/world');
      expect(c.t.content.first.spans[1].style.italic, isTrue);
      // The weight patch followed the split onto all three pieces.
      expect(c.t.common.breakpointOverrides['mobile']!.keys.toSet(), {
        'content.0.spans.0.style.fontWeight',
        'content.0.spans.1.style.fontWeight',
        'content.0.spans.2.style.fontWeight',
      });
      expect(c.paras('mobile')[0].spans[1].style.italic, isTrue);
    });

    test('This breakpoint: base split only, the style is a patch', () {
      final c = editorContainer(_textDoc());
      c.ctl
        ..setEditingBreakpoint('mobile')
        ..setEditScope(EditScope.thisBreakpoint);
      c.ctl.execute(
        StyleTextRange('t', 0, 5, const {'italic': IrValue.boolean(true)}),
      );
      expect(c.text, 'Hello| |bold/world');
      expect(c.t.content.first.spans[0].style.italic, isNull);
      expect(c.t.common.breakpointOverrides['mobile'], {
        'content.0.spans.0.style.italic': const IrValue.boolean(true),
      });
      expect(c.paras('mobile')[0].spans[0].style.italic, isTrue);
      expect(c.paras('desktop')[0].spans[0].style.italic, isFalse);
      // Desktop and mobile look as before apart from the patch: the split
      // spans only stay apart because their patches differ.
      expect(
        c.paras('desktop')[0].spans.map((s) => s.text).join(),
        'Hello bold',
      );
    });

    test('un-styling merges spans back (normal form)', () {
      final c = editorContainer(_textDoc());
      c.ctl.execute(
        StyleTextRange('t', 6, 10, const {'fontWeight': IrValue.none()}),
      );
      expect(c.text, 'Hello bold/world');
    });

    test('fills sub-paths and decoration leaves expand from the effective '
        'style', () {
      final c = editorContainer(_textDoc());
      c.ctl.execute(
        StyleTextRange('t', 0, 5, const {
          'fills.text.color': IrValue.color(StageColor(r: 1, g: 0, b: 0)),
          'decoration.kind': IrValue.enumValue('underline'),
        }),
      );
      final s = c.t.content.first.spans.first.style;
      expect(s.fills, hasLength(1));
      expect(
        (s.fills!.single as SolidPaint).color,
        const StageColor(r: 1, g: 0, b: 0),
      );
      expect(s.decoration!.kind, TextDecorationKind.underline);
      expect(s.decoration!.skipInk, isTrue);
    });
  });

  group('paragraph and node styles', () {
    test('StyleTextParagraphs writes the touched paragraphs', () {
      final c = editorContainer(_textDoc());
      c.ctl.execute(
        const StyleTextParagraphs(
          't',
          3,
          12,
          'alignHorizontal',
          IrValue.enumValue('center'),
        ),
      );
      expect(c.paras('desktop').map((p) => p.alignHorizontal), [
        TextAlignHorizontal.center,
        TextAlignHorizontal.center,
      ]);
    });

    test(
      'StyleTextNodes writes the node style and the spans overriding it',
      () {
        final c = editorContainer(_textDoc());
        expectRoundTrip(
          c,
          StyleTextNodes(['t'], 'fontWeight', const IrValue.number(300)),
        );
        expect(c.t.style.fontWeight, 300);
        expect(
          c.paras('desktop')[0].spans.map((s) => s.style.fontWeight).toSet(),
          {300},
        );
        // Equal spans merged.
        expect(c.text, 'Hello bold/world');
      },
    );

    test('StyleTextNodes for paragraph fields clears paragraph overrides', () {
      final c = editorContainer(_textDoc());
      c.ctl.execute(
        const StyleTextParagraphs(
          't',
          0,
          0,
          'paragraphSpacing',
          IrValue.number(20),
        ),
      );
      c.ctl.execute(
        StyleTextNodes(['t'], 'paragraphSpacing', const IrValue.number(8)),
      );
      expect(c.paras('desktop').map((p) => p.paragraphSpacing), [8, 8]);
      expect(c.t.content.first.style?.paragraphSpacing, isNull);
    });

    test('CommandBatch is one undo step', () {
      final c = editorContainer(_textDoc());
      final before = c.doc;
      c.ctl.execute(
        CommandBatch([
          ReplaceText('t', 0, 0, 'A'),
          StyleTextRange('t', 0, 1, const {'italic': IrValue.boolean(true)}),
        ], label: 'Both'),
      );
      expect(c.text, 'A|Hello |bold/world');
      c.ctl.undo();
      expect(identical(c.doc, before), isTrue);
    });
  });

  test('property: random edits keep every content patch addressing an '
      'existing span, and undo restores each step exactly', () {
    final rnd = Random(11);
    for (var run = 0; run < 40; run++) {
      final c = editorContainer(
        _textDoc(
          patches: {
            'mobile': {'content.0.spans.1.style.textCase': _red},
          },
        ),
      );
      c.ctl.setEditingBreakpoint('mobile');
      for (var step = 0; step < 25; step++) {
        final len = documentLength(c.t.content);
        final a = rnd.nextInt(len + 1);
        final b = (a + rnd.nextInt(5)).clamp(0, len);
        c.ctl.setEditScope(
          rnd.nextBool() ? EditScope.both : EditScope.thisBreakpoint,
        );
        final before = c.doc;
        final EditCommand cmd = switch (rnd.nextInt(3)) {
          0 => ReplaceText('t', a, b, ['x', ' y', '\n', ''][rnd.nextInt(4)]),
          1 => StyleTextRange('t', a, b, {
            'italic': rnd.nextBool()
                ? const IrValue.boolean(true)
                : const IrValue.none(),
          }),
          _ => StyleTextParagraphs(
            't',
            a,
            b,
            'paragraphIndent',
            IrValue.number(rnd.nextInt(3) * 4.0),
          ),
        };
        final r = c.ctl.execute(cmd);
        expect(r.ok, isTrue, reason: '$run/$step ${r.diagnostics}');
        for (final patch in c.t.common.breakpointOverrides.values) {
          for (final k in patch.keys) {
            expect(
              PropertyRegistry.standard.get(c.t, k),
              isNotNull,
              reason: 'run $run step $step: $k',
            );
          }
        }
        // Mobile resolves every patch without diagnostics.
        expect(c.paras('mobile'), hasLength(c.t.content.length));
        if (r.changed) {
          c.ctl.undo();
          expect(identical(c.doc, before), isTrue);
          c.ctl.redo();
        }
      }
    }
  });
}
