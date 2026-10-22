// Generates assets/demo/sound.stage.json, the T0.7 sound demo.
//
//   dart run tool/gen_sound_demo.dart
//
// Built from IR models so the file always matches the schema. Scenes:
//   title  pinned, scrollLength 1.5: a Fraunces heading whose colour and
//          letter-spacing animate with scroll, a line whose variable
//          weight sweeps 200 → 900, and a word-by-word TextReveal.
//   lyric  pinned, scrollLength 2: the "Lights Go Low" clip (scene-scoped,
//          autoplay, loop, fades) with a Lyrics frame (enhanced LRC, word
//          sweep, centred scrolling) and a progress bar on an audio clock.
//   coda   flow: text with leadingTrim: capHeight.

import 'dart:convert';
import 'dart:io';

import 'package:soundstage_platform/ir/ir.dart';

const _desktop = Breakpoint(
  id: 'desktop',
  name: 'Desktop',
  minWidth: 768,
  designSize: StageSize(width: 1440, height: 900),
);
const _mobile = Breakpoint(
  id: 'mobile',
  name: 'Mobile',
  minWidth: 0,
  designSize: StageSize(width: 390, height: 844),
);

StageColor _hex(String h) => StageColor.fromHex(h);
IrValue _n(double v) => IrValue.number(v);
IrValue _c(String h) => IrValue.color(_hex(h));

int _seq = 0;
Track _track(
  String target,
  String property,
  String clockId,
  List<(double, IrValue)> kfs, {
  Easing easing = const Easing.preset(EasingPreset.easeInOut),
}) {
  final id = 'tr${_seq++}';
  return Track(
    id: id,
    target: target,
    property: property,
    clockId: clockId,
    keyframes: [
      for (var i = 0; i < kfs.length; i++)
        Keyframe(id: '$id-k$i', t: kfs[i].$1, value: kfs[i].$2, easing: easing),
    ],
  );
}

LayoutChild _abs(HorizontalConstraint h, VerticalConstraint v) => LayoutChild(
  positioning: Positioning.absolute,
  constraints: Constraints(horizontal: h, vertical: v),
);

final _centre = _abs(HorizontalConstraint.center, VerticalConstraint.center);
final _stretchX = _abs(
  HorizontalConstraint.leftRight,
  VerticalConstraint.center,
);

Map<String, Patch> _mobile4(double x, double y, double w, double h) => {
  'mobile': {'x': _n(x), 'y': _n(y), 'width': _n(w), 'height': _n(h)},
};

TextNode _text(
  String id,
  String text, {
  required double x,
  required double y,
  required double w,
  required double size,
  String font = 'serif',
  int? weight,
  String color = '#f7f1e8',
  double lineHeight = 115,
  double letterSpacing = 0,
  TextAlignHorizontal align = TextAlignHorizontal.center,
  LeadingTrim trim = LeadingTrim.none,
  LayoutChild? lc,
  Map<String, Patch> overrides = const {},
}) => TextNode(
  common: NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    layoutChild: lc ?? _centre,
    breakpointOverrides: overrides,
  ),
  autoResize: TextAutoResize.height,
  alignHorizontal: align,
  leadingTrim: trim,
  style: TextStyleOverride(
    fontFamilyId: font,
    fontSize: size,
    fontWeight: weight,
    lineHeight: LineHeight.percent(lineHeight),
    letterSpacing: LetterSpacing.percent(letterSpacing),
    fills: [Paint.solid(id: 'ink', color: _hex(color))],
  ),
  content: [
    for (final p in text.split('\n')) Paragraph(spans: [Span(text: p)]),
  ],
);

FrameNode _root(String id, List<Node> children, {required String color}) =>
    FrameNode(
      common: NodeCommon(
        id: id,
        name: 'Stage',
        width: 1440,
        height: 900,
        breakpointOverrides: {
          'mobile': {'width': _n(390), 'height': _n(844)},
        },
      ),
      clipContent: true,
      appearance: Appearance(
        fills: [Paint.solid(id: 'bg', color: _hex(color))],
      ),
      children: children,
    );

