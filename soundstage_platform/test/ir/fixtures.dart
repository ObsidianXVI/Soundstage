// Shared IR fixtures: fully-populated samples of every model and union
// variant, plus a large composite document.
import 'package:soundstage_platform/ir/ir.dart';

const red = StageColor(r: 1, g: 0.1, b: 0.2, a: 0.9);
const blue = StageColor(r: 0.05, g: 0.3, b: 0.95);

const solid = Paint.solid(
  id: 'pSolid',
  color: red,
  visible: false,
  opacity: 0.5,
  blendMode: BlendMode.multiply,
);

const gradient = Paint.gradient(
  id: 'pGrad',
  kind: GradientKind.angular,
  stops: [
    ColorStop(position: 0, color: red),
    ColorStop(position: 0.75, color: blue),
  ],
  handles: GradientHandles(
    start: StagePoint(x: 0.1, y: 0.2),
    end: StagePoint(x: 0.9, y: 0.8),
    width: StagePoint(x: 0.3, y: 0.4),
  ),
  opacity: 0.8,
  blendMode: BlendMode.screen,
);

const image = Paint.image(
  id: 'pImg',
  assetId: 'aHero',
  scaleMode: ImageScaleMode.crop,
  focalPoint: StagePoint(x: 0.3, y: 0.7),
  cropRect: StageRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6),
  tileScale: 2,
  rotation: 90,
  filters: ImageFilters(
    exposure: 0.1,
    contrast: -0.2,
    saturation: 0.3,
    temperature: -0.4,
    tint: 0.5,
    highlights: -0.6,
    shadows: 0.7,
  ),
  blendMode: BlendMode.overlay,
);

const dropShadow = Effect.dropShadow(
  id: 'eDrop',
  color: blue,
  offset: StagePoint(x: 2, y: 8),
  blur: 16,
  spread: -2,
  blendMode: BlendMode.multiply,
  showBehindTransparentAreas: true,
);
const innerShadow = Effect.innerShadow(
  id: 'eInner',
  color: red,
  offset: StagePoint(x: -1, y: 1),
  blur: 3,
  spread: 1,
  visible: false,
);
const layerBlur = Effect.layerBlur(id: 'eBlur', radius: 12);
const backgroundBlur = Effect.backgroundBlur(id: 'eBg', radius: 30);

const stroke = Stroke(
  paints: [solid, gradient],
  weight: StrokeWeight.perSide(top: 1, right: 2, bottom: 3, left: 4),
  align: StrokeAlign.outside,
  cap: StrokeCap.round,
  join: StrokeJoin.bevel,
  miterLimit: 10,
  dash: [4, 2.5],
);

const appearance = Appearance(
  fills: [solid, gradient, image],
  strokes: stroke,
  effects: [dropShadow, innerShadow, layerBlur, backgroundBlur],
  cornerRadius: CornerRadius.perCorner(tl: 1, tr: 2, br: 3, bl: 4),
  cornerSmoothing: 0.6,
  fillStyleId: 'psFill',
  strokeStyleId: 'psStroke',
  effectStyleId: 'esShadow',
);

const textAppearance = TextAppearance(
  strokes: stroke,
  effects: [dropShadow, layerBlur],
  strokeStyleId: 'psOutline',
  effectStyleId: 'esTextShadow',
);

const autoLayout = AutoLayout(
  direction: LayoutDirection.vertical,
  wrap: true,
  gap: Gap.auto(),
  counterAxisGap: Gap.fixed(-8),
  padding: EdgeInsetsValue(top: 1, right: 2, bottom: 3, left: 4),
  primaryAlign: PrimaryAlign.end,
  counterAlign: CounterAlign.baseline,
  rowAlign: RowAlign.center,
  strokesIncludedInLayout: true,
  reverseZIndex: true,
);

const gridLayout = GridLayout(
  columns: [GridTrack.fixed(120), GridTrack.flex(2), GridTrack.hug()],
  rows: [GridTrack.flex()],
  columnGap: 12,
  rowGap: 8,
  padding: EdgeInsetsValue(top: 4, left: 4),
  autoFlow: GridAutoFlow.column,
);

const layoutChild = LayoutChild(
  positioning: Positioning.absolute,
  horizontalSizing: Sizing.fill,
  verticalSizing: Sizing.hug,
  minWidth: 10,
  maxWidth: 400,
  minHeight: 20,
  maxHeight: 300,
  constraints: Constraints(
    horizontal: HorizontalConstraint.leftRight,
    vertical: VerticalConstraint.scale,
  ),
  grid: GridPlacement(
    column: 1,
    row: 2,
    columnSpan: 2,
    rowSpan: 3,
    alignX: GridAlign.center,
    alignY: GridAlign.stretch,
  ),
);

