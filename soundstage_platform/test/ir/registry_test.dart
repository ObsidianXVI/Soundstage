import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _paints = <Paint>[
  Paint.solid(id: 'solid', color: StageColor.black),
  Paint.gradient(
    id: 'gradient',
    stops: [
      ColorStop(position: 0, color: StageColor.black),
      ColorStop(position: 1, color: StageColor.white),
    ],
  ),
  Paint.image(id: 'image', assetId: 'aImg'),
];
const _effects = <Effect>[
  Effect.dropShadow(id: 'dropShadow'),
  Effect.innerShadow(id: 'innerShadow'),
  Effect.layerBlur(id: 'layerBlur'),
  Effect.backgroundBlur(id: 'backgroundBlur'),
];
const _appearance = Appearance(
  fills: _paints,
  strokes: Stroke(paints: _paints),
  effects: _effects,
);
const _c = NodeCommon(id: 'n');

/// Nodes of every kind with every stack entry kind present, so each
/// descriptor has somewhere to land.
const Map<NodeKind, List<Node>> _nodes = {
  NodeKind.frame: [
    FrameNode(common: _c, appearance: _appearance, autoLayout: AutoLayout()),
    FrameNode(common: _c, grid: GridLayout()),
  ],
  NodeKind.text: [
    TextNode(
      common: _c,
      appearance: TextAppearance(
        strokes: Stroke(paints: _paints),
        effects: _effects,
      ),
      style: TextStyleOverride(fills: _paints),
      content: [
        Paragraph(
          spans: [
            Span(
              text: 'Hello',
              style: TextStyleOverride(fills: _paints),
            ),
            Span(text: ' world'),
          ],
        ),
        Paragraph(spans: [Span(text: 'Second')]),
      ],
    ),
  ],
  NodeKind.shape: [
    ShapeNode(common: _c, appearance: _appearance),
    ShapeNode(common: _c, geometry: ShapeGeometry.ellipse()),
    ShapeNode(common: _c, geometry: ShapeGeometry.polygon()),
    ShapeNode(common: _c, geometry: ShapeGeometry.star()),
  ],
  NodeKind.instance: [
    InstanceNode(common: _c, source: InstanceSource.component('cmp')),
    InstanceNode(
      common: _c,
      source: InstanceSource.variant(
        variantSetId: 'vs',
        variantValues: {'size': 's'},
      ),
    ),
  ],
  NodeKind.video: [
    VideoNode(common: _c, assetId: 'aVid', appearance: _appearance),
  ],
  NodeKind.embed: [EmbedNode(common: _c, assetId: 'aRive')],
};

const _candidates = <String, List<String>>{
  'paintId': ['solid', 'gradient', 'image'],
  'effectId': ['dropShadow', 'innerShadow', 'layerBlur', 'backgroundBlur'],
  'paragraphIndex': ['0', '1'],
  'spanIndex': ['0', '1'],
  'stopIndex': ['0', '1'],
};

Iterable<Map<String, String>> _combos(List<String> names) sync* {
  if (names.isEmpty) {
    yield const {};
    return;
  }
  for (final rest in _combos(names.sublist(1))) {
    for (final v in _candidates[names.first] ?? const ['wght']) {
      yield {names.first: v, ...rest};
    }
  }
}

