import 'story_database.dart';

Future<StoryDatabase> openIndexedDb(String name) =>
    Future.error(UnsupportedError('IndexedDB needs a browser.'));
