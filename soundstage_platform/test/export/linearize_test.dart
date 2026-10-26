import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/export/export.dart';
import 'package:soundstage_platform/ir/ir.dart';

TextNode _text(
  String id,
  NodeRole role,
  List<Span> spans, {
  double x = 0,
  double y = 0,
  int? order,
}) => TextNode(
  common: NodeCommon(
    id: id,
    x: x,
    y: y,
    width: 400,
    height: 40,
    role: role,
    readingOrder: order,
  ),
  content: [Paragraph(spans: spans)],
);

StageDocument _doc() => StageDocument(
  id: 'd',
  meta: const StageMeta(title: 'Night *walk*', description: 'A test.'),
  breakpoints: const [
    Breakpoint(
      id: 'bp',
      name: 'Desktop',
      minWidth: 0,
      designSize: StageSize(width: 1000, height: 800),
      primary: true,
    ),
  ],
  assets: const {
    'img': Asset(id: 'img', kind: AssetKind.image, uri: 'local://img'),
    'song': Asset(
      id: 'song',
      kind: AssetKind.audio,
      uri: 'local://song',
      name: 'Night song.mp3',
    ),
  },
  audioTracks: const [
    AudioTrack(
      id: 't1',
      assetId: 'song',
      scope: AudioScope.scene('s1'),
      lyrics: LyricsDoc(
        lines: [
          LyricLine(start: 0, text: 'First line'),
          LyricLine(start: 2, text: 'Second line'),
        ],
      ),
    ),
  ],
  scenes: [
    Scene(
      id: 's1',
      name: 'Opening',
      root: FrameNode(
        common: const NodeCommon(id: 'r1', width: 1000, height: 800),
        children: [
          // Tree order is not reading order: the paragraph sits lower.
          _text('p', NodeRole.paragraph, const [
            Span(text: 'It was '),
            Span(text: 'late', style: TextStyleOverride(fontWeight: 700)),
            Span(text: ', see '),
            Span(text: 'this', link: SpanLink.url('https://x.test/a')),
            Span(text: '.'),
          ], y: 200),
          _text('h', NodeRole.heading1, const [Span(text: 'Chapter one')]),
          const ShapeNode(
            common: NodeCommon(
              id: 'deco',
              y: 100,
              width: 10,
              height: 10,
              role: NodeRole.decorative,
            ),
          ),
          const FrameNode(
            common: NodeCommon(
              id: 'fig',
              y: 300,
              width: 400,
              height: 300,
              role: NodeRole.figure,
              altText: 'A street',
            ),
            appearance: Appearance(
              fills: [Paint.image(id: 'pi', assetId: 'img')],
            ),
          ),
          _text('cap', NodeRole.caption, const [
            Span(text: 'The street.'),
          ], y: 610),
          _text('q', NodeRole.quote, const [Span(text: 'Quiet.')], y: 700),
          const FrameNode(
            common: NodeCommon(id: 'lyr', y: 750, width: 400, height: 40),
            behavior: Behavior.lyrics(audioTrackId: 't1'),
          ),
          // An explicit reading order beats geometry.
          _text(
            'first',
            NodeRole.paragraph,
            const [Span(text: 'Prologue')],
            y: 790,
            order: 0,
          ),
        ],
      ),
    ),
    const Scene(
      id: 's2',
      name: 'The storm',
      root: FrameNode(
        common: NodeCommon(id: 'r2', width: 1000, height: 800),
        children: [
          ShapeNode(common: NodeCommon(id: 'cloud', width: 200, height: 100)),
        ],
      ),
      posterClock: 0.3,
    ),
  ],
);

