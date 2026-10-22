// Generates assets/demo/spike.stage.json, the T0.8 spike story ("The Hour
// Between"), the default of the dev harness.
//
//   dart run tool/gen_spike_images.dart   # once: the procedural images
//   dart run tool/gen_spike_demo.dart
//
// Built from IR models so the file always matches the schema. Scenes:
//   hero    pinned, scrollLength 2.4: a parallax of sky and three ridges
//           (scroll clock, smoothed), a character-by-character TextReveal of
//           the title on a timeline clock that plays on entry.
//   lyric   pinned, scrollLength 2.2: the CC0 "Lights Go Low" clip with
//           synced enhanced-LRC lyrics (styles interpolate between lines),
//           a glow that breathes on the audio clock.
//   things  flow: rich text and an auto-layout wrap grid of six cards
//           (fill width, min 340 / max 460).
//   lamp    pinned, scrollLength 2.6: a 2400x1200 panorama zoomed 2.6x about
//           its lighthouse lamp; the image is `fill`-cropped with a focal
//           point at 1440, 834 and 390, and the zoom origin is the focal
//           point's position at each width.
//   fin     flow: the closing scene.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:soundstage_platform/ir/ir.dart';

// ---- Breakpoints and sizes -------------------------------------------------------

const _desktop = Breakpoint(
  id: 'desktop',
  name: 'Desktop',
  minWidth: 1024,
  designSize: StageSize(width: 1440, height: 900),
);
const _tablet = Breakpoint(
  id: 'tablet',
  name: 'Tablet',
  minWidth: 600,
  designSize: StageSize(width: 834, height: 1112),
);
const _mobile = Breakpoint(
  id: 'mobile',
  name: 'Mobile',
  minWidth: 0,
  designSize: StageSize(width: 390, height: 844),
);

/// Desktop, tablet and mobile design sizes, indexed 0, 1, 2.
const _sizes = [Size2(1440, 900), Size2(834, 1112), Size2(390, 844)];

class Size2 {
  const Size2(this.w, this.h);
  final double w, h;
}

StageColor _hex(String h) => StageColor.fromHex(h);
IrValue _n(double v) => IrValue.number(v);

/// Breakpoint patches from per-breakpoint values: [d] desktop (the base
/// value, only used to document), [t] tablet, [m] mobile; each a map
/// property → number. A property missing from [t] falls back to desktop.
Map<String, Patch> _bp({
  Map<String, double> t = const {},
  Map<String, double> m = const {},
  Map<String, IrValue> tv = const {},
  Map<String, IrValue> mv = const {},
}) => {
  if (t.isNotEmpty || tv.isNotEmpty)
    'tablet': {for (final e in t.entries) e.key: _n(e.value), ...tv},
  if (m.isNotEmpty || mv.isNotEmpty)
    'mobile': {for (final e in m.entries) e.key: _n(e.value), ...mv},
};

/// Geometry patches for tablet and mobile: (x, y, w, h) each; null = keep.
Map<String, Patch> _geo({
  (double, double, double, double)? t,
  (double, double, double, double)? m,
  Map<String, double> tx = const {},
  Map<String, double> mx = const {},
}) {
  Map<String, double> g((double, double, double, double)? v) => v == null
      ? const {}
      : {'x': v.$1, 'y': v.$2, 'width': v.$3, 'height': v.$4};
  return _bp(t: {...g(t), ...tx}, m: {...g(m), ...mx});
}

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

List<Track> _both(
  String target,
  String clock,
  List<(double, double)> kfs, {
  Easing easing = const Easing.preset(EasingPreset.easeInOut),
}) => [
  for (final p in ['motion.scaleX', 'motion.scaleY'])
    _track(target, p, clock, [
      for (final (t, v) in kfs) (t, _n(v)),
    ], easing: easing),
];

const _lin = Easing.linear();
const _easeOut = Easing.preset(EasingPreset.easeOut);
const _easeOutBack = Easing.preset(EasingPreset.easeOutBack);

LayoutChild _abs(HorizontalConstraint h, VerticalConstraint v) => LayoutChild(
  positioning: Positioning.absolute,
  constraints: Constraints(horizontal: h, vertical: v),
);
final _scaleBoth = _abs(HorizontalConstraint.scale, VerticalConstraint.scale);
final _centre = _abs(HorizontalConstraint.center, VerticalConstraint.center);
final _centreX = _abs(HorizontalConstraint.center, VerticalConstraint.top);
final _stretchX = _abs(HorizontalConstraint.leftRight, VerticalConstraint.top);

// ---- Node builders ---------------------------------------------------------------

Span _s(
  String text, {
  int? weight,
  bool? italic,
  String? color,
  double? size,
  double? spacing,
  String? font,
}) => Span(
  text: text,
  style: TextStyleOverride(
    fontWeight: weight,
    italic: italic,
    fontSize: size,
    fontFamilyId: font,
    letterSpacing: spacing == null ? null : LetterSpacing.percent(spacing),
    fills: color == null ? null : [Paint.solid(id: 'ink', color: _hex(color))],
  ),
);

