import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'records.dart';
import 'storage_health_web.dart';
import 'story_database.dart';

const String _kStories = 'stories';
const String _kRevisions = 'revisions';
const String _kAssets = 'assets';
const String _kByStory = 'byStory';

/// The IndexedDB schema version. Bump with an upgrade step in
/// [IndexedDbStoryDatabase.open].
const int kIdbVersion = 1;

/// [StoryDatabase] on IndexedDB, through `package:web` and `dart:js_interop`
/// (no wrapper package: the API surface is small, and the wrappers on pub.dev
/// add a layer that is not needed for wasm).
///
/// Stores:
/// - `stories`: key `id`.
/// - `revisions`: key `[storyId, rev]`, plus index `byStory` on
///   `[storyId, savedAt, size]` so a listing is a key-only cursor and never
///   reads a document.
/// - `assets`: key `assetId`; the file is a `Blob`; audio rows also hold
///   `peaks`, a `Uint8Array` of waveform peaks (10 ms buckets).
///
/// Every public method is a single transaction. Code inside a transaction
/// never awaits, so it cannot outlive the transaction's active window.
class IndexedDbStoryDatabase implements StoryDatabase {
  IndexedDbStoryDatabase._(this._db);

  final web.IDBDatabase _db;

  /// Opens (and creates or upgrades) the database. Throws when IndexedDB is
  /// unavailable or blocked.
  static Future<IndexedDbStoryDatabase> open({
    String name = 'soundstage',
  }) async {
    final factory = web.window.indexedDB;
    final request = factory.open(name, kIdbVersion);
    final done = Completer<web.IDBDatabase>();
    request.onupgradeneeded = ((web.Event e) {
      final db = (request.result! as web.IDBDatabase);
      final stores = <String>[
        for (var i = 0; i < db.objectStoreNames.length; i++)
          db.objectStoreNames.item(i)!,
      ];
      if (!stores.contains(_kStories)) {
        db.createObjectStore(
          _kStories,
          web.IDBObjectStoreParameters(keyPath: 'id'.toJS),
        );
      }
      if (!stores.contains(_kRevisions)) {
        final rev = db.createObjectStore(
          _kRevisions,
          web.IDBObjectStoreParameters(
            keyPath: ['storyId'.toJS, 'rev'.toJS].toJS,
          ),
        );
        rev.createIndex(
          _kByStory,
          ['storyId'.toJS, 'savedAt'.toJS, 'size'.toJS].toJS,
        );
      }
      if (!stores.contains(_kAssets)) {
        db.createObjectStore(
          _kAssets,
          web.IDBObjectStoreParameters(keyPath: 'assetId'.toJS),
        );
      }
    }).toJS;
    request.onsuccess = ((web.Event e) {
      if (!done.isCompleted) done.complete(request.result! as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event e) {
      if (!done.isCompleted) {
        done.completeError(
          StateError('IndexedDB open failed: ${request.error?.message}'),
        );
      }
    }).toJS;
    request.onblocked = ((web.Event e) {
      if (!done.isCompleted) {
        done.completeError(
          StateError('IndexedDB is blocked by another tab (upgrade pending).'),
        );
      }
    }).toJS;
    final db = await done.future;
    db.onversionchange = ((web.Event e) => db.close()).toJS;
    return IndexedDbStoryDatabase._(db);
  }

  /// Deletes the whole database (tests).
  static Future<void> deleteDatabase(String name) {
    final request = web.window.indexedDB.deleteDatabase(name);
    final done = Completer<void>();
    request.onsuccess = ((web.Event e) => done.complete()).toJS;
    request.onerror = ((web.Event e) => done.completeError(
      StateError('deleteDatabase failed: ${request.error?.message}'),
    )).toJS;
    request.onblocked = ((web.Event e) {}).toJS;
    return done.future;
  }

  // ---- plumbing -----------------------------------------------------------

  Object _mapError(web.DOMException? error) {
    final name = error?.name ?? '';
    if (name == 'QuotaExceededError') {
      return const StorageFullException();
    }
    return StateError('IndexedDB error: $name ${error?.message ?? ''}');
  }

  /// Runs [body] in one transaction over [stores]; completes when it
  /// commits. [body] must not await.
  Future<void> _tx(
    List<String> stores,
    bool write,
    void Function(web.IDBTransaction tx) body,
  ) {
    final done = Completer<void>();
    late final web.IDBTransaction tx;
    try {
      tx = _db.transaction(
        [for (final s in stores) s.toJS].toJS,
        write ? 'readwrite' : 'readonly',
      );
    } on Object catch (e) {
      return Future<void>.error(e);
    }
    tx.oncomplete = ((web.Event e) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    tx.onabort = ((web.Event e) {
      if (!done.isCompleted) done.completeError(_mapError(tx.error));
    }).toJS;
    tx.onerror = ((web.Event e) {}).toJS; // the abort carries the error
    try {
      body(tx);
    } on Object catch (e) {
      try {
        tx.abort();
      } on Object {
        // Already finished.
      }
      if (!done.isCompleted) done.completeError(e);
    }
    return done.future;
  }

  void _onResult(web.IDBRequest r, void Function(JSAny? result) f) {
    r.onsuccess = ((web.Event e) => f(r.result)).toJS;
  }

  static JSObject _obj(Map<String, JSAny?> fields) {
    final o = JSObject();
    fields.forEach((k, v) {
      if (v != null) o.setProperty(k.toJS, v);
    });
    return o;
  }

  static JSAny? _p(JSObject o, String k) {
    final v = o.getProperty<JSAny?>(k.toJS);
    return v.isUndefinedOrNull ? null : v;
  }

  static int? _int(JSObject o, String k) =>
      (_p(o, k) as JSNumber?)?.toDartDouble.round();

  static String? _str(JSObject o, String k) => (_p(o, k) as JSString?)?.toDart;

  static JSAny _key(String storyId, [int? rev]) =>
      [storyId.toJS, if (rev != null) rev.toJS].toJS;

  /// The range of every `[storyId, …]` key (an array sorts after any number
  /// or string, so `[id, []]` is above every real second element).
  static web.IDBKeyRange _storyRange(String storyId) => web.IDBKeyRange.bound(
    _key(storyId),
    [storyId.toJS, <JSAny?>[].toJS].toJS,
  );

  // ---- stories ------------------------------------------------------------

  StoryRecord _story(JSObject o) => StoryRecord(
    id: _str(o, 'id')!,
    title: _str(o, 'title') ?? '',
    createdAt: _int(o, 'createdAt') ?? 0,
    updatedAt: _int(o, 'updatedAt') ?? 0,
    headRevision: _int(o, 'headRevision') ?? 0,
    coverAssetId: _str(o, 'coverAssetId'),
    sceneCount: _int(o, 'sceneCount'),
  );

  @override
  Future<List<StoryRecord>> listStories() async {
    final out = <StoryRecord>[];
    await _tx([_kStories], false, (tx) {
      _onResult(tx.objectStore(_kStories).getAll(), (r) {
        for (final v in (r! as JSArray<JSObject>).toDart) {
          out.add(_story(v));
        }
      });
    });
    return out;
  }

  @override
  Future<StoryRecord?> getStory(String id) async {
    StoryRecord? out;
    await _tx([_kStories], false, (tx) {
      _onResult(tx.objectStore(_kStories).get(id.toJS), (r) {
        if (!r.isUndefinedOrNull) out = _story(r! as JSObject);
      });
    });
    return out;
  }

  @override
  Future<void> putStory(StoryRecord s) => _tx([_kStories], true, (tx) {
    tx
        .objectStore(_kStories)
        .put(
          _obj({
            'id': s.id.toJS,
            'title': s.title.toJS,
            'createdAt': s.createdAt.toJS,
            'updatedAt': s.updatedAt.toJS,
            'headRevision': s.headRevision.toJS,
            'coverAssetId': s.coverAssetId?.toJS,
            'sceneCount': s.sceneCount?.toJS,
          }),
        );
  });

  @override
  Future<void> deleteStory(String id) =>
      _tx([_kStories, _kRevisions], true, (tx) {
        tx.objectStore(_kStories).delete(id.toJS);
        tx.objectStore(_kRevisions).delete(_storyRange(id));
      });

  // ---- revisions ----------------------------------------------------------

  @override
  Future<void> putRevision(RevisionRecord r) => _tx([_kRevisions], true, (tx) {
    tx
        .objectStore(_kRevisions)
        .put(
          _obj({
            'storyId': r.storyId.toJS,
            'rev': r.rev.toJS,
            'savedAt': r.savedAt.toJS,
            'size': r.size.toJS,
            'json': r.json.toJS,
          }),
        );
  });

  @override
  Future<RevisionRecord?> getRevision(String storyId, int rev) async {
    RevisionRecord? out;
    await _tx([_kRevisions], false, (tx) {
      _onResult(tx.objectStore(_kRevisions).get(_key(storyId, rev)), (r) {
        if (r.isUndefinedOrNull) return;
        final o = r! as JSObject;
        out = RevisionRecord(
          storyId: storyId,
          rev: rev,
          savedAt: _int(o, 'savedAt') ?? 0,
          json: _str(o, 'json') ?? '',
        );
      });
    });
    return out;
  }

  @override
  Future<List<RevisionInfo>> listRevisions(String storyId) async {
    final out = <RevisionInfo>[];
    await _tx([_kRevisions], false, (tx) {
      final index = tx.objectStore(_kRevisions).index(_kByStory);
      final req = index.openKeyCursor(_storyRange(storyId));
      req.onsuccess = ((web.Event e) {
        final cursor = req.result;
        if (cursor.isUndefinedOrNull) return;
        final c = cursor! as web.IDBCursor;
        final key = (c.key! as JSArray<JSAny?>).toDart; // storyId,savedAt,size
        final pk = (c.primaryKey! as JSArray<JSAny?>).toDart; // storyId,rev
        out.add(
          RevisionInfo(
            rev: (pk[1]! as JSNumber).toDartDouble.round(),
            savedAt: (key[1]! as JSNumber).toDartDouble.round(),
            size: (key[2]! as JSNumber).toDartDouble.round(),
          ),
        );
        c.continue_();
      }).toJS;
    });
    out.sort((a, b) => a.rev.compareTo(b.rev));
    return out;
  }

  @override
  Future<void> deleteRevisions(String storyId, Iterable<int> revs) =>
      _tx([_kRevisions], true, (tx) {
        final store = tx.objectStore(_kRevisions);
        for (final r in revs) {
          store.delete(_key(storyId, r));
        }
      });

  // ---- assets -------------------------------------------------------------

  AssetMeta _meta(JSObject o) => AssetMeta(
    id: _str(o, 'assetId')!,
    mime: _str(o, 'mime') ?? '',
    byteSize: _int(o, 'bytes') ?? 0,
    createdAt: _int(o, 'createdAt') ?? 0,
    name: _str(o, 'name') ?? '',
    width: _int(o, 'width'),
    height: _int(o, 'height'),
    duration: (_p(o, 'duration') as JSNumber?)?.toDartDouble,
    dominantColor: _int(o, 'dominantColor'),
    peaks: (_p(o, 'peaks') as JSUint8Array?)?.toDart,
  );

  @override
  Future<void> putAsset(AssetRecord r) => _tx([_kAssets], true, (tx) {
    final m = r.meta;
    final blob = web.Blob(
      [r.bytes.toJS].toJS,
      web.BlobPropertyBag(type: m.mime),
    );
    tx
        .objectStore(_kAssets)
        .put(
          _obj({
            'assetId': m.id.toJS,
            'blob': blob,
            'mime': m.mime.toJS,
            'bytes': m.byteSize.toJS,
            'name': m.name.toJS,
            'createdAt': m.createdAt.toJS,
            'width': m.width?.toJS,
            'height': m.height?.toJS,
            'duration': m.duration?.toJS,
            'dominantColor': m.dominantColor?.toJS,
            'peaks': m.peaks?.toJS,
          }),
        );
  });

  @override
  Future<AssetRecord?> getAsset(String id) async {
    JSObject? row;
    await _tx([_kAssets], false, (tx) {
      _onResult(tx.objectStore(_kAssets).get(id.toJS), (r) {
        if (!r.isUndefinedOrNull) row = r! as JSObject;
      });
    });
    final o = row;
    if (o == null) return null;
    final blob = _p(o, 'blob')! as web.Blob;
    final buffer = await blob.arrayBuffer().toDart;
    return AssetRecord(_meta(o), buffer.toDart.asUint8List());
  }

  @override
  Future<List<AssetMeta>> listAssets() async {
    final out = <AssetMeta>[];
    await _tx([_kAssets], false, (tx) {
      // A cursor visits rows without reading their blobs.
      final req = tx.objectStore(_kAssets).openCursor();
      req.onsuccess = ((web.Event e) {
        final cursor = req.result;
        if (cursor.isUndefinedOrNull) return;
        final c = cursor! as web.IDBCursorWithValue;
        out.add(_meta(c.value! as JSObject));
        c.continue_();
      }).toJS;
    });
    return out;
  }

  @override
  Future<void> deleteAssets(Iterable<String> ids) =>
      _tx([_kAssets], true, (tx) {
        final store = tx.objectStore(_kAssets);
        for (final id in ids) {
          store.delete(id.toJS);
        }
      });

  @override
  Future<StorageEstimate?> estimate() => readStorageEstimate();

  @override
  void close() => _db.close();
}
