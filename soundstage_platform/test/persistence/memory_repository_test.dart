import 'package:soundstage_platform/app/persistence/story_database.dart';

import 'contract.dart';

void main() {
  repositoryContract(
    'memory',
    (clock) async => Harness(MemoryStoryDatabase(), clock),
  );
}
