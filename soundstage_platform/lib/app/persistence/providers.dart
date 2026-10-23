import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

import 'autosave.dart';
import 'db_story_repository.dart';
import 'indexed_db_story_repository.dart';
import 'local_asset_store.dart';
import 'platform.dart' as platform;
import 'records.dart';
import 'storage_health.dart';

/// The repository and asset store opened at start-up, or why they are not
/// available.
class AppStorage {
  const AppStorage.ready(DbStoryRepository this.repository)
    : unavailableReason = null;
  const AppStorage.unavailable(String this.unavailableReason)
    : repository = null;

  final DbStoryRepository? repository;
  final String? unavailableReason;

  bool get available => repository != null;
  LocalAssetStore? get assets => repository?.assets;
}

/// Opens IndexedDB, installs the `local://` loader and asks for persistent
/// storage. Never throws: when browser storage is unavailable (private
/// mode, blocked) the result is [AppStorage.unavailable] and the app runs
/// from memory, with the toolbar showing "offline".
Future<AppStorage> openAppStorage() async {
  try {
    final repo = await IndexedDbStoryRepository.openDatabase();
    StageAssetResolver.defaultLocal = repo.assets;
    unawaited(requestPersistentStorage());
    return AppStorage.ready(repo);
  } on Object catch (e) {
    return AppStorage.unavailable('$e');
  }
}

/// Set in `main` from [openAppStorage].
final appStorageProvider = Provider<AppStorage>(
  (ref) => const AppStorage.unavailable('Storage was not opened.'),
);

/// Browser storage usage and quota.
final storageEstimateProvider = FutureProvider<StorageEstimate?>(
  (ref) => readStorageEstimate(),
);

/// One autosave controller per open story. Flushes on `visibilitychange` and
/// `pagehide`, and when the editor leaves. The editor calls
/// `ref.read(autosaveProvider(id)).notifyChanged(document)` after each change.
final autosaveProvider = Provider.autoDispose
    .family<AutosaveController, String>((ref, id) {
      final repo = ref.watch(storyRepositoryProvider);
      final storage = ref.watch(appStorageProvider);
      final c = AutosaveController(
        save: (doc) => repo.save(id, doc),
        readOnly: repo.isReadOnly(id),
        available: storage.available,
        unavailableReason: storage.unavailableReason,
      );
      final stop = platform.onPageHide(() => unawaited(c.flush()));
      ref.onDispose(() {
        stop();
        unawaited(c.dispose());
      });
      return c;
    });

/// Current save status of a story, for the toolbar.
final saveStatusProvider = Provider.autoDispose
    .family<ValueListenable<SaveStatus>, String>(
      (ref, id) => ref.watch(autosaveProvider(id)).status,
    );