const motionTransform = MotionTransform(
  translateX: 10,
  translateY: -20,
  scaleX: 1.5,
  scaleY: 0.5,
  rotate: 45,
  skewX: 5,
  skewY: -5,
  originX: 0,
  originY: 1,
);

const textStyle = TextStyle(
  fontFamilyId: 'fSerif',
  fontWeight: 650,
  italic: true,
  fontVariations: {'wght': 650, 'opsz': 24.5},
  fontSize: 21.5,
  lineHeight: LineHeight.percent(140),
  letterSpacing: LetterSpacing.px(-0.4),
  paragraphSpacing: 12,
  paragraphIndent: 24,
  textCase: TextCase.smallCaps,
  decoration: TextDecoration(
    kind: TextDecorationKind.underline,
    style: TextDecorationStyle.doubleLine,
    thickness: 2,
    color: blue,
    skipInk: false,
  ),
  fills: [gradient],
  openType: {'liga': 0, 'tnum': 1, 'ss01': 1},
  baselineShift: BaselineShift.superscript,
  listStyle: ListStyle.ordered,
);

const styleOverride = TextStyleOverride(
  fontFamilyId: 'fSans',
  fontWeight: 700,
  italic: false,
  fontVariations: {'wdth': 90},
  fontSize: 18,
  lineHeight: LineHeight.px(28),
  letterSpacing: LetterSpacing.percent(2),
  paragraphSpacing: 4,
  paragraphIndent: 0,
  textCase: TextCase.upper,
  decoration: TextDecoration(kind: TextDecorationKind.strikethrough),
  fills: [solid],
  openType: {'smcp': 1},
  baselineShift: BaselineShift.subscript,
  listStyle: ListStyle.unordered,
);

const paragraphStyle = ParagraphStyle(
  alignHorizontal: TextAlignHorizontal.justified,
  paragraphSpacing: 16,
  paragraphIndent: 8,
  listStyle: ListStyle.unordered,
);

const span = Span(
  text: 'Hello',
  style: styleOverride,
  link: SpanLink.url('https://example.com', newTab: false),
);

const paragraph = Paragraph(
  spans: [
    span,
    Span(text: ' world', link: SpanLink.scene('sTwo')),
  ],
  style: paragraphStyle,
);

const interaction = Interaction(
  id: 'iTap',
  trigger: InteractionTrigger.tap(),
  actions: [
    Action.playTimeline(clockId: 'cTl'),
    Action.openUrl(url: 'https://example.com'),
  ],
);

NodeCommon common(String id, {String name = ''}) => NodeCommon(
  id: id,
  name: name,
  visible: false,
  locked: true,
  opacity: 0.4,
  blendMode: BlendMode.colorDodge,
  x: 10.5,
  y: -3,
  width: 320,
  height: 200,
  rotation: 15,
  flipX: true,
  flipY: true,
  motion: motionTransform,
  layoutChild: layoutChild,
  mask: MaskMode.luminance,
  role: NodeRole.figure,
  readingOrder: 3,
  altText: 'A lighthouse at dusk',
  breakpointOverrides: const {
    'bpMobile': {
      'opacity': IrValue.number(1),
      'layoutChild.maxWidth': IrValue.none(),
    },
  },
  bindings: const {'opacity': TokenRef(variableId: 'vOpacity')},
  componentBindings: const {'visible': 'propShow'},
  interactions: const [interaction],
);

const carousel = Behavior.carousel(
  axis: LayoutDirection.vertical,
  snap: false,
  loop: true,
  autoplay: 4,
  peek: 24,
  physics: CarouselPhysics.free,
);

FrameNode fullFrame(String id, {List<Node> children = const []}) => FrameNode(
  common: common(id, name: 'Frame $id'),
  appearance: appearance,
  children: children,
  autoLayout: autoLayout,
  grid: gridLayout,
  clipContent: true,
  behavior: carousel,
  modeOverrides: const {'colTheme': 'modeDark'},
);

