import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'doc_generator.dart';
import 'mutations.dart';

const _seeds = 200;

/// Runs [body] for every seed; any failure reports the seed.
void forSeeds(String what, void Function(int seed) body) {
  test(what, () {
    for (var seed = 0; seed < _seeds; seed++) {
      try {
        body(seed);
      } on TestFailure catch (e) {
        fail('seed $seed: ${e.message}');
      } on Object catch (e, st) {
        fail('seed $seed threw: $e\n$st');
      }
    }
  });
}

String _describe(Iterable<IrDiagnostic> ds) => ds
    .map((d) => '${d.severity.name} ${d.code} @ ${d.location}: ${d.message}')
    .join('\n');

// ---- Random patches ---------------------------------------------------------

const _validPaths = [
  'name',
  'visible',
  'opacity',
  'x',
  'y',
  'width',
  'height',
  'rotation',
  'flipX',
  'role',
  'readingOrder',
  'altText',
  'motion.translateX',
  'motion.scaleY',
  'layoutChild.positioning',
  'layoutChild.constraints.horizontal',
  'clipContent',
  'autoLayout',
  'autoLayout.gap',
  'autoLayout.padding',
  'autoLayout.direction',
  'fills',
  'fills.f0.color',
  'fills.f0.opacity',
  'fills.f1.stops.0.color',
  'strokes.weight',
  'strokes.paints',
  'effects',
  'effects.e0.blur',
  'cornerRadius',
  'cornerRadius.tl',
  'characters',
  'textStyleId',
  'style.fontSize',
  'style.fontWeight',
  'style.lineHeight',
  'style.fills',
  'style.fontVariations.wght',
  'style.decoration.kind',
  'content.0.style.alignHorizontal',
  'content.0.spans.0.style.fontSize',
  'content.0.spans.0.style.fills',
  'geometry.pointCount',
  'assetId',
  'componentId',
  'propValues.pText',
  'variantValues.size',
];

const _invalidPaths = [
  '',
  '.',
  'nope',
  'a.b.c.d.e',
  'fills..color',
  'fills.f0.color.extra',
  'style',
  'style.fontSize.x',
  'content.x.style.fontSize',
  'content.-1.style.fontSize',
  'content.0.spans.99.style.fontSize',
  'fills.zz.color',
  'effects.zz.blur',
  'opacity.',
  '.opacity',
  'X',
  'motion',
  'layoutChild',
  'breakpointOverrides',
  'children',
];

List<IrValue> _values(Random r) => [
  IrValue.number((r.nextDouble() * 200 - 50).roundToDouble()),
  const IrValue.number(double.maxFinite),
  const IrValue.boolean(true),
  const IrValue.string('hello'),
  const IrValue.enumValue('center'),
  const IrValue.enumValue('nonsense'),
  const IrValue.color(StageColor.white),
  const IrValue.size(StageSize(width: 1, height: 2)),
  const IrValue.point(StagePoint(x: 1, y: 2)),
  const IrValue.gap(Gap.auto()),
  const IrValue.insets(EdgeInsetsValue(top: 1, left: 2)),
  const IrValue.cornerRadius(CornerRadius.uniform(4)),
  const IrValue.strokeWeight(StrokeWeight.uniform(3)),
  const IrValue.lineHeight(LineHeight.px(20)),
  const IrValue.letterSpacing(LetterSpacing.percent(5)),
  const IrValue.paints([Paint.solid(id: 'p', color: StageColor.black)]),
  const IrValue.paint(Paint.solid(id: 'p', color: StageColor.black)),
  const IrValue.effects([Effect.dropShadow(id: 'd')]),
  const IrValue.numbers([1, 2]),
  const IrValue.tokenRef(TokenRef(variableId: 'vNum')),
  const IrValue.tokenRef(TokenRef(variableId: 'missing')),
  const IrValue.none(),
];

