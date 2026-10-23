// Generates assets/demo/motion.stage.json, the T0.6 motion demo.
//
//   dart run tool/gen_motion_demo.dart
//
// Built from IR models so the file always matches the schema. Scenes:
//   hero      pinned, scrollLength 2: 5 parallax layers, a title that fades
//             and rises (easing presets), a sun that scales and blurs in, a
//             background colour shift; the scene clock is smoothed.
//   interlude flow scene between pinned ones.
//   pulse     pinned: a pingPong timeline that plays on scene enter, and a
//             pointer-parallax card stack (two smoothed pointer clocks).
//   tiles     pinned, scrollLength 2: 56 tiles with staggered keyframes
//             (the perf-trace scene); smoothed scroll clock.
//   coda      flow scene.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:soundstage_platform/ir/ir.dart';

const _desktop = Breakpoint(
  id: 'desktop',
  name: 'Desktop',
  minWidth: 768,
  designSize: StageSize(width: 1440, height: 900),
  primary: true,
);
const _mobile = Breakpoint(
  id: 'mobile',
  name: 'Mobile',
  minWidth: 0,
  designSize: StageSize(width: 390, height: 844),
  primary: true,
);

StageColor _hex(String h) => StageColor.fromHex(h);

IrValue _n(double v) => IrValue.number(v);
IrValue _c(String h) => IrValue.color(_hex(h));

Keyframe _k(
  String id,
  double t,
  IrValue v, [
  Easing e = const Easing.linear(),
]) => Keyframe(id: id, t: t, value: v, easing: e);

int _trackSeq = 0;
Track _track(
  String target,
  String property,
  String clockId,
  List<(double, IrValue, Easing)> kfs,
) {
  final id = 'tr${_trackSeq++}';
  return Track(
    id: id,
    target: target,
    property: property,
    clockId: clockId,
    keyframes: [
      for (var i = 0; i < kfs.length; i++)
        _k('$id-k$i', kfs[i].$1, kfs[i].$2, kfs[i].$3),
    ],
  );
}

const _lin = Easing.linear();
const _easeOut = Easing.preset(EasingPreset.easeOut);
const _easeIn = Easing.preset(EasingPreset.easeIn);
const _easeInOut = Easing.preset(EasingPreset.easeInOut);
const _easeOutBack = Easing.preset(EasingPreset.easeOutBack);

LayoutChild _lc(HorizontalConstraint h, VerticalConstraint v) => LayoutChild(
  positioning: Positioning.absolute,
  constraints: Constraints(horizontal: h, vertical: v),
);

final _scaleBoth = _lc(HorizontalConstraint.scale, VerticalConstraint.scale);
final _centerBoth = _lc(HorizontalConstraint.center, VerticalConstraint.center);

/// Geometry at desktop, with a mobile patch (x, y, width, height).
Map<String, Patch> _mobileGeo(double x, double y, double w, double h) => {
  'mobile': {'x': _n(x), 'y': _n(y), 'width': _n(w), 'height': _n(h)},
};

ShapeNode _shape(
  String id, {
  required double x,
  required double y,
  required double w,
  required double h,
  required String color,
  ShapeGeometry geometry = const ShapeGeometry.rectangle(),
  LayoutChild? lc,
  double radius = 0,
  List<Effect> effects = const [],
  Map<String, Patch> overrides = const {},
  double opacity = 1,
}) => ShapeNode(
  common: NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    height: h,
    opacity: opacity,
    layoutChild: lc ?? _scaleBoth,
    breakpointOverrides: overrides,
  ),
  geometry: geometry,
  appearance: Appearance(
    fills: [Paint.solid(id: 'fill', color: _hex(color))],
    cornerRadius: CornerRadius.uniform(radius),
    effects: effects,
  ),
);