TextNode fullText(String id) => TextNode(
  common: common(id),
  appearance: textAppearance,
  content: const [
    paragraph,
    Paragraph(spans: [Span(text: 'Second')]),
  ],
  textStyleId: 'tsBody',
  style: styleOverride,
  autoResize: TextAutoResize.truncate,
  maxLines: 3,
  truncation: TextTruncation.ending,
  alignHorizontal: TextAlignHorizontal.center,
  alignVertical: TextAlignVertical.bottom,
  leadingTrim: LeadingTrim.capHeight,
);

ShapeNode fullShape(String id, ShapeGeometry geometry) =>
    ShapeNode(common: common(id), geometry: geometry, appearance: appearance);

InstanceNode fullInstance(String id) => InstanceNode(
  common: common(id),
  source: const InstanceSource.variant(
    variantSetId: 'vsButton',
    variantValues: {'size': 'large', 'state': 'hover'},
  ),
  propValues: const {
    'propLabel': IrValue.string('Read on'),
    'propShow': IrValue.boolean(false),
  },
  overrides: const {
    'nLabel': {'style.fontSize': IrValue.number(24)},
    'nInner/nIcon': {'visible': IrValue.boolean(false)},
  },
);

VideoNode fullVideo(String id) => VideoNode(
  common: common(id),
  assetId: 'aVideo',
  appearance: appearance,
  scaleMode: ImageScaleMode.fit,
  focalPoint: const StagePoint(x: 0.2, y: 0.8),
  cropRect: const StageRect(x: 0.1, width: 0.8),
  posterAssetId: 'aPoster',
  autoplay: false,
  loop: false,
  muted: false,
);

EmbedNode fullEmbed(String id) => EmbedNode(
  common: common(id),
  assetId: 'aRive',
  scaleMode: ImageScaleMode.fill,
  artboard: 'Main',
  stateMachine: 'State Machine 1',
  autoplay: false,
  loop: false,
  inputs: const {'hover': IrValue.boolean(true), 'level': IrValue.number(3)},
  inputBindings: const {'progress': 'cScroll'},
);

/// Every `IrValue` variant.
final List<IrValue> allIrValues = [
  const IrValue.number(3.25),
  const IrValue.color(red),
  const IrValue.boolean(true),
  const IrValue.string('hello'),
  const IrValue.enumValue('leftRight'),
  const IrValue.size(StageSize(width: 390, height: 844)),
  const IrValue.point(StagePoint(x: 1, y: -1)),
  const IrValue.insets(EdgeInsetsValue(top: 1, right: 2, bottom: 3, left: 4)),
  const IrValue.cornerRadius(CornerRadius.uniform(12)),
  const IrValue.strokeWeight(StrokeWeight.uniform(2)),
  const IrValue.gap(Gap.auto()),
  const IrValue.paint(image),
  const IrValue.paints([solid, gradient]),
  const IrValue.effect(dropShadow),
  const IrValue.effects([layerBlur, backgroundBlur]),
  const IrValue.lineHeight(LineHeight.auto()),
  const IrValue.letterSpacing(LetterSpacing.percent(-1.5)),
  const IrValue.numbers([1, 2.5, 3]),
  const IrValue.tokenRef(TokenRef(variableId: 'vBrand')),
  const IrValue.none(),
];

const allShapeGeometries = <ShapeGeometry>[
  ShapeGeometry.rectangle(),
  ShapeGeometry.ellipse(arcStart: 90, arcEnd: 270, innerRadius: 0.4),
  ShapeGeometry.line(),
  ShapeGeometry.polygon(pointCount: 6),
  ShapeGeometry.star(pointCount: 7, innerRatio: 0.5),
];

const allBehaviors = <Behavior>[
  carousel,
  Behavior.lightbox(),
  Behavior.marquee(speed: 80, direction: MarqueeDirection.up),
  Behavior.textReveal(
    clockId: 'cScroll',
    unit: TextRevealUnit.char,
    stagger: 0.02,
    range: ClockRange(start: 0.1, end: 0.6),
  ),
  Behavior.lyrics(
    audioTrackId: 'atSong',
    activeStyle: TextStyleOverride(fontWeight: 800),
    inactiveStyle: TextStyleOverride(fills: [solid]),
    scrollMode: LyricsScrollMode.top,
  ),
  Behavior.audioControls(audioTrackId: 'atSong'),
];

const allTriggers = <InteractionTrigger>[
  InteractionTrigger.tap(),
  InteractionTrigger.hoverEnter(),
  InteractionTrigger.hoverLeave(),
  InteractionTrigger.sceneEnter(),
  InteractionTrigger.sceneLeave(),
  InteractionTrigger.audioCue(audioTrackId: 'atSong', time: 12.5),
  InteractionTrigger.clockReach(clockId: 'cScroll', value: 0.5),
];