TextNode _text(
  String id,
  List<List<Span>> paragraphs, {
  double x = 0,
  double y = 0,
  double w = 400,
  required double size,
  String font = 'serif',
  int weight = 400,
  String color = '#f7f1e8',
  double lineHeight = 115,
  double letterSpacing = 0,
  double paragraphSpacing = 0,
  TextAlignHorizontal align = TextAlignHorizontal.center,
  LeadingTrim trim = LeadingTrim.none,
  double? opsz,
  LayoutChild? lc,
  double opacity = 1,
  Map<String, Patch> overrides = const {},
}) => TextNode(
  common: NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    opacity: opacity,
    layoutChild: lc ?? _centreX,
    breakpointOverrides: overrides,
  ),
  autoResize: TextAutoResize.height,
  alignHorizontal: align,
  leadingTrim: trim,
  style: TextStyleOverride(
    fontFamilyId: font,
    fontSize: size,
    fontWeight: weight,
    fontVariations: opsz == null ? null : {'opsz': opsz},
    lineHeight: LineHeight.percent(lineHeight),
    letterSpacing: LetterSpacing.percent(letterSpacing),
    paragraphSpacing: paragraphSpacing,
    fills: [Paint.solid(id: 'ink', color: _hex(color))],
  ),
  content: [for (final p in paragraphs) Paragraph(spans: p)],
);

List<List<Span>> _plain(String text) => [
  for (final p in text.split('\n')) [Span(text: p)],
];

ShapeNode _shape(
  String id, {
  double x = 0,
  double y = 0,
  required double w,
  required double h,
  List<Paint> fills = const [],
  ShapeGeometry geometry = const ShapeGeometry.rectangle(),
  LayoutChild? lc,
  double radius = 0,
  List<Effect> effects = const [],
  double opacity = 1,
  MotionTransform motion = const MotionTransform(),
  StrokeWeight? strokeWeight,
  List<Paint> strokes = const [],
  Map<String, Patch> overrides = const {},
}) => ShapeNode(
  common: NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    height: h,
    opacity: opacity,
    motion: motion,
    layoutChild: lc ?? _scaleBoth,
    breakpointOverrides: overrides,
  ),
  geometry: geometry,
  appearance: Appearance(
    fills: fills,
    cornerRadius: CornerRadius.uniform(radius),
    effects: effects,
    strokes: strokes.isEmpty
        ? const Stroke()
        : Stroke(
            paints: strokes,
            weight: strokeWeight ?? const StrokeWeight.uniform(1),
          ),
  ),
);

Paint _solid(String hex, {String id = 'fill', double opacity = 1}) =>
    Paint.solid(id: id, color: _hex(hex), opacity: opacity);

Paint _image(String asset, double fx, double fy, {double opacity = 1}) =>
    Paint.image(
      id: 'img',
      assetId: asset,
      focalPoint: StagePoint(x: fx, y: fy),
      opacity: opacity,
    );

FrameNode _root(
  String id,
  List<Node> children, {
  required String color,
  double w = 1440,
  double h = 900,
}) => FrameNode(
  common: NodeCommon(
    id: id,
    name: 'Stage',
    width: w,
    height: h,
    breakpointOverrides: {
      'tablet': {'width': _n(834), 'height': _n(1112)},
      'mobile': {'width': _n(390), 'height': _n(844)},
    },
  ),
  clipContent: true,
  appearance: Appearance(
    fills: [Paint.solid(id: 'bg', color: _hex(color))],
  ),
  children: children,
);

/// A flow scene's root: hugs its height, auto-layout column.
FrameNode _flowRoot(
  String id,
  List<Node> children, {
  required String color,
  required EdgeInsetsValue pad,
  required EdgeInsetsValue padTablet,
  required EdgeInsetsValue padMobile,
  double gap = 28,
  CounterAlign align = CounterAlign.start,
}) => FrameNode(
  common: NodeCommon(
    id: id,
    name: 'Stage',
    width: 1440,
    height: 800,
    layoutChild: const LayoutChild(verticalSizing: Sizing.hug),
    breakpointOverrides: {
      'tablet': {
        'width': _n(834),
        'autoLayout.padding': IrValue.insets(padTablet),
      },
      'mobile': {
        'width': _n(390),
        'autoLayout.padding': IrValue.insets(padMobile),
        'autoLayout.gap': IrValue.gap(Gap.fixed(gap * 0.75)),
      },
    },
  ),
  autoLayout: AutoLayout(
    direction: LayoutDirection.vertical,
    gap: Gap.fixed(gap),
    padding: pad,
    counterAlign: align,
  ),
  appearance: Appearance(
    fills: [Paint.solid(id: 'bg', color: _hex(color))],
  ),
  children: children,
);

// ---- Scene 1: hero -----------------------------------------------------------------