TextNode _text(
  String id,
  String text, {
  required double x,
  required double y,
  required double w,
  required double size,
  String font = 'serif',
  int weight = 400,
  String color = '#ffffff',
  TextAlignHorizontal align = TextAlignHorizontal.center,
  Map<String, Patch> overrides = const {},
  LayoutChild? lc,
  double opacity = 1,
}) => TextNode(
  common: NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    opacity: opacity,
    layoutChild: lc ?? _centerBoth,
    breakpointOverrides: overrides,
  ),
  autoResize: TextAutoResize.height,
  alignHorizontal: align,
  style: TextStyleOverride(
    fontFamilyId: font,
    fontSize: size,
    fontWeight: weight,
    lineHeight: const LineHeight.percent(115),
    fills: [Paint.solid(id: 'ink', color: _hex(color))],
  ),
  content: [
    for (final p in text.split('\n')) Paragraph(spans: [Span(text: p)]),
  ],
);

FrameNode _root(String id, List<Node> children, {String color = '#000000'}) =>
    FrameNode(
      common: const NodeCommon(id: '', width: 1440, height: 900).copyWith(
        id: id,
        name: 'Stage',
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

// ---- Scenes ------------------------------------------------------------------

Scene _hero() {
  const clock = 'hero-scroll';
  final tracks = <Track>[];
  // Five mountain/ground layers, back to front; nearer layers move faster.
  const layers = [
    // (name, colour, top, sink distance over the scene)
    ('far', '#3b2a5c', 560.0, 60.0),
    ('ridge', '#4b2e63', 630.0, 140.0),
    ('hills', '#6a3566', 700.0, 240.0),
    ('near', '#8c3b5e', 770.0, 360.0),
    ('ground', '#1d1230', 840.0, 500.0),
  ];
  final children = <Node>[
    // A photo layer behind everything, slowest of all.
    ShapeNode(
      common: NodeCommon(
        id: 'hero-photo',
        name: 'photo',
        x: 0,
        y: -140,
        width: 1440,
        height: 1140,
        opacity: 0.45,
        layoutChild: _scaleBoth,
        breakpointOverrides: _mobileGeo(-200, 0, 790, 940),
      ),
      appearance: const Appearance(
        fills: [
          Paint.image(
            id: 'img',
            assetId: 'hero',
            focalPoint: StagePoint(x: 0.68, y: 0.42),
          ),
        ],
      ),
    ),
    _shape(
      'hero-sun',
      // Over the photo's own sun; centred so it stays round at any aspect.
      x: 890,
      y: 350,
      w: 180,
      h: 180,
      color: '#ffd58a',
      geometry: const ShapeGeometry.ellipse(),
      effects: const [Effect.layerBlur(id: 'blur', radius: 24)],
      lc: _centerBoth,
      overrides: _mobileGeo(215, 330, 110, 110),
    ),
  ];
  tracks
    ..add(
      _track('hero-photo', 'motion.translateY', clock, [
        (0, _n(0), _lin),
        (1, _n(80), _lin),
      ]),
    )
    ..add(
      _track('hero-sun', 'motion.scaleX', clock, [
        (0, _n(0.6), _easeOutBack),
        (0.35, _n(1), _lin),
      ]),
    )
    ..add(
      _track('hero-sun', 'motion.scaleY', clock, [
        (0, _n(0.6), _easeOutBack),
        (0.35, _n(1), _lin),
      ]),
    )
    ..add(
      _track('hero-sun', 'effects.blur.radius', clock, [
        (0, _n(24), _easeOut),
        (0.35, _n(0), _lin),
      ]),
    )
    ..add(
      _track('hero-sun', 'motion.translateY', clock, [
        (0, _n(0), _easeInOut),
        (1, _n(-230), _lin),
      ]),
    );
  for (final (name, color, top, travel) in layers) {
    final id = 'hero-$name';
    children.add(
      _shape(
        id,
        x: name == 'ground' ? -40 : -360 + (top % 3) * 60,
        y: top,
        w: name == 'ground' ? 1520 : 2160,
        h: 900,
        color: color,
        geometry: name == 'ground'
            ? const ShapeGeometry.rectangle()
            : const ShapeGeometry.ellipse(),
        lc: _lc(HorizontalConstraint.scale, VerticalConstraint.scale),
      ),
    );
    tracks.add(
      _track(id, 'motion.translateY', clock, [
        (0, _n(0), _lin),
        (1, _n(travel), _lin),
      ]),
    );
  }
  children.addAll([
    _text(
      'hero-title',
      'Soundstage, in motion',
      x: 220,
      y: 330,
      w: 1000,
      size: 92,
      overrides: {
        'mobile': {
          'x': _n(20),
          'y': _n(300),
          'width': _n(350),
          'style.fontSize': _n(44),
        },
      },
    ),
    _text(
      'hero-sub',
      'Scroll to play the scene. Every layer is a track on the scroll clock.',
      x: 370,
      y: 600,
      w: 700,
      size: 22,
      font: 'sans',
      color: '#f3dfe9',
      overrides: {
        'mobile': {
          'x': _n(30),
          'y': _n(560),
          'width': _n(330),
          'style.fontSize': _n(17),
        },
      },
    ),
  ]);
  tracks
    ..add(
      _track('hero-title', 'opacity', clock, [
        (0.02, _n(0), _easeOut),
        (0.25, _n(1), _lin),
        (0.8, _n(1), _easeIn),
        (0.98, _n(0), _lin),
      ]),
    )
    ..add(
      _track('hero-title', 'motion.translateY', clock, [
        (0.02, _n(80), _easeOut),
        (0.25, _n(0), _lin),
        (0.8, _n(0), _easeIn),
        (0.98, _n(-120), _lin),
      ]),
    )
    ..add(
      _track('hero-sub', 'opacity', clock, [
        // Visible from the top (it tells the reader to scroll).
        (0, _n(1), _lin),
        (0.55, _n(1), _easeIn),
        (0.75, _n(0), _lin),
      ]),
    )
    ..add(
      _track('hero-sub', 'motion.translateY', clock, [
        (0.5, _n(0), const Easing.spring(stiffness: 120, damping: 10)),
        (0.75, _n(-60), _lin),
      ]),
    )
    ..add(
      _track('hero-root', 'fills.bg.color', clock, [
        (0, _c('#0b1026'), _easeInOut),
        (0.5, _c('#3a1c4a'), _easeInOut),
        (1, _c('#f2a65a'), _lin),
      ]),
    );
  return Scene(
    id: 'hero',
    name: 'Hero',
    kind: SceneKind.pinned,
    scrollLength: 2,
    root: _root('hero-root', children, color: '#0b1026'),
    clocks: const [
      Clock.sceneScroll(id: clock, sceneId: 'hero', smoothing: 0.12),
    ],
    tracks: tracks,
  );
}

Scene _flow(String id, String heading, String body, {String bg = '#f6f1ea'}) {
  final clock = '$id-scroll';
  final root = FrameNode(
    common: NodeCommon(
      id: '$id-root',
      name: 'Stage',
      width: 1440,
      height: 600,
      layoutChild: const LayoutChild(verticalSizing: Sizing.hug),
    ),
    autoLayout: const AutoLayout(
      direction: LayoutDirection.vertical,
      gap: Gap.fixed(28),
      padding: EdgeInsetsValue(top: 160, right: 120, bottom: 160, left: 120),
      counterAlign: CounterAlign.center,
    ),
    appearance: Appearance(
      fills: [Paint.solid(id: 'bg', color: _hex(bg))],
    ),
    children: [
      _text(
        '$id-heading',
        heading,
        x: 0,
        y: 0,
        w: 900,
        size: 54,
        color: '#1d1230',
        lc: const LayoutChild(horizontalSizing: Sizing.fill, maxWidth: 900),
      ),
      _shape(
        '$id-rule',
        x: 0,
        y: 0,
        w: 160,
        h: 4,
        color: '#8c3b5e',
        lc: const LayoutChild(),
      ),
      _text(
        '$id-body',
        body,
        x: 0,
        y: 0,
        w: 720,
        size: 20,
        font: 'sans',
        color: '#3b2a3c',
        align: TextAlignHorizontal.left,
        lc: const LayoutChild(horizontalSizing: Sizing.fill, maxWidth: 720),
      ),
    ],
  );
  return Scene(
    id: id,
    name: heading,
    root: root,
    clocks: [Clock.sceneScroll(id: clock, sceneId: id)],
    tracks: [
      _track('$id-rule', 'motion.scaleX', clock, [
        (0.15, _n(0.1), _easeOut),
        (0.45, _n(1), _lin),
      ]),
      _track('$id-heading', 'motion.translateY', clock, [
        (0, _n(60), _lin),
        (1, _n(-60), _lin),
      ]),
    ],
  );
}

Scene _pulse() {
  const tl = 'pulse-tl';
  const px = 'pulse-px';
  const py = 'pulse-py';
  final children = <Node>[];
  final tracks = <Track>[];
  // Pointer-parallax cards: deeper cards move less.
  const cards = [
    ('card-back', '#2b3a67', 0.4),
    ('card-mid', '#496a9c', 0.7),
    ('card-front', '#9cc3e6', 1.0),
  ];
  for (var i = 0; i < cards.length; i++) {
    final (name, color, depth) = cards[i];
    final id = 'pulse-$name';
    children.add(
      _shape(
        id,
        x: 160 + i * 70,
        y: 220 + i * 60,
        w: 480,
        h: 320,
        color: color,
        radius: 28,
        lc: _centerBoth,
        overrides: _mobileGeo(30 + i * 20, 160 + i * 40, 300, 200),
      ),
    );
    tracks
      ..add(
        _track(id, 'motion.translateX', px, [
          (-1, _n(-50 * depth), _lin),
          (1, _n(50 * depth), _lin),
        ]),
      )
      ..add(
        _track(id, 'motion.translateY', py, [
          (-1, _n(-36 * depth), _lin),
          (1, _n(36 * depth), _lin),
        ]),
      );
  }
  // Timeline: orbiting dots that breathe and shift colour (pingPong).
  for (var i = 0; i < 6; i++) {
    final id = 'pulse-dot$i';
    final a = i * math.pi / 3;
    children.add(
      _shape(
        id,
        x: 1040 + 150 * math.cos(a) - 30,
        y: 450 + 150 * math.sin(a) - 30,
        w: 60,
        h: 60,
        color: '#f2a65a',
        geometry: const ShapeGeometry.ellipse(),
        lc: _centerBoth,
        overrides: _mobileGeo(
          195 + 80 * math.cos(a) - 20,
          640 + 80 * math.sin(a) - 20,
          40,
          40,
        ),
      ),
    );
    final d = 0.2 * i;
    tracks
      ..add(
        _track(id, 'motion.scaleX', tl, [
          (d, _n(0.5), _easeInOut),
          (d + 1, _n(1.4), _lin),
        ]),
      )
      ..add(
        _track(id, 'motion.scaleY', tl, [
          (d, _n(0.5), _easeInOut),
          (d + 1, _n(1.4), _lin),
        ]),
      )
      ..add(
        _track(id, 'fills.fill.color', tl, [
          (0, _c('#f2a65a'), _easeInOut),
          (2.4, _c('#e0457b'), _lin),
        ]),
      );
  }
  children.add(
    _text(
      'pulse-caption',
      'A timeline clock (pingPong, plays on scene enter) and two pointer clocks. '
          'Move the mouse over the stage.',
      x: 160,
      y: 110,
      w: 620,
      size: 20,
      font: 'sans',
      color: '#dbe7f5',
      align: TextAlignHorizontal.left,
      overrides: {
        'mobile': {'x': _n(30), 'y': _n(60), 'width': _n(330)},
      },
    ),
  );
  tracks.add(
    _track('pulse-orbit', 'motion.rotate', tl, [
      (0, _n(-20), _easeInOut),
      (2.4, _n(20), _lin),
    ]),
  );
  // Wrap the dots in a frame so the timeline can turn them as a group.
  final dots = children
      .whereType<ShapeNode>()
      .where((n) => n.common.id.startsWith('pulse-dot'))
      .toList();
  final others = children
      .where((n) => !n.common.id.startsWith('pulse-dot'))
      .toList();
  final orbit = FrameNode(
    common: NodeCommon(
      id: 'pulse-orbit',
      name: 'orbit',
      width: 1440,
      height: 900,
      layoutChild: _lc(
        HorizontalConstraint.leftRight,
        VerticalConstraint.topBottom,
      ),
      motion: const MotionTransform(originX: 1040 / 1440, originY: 0.5),
      breakpointOverrides: {
        'mobile': {
          'width': _n(390),
          'height': _n(844),
          'motion.originX': _n(0.5),
          'motion.originY': _n(640 / 844),
        },
      },
    ),
    children: dots,
  );
  return Scene(
    id: 'pulse',
    name: 'Pulse',
    kind: SceneKind.pinned,
    scrollLength: 1,
    root: _root('pulse-root', [...others, orbit], color: '#101a33'),
    clocks: const [
      Clock.sceneScroll(id: 'pulse-scroll', sceneId: 'pulse'),
      Clock.timeline(
        id: tl,
        name: 'Pulse',
        duration: 2.4,
        loop: TimelineLoop.pingPong,
      ),
      Clock.pointer(id: px, frameId: 'pulse-root', smoothing: 0.25),
      Clock.pointer(
        id: py,
        frameId: 'pulse-root',
        axis: PointerAxis.y,
        smoothing: 0.25,
      ),
    ],
    tracks: tracks,
  );
}

Scene _tiles() {
  const clock = 'tiles-scroll';
  const cols = 8, rows = 7; // 56 tiles
  const tile = 120.0, gap = 24.0;
  const gridW = cols * tile + (cols - 1) * gap;
  const gridH = rows * tile + (rows - 1) * gap;
  final palette = ['#e0457b', '#f2a65a', '#9cc3e6', '#496a9c', '#8c3b5e'];
  final tiles = <Node>[];
  final tracks = <Track>[];
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final i = r * cols + c;
      final id = 'tile$i';
      tiles.add(
        _shape(
          id,
          x: c * (tile + gap),
          y: r * (tile + gap),
          w: tile,
          h: tile,
          color: palette[i % palette.length],
          radius: 18,
          lc: const LayoutChild(),
        ),
      );
      // Staggered by diagonal distance from the top-left corner.
      final s = (r + c) / (rows + cols - 2) * 0.45;
      tracks
        ..add(
          _track(id, 'motion.translateY', clock, [
            (s, _n(260), _easeOut),
            (s + 0.3, _n(0), _easeIn),
            (s + 0.55, _n(-220), _lin),
          ]),
        )
        ..add(
          _track(id, 'motion.rotate', clock, [
            (s, _n(-45), _easeOutBack),
            (s + 0.3, _n(0), _easeIn),
            (s + 0.55, _n(30), _lin),
          ]),
        )
        ..add(
          _track(id, 'opacity', clock, [
            (s, _n(0), _easeOut),
            (s + 0.2, _n(1), _lin),
            (s + 0.45, _n(1), _easeIn),
            (s + 0.55, _n(0), _lin),
          ]),
        )
        ..add(
          _track(id, 'motion.scaleX', clock, [
            (s, _n(0.4), _easeOutBack),
            (s + 0.3, _n(1), _lin),
          ]),
        )
        ..add(
          _track(id, 'motion.scaleY', clock, [
            (s, _n(0.4), _easeOutBack),
            (s + 0.3, _n(1), _lin),
          ]),
        )
        ..add(
          _track(id, 'fills.fill.color', clock, [
            (s, _c(palette[i % palette.length]), _easeInOut),
            (s + 0.5, _c(palette[(i + 2) % palette.length]), _lin),
          ]),
        );
    }
  }
  final grid = FrameNode(
    common: NodeCommon(
      id: 'tiles-grid',
      name: 'grid',
      x: (1440 - gridW) / 2,
      y: (900 - gridH) / 2,
      width: gridW,
      height: gridH,
      layoutChild: _lc(HorizontalConstraint.center, VerticalConstraint.center),
      motion: const MotionTransform(scaleX: 0.74, scaleY: 0.74),
      breakpointOverrides: {
        'mobile': {
          'x': _n((390 - gridW) / 2),
          'y': _n((844 - gridH) / 2),
          'motion.scaleX': _n(0.32),
          'motion.scaleY': _n(0.32),
        },
      },
    ),
    children: tiles,
  );
  return Scene(
    id: 'tiles',
    name: 'Tiles',
    kind: SceneKind.pinned,
    scrollLength: 2,
    root: _root('tiles-root', [grid], color: '#14101f'),
    clocks: const [
      Clock.sceneScroll(id: clock, sceneId: 'tiles', smoothing: 0.08),
    ],
    tracks: tracks,
  );
}