void main() {
  group('serialisation', () {
    forSeeds('JSON round trip is exact', (seed) {
      final doc = DocGen(seed).build();
      final encoded = jsonEncode(doc.toJson());
      final back = StageDocument.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(back, doc);
      expect(jsonEncode(back.toJson()), encoded);
      // The migrating entry point agrees.
      expect(
        StageDocument.fromJsonMigrating(
          jsonDecode(encoded) as Map<String, Object?>,
        ),
        doc,
      );
    });

    forSeeds('loadDocument never throws and loads generated documents clean', (
      seed,
    ) {
      final doc = DocGen(seed).build();
      final result = loadDocument(jsonDecode(jsonEncode(doc.toJson())));
      expect(result.loaded, isTrue, reason: _describe(result.diagnostics));
      expect(result.document, doc);
      expect(
        result.diagnostics,
        isEmpty,
        reason: _describe(result.diagnostics),
      );
      // From a string too.
      expect(loadDocument(jsonEncode(doc.toJson())).document, doc);
    });

    forSeeds('loadDocument survives mangled input', (seed) {
      final r = Random(seed);
      final json = jsonDecode(jsonEncode(DocGen(seed).build().toJson()));
      // Delete or replace a random node of the JSON tree.
      void mangle(Object? node) {
        if (node is Map<String, dynamic> && node.isNotEmpty) {
          final keys = node.keys.toList();
          final k = keys[r.nextInt(keys.length)];
          switch (r.nextInt(4)) {
            case 0:
              node.remove(k);
            case 1:
              node[k] = r.nextBool() ? 42 : 'junk';
            case 2:
              node[k] = null;
            default:
              mangle(node[k]);
          }
        } else if (node is List && node.isNotEmpty) {
          mangle(node[r.nextInt(node.length)]);
        }
      }

      for (var i = 0; i < 1 + r.nextInt(4); i++) {
        mangle(json);
      }
      final result = loadDocument(json);
      if (!result.loaded) {
        expect(
          result.diagnostics.single.kind,
          IrDiagnosticKind.invalidDocument,
        );
      }
    });
  });

  test('generated documents cover every node kind, easing and behaviour', () {
    final types = <String>{};
    var nodes = 0;
    void scan(Object? j) {
      if (j is Map) {
        final t = j['type'];
        if (t is String) types.add(t);
        j.values.forEach(scan);
      } else if (j is List) {
        j.forEach(scan);
      }
    }

    for (var seed = 0; seed < _seeds; seed++) {
      final doc = DocGen(seed).build();
      scan(doc.toJson());
      nodes += sceneNodes(doc).length;
    }
    expect(nodes ~/ _seeds, greaterThan(10));
    expect(
      types,
      containsAll(<String>[
        // node kinds and shapes
        'frame', 'text', 'shape', 'instance', 'video', 'embed',
        'rectangle', 'ellipse', 'line', 'polygon', 'star',
        // instance sources
        'component', 'variant',
        // easings
        'linear', 'cubicBezier', 'preset', 'spring', 'steps', 'hold',
        // clocks
        'sceneScroll', 'timeline', 'audio', 'pointer', 'behavior',
        // behaviours
        'carousel', 'lightbox', 'marquee', 'textReveal', 'lyrics',
        'audioControls',
        // triggers and actions
        'tap', 'hoverEnter', 'hoverLeave', 'sceneEnter', 'sceneLeave',
        'audioCue', 'clockReach', 'playTimeline', 'pauseTimeline',
        'seekTimeline', 'reverseTimeline', 'playAudio', 'pauseAudio',
        'seekAudio', 'setVariable', 'scrollToScene', 'openUrl', 'openLightbox',
        // paints, effects, values
        'solid', 'gradient', 'image', 'dropShadow', 'innerShadow',
        'layerBlur', 'backgroundBlur', 'tokenRef', 'color', 'number',
        'paints', 'string', 'bool', 'url', 'scene', 'story',
      ]),
    );
  });

  group('validator', () {
    forSeeds('generated documents validate clean', (seed) {
      final doc = DocGen(seed).build();
      final diags = validateDocument(doc);
      expect(diags, isEmpty, reason: _describe(diags));
    });

    forSeeds('dangling references produce diagnostics, not exceptions', (seed) {
      final r = Random(seed);
      final doc = DocGen(seed).build();
      var applied = 0;
      for (final m in mutations) {
        final broken = m.apply(doc, r);
        if (broken == null) continue;
        applied++;
        final diags = validateDocument(broken);
        expect(
          hasErrors(diags),
          isTrue,
          reason: 'mutation "${m.name}" was not detected',
        );
        for (final d in diags) {
          expect(d.location, isNotNull, reason: '${m.name}: ${d.code}');
        }
        // The resolver survives the same document.
        resolveDocument(broken);
        resolveDocument(
          broken,
          ResolveContext(breakpointId: broken.breakpoints.last.id),
        );
        // And loading it reports the problem without failing.
        if (seed % 5 == 0) {
          final loaded = loadDocument(jsonDecode(jsonEncode(broken.toJson())));
          expect(loaded.loaded, isTrue, reason: m.name);
          expect(loaded.clean, isFalse, reason: m.name);
        }
      }
      expect(applied, greaterThan(20));
    });
  });

  group('resolver', () {
    forSeeds('never throws, is deterministic and clean on valid documents', (
      seed,
    ) {
      final doc = DocGen(seed).build();
      final contexts = [
        const ResolveContext(),
        for (final b in doc.breakpoints) ResolveContext(breakpointId: b.id),
        const ResolveContext(viewportWidth: 700),
        const ResolveContext(
          modeState: {'colMode': 'dark', 'colSize': 'compact'},
        ),
        const ResolveContext(variableState: {'vNum': IrValue.number(9)}),
      ];
      for (final ctx in contexts) {
        final a = resolveDocument(doc, ctx);
        final b = resolveDocument(doc, ctx);
        expect(a, b, reason: 'resolving twice differs for $ctx');
        expect(a.diagnostics, isEmpty, reason: _describe(a.diagnostics));
        // A long-lived resolver agrees with a fresh one.
        if (ctx == contexts.first) {
          final long = Resolver();
          expect(long.resolve(doc, ctx), a);
          expect(long.resolve(doc, ctx), a);
        }
      }
    });

    forSeeds('incremental re-resolve equals a fresh resolve after edits', (
      seed,
    ) {
      final r = Random(seed);
      var doc = DocGen(seed).build();
      final long = Resolver();
      final ctx = ResolveContext(
        breakpointId: doc.breakpoints[r.nextInt(doc.breakpoints.length)].id,
      );
      long.resolve(doc, ctx);
      for (var step = 0; step < 6; step++) {
        final nodes = sceneNodes(doc);
        final target = nodes[r.nextInt(nodes.length)];
        final edited = switch (r.nextInt(4)) {
          0 => editNode(
            doc,
            target.id,
            (n) =>
                n.copyWith(common: n.common.copyWith(opacity: r.nextDouble())),
          ),
          1 => editNode(
            doc,
            target.id,
            (n) =>
                n.copyWith(common: n.common.copyWith(x: r.nextDouble() * 99)),
          ),
          2 => editNode(
            doc,
            target.id,
            (n) => n is FrameNode
                ? n.copyWith(
                    modeOverrides: {'colMode': r.nextBool() ? 'dark' : 'light'},
                  )
                : n,
          ),
          _ => editNode(
            doc,
            target.id,
            (n) => n is TextNode
                ? n.copyWith(
                    style: TextStyleOverride(fontSize: r.nextDouble() * 40 + 1),
                  )
                : n,
          ),
        };
        doc = edited ?? doc;
        // Occasionally change a shared input (tokens) so the memo must reset.
        if (step == 3 && r.nextBool()) {
          doc = doc.copyWith(
            defaultTextStyle: doc.defaultTextStyle.copyWith(fontSize: 31),
          );
        }
        final incremental = long.resolve(doc, ctx);
        expect(incremental, Resolver().resolve(doc, ctx), reason: 'step $step');
      }
    });

    forSeeds('every resolved text span has a complete style', (seed) {
      final doc = DocGen(seed).build();
      final out = resolveDocument(doc);
      for (final n in out.nodeIndex.values) {
        for (final p in n.paragraphs ?? const <ResolvedParagraph>[]) {
          for (final s in p.spans) {
            expect(s.style.fontSize, greaterThan(0));
            expect(s.style.fills, isNotEmpty);
          }
        }
      }
    });
  });

  group('patches', () {
    forSeeds('applyPatch never throws; unknown paths yield diagnostics', (
      seed,
    ) {
      final r = Random(seed);
      final nodes = sceneNodes(DocGen(seed).build());
      final values = _values(r);
      for (var i = 0; i < 25; i++) {
        final node = nodes[r.nextInt(nodes.length)];
        final patch = <String, IrValue>{
          for (var k = 0; k < 1 + r.nextInt(4); k++)
            (r.nextBool()
                    ? _validPaths[r.nextInt(_validPaths.length)]
                    : _invalidPaths[r.nextInt(_invalidPaths.length)]):
                values[r.nextInt(values.length)],
        };
        final diags = <IrDiagnostic>[];
        final out = applyPatch(node, patch, diagnostics: diags);
        // Every path that no descriptor matches is reported.
        final unknown = patch.keys.where(
          (p) => PropertyRegistry.standard.lookup(p) == null,
        );
        expect(
          diags
              .where((d) => d.kind == IrDiagnosticKind.unknownPath)
              .map((d) => d.path)
              .toSet(),
          unknown.toSet(),
        );
        // The node keeps its kind and id.
        expect(out.runtimeType, node.runtimeType);
        expect(out.id, node.id);
        // Patching is deterministic.
        expect(applyPatch(node, patch), out);
      }
    });

    forSeeds('invalid paths alone leave the node untouched', (seed) {
      final r = Random(seed);
      final nodes = sceneNodes(DocGen(seed).build());
      final node = nodes[r.nextInt(nodes.length)];
      final diags = <IrDiagnostic>[];
      final out = applyPatch(node, {
        for (final p in _invalidPaths.where(
          (p) => PropertyRegistry.standard.lookup(p) == null,
        ))
          p: const IrValue.number(1),
      }, diagnostics: diags);
      expect(identical(out, node) || out == node, isTrue);
      expect(diags, isNotEmpty);
    });

    forSeeds('registry get/trySet never throw on arbitrary input', (seed) {
      final r = Random(seed);
      final nodes = sceneNodes(DocGen(seed).build());
      final values = _values(r);
      const reg = [
        'fills.f0.color',
        'style.fontSize',
        'x',
        '',
        'a.b',
        'content.0.spans.0.style.fills',
      ];
      for (final node in nodes.take(30)) {
        for (final p in [..._validPaths, ..._invalidPaths, ...reg]) {
          PropertyRegistry.standard.get(node, p);
          PropertyRegistry.standard.trySet(
            node,
            p,
            values[r.nextInt(values.length)],
          );
        }
      }
    });
  });

  group('ids', () {
    forSeeds('a document-aware generator never reissues a document id', (seed) {
      final doc = StageDocument.empty(ids: IdGenerator.seeded(seed));
      final json = jsonEncode(doc.toJson());
      final gen = IdGenerator.forDocument(doc, random: Random(seed));
      for (var i = 0; i < 200; i++) {
        final id = gen.next();
        expect(json.contains(id), isFalse);
      }
    });
  });
}