void main() {
  test('scenes become blocks in reading order, by role', () {
    final story = linearize(_doc());
    expect(story.title, 'Night *walk*');
    final s1 = story.scenes.first;
    expect(s1.isPoster, isFalse);
    final kinds = [for (final b in s1.blocks) b.runtimeType];
    expect(kinds, [
      ParagraphBlock, // Prologue (readingOrder 0)
      HeadingBlock,
      ParagraphBlock,
      FigureBlock,
      QuoteBlock,
      TranscriptBlock,
      AudioBlock,
    ]);
    final p = s1.blocks[2] as ParagraphBlock;
    expect(p.runs.map((r) => r.text).join(), 'It was late, see this.');
    expect(p.runs[1].bold, isTrue);
    expect(p.runs[3].href, 'https://x.test/a');
    final fig = s1.blocks[3] as FigureBlock;
    expect(fig.assetId, 'img');
    expect(fig.alt, 'A street');
    expect(fig.caption.single.text, 'The street.');
    expect((s1.blocks[5] as TranscriptBlock).lines, [
      'First line',
      'Second line',
    ]);
    expect((s1.blocks[6] as AudioBlock).name, 'Night song');
  });

  test('a scene without role-bearing text is a poster at its clock', () {
    final s2 = linearize(_doc()).scenes[1];
    expect(s2.isPoster, isTrue);
    final poster = s2.blocks.single as PosterBlock;
    expect(poster.clock, 0.3);
    expect(poster.alt, 'The storm');
  });

  test('exportAs overrides the automatic choice', () {
    final doc = _doc();
    final forced = doc.copyWith(
      scenes: [doc.scenes.first.copyWith(exportAs: SceneExportMode.poster)],
    );
    expect(linearize(forced).scenes.single.isPoster, isTrue);
  });

  test('Markdown', () {
    final md = toMarkdown(
      linearize(_doc()),
      pathOf: (k) => switch (k) {
        'img' => 'assets/img.png',
        'scene-s2' => 'assets/scene-s2.png',
        _ => null,
      },
      backlink: const Backlink('https://soundstage.app/s/night'),
    );
    expect(md, startsWith('# Night \\*walk\\*\n\nA test.\n'));
    expect(md, contains('\n## Chapter one\n'));
    expect(md, contains('It was **late**, see [this](https://x.test/a).'));
    expect(md, contains('![A street](assets/img.png)\n\n*The street.*'));
    expect(md, contains('> Quiet.'));
    expect(md, contains('> First line  \n> Second line'));
    expect(md, contains('🎧 Night song'));
    expect(
      md,
      contains(
        '![The storm](assets/scene-s2.png)\n\n'
        '[View interactive article on Soundstage]'
        '(https://soundstage.app/s/night#scene-s2)',
      ),
    );
    expect(md.trimRight(), endsWith('(https://soundstage.app/s/night)'));
  });

  test('HTML is standalone and semantic', () {
    final html = toHtml(
      linearize(_doc()),
      pathOf: (k) => k == 'img' ? 'assets/img.png' : null,
    );
    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('<html lang="en">'));
    expect(html, contains('<title>Night *walk*</title>'));
    expect(html, contains('<h2>Chapter one</h2>'));
    expect(
      html,
      contains(
        'It was <strong>late</strong>, see '
        '<a href="https://x.test/a" rel="noopener">this</a>.',
      ),
    );
    expect(
      html,
      contains(
        '<img src="assets/img.png" alt="A street" width="400" height="300"',
      ),
    );
    expect(html, contains('<figcaption>The street.</figcaption>'));
    expect(html, contains('<section id="scene-s2">'));
    // No backlink without a published URL; no poster file either.
    expect(html, isNot(contains('View interactive')));
  });

  test('lists group consecutive items', () {
    final story = const LinearStory(
      title: 'L',
      scenes: [
        LinearScene(
          id: 's',
          name: 's',
          blocks: [
            ParagraphBlock([InlineRun('a')], list: ListKind.unordered),
            ParagraphBlock([InlineRun('b')], list: ListKind.unordered),
            ParagraphBlock([InlineRun('after')]),
            ParagraphBlock([InlineRun('one')], list: ListKind.ordered),
            ParagraphBlock([InlineRun('two')], list: ListKind.ordered),
          ],
        ),
      ],
    );
    expect(
      toMarkdown(story),
      contains('\n- a\n- b\n\nafter\n\n1. one\n2. two\n'),
    );
    expect(
      toHtml(story),
      contains('<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<p>after</p>\n<ol>'),
    );
  });
}
