import 'dart:math';

import 'package:soundstage_platform/ir/ir.dart';

/// Seeded generator of **valid** documents: every reference resolves, ids are
/// unique, and every node kind, instance form, token feature, style, patch,
/// easing, audio track, behaviour and interaction shape appears across seeds.
///
/// `DocGen(seed).build()` is deterministic. Documents are small (tens to a
/// few hundred nodes) so hundreds of seeds run in seconds.
class DocGen {
  DocGen(this.seed, {this.maxDepth = 3, this.maxBreadth = 4})
    : r = Random(seed);

  final int seed;
  final int maxDepth;
  final int maxBreadth;
  final Random r;

  int _n = 0;
  String _id(String prefix) => '$prefix${_n++}';

  bool _p(double probability) => r.nextDouble() < probability;
  T _pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];
  double _num([double lo = 0, double hi = 400]) =>
      (lo + r.nextDouble() * (hi - lo)).roundToDouble();
  double _frac() => (r.nextDouble() * 100).roundToDouble() / 100;

  // Fixed vocabularies ----------------------------------------------------

  static const _bpIds = ['bpA', 'bpB', 'bpC', 'bpD'];
  late final List<String> _bps;
  late final List<String> _sceneIds;

  final List<ComponentDef> _comps = [];

  /// Per component: ids of inner nodes an override may address.
  final Map<String, ({String label, String root, String? nested})> _inner = {};

  // Per-scene state while building.
  late List<String> _frameIds;
  late List<String> _leafIds;
  late List<InstanceNode> _instances;
  late String _tl;
  late List<String> _clockIds;
  bool _inComponent = false;

  StageDocument build() {
    final bpCount = 2 + r.nextInt(3);
    _bps = _bpIds.sublist(0, bpCount);
    final sceneCount = 1 + r.nextInt(3);
    _sceneIds = [for (var i = 0; i < sceneCount; i++) 'sc$i'];

    final assets = <String, Asset>{
      for (var i = 0; i < 3; i++)
        'aImg$i': Asset(
          id: 'aImg$i',
          kind: AssetKind.image,
          uri: 'asset://img$i.png',
          width: 100 + i,
          height: 80,
          placeholder: const AssetPlaceholder(dominantColor: StageColor.black),
        ),
      'aVid': const Asset(
        id: 'aVid',
        kind: AssetKind.video,
        uri: 'asset://v.mp4',
        duration: 9.5,
      ),
      'aAud0': const Asset(
        id: 'aAud0',
        kind: AssetKind.audio,
        uri: 'asset://a0.mp3',
        duration: 60,
      ),
      'aAud1': const Asset(
        id: 'aAud1',
        kind: AssetKind.audio,
        uri: 'asset://a1.mp3',
        duration: 30,
      ),
      'aFontA': const Asset(
        id: 'aFontA',
        kind: AssetKind.font,
        uri: 'asset://a.woff2',
      ),
      'aFontB': const Asset(
        id: 'aFontB',
        kind: AssetKind.font,
        uri: 'asset://b.woff2',
      ),
      'aLottie': const Asset(
        id: 'aLottie',
        kind: AssetKind.lottie,
        uri: 'asset://l.json',
      ),
    };
    final fonts = <String, FontFamily>{
      'fA': const FontFamily(
        id: 'fA',
        name: 'A',
        faces: [
          FontFace(
            assetId: 'aFontA',
            variable: true,
            axes: [
              FontAxis(tag: 'wght', min: 100, max: 900, defaultValue: 400),
            ],
          ),
        ],
      ),
      'fB': const FontFamily(
        id: 'fB',
        name: 'B',
        faces: [FontFace(assetId: 'aFontB', italic: true)],
        fallback: FontFallback.serif,
      ),
    };

    final tokens = _tokens();

    // Components, each built from earlier ones only (no cycles).
    final compCount = 2 + r.nextInt(3);
    for (var i = 0; i < compCount; i++) {
      _comps.add(_component('cmp$i'));
    }
    final variantSets = {
      'vsMain': VariantSet(
        id: 'vsMain',
        name: 'Main',
        axes: const {
          'size': ['small', 'large'],
        },
        variants: [
          Variant(componentId: _comps[0].id, values: const {'size': 'small'}),
          Variant(componentId: _comps[1].id, values: const {'size': 'large'}),
        ],
      ),
    };

    final audioTracks = [
      AudioTrack(
        id: 'at0',
        assetId: 'aAud0',
        autoplay: _p(0.5),
        loop: _p(0.5),
        volume: _frac(),
        fadeIn: _frac(),
        fadeOut: _frac(),
        lyrics: const LyricsDoc(
          lines: [
            LyricLine(
              start: 0,
              end: 2,
              text: 'la la',
              words: [
                LyricWord(start: 0, text: 'la', end: 1),
                LyricWord(start: 1, text: 'la'),
              ],
            ),
            LyricLine(start: 2, text: 'lo'),
          ],
        ),
      ),
      AudioTrack(
        id: 'at1',
        assetId: 'aAud1',
        scope: AudioScope.scene(_sceneIds.first),
      ),
    ];

    final scenes = [
      for (var i = 0; i < sceneCount; i++) _scene(_sceneIds[i], i),
    ];

    final overlay = _p(0.5)
        ? FrameNode(
            common: NodeCommon(id: _id('ov'), width: 100, height: 8),
            appearance: const Appearance(
              fills: [Paint.solid(id: 'f0', color: StageColor.black)],
            ),
            children: [
              FrameNode(
                common: NodeCommon(id: _id('ovc')),
                behavior: const Behavior.audioControls(audioTrackId: 'at0'),
              ),
            ],
          )
        : null;

    return StageDocument(
      id: 'doc$seed',
      meta: StageMeta(
        title: 'Fuzz $seed',
        slug: 'fuzz-$seed',
        coverAssetId: _p(0.5) ? 'aImg0' : null,
      ),
      breakpoints: [
        for (var i = 0; i < _bps.length; i++)
          Breakpoint(
            id: _bps[i],
            name: 'bp$i',
            minWidth: (_bps.length - 1 - i) * 400.0,
            designSize: StageSize(width: 1440 - i * 300, height: 900),
            // Acyclic: a breakpoint inherits from an earlier one or none.
            inheritsFrom: i > 0 && _p(0.5) ? _bps[r.nextInt(i)] : null,
            primary: i == 0 || _p(0.4),
          ),
      ],
      defaultTextStyle: TextStyle(
        fontFamilyId: _p(0.5) ? 'fA' : null,
        fontSize: _num(10, 30),
        fontWeight: 100 * (1 + r.nextInt(9)),
      ),
      tokens: tokens,
      assets: assets,
      fonts: fonts,
      components: {for (final c in _comps) c.id: c},
      variantSets: variantSets,
      scenes: scenes,
      audioTracks: audioTracks,
      overlay: overlay,
    );
  }

  // Tokens ----------------------------------------------------------------

  TokenSystem _tokens() {
    final colors = <String, StageColor>{
      'light': StageColor(r: _frac(), g: _frac(), b: _frac()),
      'dark': StageColor(r: _frac(), g: _frac(), b: _frac()),
    };
    return TokenSystem(
      collections: [
        VariableCollection(
          id: 'colMode',
          name: 'Mode',
          modes: const [
            TokenMode(id: 'light', name: 'Light'),
            TokenMode(id: 'dark', name: 'Dark'),
          ],
          defaultModeId: 'light',
          variables: [
            Variable(
              id: 'vCol',
              name: 'color/brand',
              type: VariableType.color,
              valuesByMode: {
                'light': IrValue.color(colors['light']!),
                'dark': IrValue.color(colors['dark']!),
              },
            ),
            Variable(
              // Alias in one mode, concrete in the other.
              id: 'vColAlias',
              name: 'color/alias',
              type: VariableType.color,
              valuesByMode: {
                'light': const IrValue.tokenRef(TokenRef(variableId: 'vCol')),
                'dark': IrValue.color(colors['light']!),
              },
            ),
            const Variable(
              id: 'vColAlias2',
              name: 'color/alias2',
              type: VariableType.color,
              valuesByMode: {
                'light': IrValue.tokenRef(TokenRef(variableId: 'vColAlias')),
              },
            ),
            const Variable(
              id: 'vOp',
              name: 'opacity/dim',
              type: VariableType.number,
              valuesByMode: {
                'light': IrValue.number(0.8),
                'dark': IrValue.number(0.4),
              },
            ),
            const Variable(
              id: 'vFont',
              name: 'font/body',
              type: VariableType.fontFamily,
              valuesByMode: {'light': IrValue.string('fA')},
            ),
            const Variable(
              id: 'vNum',
              name: 'misc/number',
              type: VariableType.number,
              valuesByMode: {'light': IrValue.number(3)},
            ),
            const Variable(
              id: 'vFlag',
              name: 'misc/flag',
              type: VariableType.boolean,
              valuesByMode: {'light': IrValue.boolean(true)},
            ),
          ],
        ),
        VariableCollection(
          id: 'colSize',
          name: 'Size',
          modes: const [
            TokenMode(id: 'compact', name: 'Compact'),
            TokenMode(id: 'roomy', name: 'Roomy'),
          ],
          defaultModeId: 'roomy',
          breakpointModes: {_bps.last: 'compact'},
          variables: const [
            Variable(
              id: 'vSize',
              name: 'size/text',
              type: VariableType.number,
              valuesByMode: {
                'compact': IrValue.number(14),
                'roomy': IrValue.number(20),
              },
            ),
          ],
        ),
      ],
      textStyles: {
        'tsA': TextStyleDef(
          name: 'A',
          style: TextStyleOverride(
            fontFamilyId: 'fB',
            fontSize: _num(10, 30),
            fontWeight: 500,
            lineHeight: const LineHeight.percent(120),
            letterSpacing: const LetterSpacing.px(1),
          ),
          bindings: const {
            'fontSize': TokenRef(variableId: 'vSize'),
            'fills.text.color': TokenRef(variableId: 'vColAlias2'),
          },
        ),
        'tsB': const TextStyleDef(name: 'B'),
      },
      paintStyles: {
        'psA': PaintStyleDef(
          name: 'A',
          paints: [
            Paint.solid(id: 'pa', color: colors['light']!),
            Paint.gradient(
              id: 'pb',
              stops: [
                ColorStop(position: 0, color: colors['light']!),
                ColorStop(position: 1, color: colors['dark']!),
              ],
              kind: GradientKind.radial,
            ),
          ],
        ),
      },
      effectStyles: const {
        'esA': EffectStyleDef(
          name: 'A',
          effects: [
            Effect.dropShadow(id: 'sh'),
            Effect.layerBlur(id: 'bl'),
          ],
        ),
      },
    );
  }

  // Components ------------------------------------------------------------

  ComponentDef _component(String cid) {
    _inComponent = true;
    final label = '${cid}_label';
    final root = '${cid}_root';
    String? nestedKey;
    final children = <Node>[
      TextNode(
        common: NodeCommon(
          id: label,
          componentBindings: const {'characters': 'pText'},
        ),
        content: const [
          Paragraph(spans: [Span(text: 'Label')]),
        ],
      ),
      ShapeNode(
        common: NodeCommon(
          id: '${cid}_icon',
          width: 20,
          height: 20,
          componentBindings: const {'visible': 'pShow'},
        ),
        appearance: const Appearance(
          fills: [Paint.solid(id: 'f0', color: StageColor.black)],
        ),
      ),
    ];
    if (_comps.isNotEmpty && _p(0.7)) {
      final inner = _pick(_comps);
      nestedKey = '${cid}_nested';
      children.add(
        InstanceNode(
          common: NodeCommon(id: nestedKey),
          source: InstanceSource.component(inner.id),
          propValues: const {'pText': IrValue.string('Nested')},
        ),
      );
      _inner[cid] = (label: label, root: root, nested: inner.id);
    } else {
      _inner[cid] = (label: label, root: root, nested: null);
    }
    final def = ComponentDef(
      id: cid,
      name: cid,
      root: FrameNode(
        common: NodeCommon(
          id: root,
          width: 120,
          height: 40,
          bindings: const {'opacity': TokenRef(variableId: 'vOp')},
          componentBindings: const {},
        ),
        appearance: Appearance(
          fills: [const Paint.solid(id: 'f0', color: StageColor.black)],
          cornerRadius: CornerRadius.uniform(_num(0, 12)),
        ),
        autoLayout: AutoLayout(
          direction: _pick(LayoutDirection.values),
          gap: _p(0.3) ? const Gap.auto() : Gap.fixed(_num(0, 20)),
          padding: EdgeInsetsValue.all(_num(0, 16)),
        ),
        children: children,
      ),
      properties: {
        'pText': const ComponentPropDef(
          name: 'Text',
          type: ComponentPropType.text,
          defaultValue: IrValue.string('Hello'),
        ),
        'pShow': const ComponentPropDef(
          name: 'Show',
          type: ComponentPropType.boolean,
          defaultValue: IrValue.boolean(true),
        ),
        'pSwap': ComponentPropDef(
          name: 'Swap',
          type: ComponentPropType.instanceSwap,
          defaultValue: IrValue.string(_comps.isEmpty ? cid : _comps.first.id),
        ),
      },
    );
    _inComponent = false;
    return def;
  }

  // Scenes ----------------------------------------------------------------

  Scene _scene(String sid, int index) {
    _frameIds = [];
    _leafIds = [];
    _instances = [];
    _tl = _id('tl');
    final scroll = _id('cs');
    _clockIds = [_tl, scroll];
    final clocks = <Clock>[
      Clock.sceneScroll(id: scroll, sceneId: sid, smoothing: _frac()),
      Clock.timeline(
        id: _tl,
        duration: 1 + _num(0, 8),
        name: 'main',
        loop: _pick(TimelineLoop.values),
        rate: 1,
        trigger: _pick(TimelineTrigger.values),
      ),
    ];
    if (_p(0.6)) {
      final ac = _id('ca');
      _clockIds.add(ac);
      clocks.add(Clock.audio(id: ac, audioTrackId: 'at0'));
    }

    final rootId = _id('root');
    _frameIds.add(rootId);
    final children = _children(0, parent: rootId);
    final root = FrameNode(
      common: NodeCommon(id: rootId, width: 1440, height: 900),
      appearance: const Appearance(
        fills: [Paint.solid(id: 'f0', color: StageColor.black)],
      ),
      clipContent: true,
      children: children,
    );

    // Clocks that depend on the built tree.
    final pointerFrame = _pick(_frameIds);
    final pc = _id('cp');
    _clockIds.add(pc);
    clocks.add(
      Clock.pointer(
        id: pc,
        frameId: pointerFrame,
        axis: _pick(PointerAxis.values),
      ),
    );
    final bc = _id('cb');
    _clockIds.add(bc);
    clocks.add(
      Clock.behavior(id: bc, nodeId: _pick(_frameIds), name: 'progress'),
    );

    return Scene(
      id: sid,
      name: 'Scene $index',
      kind: index == 0 ? SceneKind.pinned : _pick(SceneKind.values),
      scrollLength: _num(1, 4),
      root: root,
      clocks: clocks,
      tracks: _tracks(clocks),
      background: [const Paint.solid(id: 'bg', color: StageColor.black)],
      modeOverrides: _p(0.3) ? const {'colMode': 'dark'} : const {},
      transitionIn: SceneTransition(
        kind: _pick(SceneTransitionKind.values),
        amount: _frac(),
      ),
      exportAs: _pick(SceneExportMode.values),
      posterClock: _p(0.5) ? _frac() : null,
    );
  }

  List<Node> _children(int depth, {required String parent}) {
    final count = 1 + r.nextInt(maxBreadth);
    return [for (var i = 0; i < count; i++) _node(depth)];
  }

  Node _node(int depth) {
    final roll = r.nextInt(depth >= maxDepth ? 6 : 8);
    return switch (roll) {
      0 || 1 => _text(),
      2 => _shape(),
      3 => _video(),
      4 => _embed(),
      5 => _instance(),
      _ => _frame(depth + 1),
    };
  }

  // Node pieces ------------------------------------------------------------

  NodeCommon _common(String id, {bool fills = false}) {
    final bpPatches = <String, Patch>{};
    for (final bp in _bps) {
      if (!_p(0.5)) continue;
      bpPatches[bp] = {
        'x': IrValue.number(_num()),
        'opacity': IrValue.number(_frac()),
        if (_p(0.3)) 'visible': IrValue.boolean(_p(0.5)),
        if (fills) 'fills.f0.color': const IrValue.color(StageColor.black),
        if (_p(0.3))
          'opacity': const IrValue.tokenRef(TokenRef(variableId: 'vOp')),
      };
    }
    return NodeCommon(
      id: id,
      name: 'n $id',
      visible: _p(0.9),
      locked: _p(0.1),
      opacity: _frac(),
      blendMode: _p(0.2) ? _pick(BlendMode.values) : null,
      x: _num(),
      y: _num(),
      width: _num(10, 300),
      height: _num(10, 300),
      rotation: _p(0.2) ? _num(0, 90) : 0,
      flipX: _p(0.1),
      motion: _p(0.3)
          ? MotionTransform(translateX: _num(0, 20), scaleX: 1 + _frac())
          : const MotionTransform(),
      layoutChild: _p(0.4)
          ? LayoutChild(
              positioning: _pick(Positioning.values),
              horizontalSizing: _pick(Sizing.values),
              verticalSizing: _pick(Sizing.values),
              maxWidth: _p(0.3) ? 500 : null,
            )
          : const LayoutChild(),
      mask: _p(0.1) ? MaskMode.alpha : MaskMode.none,
      role: _p(0.5) ? _pick(NodeRole.values) : NodeRole.none,
      readingOrder: _p(0.2) ? r.nextInt(20) : null,
      altText: _p(0.2) ? 'alt $id' : null,
      breakpointOverrides: bpPatches,
      bindings: _p(0.2)
          ? const {'opacity': TokenRef(variableId: 'vOp')}
          : const {},
      interactions: _p(0.3) ? _interactions() : const [],
    );
  }

  List<Interaction> _interactions() {
    final n = 1 + r.nextInt(2);
    return [
      for (var i = 0; i < n; i++)
        Interaction(
          id: _id('int'),
          trigger: _trigger(),
          actions: [for (var j = 0; j < 1 + r.nextInt(3); j++) _action()],
        ),
    ];
  }

  InteractionTrigger _trigger() => switch (r.nextInt(7)) {
    0 => const InteractionTrigger.tap(),
    1 => const InteractionTrigger.hoverEnter(),
    2 => const InteractionTrigger.hoverLeave(),
    3 => const InteractionTrigger.sceneEnter(),
    4 => const InteractionTrigger.sceneLeave(),
    5 => InteractionTrigger.audioCue(audioTrackId: 'at0', time: _num(0, 30)),
    _ => InteractionTrigger.clockReach(
      clockId: _inComponent ? _tl : _pick(_clockIds),
      value: _frac(),
    ),
  };

  Action _action() => switch (r.nextInt(11)) {
    0 => Action.playTimeline(clockId: _tl),
    1 => Action.pauseTimeline(clockId: _tl),
    2 => Action.seekTimeline(clockId: _tl, time: _frac()),
    3 => Action.reverseTimeline(clockId: _tl),
    4 => const Action.playAudio(audioTrackId: 'at0'),
    5 => const Action.pauseAudio(audioTrackId: 'at1'),
    6 => Action.seekAudio(audioTrackId: 'at0', time: _num(0, 30)),
    7 => const Action.setVariable(variableId: 'vNum', value: IrValue.number(7)),
    8 => Action.scrollToScene(sceneId: _pick(_sceneIds)),
    9 => const Action.openUrl(url: 'https://example.com', newTab: false),
    _ => Action.openLightbox(nodeId: _pick(_frameIds)),
  };

  Appearance _appearance() {
    final styled = _p(0.2);
    return Appearance(
      fills: [
        Paint.solid(
          id: 'f0',
          color: StageColor(r: _frac(), g: _frac(), b: _frac()),
        ),
        if (_p(0.3))
          Paint.gradient(
            id: 'f1',
            stops: [
              const ColorStop(position: 0, color: StageColor.black),
              const ColorStop(position: 1, color: StageColor.white),
            ],
            kind: _pick(GradientKind.values),
          ),
        if (_p(0.3))
          Paint.image(
            id: 'f2',
            assetId: 'aImg${r.nextInt(3)}',
            scaleMode: _pick(ImageScaleMode.values),
            cropRect: _p(0.3)
                ? const StageRect(x: 0, y: 0, width: 0.5, height: 0.5)
                : null,
          ),
      ],
      strokes: Stroke(
        paints: _p(0.4)
            ? const [Paint.solid(id: 's0', color: StageColor.black)]
            : const [],
        weight: _p(0.2)
            ? const StrokeWeight.perSide(top: 1, left: 2)
            : const StrokeWeight.uniform(2),
        dash: _p(0.2) ? const [4, 2] : const [],
      ),
      effects: _p(0.4)
          ? const [
              Effect.dropShadow(id: 'e0'),
              Effect.innerShadow(id: 'e1'),
              Effect.layerBlur(id: 'e2'),
              Effect.backgroundBlur(id: 'e3'),
            ]
          : const [],
      cornerRadius: _p(0.3)
          ? const CornerRadius.perCorner(tl: 4, br: 8)
          : CornerRadius.uniform(_num(0, 20)),
      fillStyleId: styled ? 'psA' : null,
      effectStyleId: _p(0.1) ? 'esA' : null,
    );
  }

  FrameNode _frame(int depth) {
    final id = _id('fr');
    _frameIds.add(id);
    final layoutRoll = r.nextInt(4);
    final behavior = _p(0.35) ? _behavior() : null;
    final children = _children(depth, parent: id);
    return FrameNode(
      common: _common(id, fills: true),
      appearance: _appearance(),
      clipContent: _p(0.4),
      autoLayout: layoutRoll == 0
          ? AutoLayout(
              direction: _pick(LayoutDirection.values),
              wrap: _p(0.3),
              gap: _p(0.3) ? const Gap.auto() : Gap.fixed(_num(0, 30)),
              padding: EdgeInsetsValue.all(_num(0, 24)),
              primaryAlign: _pick(PrimaryAlign.values),
              counterAlign: _pick(CounterAlign.values),
            )
          : null,
      grid: layoutRoll == 1
          ? GridLayout(
              columns: const [
                GridTrack.flex(),
                GridTrack.fixed(100),
                GridTrack.hug(),
              ],
              rows: const [GridTrack.flex(2)],
              columnGap: _num(0, 20),
            )
          : null,
      behavior: behavior,
      modeOverrides: _p(0.15) ? const {'colSize': 'compact'} : const {},
      children: children,
    );
  }

  Behavior _behavior() => switch (r.nextInt(6)) {
    0 => Behavior.carousel(
      axis: _pick(LayoutDirection.values),
      loop: _p(0.5),
      autoplay: _num(0, 5),
      physics: _pick(CarouselPhysics.values),
    ),
    1 => const Behavior.lightbox(),
    2 => Behavior.marquee(
      speed: _num(10, 100),
      direction: _pick(MarqueeDirection.values),
    ),
    3 => Behavior.textReveal(
      clockId: _inComponent ? _tl : _pick(_clockIds),
      unit: _pick(TextRevealUnit.values),
      range: ClockRange(start: 0, end: _frac()),
    ),
    4 => Behavior.lyrics(
      audioTrackId: 'at0',
      activeStyle: const TextStyleOverride(fontWeight: 800),
      inactiveStyle: const TextStyleOverride(
        fills: [Paint.solid(id: 'ia', color: StageColor.black)],
      ),
      scrollMode: _pick(LyricsScrollMode.values),
    ),
    _ => const Behavior.audioControls(audioTrackId: 'at1'),
  };

  TextNode _text() {
    final id = _id('tx');
    _leafIds.add(id);
    final spans = [
      for (var i = 0; i < 1 + r.nextInt(3); i++)
        Span(
          text: 'word$i ',
          style: _p(0.5) ? _override() : const TextStyleOverride(),
          link: _p(0.2)
              ? (_p(0.5)
                    ? const SpanLink.url('https://example.com')
                    : SpanLink.scene(_pick(_sceneIds)))
              : null,
        ),
    ];
    return TextNode(
      common: _common(id),
      appearance: TextAppearance(
        strokes: _p(0.2)
            ? const Stroke(
                paints: [Paint.solid(id: 's0', color: StageColor.black)],
              )
            : const Stroke(),
        effects: _p(0.2) ? const [Effect.dropShadow(id: 'e0')] : const [],
      ),
      textStyleId: _p(0.4) ? _pick(['tsA', 'tsB']) : null,
      style: _p(0.6) ? _override() : const TextStyleOverride(),
      content: [
        for (var p = 0; p < 1 + r.nextInt(2); p++)
          Paragraph(
            spans: spans,
            style: _p(0.4)
                ? ParagraphStyle(
                    alignHorizontal: _pick(TextAlignHorizontal.values),
                    paragraphSpacing: _num(0, 12),
                    listStyle: _pick(ListStyle.values),
                  )
                : null,
          ),
      ],
      autoResize: _pick(TextAutoResize.values),
      maxLines: _p(0.2) ? 3 : null,
      alignHorizontal: _pick(TextAlignHorizontal.values),
    );
  }

  TextStyleOverride _override() => TextStyleOverride(
    fontFamilyId: _p(0.3) ? _pick(['fA', 'fB']) : null,
    fontWeight: _p(0.5) ? 100 * (1 + r.nextInt(9)) : null,
    italic: _p(0.2) ? true : null,
    fontVariations: _p(0.2) ? const {'wght': 650} : null,
    fontSize: _p(0.6) ? _num(8, 60) : null,
    lineHeight: _p(0.3)
        ? _pick(const [
            LineHeight.auto(),
            LineHeight.px(24),
            LineHeight.percent(130),
          ])
        : null,
    letterSpacing: _p(0.2) ? const LetterSpacing.px(-0.5) : null,
    textCase: _p(0.2) ? _pick(TextCase.values) : null,
    decoration: _p(0.2)
        ? TextDecoration(kind: _pick(TextDecorationKind.values))
        : null,
    fills: _p(0.3)
        ? [
            Paint.solid(
              id: 'text',
              color: StageColor(r: _frac(), g: 0, b: 0),
            ),
          ]
        : null,
    openType: _p(0.1) ? const {'liga': 1} : null,
    baselineShift: _p(0.1) ? BaselineShift.superscript : null,
  );

  ShapeNode _shape() {
    final id = _id('sh');
    _leafIds.add(id);
    return ShapeNode(
      common: _common(id, fills: true),
      geometry: switch (r.nextInt(5)) {
        0 => const ShapeGeometry.rectangle(),
        1 => ShapeGeometry.ellipse(arcEnd: _num(90, 360)),
        2 => const ShapeGeometry.line(),
        3 => ShapeGeometry.polygon(pointCount: 3 + r.nextInt(5)),
        _ => ShapeGeometry.star(pointCount: 4 + r.nextInt(4)),
      },
      appearance: _appearance(),
    );
  }

  VideoNode _video() {
    final id = _id('vd');
    _leafIds.add(id);
    return VideoNode(
      common: _common(id, fills: true),
      assetId: 'aVid',
      posterAssetId: _p(0.5) ? 'aImg1' : null,
      appearance: _appearance(),
      scaleMode: _pick(ImageScaleMode.values),
      muted: _p(0.5),
    );
  }

  EmbedNode _embed() {
    final id = _id('em');
    _leafIds.add(id);
    return EmbedNode(
      common: _common(id),
      assetId: 'aLottie',
      inputs: const {'speed': IrValue.number(2)},
      inputBindings: {'progress': _tl},
    );
  }

  InstanceNode _instance() {
    final id = _id('in');
    final useVariant = _p(0.3);
    final comp = _pick(_comps);
    final inner = _inner[comp.id]!;
    final node = InstanceNode(
      common: _common(id),
      source: useVariant
          ? InstanceSource.variant(
              variantSetId: 'vsMain',
              variantValues: {
                'size': _pick(['small', 'large']),
              },
            )
          : InstanceSource.component(comp.id),
      propValues: {
        if (_p(0.7)) 'pText': IrValue.string('Hi $id'),
        if (_p(0.4)) 'pShow': IrValue.boolean(_p(0.5)),
        if (_p(0.2)) 'pSwap': IrValue.string(_pick(_comps).id),
      },
      overrides: useVariant
          ? const {}
          : {
              if (_p(0.6))
                inner.label: {
                  'style.fontWeight': const IrValue.number(700),
                  'style.fills': const IrValue.paints([
                    Paint.solid(id: 'text', color: StageColor.white),
                  ]),
                },
              if (_p(0.4))
                inner.root: {
                  'fills.f0.color': IrValue.color(
                    StageColor(r: _frac(), g: 0, b: 0),
                  ),
                },
              if (inner.nested != null && _p(0.5))
                '${comp.id}_nested/${_inner[inner.nested]!.label}': {
                  'style.fontSize': const IrValue.number(33),
                },
            },
    );
    if (!useVariant) _instances.add(node);
    return node;
  }

  // Tracks ---------------------------------------------------------------

  static const _numberProps = [
    'x',
    'y',
    'width',
    'height',
    'rotation',
    'opacity',
    'motion.translateX',
    'motion.scaleX',
  ];

  List<Track> _tracks(List<Clock> clocks) {
    final tracks = <Track>[];
    final targets = [..._frameIds, ..._leafIds];
    final sceneClockIds = [for (final c in clocks) c.id];
    final count = r.nextInt(7);
    for (var i = 0; i < count; i++) {
      final target = _pick(targets);
      final prop = _pick(_numberProps);
      tracks.add(
        Track(
          id: _id('trk'),
          target: target,
          property: prop,
          clockId: _pick(sceneClockIds),
          keyframes: _keyframes(2 + r.nextInt(3), prop),
          breakpoints: _p(0.2) ? [_pick(_bps)] : null,
        ),
      );
    }
    // Colour track on a frame's fill, if any frame has the paint.
    tracks.add(
      Track(
        id: _id('trk'),
        target: _pick(_frameIds),
        property: 'visible',
        clockId: _tl,
        keyframes: [
          Keyframe(id: _id('kf'), t: 0, value: const IrValue.boolean(true)),
          Keyframe(id: _id('kf'), t: 1, value: const IrValue.boolean(false)),
        ],
      ),
    );
    // Every easing kind on one track.
    final easings = <Easing>[
      const Easing.linear(),
      const Easing.cubicBezier(0.1, 0.2, 0.3, 1.1),
      for (final p in EasingPreset.values) Easing.preset(p),
      const Easing.spring(mass: 1, stiffness: 120, damping: 12),
      const Easing.steps(4, position: StepPosition.jumpStart),
      const Easing.steps(3),
      const Easing.hold(),
    ];
    tracks.add(
      Track(
        id: _id('trk'),
        target: _pick(targets),
        property: 'x',
        clockId: _tl,
        keyframes: [
          for (var i = 0; i < easings.length; i++)
            Keyframe(
              id: _id('kf'),
              t: i.toDouble(),
              value: IrValue.number(i * 10.0),
              easing: easings[i],
            ),
        ],
      ),
    );
    // Namespaced target inside an instance.
    if (_instances.isNotEmpty) {
      final inst = _pick(_instances);
      final comp = (inst.source as ComponentSource).componentId;
      tracks.add(
        Track(
          id: _id('trk'),
          target: '${inst.id}/${_inner[comp]!.label}',
          property: 'opacity',
          clockId: _tl,
          keyframes: _keyframes(2, 'opacity'),
        ),
      );
    }
    return tracks;
  }

  List<Keyframe> _keyframes(int n, String prop) {
    var t = 0.0;
    return [
      for (var i = 0; i < n; i++)
        () {
          t += _frac() + 0.01;
          return Keyframe(
            id: _id('kf'),
            t: t,
            value: IrValue.number(prop == 'opacity' ? _frac() : _num()),
            easing: _pick(const [
              Easing.linear(),
              Easing.preset(EasingPreset.easeInOut),
              Easing.hold(),
            ]),
          );
        }(),
    ];
  }
}