Scene _hero() {
  const scroll = 'hero-scroll', tl = 'hero-tl';
  final children = <Node>[];
  final tracks = <Track>[];

  // Sky: slow push-in about the sun.
  children.add(
    _shape(
      'hero-sky',
      w: 1440,
      h: 900,
      fills: [_image('sky', 0.62, 0.40)],
      overrides: _geo(t: (0, 0, 834, 1112), m: (0, 0, 390, 844)),
    ),
  );
  tracks.addAll(_both('hero-sky', scroll, [(0, 1), (1, 1.18)], easing: _lin));

  // Three ridges, far to near. Each node is as tall as the viewport and 10%
  // wider; its ridge edge sits at 52 / 64 / 76% of the height.
  const ridges = [
    ('far', 'ridge-far', 0.22, -36.0),
    ('mid', 'ridge-mid', 0.38, -110.0),
    ('near', 'ridge-near', 0.54, -230.0),
  ];
  for (final (name, asset, topFrac, travel) in ridges) {
    final id = 'hero-$name';
    (double, double, double, double) g(Size2 s) =>
        (-0.05 * s.w, topFrac * s.h, 1.1 * s.w, s.h);
    children.add(
      _shape(
        id,
        x: g(_sizes[0]).$1,
        y: g(_sizes[0]).$2,
        w: g(_sizes[0]).$3,
        h: g(_sizes[0]).$4,
        fills: [_image(asset, 0.5, 0.5)],
        overrides: _geo(t: g(_sizes[1]), m: g(_sizes[2])),
      ),
    );
    tracks.add(
      _track(id, 'motion.translateY', scroll, [
        (0, _n(0)),
        (1, _n(travel)),
      ], easing: _lin),
    );
  }

  // The sun's bloom: a soft radial glow over the sky that swells on scroll.
  children.add(
    _shape(
      'hero-bloom',
      x: 480,
      y: -40,
      w: 960,
      h: 960,
      geometry: const ShapeGeometry.ellipse(),
      lc: _centre,
      fills: [
        const Paint.gradient(
          id: 'g',
          kind: GradientKind.radial,
          handles: GradientHandles(
            start: StagePoint(x: 0.5, y: 0.5),
            end: StagePoint(x: 1, y: 0.5),
          ),
          stops: [
            ColorStop(
              position: 0,
              color: StageColor(r: 1, g: 0.85, b: 0.6, a: 0.38),
            ),
            ColorStop(
              position: 1,
              color: StageColor(r: 1, g: 0.85, b: 0.6, a: 0),
            ),
          ],
        ),
      ],
      opacity: 0.0,
      overrides: _geo(t: (0, 100, 760, 760), m: (-60, 130, 510, 510)),
    ),
  );
  tracks
    ..add(
      _track('hero-bloom', 'opacity', scroll, [
        (0, _n(0.0)),
        (0.5, _n(0.9)),
        (1, _n(0.5)),
      ], easing: _lin),
    )
    ..addAll(_both('hero-bloom', scroll, [(0, 0.8), (1, 1.4)], easing: _lin));

  // Title: reveals char by char on entry (timeline), then lifts and fades
  // with scroll.
  children.add(
    FrameNode(
      common: NodeCommon(
        id: 'hero-title-wrap',
        name: 'title',
        x: 120,
        y: 590,
        width: 1200,
        height: 180,
        layoutChild: _centreX,
        breakpointOverrides: _geo(
          t: (48, 690, 738, 220),
          m: (16, 500, 358, 200),
        ),
      ),
      behavior: const Behavior.textReveal(
        clockId: tl,
        unit: TextRevealUnit.char,
        stagger: 0.04,
        range: ClockRange(start: 0.15, end: 1.9),
      ),
      children: [
        _text(
          'hero-title',
          _plain('The Hour Between'),
          w: 1200,
          size: 132,
          weight: 340,
          opsz: 40,
          letterSpacing: -2,
          lineHeight: 100,
          color: '#fff1d6',
          lc: _stretchX,
          overrides: _bp(
            t: {'width': 738, 'style.fontSize': 96},
            m: {'width': 358, 'style.fontSize': 64},
          ),
        ),
      ],
    ),
  );
  children.add(
    _text(
      'hero-sub',
      [
        [_s('a story in five scenes', weight: 500, spacing: 22)],
      ],
      x: 320,
      y: 790,
      w: 800,
      size: 16,
      font: 'sans',
      color: '#ffe4b8',
      overrides: _geo(t: (48, 910, 738, 30), m: (16, 710, 358, 30)),
    ),
  );
  children.add(
    _text(
      'hero-hint',
      [
        [_s('SCROLL', weight: 500, spacing: 30)],
      ],
      x: 520,
      y: 850,
      w: 400,
      size: 12,
      font: 'sans',
      color: '#ffe4b8',
      overrides: _geo(t: (217, 1030, 400, 20), m: (95, 770, 200, 20)),
    ),
  );
  tracks
    ..add(
      _track('hero-title-wrap', 'motion.translateY', scroll, [
        (0, _n(0)),
        (0.5, _n(-110)),
      ], easing: _lin),
    )
    ..add(
      _track('hero-title-wrap', 'opacity', scroll, [
        (0.25, _n(1)),
        (0.55, _n(0)),
      ], easing: _lin),
    )
    ..add(
      _track('hero-sub', 'opacity', scroll, [
        (0.0, _n(1)),
        (0.25, _n(0)),
      ], easing: _lin),
    )
    ..add(
      _track('hero-hint', 'opacity', scroll, [
        (0, _n(0.8)),
        (0.12, _n(0)),
      ], easing: _lin),
    )
    ..add(
      _track('hero-hint', 'motion.translateY', tl, [
        (0, _n(8)),
        (1, _n(0)),
        (2, _n(8)),
      ], easing: _lin),
    );

  return Scene(
    id: 'hero',
    name: 'The Hour Between',
    kind: SceneKind.pinned,
    scrollLength: 2.4,
    root: _root('hero-root', children, color: '#141a3a'),
    clocks: const [
      Clock.sceneScroll(id: scroll, sceneId: 'hero', smoothing: 0.1),
      Clock.timeline(id: tl, name: 'Title reveal', duration: 2.2),
    ],
    tracks: tracks,
  );
}

// ---- Scene 2: lyric ---------------------------------------------------------------