Scene _title() {
  const clock = 'title-scroll';
  final heading = _text(
    'title-heading',
    'Lights Go Low',
    x: 120,
    y: 170,
    w: 1200,
    size: 132,
    weight: 300,
    letterSpacing: -2,
    lineHeight: 100,
    overrides: {
      'mobile': {
        'x': _n(16),
        'y': _n(150),
        'width': _n(358),
        'style.fontSize': _n(58),
      },
    },
  );
  final weightLine = _text(
    'title-weight',
    'variable weight',
    x: 320,
    y: 360,
    w: 800,
    size: 56,
    weight: 200,
    color: '#f2b880',
    overrides: _mobile4(16, 290, 358, 60)
      ..['mobile']!['style.fontSize'] = _n(30),
  );
  final reveal = FrameNode(
    common: NodeCommon(
      id: 'title-reveal',
      name: 'reveal',
      x: 270,
      y: 520,
      width: 900,
      height: 260,
      layoutChild: _centre,
      breakpointOverrides: _mobile4(16, 400, 358, 380),
    ),
    behavior: const Behavior.textReveal(
      clockId: clock,
      unit: TextRevealUnit.word,
      stagger: 0.03,
      range: ClockRange(start: 0.05, end: 0.75),
    ),
    children: [
      _text(
        'title-reveal-text',
        'A story is a sequence of scenes. Scroll, and each word arrives in '
            'its own time, fading and rising into place.',
        x: 0,
        y: 0,
        w: 900,
        size: 30,
        font: 'sans',
        weight: 400,
        lineHeight: 140,
        color: '#d9d2c5',
        lc: _stretchX,
        overrides: {
          'mobile': {'style.fontSize': _n(22)},
        },
      ),
    ],
  );
  return Scene(
    id: 'title',
    name: 'Title',
    kind: SceneKind.pinned,
    scrollLength: 1.5,
    root: _root('title-root', [heading, weightLine, reveal], color: '#14111c'),
    clocks: const [
      Clock.sceneScroll(id: clock, sceneId: 'title', smoothing: 0.15),
    ],
    tracks: [
      _track('title-heading', 'style.fills.ink.color', clock, [
        (0, _c('#f7f1e8')),
        (0.5, _c('#f2b880')),
        (1, _c('#e86f68')),
      ]),
      _track('title-heading', 'style.letterSpacing', clock, [
        (0, const IrValue.letterSpacing(LetterSpacing.percent(-2))),
        (1, const IrValue.letterSpacing(LetterSpacing.percent(12))),
      ]),
      _track('title-weight', 'style.fontWeight', clock, [
        (0, _n(200)),
        (0.8, _n(900)),
      ]),
    ],
  );
}

Scene _lyric(LyricsDoc lyrics) {
  const clock = 'song-time';
  final lyricsFrame = FrameNode(
    common: NodeCommon(
      id: 'lyric-frame',
      name: 'lyrics',
      x: 220,
      y: 190,
      width: 1000,
      height: 460,
      layoutChild: _centre,
      breakpointOverrides: _mobile4(12, 180, 366, 440),
    ),
    clipContent: true,
    behavior: const Behavior.lyrics(
      audioTrackId: 'song',
      scrollMode: LyricsScrollMode.center,
      activeStyle: TextStyleOverride(
        fontWeight: 600,
        fills: [
          Paint.solid(id: 'ink', color: StageColor(r: 1, g: 0.96, b: 0.9)),
        ],
      ),
      inactiveStyle: TextStyleOverride(
        fontWeight: 300,
        fills: [
          Paint.solid(
            id: 'ink',
            color: StageColor(r: 1, g: 0.96, b: 0.9, a: 0.28),
          ),
        ],
      ),
    ),
    children: [
      _text(
        'lyric-template',
        'Line',
        x: 0,
        y: 0,
        w: 1000,
        size: 52,
        lineHeight: 120,
        lc: _stretchX,
        overrides: {
          'mobile': {'style.fontSize': _n(28)},
        },
      ).copyWith(
        style: const TextStyleOverride(
          fontFamilyId: 'serif',
          fontSize: 52,
          lineHeight: LineHeight.percent(120),
          paragraphSpacing: 18,
        ),
      ),
    ],
  );
  final caption = _text(
    'lyric-caption',
    'LIGHTS GO LOW · an original tone sketch, CC0',
    x: 320,
    y: 92,
    w: 800,
    size: 15,
    font: 'sans',
    weight: 500,
    letterSpacing: 18,
    color: '#a59fb5',
    overrides: _mobile4(16, 96, 358, 40)
      ..['mobile']!['style.fontSize'] = _n(11),
  );
  final barTrack = ShapeNode(
    common: NodeCommon(
      id: 'lyric-bar-bg',
      x: 420,
      y: 760,
      width: 600,
      height: 3,
      layoutChild: _centre,
      breakpointOverrides: _mobile4(45, 720, 300, 3),
    ),
    appearance: Appearance(
      fills: [Paint.solid(id: 'f', color: _hex('#3a3448'))],
    ),
  );
  final bar = ShapeNode(
    common: NodeCommon(
      id: 'lyric-bar',
      x: 420,
      y: 760,
      width: 600,
      height: 3,
      layoutChild: _centre,
      motion: const MotionTransform(scaleX: 0, originX: 0),
      breakpointOverrides: _mobile4(45, 720, 300, 3),
    ),
    appearance: Appearance(
      fills: [Paint.solid(id: 'f', color: _hex('#f2b880'))],
    ),
  );
  return Scene(
    id: 'lyric',
    name: 'Lyric',
    kind: SceneKind.pinned,
    scrollLength: 2,
    root: _root('lyric-root', [
      caption,
      lyricsFrame,
      barTrack,
      bar,
    ], color: '#0d0b14'),
    clocks: const [Clock.audio(id: clock, audioTrackId: 'song')],
    tracks: [
      _track('lyric-bar', 'motion.scaleX', clock, [
        (0, _n(0)),
        (16, _n(1)),
      ], easing: const Easing.linear()),
    ],
  );
}

