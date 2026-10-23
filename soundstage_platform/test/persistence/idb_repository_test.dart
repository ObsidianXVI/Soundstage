@TestOn('chrome')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:soundstage_platform/app/persistence/idb_database.dart';

import 'contract.dart';

void main() {
  var n = 0;
  repositoryContract('indexeddb', (clock) async {
    final name = 'test-${DateTime.now().microsecondsSinceEpoch}-${n++}';
    await IndexedDbStoryDatabase.deleteDatabase(name);
    return Harness(await IndexedDbStoryDatabase.open(name: name), clock);
  });
}
