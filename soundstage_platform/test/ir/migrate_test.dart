import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

void main() {
  test('current version is 1 and no steps are registered', () {
    expect(kStageSchemaVersion, 1);
    expect(kMigrationSteps, isEmpty);
  });

  test('a current document passes through unchanged', () {
    final json = <String, Object?>{'schemaVersion': 1, 'id': 'd'};
    expect(migrateDocumentJson(json), json);
  });

  test('steps chain in order from the file version to the target', () {
    final calls = <int>[];
    Map<String, Object?> Function(Map<String, Object?>) step(int from) =>
        (json) {
          calls.add(from);
          expect(json['schemaVersion'], from);
          return {
            ...json,
            'log': [...(json['log'] as List? ?? const []), from],
          };
        };
    final steps = {1: step(1), 2: step(2), 3: step(3)};

    final input = <String, Object?>{'schemaVersion': 1, 'id': 'd'};
    final out = migrateDocumentJson(input, steps: steps, targetVersion: 4);
    expect(calls, [1, 2, 3]);
    expect(out['schemaVersion'], 4);
    expect(out['log'], [1, 2, 3]);
    expect(input['schemaVersion'], 1, reason: 'input is not mutated');

    calls.clear();
    final fromTwo = migrateDocumentJson(
      {'schemaVersion': 2},
      steps: steps,
      targetVersion: 4,
    );
    expect(calls, [2, 3]);
    expect(fromTwo['log'], [2, 3]);
  });

  test('a step can rename fields', () {
    final out = migrateDocumentJson(
      {'schemaVersion': 1, 'title': 'Old'},
      steps: {
        1: (json) => {
          ...json,
          'meta': {'title': json['title']},
        }..remove('title'),
      },
      targetVersion: 2,
    );
    expect(out, {
      'schemaVersion': 2,
      'meta': {'title': 'Old'},
    });
  });

  test('a newer document is rejected with a clear message', () {
    expect(
      () => migrateDocumentJson({'schemaVersion': 2}),
      throwsA(
        isA<StageMigrationException>().having(
          (e) => e.message,
          'message',
          contains('newer'),
        ),
      ),
    );
  });

  test('a missing or invalid version is rejected', () {
    for (final v in [null, 0, '1', 1.5]) {
      expect(
        () => migrateDocumentJson({'schemaVersion': v}),
        throwsA(isA<StageMigrationException>()),
        reason: '$v',
      );
    }
  });

  test('a gap in the step chain is rejected', () {
    expect(
      () => migrateDocumentJson(
        {'schemaVersion': 1},
        steps: {1: (j) => j},
        targetVersion: 3,
      ),
      throwsA(
        isA<StageMigrationException>().having(
          (e) => e.message,
          'message',
          contains('from schemaVersion 2'),
        ),
      ),
    );
  });
}