Scene _lyric() {
  const clock = 'song-time';
  final tracks = <Track>[];
  final lyricsFrame = FrameNode(
    common: NodeCommon(
      id: 'lyric-frame',
      name: 'lyrics',
      x: 220,
      y: 170,
      width: 1000,
      height: 500,
      layoutChild: _centre,
      breakpointOverrides: _geo(t: (48, 250, 738, 640), m: (12, 190, 366, 470)),
    ),
    clipContent: true,
    behavior: const Behavior.lyrics(
      audioTrackId: 'song',
      scrollMode: LyricsScrollMode.center,
      // Weight, letter spacing and colour interpolate across each line's
      // start and end; the size comes from the template at every width.
      activeStyle: TextStyleOverride(
        fontWeight: 640,
        letterSpacing: LetterSpacing.percent(0),
        fills: [
          Paint.solid(id: 'ink', color: StageColor(r: 1, g: 0.93, b: 0.8)),
        ],
      ),
      inactiveStyle: TextStyleOverride(
        fontWeight: 320,
        letterSpacing: LetterSpacing.percent(3),
        fills: [
          Paint.solid(
            id: 'ink',
            color: StageColor(r: 1, g: 0.93, b: 0.8, a: 0.3),
          ),
        ],
      ),
    ),
    children: [
      _text(
        'lyric-template',
        _plain('Line'),
        w: 1000,
        size: 58,
        lineHeight: 120,
        lc: _stretchX,
        overrides: _bp(
          t: {'width': 738, 'style.fontSize': 48},
          m: {'width': 366, 'style.fontSize': 30},
        ),
      ).copyWith(
        style: const TextStyleOverride(
          fontFamilyId: 'serif',
          fontVariations: {'opsz': 40},
          fontSize: 58,
          lineHeight: LineHeight.percent(120),
          paragraphSpacing: 22,
        ),
      ),
    ],
  );
  final glow = _shape(
    'lyric-glow',
    x: 270,
    y: -60,
    w: 900,
    h: 900,
    geometry: const ShapeGeometry.ellipse(),
    lc: _centre,
    fills: [
      const Paint.gradient(
        id: 'g',
        kind: GradientKind.radial,
        handles: GradientHandles(
          start: StagePoint(x: 0.5, y: 0.5),
          end: StagePoint(x: 1, y: 0.5),
        ),
        stops: [
          ColorStop(
            position: 0,
            color: StageColor(r: 0.95, g: 0.68, b: 0.42, a: 0.34),
          ),
          ColorStop(
            position: 1,
            color: StageColor(r: 0.95, g: 0.68, b: 0.42, a: 0),
          ),
        ],
      ),
    ],
    overrides: _geo(t: (17, 100, 800, 800), m: (-60, 150, 510, 510)),
  );
  // Breathe: swell on each line's first note.
  tracks.addAll(
    _both('lyric-glow', clock, [
      (0, 0.85),
      (1, 1.05),
      (2.5, 0.98),
      (4, 1.14),
      (5.5, 1.0),
      (7, 1.2),
      (8.5, 1.02),
      (10, 1.26),
      (11.5, 1.04),
      (13, 1.12),
      (16, 0.85),
    ]),
  );
  final caption = _text(
    'lyric-caption',
    [
      [
        _s(
          'LIGHTS GO LOW  ·  an original tone sketch, CC0',
          weight: 500,
          spacing: 18,
        ),
      ],
    ],
    x: 320,
    y: 92,
    w: 800,
    size: 14,
    font: 'sans',
    color: '#b3a8c4',
    overrides: _geo(
      t: (48, 120, 738, 24),
      m: (16, 100, 358, 40),
      tx: {},
      mx: {'style.fontSize': 10},
    ),
  );
  final barBg = _shape(
    'lyric-bar-bg',
    x: 420,
    y: 760,
    w: 600,
    h: 2,
    lc: _centre,
    fills: [_solid('#3a3448')],
    overrides: _geo(t: (117, 960, 600, 2), m: (45, 740, 300, 2)),
  );
  final bar = _shape(
    'lyric-bar',
    x: 420,
    y: 760,
    w: 600,
    h: 2,
    lc: _centre,
    fills: [_solid('#f2b880')],
    motion: const MotionTransform(scaleX: 0, originX: 0),
    overrides: _geo(t: (117, 960, 600, 2), m: (45, 740, 300, 2)),
  );
  tracks.add(
    _track('lyric-bar', 'motion.scaleX', clock, [
      (0, _n(0)),
      (16, _n(1)),
    ], easing: _lin),
  );
  return Scene(
    id: 'lyric',
    name: 'Lights Go Low',
    kind: SceneKind.pinned,
    scrollLength: 2.2,
    root: _root('lyric-root', [
      glow,
      caption,
      lyricsFrame,
      barBg,
      bar,
    ], color: '#0d0b14'),
    clocks: const [Clock.audio(id: clock, audioTrackId: 'song')],
    tracks: tracks,
  );
}

// ---- Scene 3: things (flow, rich text, wrap grid) ----------------------------------