/// Sample values for a descriptor (more than one where the first may be a
/// no-op or out of range).
List<IrValue> _samples(PropertyDescriptor d, Map<String, String> params) {
  final id = params['paintId'] ?? params['effectId'] ?? 'x';
  return switch (d.valueType) {
    IrValueType.number => const [IrValue.number(3), IrValue.number(90)],
    IrValueType.color => const [
      IrValue.color(StageColor(r: 0.2, g: 0.4, b: 0.6, a: 0.8)),
    ],
    IrValueType.boolean => const [
      IrValue.boolean(true),
      IrValue.boolean(false),
    ],
    IrValueType.string => const [IrValue.string('abc')],
    IrValueType.enumValue => [
      for (final e in d.enumValues!) IrValue.enumValue(e),
    ],
    IrValueType.size => const [IrValue.size(StageSize(width: 3, height: 4))],
    IrValueType.point => const [IrValue.point(StagePoint(x: 0.25, y: 0.75))],
    IrValueType.insets => const [
      IrValue.insets(EdgeInsetsValue(top: 1, right: 2, bottom: 3, left: 4)),
    ],
    IrValueType.cornerRadius => const [
      IrValue.cornerRadius(CornerRadius.perCorner(tl: 1, tr: 2, br: 3, bl: 4)),
      IrValue.cornerRadius(CornerRadius.uniform(6)),
    ],
    IrValueType.strokeWeight => const [
      IrValue.strokeWeight(
        StrokeWeight.perSide(top: 1, right: 2, bottom: 3, left: 4),
      ),
      IrValue.strokeWeight(StrokeWeight.uniform(2)),
    ],
    IrValueType.gap => const [
      IrValue.gap(Gap.fixed(7)),
      IrValue.gap(Gap.auto()),
    ],
    IrValueType.paint => [
      IrValue.paint(Paint.solid(id: id, color: StageColor.white, opacity: 0.5)),
    ],
    IrValueType.paints => const [
      IrValue.paints([Paint.solid(id: 'z', color: StageColor.white)]),
    ],
    IrValueType.effect => [IrValue.effect(Effect.layerBlur(id: id, radius: 9))],
    IrValueType.effects => const [
      IrValue.effects([Effect.backgroundBlur(id: 'z', radius: 2)]),
    ],
    IrValueType.lineHeight => const [
      IrValue.lineHeight(LineHeight.px(20)),
      IrValue.lineHeight(LineHeight.auto()),
    ],
    IrValueType.letterSpacing => const [
      IrValue.letterSpacing(LetterSpacing.px(1.5)),
    ],
    IrValueType.numbers => const [
      IrValue.numbers([4, 2]),
    ],
    IrValueType.any => const [IrValue.number(5), IrValue.string('on')],
  };
}

