@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hard rule 2: `lib/ir/` must stay free of Flutter so it can be extracted
/// into a standalone Dart package.
void main() {
  test('lib/ir imports nothing from Flutter', () {
    final offenders = Directory('lib/ir')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('.g.dart') && !f.path.endsWith('.freezed.dart'))
        .where((f) => f.readAsStringSync().contains(RegExp(r"import\s+'package:flutter")))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });
}