Scene _coda() => Scene(
  id: 'coda',
  name: 'Coda',
  root: FrameNode(
    common: NodeCommon(
      id: 'coda-root',
      name: 'Coda',
      width: 1440,
      height: 520,
      breakpointOverrides: {
        'mobile': {'width': _n(390), 'height': _n(480)},
      },
    ),
    appearance: Appearance(
      fills: [Paint.solid(id: 'bg', color: _hex('#f4efe6'))],
    ),
    autoLayout: const AutoLayout(
      direction: LayoutDirection.vertical,
      padding: EdgeInsetsValue(top: 120, right: 120, bottom: 120, left: 120),
      gap: Gap.fixed(24),
    ),
    children: [
      _text(
        'coda-heading',
        'Trimmed to the cap height',
        x: 0,
        y: 0,
        w: 1200,
        size: 72,
        weight: 500,
        color: '#1d1626',
        align: TextAlignHorizontal.left,
        trim: LeadingTrim.capHeight,
        lc: const LayoutChild(horizontalSizing: Sizing.fill),
        overrides: {
          'mobile': {'style.fontSize': _n(36)},
        },
      ),
      _text(
        'coda-body',
        'leadingTrim: capHeight reads the font’s OS/2 table, so the block '
            'above starts exactly at the top of its capitals and ends on its '
            'baseline, the way Figma’s vertical trim does.',
        x: 0,
        y: 0,
        w: 1200,
        size: 22,
        font: 'sans',
        weight: 400,
        lineHeight: 150,
        color: '#4a4258',
        align: TextAlignHorizontal.left,
        lc: const LayoutChild(horizontalSizing: Sizing.fill),
        overrides: {
          'mobile': {'style.fontSize': _n(17)},
        },
      ),
    ],
  ),
  clocks: const [Clock.sceneScroll(id: 'coda-scroll', sceneId: 'coda')],
);

void main() {
  final lrc = File('assets/demo/audio/lights_go_low.lrc').readAsStringSync();
  final parsed = parseLrc(lrc);
  if (parsed.diagnostics.isNotEmpty) {
    stderr.writeln(parsed.diagnostics.join('\n'));
    exit(1);
  }
  final doc = StageDocument(
    id: 'demo-sound',
    breakpoints: const [_desktop, _mobile],
    baseBreakpointId: 'desktop',
    meta: const StageMeta(
      title: 'Lights Go Low',
      slug: 'sound-demo',
      author: 'Soundstage',
      description: 'Fonts, audio, lyrics and animated text (T0.7).',
      coverAssetId: 'cover',
    ),
    defaultTextStyle: const TextStyle(fontFamilyId: 'serif'),
    fonts: const {
      'serif': FontFamily(
        id: 'serif',
        name: 'Fraunces',
        fallback: FontFallback.serif,
        faces: [
          FontFace(
            assetId: 'font-fraunces',
            weight: 400,
            variable: true,
            axes: [
              FontAxis(tag: 'opsz', min: 9, max: 144, defaultValue: 9),
              FontAxis(tag: 'wght', min: 100, max: 900, defaultValue: 900),
              FontAxis(tag: 'SOFT', min: 0, max: 100, defaultValue: 0),
              FontAxis(tag: 'WONK', min: 0, max: 1, defaultValue: 1),
            ],
          ),
        ],
      ),
      'sans': FontFamily(
        id: 'sans',
        name: 'Space Grotesk',
        faces: [
          FontFace(
            assetId: 'font-grotesk',
            weight: 400,
            variable: true,
            axes: [
              FontAxis(tag: 'wght', min: 300, max: 700, defaultValue: 300),
            ],
          ),
        ],
      ),
    },
    assets: const {
      'font-fraunces': Asset(
        id: 'font-fraunces',
        kind: AssetKind.font,
        uri: 'asset://assets/demo/fonts/Fraunces-Variable.ttf',
        name: 'Fraunces (OFL)',
      ),
      'font-grotesk': Asset(
        id: 'font-grotesk',
        kind: AssetKind.font,
        uri: 'asset://assets/demo/fonts/SpaceGrotesk-Variable.ttf',
        name: 'Space Grotesk (OFL)',
      ),
      'clip': Asset(
        id: 'clip',
        kind: AssetKind.audio,
        uri: 'asset://assets/demo/audio/lights_go_low.wav',
        mime: 'audio/wav',
        name: 'Lights Go Low (CC0)',
        duration: 16,
      ),
      'cover': Asset(
        id: 'cover',
        kind: AssetKind.image,
        uri: 'asset://assets/demo/images/hero_dusk.png',
        name: 'Dusk',
      ),
    },
    audioTracks: [
      AudioTrack(
        id: 'song',
        assetId: 'clip',
        scope: const AudioScope.scene('lyric'),
        autoplay: true,
        loop: true,
        volume: 0.8,
        fadeIn: 0.6,
        fadeOut: 0.8,
        lyrics: parsed.doc,
      ),
    ],
    scenes: [_title(), _lyric(parsed.doc), _coda()],
  );
  final json = const JsonEncoder.withIndent('  ').convert(doc.toJson());
  File('assets/demo/sound.stage.json').writeAsStringSync('$json\n');
  stdout.writeln('wrote assets/demo/sound.stage.json');
}
