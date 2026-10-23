import 'idb_database.dart';
import 'story_database.dart';

Future<StoryDatabase> openIndexedDb(String name) =>
    IndexedDbStoryDatabase.open(name: name);