const allActions = <Action>[
  Action.playTimeline(clockId: 'cTl'),
  Action.pauseTimeline(clockId: 'cTl'),
  Action.seekTimeline(clockId: 'cTl', time: 1.5),
  Action.reverseTimeline(clockId: 'cTl'),
  Action.playAudio(audioTrackId: 'atSong'),
  Action.pauseAudio(audioTrackId: 'atSong'),
  Action.seekAudio(audioTrackId: 'atSong', time: 30),
  Action.setVariable(variableId: 'vOpen', value: IrValue.boolean(true)),
  Action.scrollToScene(sceneId: 'sTwo'),
  Action.openUrl(url: 'https://example.com', newTab: false),
  Action.openLightbox(nodeId: 'nGallery'),
];

const allClocks = <Clock>[
  Clock.sceneScroll(id: 'cScroll', sceneId: 'sOne', smoothing: 0.15),
  Clock.timeline(
    id: 'cTl',
    duration: 4.5,
    name: 'Intro',
    loop: TimelineLoop.pingPong,
    rate: 0.5,
    trigger: TimelineTrigger.autoplay,
    smoothing: 0.05,
  ),
  Clock.audio(id: 'cAudio', audioTrackId: 'atSong'),
  Clock.pointer(
    id: 'cPtr',
    frameId: 'nHero',
    axis: PointerAxis.y,
    smoothing: 0.3,
  ),
  Clock.behavior(id: 'cIdx', nodeId: 'nCarousel', name: 'index'),
];

const allEasings = <Easing>[
  Easing.linear(),
  Easing.cubicBezier(0.25, 0.1, 0.25, 1),
  Easing.preset(EasingPreset.easeInOutBack),
  Easing.spring(mass: 2, stiffness: 180, damping: 12),
  Easing.steps(4, position: StepPosition.jumpStart),
  Easing.hold(),
];

Track trackWithAllEasings() => Track(
  id: 'tAll',
  target: 'nHero',
  property: 'motion.translateY',
  clockId: 'cScroll',
  keyframes: [
    for (var i = 0; i < allEasings.length; i++)
      Keyframe(
        id: 'k$i',
        t: i / allEasings.length,
        value: IrValue.number(i * 10.0),
        easing: allEasings[i],
      ),
  ],
  breakpoints: const ['bpDesktop', 'bpTablet'],
);

const lyrics = LyricsDoc(
  lines: [
    LyricLine(
      start: 0,
      end: 2.5,
      text: 'First line',
      words: [
        LyricWord(start: 0, end: 1, text: 'First'),
        LyricWord(start: 1, text: 'line'),
      ],
    ),
    LyricLine(start: 2.5, text: 'Second line'),
  ],
);

const audioTrack = AudioTrack(
  id: 'atSong',
  assetId: 'aSong',
  scope: AudioScope.scene('sTwo'),
  autoplay: true,
  loop: true,
  volume: 0.8,
  fadeIn: 1.5,
  fadeOut: 2,
  lyrics: lyrics,
);

const asset = Asset(
  id: 'aHero',
  kind: AssetKind.image,
  uri: 'asset://demo/hero.jpg',
  name: 'Hero',
  mime: 'image/jpeg',
  byteSize: 123456,
  width: 3000,
  height: 2000,
  duration: 1.5,
  frameCount: 24,
  variants: [
    AssetVariant(width: 640, uri: 'asset://demo/hero-640.webp', format: 'webp'),
  ],
  placeholder: AssetPlaceholder(dominantColor: blue, blurhash: 'LEHV6nWB2yk8'),
  alt: 'A hill at dusk',
  credit: 'Photo: me',
);

const fontFamily = FontFamily(
  id: 'fSerif',
  name: 'Fraunces',
  faces: [
    FontFace(assetId: 'aFrauncesR'),
    FontFace(
      assetId: 'aFrauncesVar',
      weight: 300,
      italic: true,
      variable: true,
      axes: [FontAxis(tag: 'wght', min: 100, max: 900, defaultValue: 400)],
    ),
  ],
  fallback: FontFallback.serif,
);