FrameNode _card(
  String id, {
  required String title,
  required String body,
  String? imageAsset,
  List<String>? gradient,
  required String tag,
}) {
  final art = _shape(
    '$id-art',
    w: 400,
    h: 190,
    lc: const LayoutChild(horizontalSizing: Sizing.fill),
    fills: [
      if (imageAsset != null) _image(imageAsset, 0.5, 0.5),
      if (gradient != null)
        Paint.gradient(
          id: 'g',
          stops: [
            ColorStop(position: 0, color: _hex(gradient[0])),
            ColorStop(position: 1, color: _hex(gradient[1])),
          ],
          handles: const GradientHandles(
            start: StagePoint(x: 0.1, y: 0),
            end: StagePoint(x: 0.9, y: 1),
          ),
        ),
    ],
  );
  final text = FrameNode(
    common: NodeCommon(
      id: '$id-text',
      width: 400,
      height: 100,
      layoutChild: const LayoutChild(
        horizontalSizing: Sizing.fill,
        verticalSizing: Sizing.hug,
      ),
    ),
    autoLayout: const AutoLayout(
      direction: LayoutDirection.vertical,
      gap: Gap.fixed(10),
      padding: EdgeInsetsValue(top: 22, right: 24, bottom: 26, left: 24),
    ),
    children: [
      _text(
        '$id-tag',
        [
          [_s(tag, weight: 600, spacing: 16)],
        ],
        w: 340,
        size: 11,
        font: 'sans',
        color: '#a0523f',
        align: TextAlignHorizontal.left,
        lc: const LayoutChild(horizontalSizing: Sizing.fill),
      ),
      _text(
        '$id-title',
        _plain(title),
        w: 340,
        size: 30,
        weight: 420,
        color: '#241a2e',
        align: TextAlignHorizontal.left,
        lc: const LayoutChild(horizontalSizing: Sizing.fill),
      ),
      _text(
        '$id-body',
        _plain(body),
        w: 340,
        size: 16,
        font: 'sans',
        lineHeight: 155,
        color: '#51465c',
        align: TextAlignHorizontal.left,
        lc: const LayoutChild(horizontalSizing: Sizing.fill),
      ),
    ],
  );
  return FrameNode(
    common: NodeCommon(
      id: id,
      name: title,
      width: 400,
      height: 360,
      layoutChild: const LayoutChild(
        horizontalSizing: Sizing.fill,
        verticalSizing: Sizing.hug,
        minWidth: 340,
        maxWidth: 460,
      ),
    ),
    clipContent: true,
    autoLayout: const AutoLayout(direction: LayoutDirection.vertical),
    appearance: Appearance(
      fills: [_solid('#fffaf1')],
      cornerRadius: const CornerRadius.uniform(22),
      effects: [
        const Effect.dropShadow(
          id: 'sh',
          color: StageColor(r: 0.2, g: 0.1, b: 0.2, a: 0.14),
          offset: StagePoint(x: 0, y: 14),
          blur: 32,
        ),
      ],
    ),
    children: [art, text],
  );
}

Scene _things() {
  const clock = 'things-scroll';
  const cards = [
    (
      'c1',
      'Pines',
      'They go first: a hundred black triangles agreeing on a horizon.',
      'card-forest',
      null,
      'I · THE TREES',
    ),
    (
      'c2',
      'Salt',
      'The water keeps the colour a minute longer than the sky does.',
      'card-sea',
      null,
      'II · THE SEA',
    ),
    (
      'c3',
      'Dunes',
      'Every ridge draws a line, and the light stops to read it.',
      'card-dunes',
      null,
      'III · THE SAND',
    ),
    (
      'c4',
      'Windows',
      'Somewhere a kitchen light comes on, and the evening becomes a place.',
      null,
      ['#f6b96b', '#d9654f'],
      'IV · THE TOWN',
    ),
    (
      'c5',
      'Bells',
      'Sound travels better now. You can hear which village it is.',
      null,
      ['#8a6fb0', '#3b2a5c'],
      'V · THE AIR',
    ),
    (
      'c6',
      'Lamps',
      'One by one, small decisions to stay awake.',
      null,
      ['#3f7f8c', '#14274a'],
      'VI · THE HARBOUR',
    ),
  ];
  final tracks = <Track>[];
  final cardNodes = <Node>[];
  for (final (i, (id, title, body, img, grad, tag)) in cards.indexed) {
    cardNodes.add(
      _card(
        id,
        title: title,
        body: body,
        imageAsset: img,
        gradient: grad,
        tag: tag,
      ),
    );
    final a = 0.18 + i * 0.045;
    tracks
      ..add(
        _track(id, 'opacity', clock, [
          (a, _n(0)),
          (a + 0.12, _n(1)),
        ], easing: _easeOut),
      )
      ..add(
        _track(id, 'motion.translateY', clock, [
          (a, _n(48)),
          (a + 0.14, _n(0)),
        ], easing: _easeOut),
      );
  }
  final grid = FrameNode(
    common: const NodeCommon(
      id: 'grid',
      name: 'cards',
      width: 1200,
      height: 700,
      layoutChild: LayoutChild(
        horizontalSizing: Sizing.fill,
        verticalSizing: Sizing.hug,
      ),
    ),
    autoLayout: const AutoLayout(
      direction: LayoutDirection.horizontal,
      wrap: true,
      gap: Gap.fixed(28),
      counterAxisGap: Gap.fixed(28),
    ),
    children: cardNodes,
  );
  final intro = _text(
    'things-intro',
    [
      [
        _s('The hour between is not day and not night. It is '),
        _s(
          'the light that has not noticed yet',
          italic: true,
          color: '#a0523f',
        ),
        _s(
          ' that it is leaving. Nothing in it is quite finished, which is why ',
        ),
        _s('everything in it looks like a decision', weight: 600),
        _s('.'),
      ],
      [
        _s(
          'Here are six small things that happen inside it. The grid below is one '
          'frame with ',
        ),
        _s('wrap', weight: 600, font: 'sans'),
        _s(
          ' on: cards fill the row between a minimum and a maximum width, and the '
          'rows re-flow at every size. ',
        ),
        _s('Nothing is positioned by hand.', color: '#51465c', italic: true),
      ],
    ],
    w: 820,
    size: 24,
    lineHeight: 150,
    color: '#241a2e',
    paragraphSpacing: 20,
    align: TextAlignHorizontal.left,
    lc: const LayoutChild(horizontalSizing: Sizing.fill, maxWidth: 820),
    overrides: _bp(t: {'style.fontSize': 22}, m: {'style.fontSize': 19}),
  );
  final heading = _text(
    'things-heading',
    _plain('What the light leaves behind'),
    w: 1000,
    size: 76,
    weight: 340,
    opsz: 40,
    letterSpacing: -2,
    lineHeight: 104,
    color: '#241a2e',
    align: TextAlignHorizontal.left,
    lc: const LayoutChild(horizontalSizing: Sizing.fill, maxWidth: 1000),
    overrides: _bp(t: {'style.fontSize': 58}, m: {'style.fontSize': 38}),
  );
  final rule = _shape(
    'things-rule',
    w: 120,
    h: 3,
    fills: [_solid('#a0523f')],
    lc: const LayoutChild(),
    motion: const MotionTransform(scaleX: 0.1, originX: 0),
  );
  tracks
    ..add(
      _track('things-rule', 'motion.scaleX', clock, [
        (0.05, _n(0.1)),
        (0.2, _n(1)),
      ], easing: _easeOut),
    )
    ..add(
      _track('things-heading', 'motion.translateY', clock, [
        (0, _n(50)),
        (0.3, _n(-30)),
      ], easing: _lin),
    );
  return Scene(
    id: 'things',
    name: 'What the light leaves behind',
    root: _flowRoot(
      'things-root',
      [heading, rule, intro, grid],
      color: '#f4efe6',
      pad: const EdgeInsetsValue(top: 160, right: 120, bottom: 180, left: 120),
      padTablet: const EdgeInsetsValue(
        top: 120,
        right: 48,
        bottom: 140,
        left: 48,
      ),
      padMobile: const EdgeInsetsValue(
        top: 88,
        right: 20,
        bottom: 100,
        left: 20,
      ),
      gap: 36,
    ),
    clocks: const [Clock.sceneScroll(id: clock, sceneId: 'things')],
    tracks: tracks,
  );
}

