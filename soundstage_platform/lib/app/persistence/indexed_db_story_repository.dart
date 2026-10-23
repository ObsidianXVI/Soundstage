import 'db_story_repository.dart';
import 'idb_factory.dart';
import 'local_asset_store.dart';

/// The browser's story repository: [DbStoryRepository] over IndexedDB.
class IndexedDbStoryRepository extends DbStoryRepository {
  IndexedDbStoryRepository._(super.db, {required super.assets});

  /// Opens (creating on first use) the `soundstage` database. Throws when
  /// IndexedDB is unavailable (callers fall back to memory).
  static Future<IndexedDbStoryRepository> openDatabase({
    String databaseName = 'soundstage',
  }) async {
    final db = await openIndexedDb(databaseName);
    return IndexedDbStoryRepository._(db, assets: LocalAssetStore(db));
  }
}