StageDocument buildMotionDemo() => StageDocument(
  id: 'demo-motion',
  breakpoints: const [_desktop, _mobile],
  meta: const StageMeta(
    title: 'Motion demo (T0.6)',
    slug: 'motion-demo',
    author: 'Soundstage',
    description: 'Scroll, timeline and pointer clocks driving compiled tracks.',
  ),
  fonts: const {
    'serif': FontFamily(
      id: 'serif',
      name: 'Fraunces',
      fallback: FontFallback.serif,
    ),
    'sans': FontFamily(id: 'sans', name: 'Inter'),
  },
  assets: {
    'hero': Asset(
      id: 'hero',
      kind: AssetKind.image,
      uri: 'asset://assets/demo/images/hero_dusk.png',
      name: 'Dusk over mountains',
      mime: 'image/png',
      width: 1600,
      height: 1000,
      placeholder: AssetPlaceholder(dominantColor: _hex('#5e3a55')),
      alt: 'Dusk over mountains',
      credit: 'Procedural (tool/gen_demo_images.dart)',
    ),
  },
  scenes: [
    _hero(),
    _flow(
      'interlude',
      'Between the pinned scenes',
      'This is a flow scene: it scrolls like a page section, and its own '
          'scroll clock runs from 0 when its top enters the viewport to 1 '
          'when its bottom leaves. The rule above grows with it.\n'
          'Pinned scenes hold the stage still while their clock runs from 0 '
          'to 1 over their scroll length.',
    ),
    _pulse(),
    _flow(
      'bridge',
      'Fifty-six tiles',
      'The next scene animates 56 tiles with six tracks each (336 tracks) on '
          'a smoothed scroll clock. It is the performance-trace scene.',
      bg: '#efe6f4',
    ),
    _tiles(),
    _flow(
      'coda',
      'Coda',
      'Clocks are sources; tracks are compiled; render objects take the '
          'values directly. Scrolling rebuilds no widgets.',
    ),
  ],
);

void main() {
  final doc = buildMotionDemo();
  final issues = validateDocument(doc);
  for (final d in issues) {
    stderr.writeln('validate: $d');
  }
  final out = File('assets/demo/motion.stage.json');
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(doc.toJson())}\n',
  );
  final tracks = doc.scenes.fold<int>(0, (n, s) => n + s.tracks.length);
  stdout.writeln(
    'wrote ${out.path}: ${doc.scenes.length} scenes, $tracks tracks',
  );
}