// ---- Scene 4: lamp (zoom and focal crop) ------------------------------------------

const _lampFocal = StagePoint(x: 0.70, y: 0.405);

/// Where the focal point of a `fill`-cropped 2400x1200 image lands in a
/// viewport of [s] (the runtime's `imageFillRect`), as a fraction of it.
(double, double) _focalAt(Size2 s) {
  const iw = 2400.0, ih = 1200.0;
  final scale = math.max(s.w / iw, s.h / ih);
  double place(double box, double len, double f) =>
      (box / 2 - f * len).clamp(box - len, 0.0);
  final ox = place(s.w, iw * scale, _lampFocal.x);
  final oy = place(s.h, ih * scale, _lampFocal.y);
  return (
    (ox + _lampFocal.x * iw * scale) / s.w,
    (oy + _lampFocal.y * ih * scale) / s.h,
  );
}

Scene _lamp() {
  const clock = 'lamp-scroll';
  final tracks = <Track>[];
  final (dx, dy) = _focalAt(_sizes[0]);
  final (tx, ty) = _focalAt(_sizes[1]);
  final (mx, my) = _focalAt(_sizes[2]);
  Map<String, Patch> origins() => {
    'tablet': {'motion.originX': _n(tx), 'motion.originY': _n(ty)},
    'mobile': {'motion.originX': _n(mx), 'motion.originY': _n(my)},
  };
  final image = ShapeNode(
    common: NodeCommon(
      id: 'lamp-img',
      name: 'panorama',
      width: 1440,
      height: 900,
      layoutChild: _scaleBoth,
      motion: MotionTransform(originX: dx, originY: dy),
      breakpointOverrides: {
        'tablet': {
          'width': _n(834),
          'height': _n(1112),
          ...origins()['tablet']!,
        },
        'mobile': {
          'width': _n(390),
          'height': _n(844),
          ...origins()['mobile']!,
        },
      },
    ),
    appearance: Appearance(fills: [_image('cove', _lampFocal.x, _lampFocal.y)]),
  );
  tracks.addAll(_both('lamp-img', clock, [(0.08, 1.0), (0.72, 2.6)]));

  // A vignette that closes in with the zoom.
  final vignette = _shape(
    'lamp-vignette',
    w: 1440,
    h: 900,
    opacity: 0,
    fills: [
      const Paint.gradient(
        id: 'g',
        kind: GradientKind.radial,
        handles: GradientHandles(
          start: StagePoint(x: 0.5, y: 0.45),
          end: StagePoint(x: 1.1, y: 0.45),
          width: StagePoint(x: 0.5, y: 1.0),
        ),
        stops: [
          ColorStop(
            position: 0.45,
            color: StageColor(r: 0.04, g: 0.03, b: 0.08, a: 0),
          ),
          ColorStop(
            position: 1,
            color: StageColor(r: 0.04, g: 0.03, b: 0.08, a: 0.85),
          ),
        ],
      ),
    ],
    overrides: _geo(t: (0, 0, 834, 1112), m: (0, 0, 390, 844)),
  );
  tracks.add(
    _track('lamp-vignette', 'opacity', clock, [
      (0.3, _n(0)),
      (0.75, _n(1)),
    ], easing: _lin),
  );

  // The ring finds the lamp (it sits at the focal point at every width).
  const ringSize = 150.0;
  final ring = _shape(
    'lamp-ring',
    x: dx * 1440 - ringSize / 2,
    y: dy * 900 - ringSize / 2,
    w: ringSize,
    h: ringSize,
    geometry: const ShapeGeometry.ellipse(),
    lc: _abs(HorizontalConstraint.left, VerticalConstraint.top),
    opacity: 0,
    strokes: [_solid('#ffe9b0', id: 's')],
    strokeWeight: const StrokeWeight.uniform(1.5),
    overrides: _geo(
      t: (
        tx * 834 - ringSize / 2,
        ty * 1112 - ringSize / 2,
        ringSize,
        ringSize,
      ),
      m: (mx * 390 - 60, my * 844 - 60, 120, 120),
    ),
  );
  tracks
    ..add(
      _track('lamp-ring', 'opacity', clock, [
        (0.66, _n(0)),
        (0.82, _n(0.9)),
      ], easing: _lin),
    )
    ..addAll(
      _both('lamp-ring', clock, [
        (0.66, 1.8),
        (0.86, 1.0),
      ], easing: _easeOutBack),
    );

  final kicker = _text(
    'lamp-kicker',
    [
      [_s('IV  ·  THE LAMP', weight: 500, spacing: 24)],
    ],
    x: 120,
    y: 72,
    w: 600,
    size: 13,
    font: 'sans',
    color: '#ffe4b8',
    align: TextAlignHorizontal.left,
    overrides: _geo(t: (48, 72, 600, 20), m: (24, 64, 300, 20)),
  );
  final cap1 = _text(
    'lamp-cap1',
    _plain('Out past the last ridge,\none light stays on.'),
    x: 96,
    y: 700,
    w: 640,
    size: 48,
    weight: 360,
    opsz: 40,
    lineHeight: 112,
    color: '#fff1d6',
    align: TextAlignHorizontal.left,
    overrides: _bp(
      t: {'x': 48, 'y': 880, 'width': 738, 'style.fontSize': 44},
      m: {'x': 24, 'y': 700, 'width': 342, 'style.fontSize': 32},
    ),
  );
  final cap2 = _text(
    'lamp-cap2',
    _plain('Zoom in far enough and it is a room,\nwith a person in it, awake.'),
    x: 96,
    y: 730,
    w: 760,
    size: 28,
    weight: 360,
    lineHeight: 130,
    color: '#fff1d6',
    align: TextAlignHorizontal.left,
    opacity: 0,
    overrides: _bp(
      t: {'x': 48, 'y': 920, 'width': 738, 'style.fontSize': 26},
      m: {'x': 24, 'y': 720, 'width': 342, 'style.fontSize': 20},
    ),
  );
  tracks
    ..add(
      _track('lamp-cap1', 'opacity', clock, [
        (0.0, _n(1)),
        (0.12, _n(1)),
        (0.3, _n(0)),
      ], easing: _lin),
    )
    ..add(
      _track('lamp-cap1', 'motion.translateY', clock, [
        (0.12, _n(0)),
        (0.3, _n(-30)),
      ], easing: _lin),
    )
    ..add(
      _track('lamp-cap2', 'opacity', clock, [
        (0.7, _n(0)),
        (0.88, _n(1)),
      ], easing: _lin),
    )
    ..add(
      _track('lamp-cap2', 'motion.translateY', clock, [
        (0.7, _n(24)),
        (0.88, _n(0)),
      ], easing: _easeOut),
    );

  return Scene(
    id: 'lamp',
    name: 'The lamp',
    kind: SceneKind.pinned,
    scrollLength: 2.6,
    root: _root('lamp-root', [
      image,
      vignette,
      ring,
      kicker,
      cap1,
      cap2,
    ], color: '#0b1226'),
    clocks: const [
      Clock.sceneScroll(id: clock, sceneId: 'lamp', smoothing: 0.1),
    ],
    tracks: tracks,
  );
}