const tokenSystem = TokenSystem(
  collections: [
    VariableCollection(
      id: 'colTheme',
      name: 'Theme',
      modes: [
        TokenMode(id: 'modeLight', name: 'Light'),
        TokenMode(id: 'modeDark', name: 'Dark'),
      ],
      defaultModeId: 'modeLight',
      breakpointModes: {'bpMobile': 'modeDark'},
      variables: [
        Variable(
          id: 'vBrand',
          name: 'color/brand/primary',
          type: VariableType.color,
          valuesByMode: {
            'modeLight': IrValue.color(red),
            'modeDark': IrValue.color(blue),
          },
        ),
        Variable(
          id: 'vAccent',
          name: 'color/accent',
          type: VariableType.color,
          valuesByMode: {
            'modeLight': IrValue.tokenRef(TokenRef(variableId: 'vBrand')),
            'modeDark': IrValue.tokenRef(TokenRef(variableId: 'vBrand')),
          },
        ),
        Variable(
          id: 'vOpacity',
          name: 'opacity/muted',
          type: VariableType.number,
          valuesByMode: {'modeLight': IrValue.number(0.6)},
        ),
        Variable(
          id: 'vOpen',
          name: 'state/open',
          type: VariableType.boolean,
          valuesByMode: {'modeLight': IrValue.boolean(false)},
        ),
        Variable(
          id: 'vFont',
          name: 'font/body',
          type: VariableType.fontFamily,
          valuesByMode: {'modeLight': IrValue.string('fSerif')},
        ),
        Variable(
          id: 'vLabel',
          name: 'copy/cta',
          type: VariableType.string,
          valuesByMode: {'modeLight': IrValue.string('Begin')},
        ),
      ],
    ),
  ],
  textStyles: {
    'tsBody': TextStyleDef(
      name: 'Body',
      style: styleOverride,
      bindings: {'fontFamilyId': TokenRef(variableId: 'vFont')},
    ),
  },
  paintStyles: {
    'psFill': PaintStyleDef(name: 'Brand fill', paints: [solid]),
  },
  effectStyles: {
    'esShadow': EffectStyleDef(name: 'Soft', effects: [dropShadow]),
  },
);

ComponentDef buttonComponent(String id) => ComponentDef(
  id: id,
  name: 'Button/$id',
  description: 'A call to action',
  root: FrameNode(
    common: NodeCommon(id: 'nRoot$id', width: 160, height: 48),
    autoLayout: const AutoLayout(padding: EdgeInsetsValue(left: 16, right: 16)),
    children: [
      const TextNode(
        common: NodeCommon(
          id: 'nLabel',
          componentBindings: {'content.0.spans.0.text': 'propLabel'},
        ),
        content: [
          Paragraph(spans: [Span(text: 'Button')]),
        ],
      ),
    ],
  ),
  properties: const {
    'propLabel': ComponentPropDef(
      name: 'Label',
      type: ComponentPropType.text,
      defaultValue: IrValue.string('Button'),
    ),
    'propShow': ComponentPropDef(
      name: 'Show icon',
      type: ComponentPropType.boolean,
      defaultValue: IrValue.boolean(true),
    ),
    'propSize': ComponentPropDef(
      name: 'Size',
      type: ComponentPropType.variant,
      defaultValue: IrValue.string('small'),
    ),
  },
);

const variantSet = VariantSet(
  id: 'vsButton',
  name: 'Button',
  axes: {
    'size': ['small', 'large'],
    'state': ['default', 'hover'],
  },
  variants: [
    Variant(
      componentId: 'cmpSmall',
      values: {'size': 'small', 'state': 'default'},
    ),
    Variant(
      componentId: 'cmpLarge',
      values: {'size': 'large', 'state': 'hover'},
    ),
  ],
);

const breakpoints = <Breakpoint>[
  Breakpoint(
    id: 'bpDesktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: StageSize(width: 1440, height: 900),
  ),
  Breakpoint(
    id: 'bpTablet',
    name: 'Tablet',
    minWidth: 600,
    designSize: StageSize(width: 834, height: 1112),
  ),
  Breakpoint(
    id: 'bpMobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: StageSize(width: 390, height: 844),
  ),
];

