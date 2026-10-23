import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'records.dart';

JSObject? _storage() {
  final nav = web.window.navigator as JSObject;
  if (!nav.has('storage')) return null;
  final s = nav.getProperty<JSAny?>('storage'.toJS);
  return s.isUndefinedOrNull ? null : s as JSObject;
}

/// Asks the browser not to evict this origin's data
/// (`navigator.storage.persist()`), feature-detected. Returns whether the
/// storage is persistent, or null when unsupported or the call failed.
Future<bool?> requestPersistentStorage() async {
  try {
    final s = _storage();
    if (s == null || !s.has('persist')) return null;
    final granted = await (s.callMethod<JSPromise<JSBoolean>>(
      'persist'.toJS,
    )).toDart;
    return granted.toDart;
  } on Object {
    return null;
  }
}

/// `navigator.storage.estimate()` plus `persisted()`, feature-detected.
Future<StorageEstimate?> readStorageEstimate() async {
  try {
    final s = _storage();
    if (s == null || !s.has('estimate')) return null;
    final e = await (s.callMethod<JSPromise<JSObject>>('estimate'.toJS)).toDart;
    int? num(String k) {
      final v = e.getProperty<JSAny?>(k.toJS);
      return v.isUndefinedOrNull ? null : (v as JSNumber).toDartDouble.round();
    }

    bool? persisted;
    if (s.has('persisted')) {
      persisted = (await (s.callMethod<JSPromise<JSBoolean>>(
        'persisted'.toJS,
      )).toDart).toDart;
    }
    return StorageEstimate(
      usage: num('usage'),
      quota: num('quota'),
      persisted: persisted,
    );
  } on Object {
    return null;
  }
}