void main() {
  final reg = PropertyRegistry.standard;

  group('registry walk', () {
    test('has a broad property table', () {
      expect(reg.descriptors.length, greaterThan(200));
    });

    for (final d in PropertyRegistry.standard.descriptors) {
      test(d.pathPattern, () {
        for (final kind in d.appliesTo) {
          var landed = false;
          for (final node in _nodes[kind]!) {
            for (final params in _combos(d.paramNames)) {
              var accepted = 0;
              for (final v in _samples(d, params)) {
                final set = d.trySet(node, v, params);
                if (set == null) continue;
                accepted++;
                expect(d.get(set, params), v, reason: '$v on ${kind.name}');
              }
              if (accepted == 0) continue;
              landed = true;
              if (d.nullable) {
                final cleared = d.trySet(node, const IrValue.none(), params);
                expect(cleared, isNotNull, reason: 'none on $kind');
                // Cleared reads as none, or as the default for presence flags.
                expect(
                  d.get(cleared!, params),
                  anyOf(const IrValue.none(), d.defaultValue),
                );
              }
            }
          }
          expect(landed, isTrue, reason: '${d.pathPattern} on ${kind.name}');
        }
        // A kind the property does not apply to reads null and rejects writes.
        for (final kind in NodeKind.values.where(
          (k) => !d.appliesTo.contains(k),
        )) {
          final node = _nodes[kind]!.first;
          expect(d.get(node), isNull);
          expect(d.trySet(node, _samples(d, const {}).first), isNull);
        }
      });
    }

    test('every descriptor round-trips through lookup', () {
      for (final d in reg.descriptors) {
        final concrete = d.patternSegments
            .map(
              (s) => isPatternParam(s) ? (s.contains('Index') ? '0' : 'id') : s,
            )
            .join('.');
        expect(reg.lookup(concrete)?.descriptor, same(d), reason: concrete);
      }
    });
  });

  group('lookup', () {
    test('binds params', () {
      final m = reg.lookup('content.3.spans.12.style.fontWeight')!;
      expect(
        m.descriptor.pathPattern,
        'content.<paragraphIndex>.spans.<spanIndex>.style.fontWeight',
      );
      expect(m.params, {'paragraphIndex': '3', 'spanIndex': '12'});
      expect(reg.lookup('fills.p1.color')!.params, {'paintId': 'p1'});
      expect(reg.lookup('effects.e1.blur')!.params, {'effectId': 'e1'});
    });

    test('spec examples resolve', () {
      for (final p in [
        'opacity',
        'motion.translateY',
        'autoLayout.gap',
        'fills.p.color',
        'fills.p.opacity',
        'fills.p.stops.1.color',
        'fills.p.focalPoint',
        'strokes.weight',
        'effects.e.blur',
        'style.fontSize',
        'style.fills.p.color',
        'content.0.spans.2.style.fontWeight',
        'layoutChild.constraints.horizontal',
        'fills',
        'effects',
      ]) {
        expect(reg.lookup(p), isNotNull, reason: p);
      }
    });

    test('unknown paths return null and never throw', () {
      for (final p in [
        '',
        'nope',
        'opacity.extra',
        'fills',
        'content.x.spans.0.text', // index params must be integers
        'motion.',
        '..',
        'fills.p.colour',
      ].skip(0)) {
        if (p == 'fills') continue;
        expect(reg.lookup(p), isNull, reason: p);
      }
      const node = FrameNode(common: _c);
      expect(reg.get(node, 'nope'), isNull);
      expect(reg.trySet(node, 'nope', const IrValue.number(1)), isNull);
    });

    test('metadata', () {
      expect(
        reg.lookup('opacity')!.descriptor.invalidation,
        Invalidation.compositing,
      );
      expect(
        reg.lookup('motion.scaleX')!.descriptor.invalidation,
        Invalidation.compositing,
      );
      expect(
        reg.lookup('fills.p.color')!.descriptor.invalidation,
        Invalidation.paint,
      );
      expect(
        reg.lookup('effects.e.blur')!.descriptor.invalidation,
        Invalidation.paint,
      );
      expect(reg.lookup('width')!.descriptor.invalidation, Invalidation.layout);
      expect(
        reg.lookup('autoLayout.padding.top')!.descriptor.invalidation,
        Invalidation.layout,
      );
      expect(
        reg.lookup('style.fontSize')!.descriptor.invalidation,
        Invalidation.layout,
      );
      expect(
        reg.lookup('style.letterSpacing')!.descriptor.invalidation,
        Invalidation.layout,
      );
      expect(
        reg.lookup('opacity')!.descriptor.defaultValue,
        const IrValue.number(1),
      );
      expect(
        reg.lookup('motion.scaleX')!.descriptor.defaultValue,
        const IrValue.number(1),
      );
      expect(
        reg.lookup('layoutChild.maxWidth')!.descriptor.defaultValue,
        const IrValue.none(),
      );
      expect(
        reg.lookup('fills.p.opacity')!.descriptor.defaultValue,
        const IrValue.number(1),
      );
      expect(
        reg.lookup('autoLayout')!.descriptor.defaultValue,
        const IrValue.boolean(false),
      );
      expect(
        reg.lookup('visible')!.descriptor.interpolation,
        Interpolation.step,
      );
      expect(
        reg.lookup('blendMode')!.descriptor.interpolation,
        Interpolation.step,
      );
      expect(
        reg.lookup('opacity')!.descriptor.interpolation,
        Interpolation.continuous,
      );
      expect(reg.lookup('name')!.descriptor.animatable, isFalse);
      expect(
        reg.lookup('opacity')!.descriptor.appliesTo,
        NodeKind.values.toSet(),
      );
      expect(
        reg.lookup('strokes.weight')!.descriptor.appliesTo,
        contains(NodeKind.text),
      );
      expect(
        reg.lookup('cornerRadius')!.descriptor.appliesTo,
        contains(NodeKind.video),
      );
      expect(
        reg.lookup('cornerRadius')!.descriptor.appliesTo,
        isNot(contains(NodeKind.text)),
      );
    });
  });

  group('setters', () {
    test('wrong value types are rejected', () {
      const node = FrameNode(common: _c);
      expect(reg.trySet(node, 'opacity', const IrValue.string('x')), isNull);
      expect(reg.trySet(node, 'opacity', const IrValue.none()), isNull);
      expect(
        reg.trySet(node, 'blendMode', const IrValue.enumValue('bogus')),
        isNull,
      );
      expect(
        reg.trySet(node, 'opacity', const IrValue.number(double.nan)),
        isNull,
      );
    });

    test('numbers coerce into radii, weights and gaps', () {
      final f = _nodes[NodeKind.frame]!.first;
      final r = reg.trySet(f, 'cornerRadius', const IrValue.number(8))!;
      expect(
        (r as FrameNode).appearance.cornerRadius,
        const CornerRadius.uniform(8),
      );
      final g = reg.trySet(f, 'autoLayout.gap', const IrValue.number(12))!;
      expect((g as FrameNode).autoLayout!.gap, const Gap.fixed(12));
    });

    test('a per-corner write expands a uniform radius', () {
      const f = FrameNode(
        common: _c,
        appearance: Appearance(cornerRadius: CornerRadius.uniform(4)),
      );
      final r =
          reg.trySet(f, 'cornerRadius.tl', const IrValue.number(10))!
              as FrameNode;
      expect(
        r.appearance.cornerRadius,
        const CornerRadius.perCorner(tl: 10, tr: 4, br: 4, bl: 4),
      );
    });

    test(
      'auto layout fields need auto layout; turning it on replaces a grid',
      () {
        const free = FrameNode(common: _c, grid: GridLayout());
        expect(reg.get(free, 'autoLayout.gap'), isNull);
        expect(
          reg.trySet(free, 'autoLayout.gap', const IrValue.number(4)),
          isNull,
        );
        final on =
            reg.trySet(free, 'autoLayout', const IrValue.boolean(true))!
                as FrameNode;
        expect(on.autoLayout, const AutoLayout());
        expect(on.grid, isNull);
        final off =
            reg.trySet(on, 'autoLayout', const IrValue.none())! as FrameNode;
        expect(off.autoLayout, isNull);
      },
    );

    test('paint ids are kept when a whole paint is replaced', () {
      final f = _nodes[NodeKind.frame]!.first;
      final r =
          reg.trySet(
                f,
                'fills.solid',
                const IrValue.paint(
                  Paint.solid(id: 'other', color: StageColor.white),
                ),
              )!
              as FrameNode;
      expect(r.appearance.fills.first.id, 'solid');
      expect(reg.get(f, 'fills.missing.color'), isNull);
      expect(reg.get(f, 'fills.gradient.color'), isNull); // not a solid
    });

    test('characters rewrites content from the first span style', () {
      final t = _nodes[NodeKind.text]!.first as TextNode;
      expect(
        reg.get(t, 'characters'),
        const IrValue.string('Hello world\nSecond'),
      );
      final r =
          reg.trySet(t, 'characters', const IrValue.string('A\nB\nC'))!
              as TextNode;
      expect(r.content.length, 3);
      expect(
        r.content.every(
          (p) => p.spans.single.style == t.content.first.spans.first.style,
        ),
        isTrue,
      );
    });

    test('image rotation only takes quarter turns', () {
      final f = _nodes[NodeKind.frame]!.first;
      expect(
        reg.trySet(f, 'fills.image.rotation', const IrValue.number(45)),
        isNull,
      );
      final r = reg.trySet(
        f,
        'fills.image.rotation',
        const IrValue.number(-90),
      )!;
      expect(reg.get(r, 'fills.image.rotation'), const IrValue.number(270));
    });
  });

  group('applyPatch', () {
    const node = FrameNode(
      common: NodeCommon(
        id: 'f',
        opacity: 0.5,
        layoutChild: LayoutChild(maxWidth: 300),
        bindings: {'opacity': TokenRef(variableId: 'vOp')},
      ),
    );

    test('writes values and clears with none', () {
      final diags = <IrDiagnostic>[];
      final r = applyPatch(node, {
        'x': const IrValue.number(10),
        'layoutChild.maxWidth': const IrValue.none(),
      }, diagnostics: diags);
      expect(r.common.x, 10);
      expect(r.common.layoutChild.maxWidth, isNull);
      expect(diags, isEmpty);
    });

    test('unknown and inapplicable paths are skipped and reported', () {
      final diags = <IrDiagnostic>[];
      final r = applyPatch(node, {
        'bogus.path': const IrValue.number(1),
        'style.fontSize': const IrValue.number(20), // text only
        'opacity': const IrValue.string('nope'), // wrong type
        'y': const IrValue.number(5),
      }, diagnostics: diags);
      expect(r.common.y, 5);
      expect(r.common.opacity, 0.5);
      expect(diags.map((d) => (d.kind, d.path)), [
        (IrDiagnosticKind.unknownPath, 'bogus.path'),
        (IrDiagnosticKind.inapplicablePath, 'style.fontSize'),
        (IrDiagnosticKind.inapplicablePath, 'opacity'),
      ]);
      expect(diags.every((d) => d.nodeId == 'f'), isTrue);
    });

    test('a concrete value detaches the token binding at that path', () {
      final r = applyPatch(node, {'opacity': const IrValue.number(1)});
      expect(r.common.opacity, 1);
      expect(r.common.bindings, isEmpty);
    });

    test('a token ref value binds the path', () {
      final r = applyPatch(node, {
        'rotation': const IrValue.tokenRef(TokenRef(variableId: 'vRot')),
      });
      expect(r.common.bindings, {
        'opacity': const TokenRef(variableId: 'vOp'),
        'rotation': const TokenRef(variableId: 'vRot'),
      });
    });
  });
}