// ---- Scene 5: fin -----------------------------------------------------------------

Scene _fin() {
  const clock = 'fin-scroll';
  final tracks = <Track>[];
  final kicker = _text(
    'fin-kicker',
    [
      [_s('FIN', weight: 600, spacing: 40)],
    ],
    w: 400,
    size: 13,
    font: 'sans',
    color: '#f2b880',
    lc: const LayoutChild(horizontalSizing: Sizing.fill),
  );
  final heading = _text(
    'fin-heading',
    [
      [
        _s('Lights go ', weight: 340),
        _s('low', weight: 700, italic: true, color: '#f2b880'),
        _s('.', weight: 340),
      ],
    ],
    w: 1100,
    size: 140,
    opsz: 40,
    letterSpacing: -2,
    lineHeight: 100,
    color: '#fff1d6',
    lc: const LayoutChild(horizontalSizing: Sizing.fill, maxWidth: 1100),
    overrides: _bp(t: {'style.fontSize': 96}, m: {'style.fontSize': 56}),
  );
  final rule = _shape(
    'fin-rule',
    w: 160,
    h: 2,
    fills: [_solid('#f2b880')],
    lc: const LayoutChild(),
    motion: const MotionTransform(scaleX: 0.1),
  );
  final body = _text(
    'fin-body',
    [
      [
        _s(
          'That was a spike: five scenes, one clip, two fonts and a handful of '
          'procedural images, all described as data and played by the runtime. '
          'If it felt like a page, ',
        ),
        _s('that is the thing to fix.', weight: 600, color: '#f2b880'),
      ],
    ],
    w: 620,
    size: 21,
    font: 'sans',
    lineHeight: 160,
    color: '#cfc6dc',
    lc: const LayoutChild(horizontalSizing: Sizing.fill, maxWidth: 620),
    overrides: _bp(m: {'style.fontSize': 17}),
  );
  final credit = _text(
    'fin-credit',
    [
      [
        _s(
          'Fraunces and Space Grotesk, SIL OFL  ·  audio and lyrics, CC0  ·  '
          'images generated by tool/gen_spike_images.dart',
        ),
      ],
    ],
    w: 900,
    size: 12,
    font: 'sans',
    letterSpacing: 4,
    color: '#7d7390',
    lc: const LayoutChild(horizontalSizing: Sizing.fill, maxWidth: 900),
  );
  tracks
    ..add(
      _track('fin-heading', 'opacity', clock, [
        (0.15, _n(0)),
        (0.4, _n(1)),
      ], easing: _easeOut),
    )
    ..add(
      _track('fin-heading', 'motion.translateY', clock, [
        (0.15, _n(50)),
        (0.4, _n(0)),
      ], easing: _easeOut),
    )
    ..add(
      _track('fin-rule', 'motion.scaleX', clock, [
        (0.3, _n(0.1)),
        (0.55, _n(1)),
      ], easing: _easeOut),
    )
    ..add(
      _track('fin-body', 'opacity', clock, [
        (0.4, _n(0)),
        (0.6, _n(1)),
      ], easing: _lin),
    );
  return Scene(
    id: 'fin',
    name: 'Fin',
    root: _flowRoot(
      'fin-root',
      [kicker, heading, rule, body, credit],
      color: '#14111c',
      pad: const EdgeInsetsValue(top: 220, right: 120, bottom: 200, left: 120),
      padTablet: const EdgeInsetsValue(
        top: 160,
        right: 48,
        bottom: 160,
        left: 48,
      ),
      padMobile: const EdgeInsetsValue(
        top: 120,
        right: 20,
        bottom: 120,
        left: 20,
      ),
      gap: 34,
      align: CounterAlign.center,
    ),
    clocks: const [Clock.sceneScroll(id: clock, sceneId: 'fin')],
    tracks: tracks,
  );
}

