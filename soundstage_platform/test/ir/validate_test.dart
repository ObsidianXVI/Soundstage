import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fuzz/doc_generator.dart';
import 'fuzz/mutations.dart';

Set<String> codes(Iterable<IrDiagnostic> d) => {for (final x in d) x.code};

void main() {
  final doc = DocGen(3).build();

  test('a generated document is clean', () {
    expect(validateDocument(doc), isEmpty);
  });

  test('a freshly created empty document is clean', () {
    expect(
      validateDocument(StageDocument.empty(ids: IdGenerator.seeded(1))),
      isEmpty,
    );
  });

  test('diagnostics carry severity, code and a location path', () {
    final broken = changeFirst<TextNode>(
      doc,
      (n) => n.copyWith(textStyleId: 'zzz'),
    )!;
    final d = validateDocument(broken).single;
    expect(d.severity, IrSeverity.error);
    expect(d.code, 'missingStyle');
    expect(d.kind, IrDiagnosticKind.missingStyle);
    expect(
      d.location,
      matches(r'^scenes\[\d+\]\.root(\.children\[\d+\])*\.textStyleId$'),
    );
    expect(d.nodeId, isNotNull);
  });

  test('duplicate node ids are reported document-wide and per component', () {
    final dup = mutations
        .firstWhere((m) => m.name == 'duplicate node id')
        .apply(doc, Random(0))!;
    expect(codes(validateDocument(dup)), {'duplicateNodeId'});

    final comp = doc.components.values.first;
    final inComp = doc.copyWith(
      components: {
        ...doc.components,
        comp.id: comp.copyWith(
          root: comp.root.copyWith(
            children: [...comp.root.children, comp.root.children.first],
          ),
        ),
      },
    );
    final d = validateDocument(
      inComp,
    ).where((x) => x.code == 'duplicateNodeId');
    expect(d, isNotEmpty);
    expect(d.first.location, startsWith('components.${comp.id}.root'));
  });

  test('the same inner id in different components is fine', () {
    // Components are separate id scopes.
    final a = doc.components.values.first;
    final b = a.copyWith(id: 'cmpTwin');
    final withTwin = doc.copyWith(
      components: {...doc.components, 'cmpTwin': b},
    );
    expect(
      validateDocument(withTwin).where((d) => d.code == 'duplicateNodeId'),
      isEmpty,
    );
  });

  test('track targets: base ids and namespaced instance ids resolve', () {
    final scene = doc.scenes.first;
    final ns = [
      for (final s in doc.scenes)
        for (final t in s.tracks)
          if (t.target.contains('/')) t,
    ];
    // Namespaced tracks are generated in most documents; if present they pass.
    for (final t in ns) {
      expect(t.target, contains('/'));
    }
    expect(validateDocument(doc), isEmpty);
    final bad = doc.copyWith(
      scenes: [
        scene.copyWith(
          tracks: [
            ...scene.tracks,
            Track(
              id: 'tBad',
              target: 'nope/also',
              property: 'x',
              clockId: scene.clocks.first.id,
            ),
          ],
        ),
        ...doc.scenes.skip(1),
      ],
    );
    expect(codes(validateDocument(bad)), {'missingTrackTarget'});
  });

  test('unknown property paths are warnings', () {
    final broken = changeFirst<ShapeNode>(
      doc,
      (n) => n.copyWith(
        common: n.common.copyWith(
          breakpointOverrides: {
            doc.breakpoints.first.id: {'no.such.path': const IrValue.number(1)},
          },
        ),
      ),
    )!;
    final d = validateDocument(broken).single;
    expect(d.code, 'unknownPath');
    expect(d.severity, IrSeverity.warning);
    expect(hasErrors([d]), isFalse);
  });

  test('assets of the wrong kind are warnings', () {
    final broken = changeFirst<VideoNode>(
      doc,
      (n) => n.copyWith(assetId: 'aAud0'),
    );
    if (broken == null) return;
    final d = validateDocument(broken).single;
    expect(d.code, 'wrongAssetKind');
    expect(d.severity, IrSeverity.warning);
  });

  group('loadDocument', () {
    test('loads, migrates and validates', () {
      final r = loadDocument(jsonDecode(jsonEncode(doc.toJson())));
      expect(r.document, doc);
      expect(r.clean, isTrue);
    });

    test('reports dangling references but still returns the document', () {
      final broken = doc.copyWith(baseBreakpointId: 'zzz');
      final r = loadDocument(broken.toJson());
      expect(r.loaded, isTrue);
      expect(r.clean, isFalse);
      expect(codes(r.diagnostics), contains('missingBreakpoint'));
    });

    test('never throws on non-documents', () {
      for (final input in <Object?>[
        null,
        42,
        'not json',
        '[]',
        <Object?>[],
        <String, Object?>{},
        {'schemaVersion': 'one'},
        {'schemaVersion': 99},
        {'schemaVersion': 1},
        {'schemaVersion': 1, 'id': 5},
        {...doc.toJson(), 'scenes': 'oops'},
        {
          ...doc.toJson(),
          'breakpoints': [1, 2],
        },
        <Object?, Object?>{1: 2},
      ]) {
        final r = loadDocument(input);
        expect(r.loaded, isFalse, reason: '$input');
        expect(r.diagnostics.single.kind, IrDiagnosticKind.invalidDocument);
        expect(r.diagnostics.single.severity, IrSeverity.error);
        expect(r.clean, isFalse);
      }
    });
  });

  group('IdGenerator.forDocument', () {
    test('skips every id already in the document, retrying on collision', () {
      final d = StageDocument.empty(ids: IdGenerator.seeded(5));
      // A Random that first replays the ids already used.
      final replay = IdGenerator.seeded(5);
      final used = [for (var i = 0; i < 4; i++) replay.next()];
      final gen = IdGenerator.forDocument(d, random: Random(5));
      final fresh = {for (var i = 0; i < 50; i++) gen.next()};
      expect(fresh.length, 50);
      expect(fresh.intersection(used.toSet()), isEmpty);
      // Same seed as the document's generator: without reservation the first
      // ids would repeat the document's.
      final naive = IdGenerator.seeded(5);
      final collisions = [for (var i = 0; i < 4; i++) naive.next()];
      expect(collisions, used);
    });

    test('reserved ids are never issued', () {
      final gen = IdGenerator.seeded(1)..reserve(['x']);
      final probe = IdGenerator.seeded(1);
      final first = probe.next();
      gen.reserve([first]);
      expect(gen.next(), isNot(first));
      expect(gen.reservedCount, 3);
    });
  });
}