/// A large document exercising every part of the IR.
StageDocument compositeDocument() {
  final card = FrameNode(
    common: const NodeCommon(
      id: 'nCard',
      layoutChild: LayoutChild(horizontalSizing: Sizing.fill),
    ),
    autoLayout: const AutoLayout(
      direction: LayoutDirection.vertical,
      gap: Gap.fixed(12),
      padding: EdgeInsetsValue(top: 24, right: 24, bottom: 24, left: 24),
    ),
    appearance: const Appearance(
      fills: [solid],
      cornerRadius: CornerRadius.uniform(16),
      effects: [dropShadow],
    ),
    children: [
      fullText('nCardTitle'),
      fullShape('nCardRule', const ShapeGeometry.line()),
      FrameNode(
        common: const NodeCommon(id: 'nCardRow'),
        autoLayout: const AutoLayout(gap: Gap.auto(), wrap: true),
        children: [
          fullInstance('nCta'),
          fullShape('nBadge', const ShapeGeometry.star()),
        ],
      ),
    ],
  );

  final hero = Scene(
    id: 'sOne',
    name: 'Hero',
    kind: SceneKind.pinned,
    scrollLength: 2.5,
    exportAs: SceneExportMode.poster,
    posterClock: 0.25,
    root: fullFrame(
      'nStage1',
      children: [
        fullFrame('nHero', children: [fullText('nHeroTitle')]),
        fullVideo('nVideo'),
        fullEmbed('nRive'),
        for (var i = 0; i < allShapeGeometries.length; i++)
          fullShape('nShape$i', allShapeGeometries[i]),
      ],
    ),
    tracks: [
      trackWithAllEasings(),
      const Track(
        id: 'tFill',
        target: 'nCta/nLabel',
        property: 'fills.pSolid.color',
        clockId: 'cTl',
        keyframes: [
          Keyframe(id: 'kc0', t: 0, value: IrValue.color(red)),
          Keyframe(
            id: 'kc1',
            t: 1,
            value: IrValue.tokenRef(TokenRef(variableId: 'vBrand')),
          ),
        ],
      ),
    ],
    clocks: allClocks,
    background: const [gradient],
    modeOverrides: const {'colTheme': 'modeDark'},
    transitionIn: const SceneTransition(
      kind: SceneTransitionKind.crossfade,
      amount: 0.5,
    ),
  );

  final grid = Scene(
    id: 'sTwo',
    name: 'Cards',
    root: FrameNode(
      common: const NodeCommon(
        id: 'nStage2',
        width: 1440,
        layoutChild: LayoutChild(verticalSizing: Sizing.hug),
      ),
      autoLayout: const AutoLayout(
        wrap: true,
        gap: Gap.fixed(24),
        counterAxisGap: Gap.fixed(24),
      ),
      children: [
        card,
        card.copyWith(common: card.common.copyWith(id: 'nCard2')),
      ],
    ),
  );

  final lyricScene = Scene(
    id: 'sThree',
    name: 'Lyrics',
    kind: SceneKind.pinned,
    scrollLength: 4,
    root: FrameNode(
      common: const NodeCommon(id: 'nStage3', width: 1440, height: 900),
      children: [
        FrameNode(
          common: const NodeCommon(id: 'nLyrics'),
          behavior: allBehaviors[4],
          children: [fullText('nLyricLine')],
        ),
        for (var i = 0; i < allBehaviors.length; i++)
          FrameNode(
            common: NodeCommon(id: 'nB$i'),
            behavior: allBehaviors[i],
          ),
      ],
    ),
    clocks: const [Clock.audio(id: 'cAudio', audioTrackId: 'atSong')],
  );

  return StageDocument(
    id: 'doc1',
    meta: const StageMeta(
      title: 'Night Walk',
      slug: 'night-walk',
      author: 'Me',
      description: 'A story',
      coverAssetId: 'aHero',
      language: 'en-GB',
    ),
    breakpoints: breakpoints,
    baseBreakpointId: 'bpDesktop',
    tokens: tokenSystem,
    defaultTextStyle: textStyle,
    assets: {
      'aHero': asset,
      'aSong': const Asset(
        id: 'aSong',
        kind: AssetKind.audio,
        uri: 'asset://demo/song.mp3',
        duration: 182.4,
      ),
    },
    fonts: const {'fSerif': fontFamily},
    components: {
      'cmpSmall': buttonComponent('cmpSmall'),
      'cmpLarge': buttonComponent('cmpLarge'),
    },
    variantSets: const {'vsButton': variantSet},
    scenes: [hero, grid, lyricScene],
    audioTracks: const [
      audioTrack,
      AudioTrack(id: 'atAmb', assetId: 'aSong'),
    ],
    overlay: const FrameNode(
      common: NodeCommon(id: 'nOverlay', width: 1440, height: 4),
      appearance: Appearance(fills: [solid]),
      children: [
        FrameNode(
          common: NodeCommon(id: 'nPlayer'),
          behavior: Behavior.audioControls(audioTrackId: 'atSong'),
        ),
      ],
    ),
  );
}
