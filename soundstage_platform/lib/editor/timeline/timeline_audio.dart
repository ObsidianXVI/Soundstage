import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../core/editor_controller.dart';

/// Builds the audio service the timeline plays audio clocks through
/// (overridden in tests with a fake backend).
final timelineAudioServiceFactoryProvider =
    Provider<StageAudioService Function(ir.StageDocument doc)>(
      (ref) => StageAudioService.forDocument,
    );

/// Plays an audio clock's track while the timeline's transport runs, and
/// reports its position so the playhead follows the sound (m2.md "Audio
/// lane"). The service is rebuilt when the document's audio tracks or
/// assets change.
class TimelineAudio {
  TimelineAudio(this._create, this._doc);

  final StageAudioService Function(ir.StageDocument doc) _create;
  final ir.StageDocument Function() _doc;

  StageAudioService? _service;
  List<ir.AudioTrack>? _tracks;
  Map<String, ir.Asset>? _assets;
  String? _playing;

  StageAudioService _current() {
    final doc = _doc();
    final s = _service;
    if (s != null &&
        identical(doc.audioTracks, _tracks) &&
        identical(doc.assets, _assets)) {
      return s;
    }
    if (s != null) unawaited(s.dispose());
    _tracks = doc.audioTracks;
    _assets = doc.assets;
    return _service = _create(doc);
  }

  /// Starts track [trackId] at [seconds]. Called from a user gesture (play
  /// or Space), which unlocks browser audio.
  Future<void> start(String trackId, double seconds) async {
    final s = _current();
    _playing = trackId;
    await s.unlock();
    await s.preload();
    if (_playing != trackId) return;
    await s.seek(trackId, seconds);
    if (_playing == trackId) s.play(trackId);
  }

  /// Stops whatever is playing.
  void stop() {
    final id = _playing;
    _playing = null;
    if (id != null) _service?.pause(id);
  }

  /// The playing track's position in seconds, or null when it isn't
  /// playing [trackId] (yet).
  double? position(String trackId) {
    final s = _service;
    if (s == null || _playing != trackId) return null;
    final st = s.track(trackId);
    if (st == null || !st.loaded || !st.isPlaying) return null;
    return s.position(trackId);
  }

  void dispose() {
    _playing = null;
    final s = _service;
    _service = null;
    if (s != null) unawaited(s.dispose());
  }
}

final timelineAudioProvider = Provider<TimelineAudio>((ref) {
  final audio = TimelineAudio(
    ref.watch(timelineAudioServiceFactoryProvider),
    () => ref.read(editorControllerProvider).document,
  );
  ref.onDispose(audio.dispose);
  return audio;
}, dependencies: [editorControllerProvider]);
