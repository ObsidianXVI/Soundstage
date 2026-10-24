@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// AGENTS.md: `ir` <- `runtime` <- `editor` <- `app`. The editor never
/// imports the app (the app supplies services through provider overrides).
void main() {
  test('lib/editor imports nothing from lib/app', () {
    final offenders = Directory('lib/editor')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where(
          (f) => f.readAsStringSync().contains(
            RegExp(
              r'''import\s+['"](package:soundstage_platform/app/|(\.\./)+app/)''',
            ),
          ),
        )
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });
}
