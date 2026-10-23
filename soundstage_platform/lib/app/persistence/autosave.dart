import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'records.dart';

/// Where the toolbar's save indicator is.
enum SaveState {
  /// Nothing has changed yet.
  idle,

  /// Changes are waiting for the debounce, or a write is in flight.
  saving,

  /// Everything is stored.
  saved,

  /// The last write failed; the previous good version is intact and the
  /// controller keeps retrying. See [SaveStatus.message].
  error,

  /// Browser storage is unavailable (private mode, blocked): nothing can be
  /// saved. The indicator says so ("offline").
  offline,

  /// A bundled demo: it cannot be saved. Duplicate it first.
  readOnly,
}

class SaveStatus {
  const SaveStatus(this.state, {this.message, this.lastSaved});

  final SaveState state;

  /// A human-readable reason for [SaveState.error] / [SaveState.offline].
  final String? message;

  /// When the last successful write finished.
  final DateTime? lastSaved;

  @override
  String toString() =>
      'SaveStatus($state${message == null ? '' : ', $message'})';
}

/// Writes a document. [AutosaveController] calls it with the story id it was
/// built for.
typedef SaveFn = Future<void> Function(ir.StageDocument document);

/// Debounced, crash-safe autosave (architecture §17.2).
///
/// The editor calls [notifyChanged] with the new document after every
/// change. The controller writes
/// - [debounce] (800 ms) after the last change, and
/// - at the latest [maxInterval] (5 s) after the first unsaved change, so a
///   long drag still saves,
/// - immediately on [flush] (page hide, leaving the editor).
///
/// Only the newest pending document is written (intermediate states are
/// dropped). A failed write keeps the pending document and retries after
/// [retryDelay]; the repository's crash-safe save means a failure never
/// damages the last good version.
class AutosaveController {
  AutosaveController({
    required this._save,
    this.debounce = const Duration(milliseconds: 800),
    this.maxInterval = const Duration(seconds: 5),
    this.retryDelay = const Duration(seconds: 5),
    DateTime Function()? now,
    bool readOnly = false,
    bool available = true,
    String? unavailableReason,
  }) : _now = now ?? DateTime.now,
       _status = ValueNotifier(
         !available
             ? SaveStatus(SaveState.offline, message: unavailableReason)
             : readOnly
             ? const SaveStatus(SaveState.readOnly)
             : const SaveStatus(SaveState.idle),
       ),
       _readOnly = readOnly,
       _available = available;

  final SaveFn _save;
  final DateTime Function() _now;
  final Duration debounce;
  final Duration maxInterval;
  final Duration retryDelay;
  final bool _readOnly;
  final bool _available;
  final ValueNotifier<SaveStatus> _status;

  ir.StageDocument? _pending;
  Timer? _debounceTimer;
  Timer? _maxTimer;
  Timer? _retryTimer;
  Future<void>? _inFlight;
  bool _disposed = false;
  DateTime? _lastSaved;

  /// The save status for the toolbar.
  ValueListenable<SaveStatus> get status => _status;

  /// True while a change is waiting or being written.
  bool get hasPendingChanges => _pending != null || _inFlight != null;

  /// The editor reports a changed document. Cheap: it only stores the
  /// reference and (re)arms timers.
  void notifyChanged(ir.StageDocument document) {
    if (_disposed || _readOnly || !_available) return;
    _pending = document;
    _retryTimer?.cancel();
    _retryTimer = null;
    _set(SaveStatus(SaveState.saving, lastSaved: _lastSaved));
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _fire);
    _maxTimer ??= Timer(maxInterval, _fire);
  }

  void _fire() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    unawaited(_drain());
  }

  /// Writes any pending document now and completes when it is stored (or
  /// failed). Used on `visibilitychange`/`pagehide` and when leaving the
  /// editor.
  Future<void> flush() async {
    _fire();
    await _inFlight;
  }

  Future<void> _drain() async {
    // One write at a time; the loop picks up what arrived meanwhile.
    final running = _inFlight;
    if (running != null) return running;
    final done = Completer<void>();
    _inFlight = done.future;
    try {
      // A newly armed debounce timer means the author is still editing: leave
      // that change to the timer instead of writing it right away.
      while (_pending != null && _debounceTimer == null && !_disposed) {
        final doc = _pending!;
        _pending = null;
        try {
          await _save(doc);
          _lastSaved = _now();
          if (_pending == null) {
            _set(SaveStatus(SaveState.saved, lastSaved: _lastSaved));
          }
        } on Object catch (e) {
          // Keep the newest document; a newer notification wins.
          _pending ??= doc;
          _set(
            SaveStatus(
              SaveState.error,
              message: e is StorageFullException
                  ? 'Storage is full. Free up space or export the story.'
                  : e is ReadOnlyStoryException
                  ? 'This demo is read-only. Duplicate it to edit.'
                  : 'Could not save: $e',
              lastSaved: _lastSaved,
            ),
          );
          if (e is! ReadOnlyStoryException) {
            _retryTimer?.cancel();
            _retryTimer = Timer(retryDelay, () => unawaited(_drain()));
          }
          return;
        }
      }
    } finally {
      _inFlight = null;
      done.complete();
    }
  }

  void _set(SaveStatus s) {
    if (!_disposed) _status.value = s;
  }

  /// Flushes and releases the timers.
  Future<void> dispose() async {
    if (_disposed) return;
    await flush();
    _disposed = true;
    _debounceTimer?.cancel();
    _maxTimer?.cancel();
    _retryTimer?.cancel();
    _status.dispose();
  }
}