// ---- Document ---------------------------------------------------------------------

Asset _img(String id, String file, int w, int h, String name, String alt) =>
    Asset(
      id: id,
      kind: AssetKind.image,
      uri: 'asset://assets/demo/images/$file',
      name: name,
      mime: 'image/png',
      width: w,
      height: h,
      alt: alt,
      credit: 'Procedural (tool/gen_spike_images.dart / gen_demo_images.dart)',
    );

void main() {
  final lrc = File('assets/demo/audio/lights_go_low.lrc').readAsStringSync();
  final parsed = parseLrc(lrc);
  if (parsed.diagnostics.isNotEmpty) {
    stderr.writeln(parsed.diagnostics.join('\n'));
    exit(1);
  }
  final doc = StageDocument(
    id: 'demo-spike',
    breakpoints: const [_desktop, _tablet, _mobile],
    baseBreakpointId: 'desktop',
    meta: const StageMeta(
      title: 'The Hour Between',
      slug: 'spike',
      author: 'Soundstage',
      description: 'A short story in five scenes. Sound on.',
      coverAssetId: 'sky',
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
    assets: {
      'font-fraunces': const Asset(
        id: 'font-fraunces',
        kind: AssetKind.font,
        uri: 'asset://assets/demo/fonts/Fraunces-Variable.ttf',
        name: 'Fraunces (OFL)',
      ),
      'font-grotesk': const Asset(
        id: 'font-grotesk',
        kind: AssetKind.font,
        uri: 'asset://assets/demo/fonts/SpaceGrotesk-Variable.ttf',
        name: 'Space Grotesk (OFL)',
      ),
      'clip': const Asset(
        id: 'clip',
        kind: AssetKind.audio,
        uri: 'asset://assets/demo/audio/lights_go_low.wav',
        mime: 'audio/wav',
        name: 'Lights Go Low (CC0)',
        duration: 16,
      ),
      'sky': _img(
        'sky',
        'spike_sky.png',
        1600,
        1000,
        'Dusk sky',
        'A dusk sky with a low sun',
      ),
      'ridge-far': _img(
        'ridge-far',
        'spike_ridge_far.png',
        1600,
        700,
        'Far ridge',
        'A hazy ridge',
      ),
      'ridge-mid': _img(
        'ridge-mid',
        'spike_ridge_mid.png',
        1600,
        700,
        'Middle ridge',
        'A ridge',
      ),
      'ridge-near': _img(
        'ridge-near',
        'spike_ridge_near.png',
        1600,
        700,
        'Near ridge',
        'A dark ridge',
      ),
      'cove': _img(
        'cove',
        'spike_cove.png',
        2400,
        1200,
        'The cove',
        'A lighthouse on an island at dusk',
      ),
      'card-forest': _img(
        'card-forest',
        'card_forest.png',
        800,
        500,
        'Pines',
        'Pine forest',
      ),
      'card-sea': _img('card-sea', 'card_sea.png', 800, 500, 'Sea', 'Open sea'),
      'card-dunes': _img(
        'card-dunes',
        'card_dunes.png',
        800,
        500,
        'Dunes',
        'Desert dunes',
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
    scenes: [_hero(), _lyric(), _things(), _lamp(), _fin()],
  );
  final json = const JsonEncoder.withIndent('  ').convert(doc.toJson());
  File('assets/demo/spike.stage.json').writeAsStringSync('$json\n');
  stdout.writeln('wrote assets/demo/spike.stage.json');
}
