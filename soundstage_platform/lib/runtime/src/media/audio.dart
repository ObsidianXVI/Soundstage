import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../clocks/clock_source.dart';
import 'asset_resolver.dart';

/// One playable audio source (architecture §10.4, §14). The production
/// implementation is [JustAudioBackend]; tests use fakes.
abstract class StageAudioBackend {
  /// Loads [uri] (`asset://<path>` or `https://…`).
  Future<void> load(String uri);

  /// Starts or resumes playback. Fire and forget (on the web this must be
  /// called from, or after, a user gesture).
  void play();
  Future<void> pause();
  Future<void> seek(double seconds);

  /// 0–1.
  Future<void> setVolume(double volume);
  Future<void> setLoop(bool loop);

  /// The player's own position estimate, in seconds. It may be coarse (it
  /// can lag between platform updates).
  double get position;
  bool get playing;
  double get speed;

  /// Seconds, once known.
  double? get duration;
  Future<void> dispose();
}

/// [StageAudioBackend] on `just_audio`'s [ja.AudioPlayer].
class JustAudioBackend implements StageAudioBackend {
  final ja.AudioPlayer _player = ja.AudioPlayer();

  String? _heldLocalId;
  LocalAssetLoader? _heldFrom;

  void _releaseLocal() {
    final id = _heldLocalId;
    if (id != null) _heldFrom?.releaseObjectUrl(id);
    _heldLocalId = null;
    _heldFrom = null;
  }

  @override
  Future<void> load(String uri) async {
    final path = bundledAssetPath(uri);
    final localId = localAssetId(uri);
    if (path != null) {
      await _player.setAsset(path);
    } else if (localId != null) {
      // A media element needs a URL: hold an object URL while this source
      // is loaded and revoke it when the backend moves on or is disposed.
      final loader = StageAssetResolver.defaultLocal;
      final url = await loader?.acquireObjectUrl(localId);
      if (loader == null || url == null) {
        throw StateError('Local audio "$localId" is missing.');
      }
      _releaseLocal();
      _heldLocalId = localId;
      _heldFrom = loader;
      await _player.setUrl(url);
    } else {
      await _player.setUrl(uri);
    }
  }

  @override
  void play() => unawaited(_player.play());

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(double seconds) =>
      _player.seek(Duration(microseconds: (seconds * 1e6).round()));

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> setLoop(bool loop) =>
      _player.setLoopMode(loop ? ja.LoopMode.one : ja.LoopMode.off);

  @override
  double get position => _player.position.inMicroseconds / 1e6;

  @override
  bool get playing =>
      _player.playing &&
      _player.processingState != ja.ProcessingState.completed;

  @override
  double get speed => _player.speed;

  @override
  double? get duration {
    final d = _player.duration;
    return d == null ? null : d.inMicroseconds / 1e6;
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
    _releaseLocal();
  }
}

/// How far the interpolated audio clock may drift from the player before it
/// jumps to the player's position (a seek, a loop wrap or a stall).
const double kAudioResyncThreshold = 0.25;

/// How fast (per second) the interpolated clock closes a small drift.
const double kAudioDriftCorrection = 5;

enum _Fade { none, fadingIn, fadingOut }

/// The playback state of one [ir.AudioTrack].
class StageAudioTrackState {
  StageAudioTrackState(this.track, this.backend);

  final ir.AudioTrack track;
  final StageAudioBackend backend;

  bool loaded = false;
  Object? loadError;

  /// The fade gain (0–1), multiplied with the track's volume.
  double gain = 1;
  _Fade _fade = _Fade.none;
  double _fadeFrom = 0, _fadeTo = 1, _fadeTime = 0, _fadeElapsed = 0;
  bool _pauseAfterFade = false;
  bool _endFading = false;

  /// Bumped on every seek, so clock sources resynchronise.
  int seekGeneration = 0;

  bool get isPlaying => backend.playing;
  bool get isFading => _fade != _Fade.none;
}

/// Plays a document's audio tracks (architecture §10.4).
///
/// - **Unlock.** Browsers block audio until a user gesture. Nothing plays
///   before [unlock], which the enter gate calls from its gesture. Then
///   story-scoped `autoplay` tracks start, and scene-scoped `autoplay`
///   tracks whose scene is on screen.
/// - **Scenes.** [sceneVisibilityChanged] (from the player's slivers):
///   scene-scoped `autoplay` tracks fade in and play while their scene is
///   on screen and fade out and pause when it leaves; re-entering resumes
///   where they paused (a music player's pause, not a restart).
///   Non-autoplay scene tracks only pause on leave.
/// - **Fades.** `fadeIn` on every start, `fadeOut` on every pause, and,
///   for tracks that do not loop, before the natural end. Fades run on a
///   timer while needed ([advance] steps them; tests call it directly).
/// - **Clocks.** [clockSource] creates the `audio` clock sources for
///   `StageClockFactories.audio`; seeks and starts notify
///   [addClockListener] listeners (the player's animator) so clocks re-read
///   at once and the player ticks while audio plays.
class StageAudioService {
  StageAudioService({
    required List<ir.AudioTrack> tracks,
    this._assets = const {},
    StageAudioBackend Function()? createBackend,
    this.autoTick = true,
  }) : _create = createBackend ?? JustAudioBackend.new {
    for (final t in tracks) {
      _tracks[t.id] = StageAudioTrackState(t, _create());
    }
  }

  factory StageAudioService.forDocument(
    ir.StageDocument doc, {
    StageAudioBackend Function()? createBackend,
    bool autoTick = true,
  }) => StageAudioService(
    tracks: doc.audioTracks,
    assets: doc.assets,
    createBackend: createBackend,
    autoTick: autoTick,
  );

  final Map<String, ir.Asset> _assets;
  final StageAudioBackend Function() _create;

  /// Whether fades step on a timer by themselves (off in tests).
  final bool autoTick;

  final Map<String, StageAudioTrackState> _tracks = {};
  final Map<String, bool> _sceneVisible = {};
  final List<VoidCallback> _clockListeners = [];
  Future<void>? _preload;
  Timer? _timer;
  final Stopwatch _watch = Stopwatch();
  bool _unlocked = false;
  bool _disposed = false;

  /// Whether audio has been unlocked by a user gesture.
  bool get unlocked => _unlocked;

  /// The state of track [id] (tests, controls).
  StageAudioTrackState? track(String id) => _tracks[id];

  Iterable<StageAudioTrackState> get tracks => _tracks.values;

  void addClockListener(VoidCallback l) => _clockListeners.add(l);
  void removeClockListener(VoidCallback l) => _clockListeners.remove(l);

  /// Loads every track's source once (idempotent). Never throws: a track
  /// that fails keeps [StageAudioTrackState.loadError] and stays silent.
  Future<void> preload() => _preload ??= _loadAll();

  Future<void> _loadAll() async {
    await Future.wait([for (final s in _tracks.values) _loadTrack(s)]);
  }

  Future<void> _loadTrack(StageAudioTrackState s) async {
    final asset = _assets[s.track.assetId];
    if (asset == null) {
      s.loadError = 'audio asset "${s.track.assetId}" does not exist';
      debugPrint('soundstage audio: ${s.loadError}');
      return;
    }
    try {
      await s.backend.load(asset.uri);
      await s.backend.setLoop(s.track.loop);
      await s.backend.setVolume(s.track.volume);
      s.loaded = true;
    } catch (e) {
      s.loadError = e;
      debugPrint('soundstage audio: could not load "${asset.uri}": $e');
    }
  }

  /// Unlocks audio. Call it from a user gesture (the enter gate). Starts
  /// the tracks that should be playing now.
  Future<void> unlock() async {
    if (_unlocked || _disposed) return;
    _unlocked = true;
    await preload();
    for (final s in _tracks.values) {
      if (!s.track.autoplay) continue;
      switch (s.track.scope) {
        case ir.StoryAudioScope():
          _start(s);
        case ir.SceneAudioScope(:final sceneId):
          if (_sceneVisible[sceneId] ?? false) _start(s);
      }
    }
  }

  /// A scene came on screen or left it.
  void sceneVisibilityChanged(String sceneId, {required bool visible}) {
    if (_sceneVisible[sceneId] == visible) return;
    _sceneVisible[sceneId] = visible;
    if (!_unlocked) return;
    for (final s in _tracks.values) {
      final scope = s.track.scope;
      if (scope is! ir.SceneAudioScope || scope.sceneId != sceneId) continue;
      if (visible) {
        if (s.track.autoplay) _start(s);
      } else if (s.isPlaying || s.isFading) {
        _stop(s);
      }
    }
  }

  /// Plays track [id] (with its fade-in). Ignored before [unlock].
  void play(String id) {
    final s = _tracks[id];
    if (s != null && _unlocked) _start(s);
  }

  /// Pauses track [id] after its fade-out.
  void pause(String id) {
    final s = _tracks[id];
    if (s != null) _stop(s);
  }

  /// Seeks track [id] to [seconds] and tells clock listeners.
  Future<void> seek(String id, double seconds) async {
    final s = _tracks[id];
    if (s == null) return;
    s.seekGeneration++;
    s._endFading = false;
    await s.backend.seek(math.max(0, seconds));
    _notify();
  }

  /// Tells clock listeners that a position jumped or playback started, so
  /// the player re-reads (and keeps ticking) its audio clocks.
  void _notify() {
    for (final l in List.of(_clockListeners)) {
      l();
    }
  }

  /// The position of track [id] in seconds (the player's estimate).
  double position(String id) => _tracks[id]?.backend.position ?? 0;

  void _start(StageAudioTrackState s) {
    if (!s.loaded) return;
    final fadeIn = s.track.fadeIn;
    s._pauseAfterFade = false;
    if (fadeIn > 0) {
      _beginFade(s, _Fade.fadingIn, s.isPlaying ? s.gain : 0, 1, fadeIn);
    } else {
      s
        ..gain = 1
        .._fade = _Fade.none;
      _applyVolume(s);
    }
    if (!s.isPlaying) s.backend.play();
    _ensureTicking();
    _notify();
  }

  void _stop(StageAudioTrackState s) {
    final fadeOut = s.track.fadeOut;
    if (fadeOut > 0 && s.isPlaying) {
      _beginFade(s, _Fade.fadingOut, s.gain, 0, fadeOut);
      s._pauseAfterFade = true;
      _ensureTicking();
    } else {
      s._fade = _Fade.none;
      unawaited(s.backend.pause());
    }
  }

  void _beginFade(
    StageAudioTrackState s,
    _Fade kind,
    double from,
    double to,
    double seconds,
  ) {
    s
      .._fade = kind
      .._fadeFrom = from
      .._fadeTo = to
      .._fadeTime = seconds
      .._fadeElapsed = 0
      ..gain = from;
    _applyVolume(s);
  }

  void _applyVolume(StageAudioTrackState s) =>
      unawaited(s.backend.setVolume(_muted ? 0 : s.track.volume * s.gain));

  bool _muted = false;

  /// Silences every track without pausing it (the editor preview's mute).
  bool get muted => _muted;
  set muted(bool value) {
    if (_muted == value) return;
    _muted = value;
    for (final s in _tracks.values) {
      if (s.loaded) _applyVolume(s);
    }
  }

  /// Steps fades by [dt] seconds, and starts the end-of-track fade-out of
  /// tracks that do not loop.
  void advance(double dt) {
    for (final s in _tracks.values) {
      if (s._fade != _Fade.none) {
        s._fadeElapsed += dt;
        final t = s._fadeTime <= 0
            ? 1.0
            : (s._fadeElapsed / s._fadeTime).clamp(0.0, 1.0);
        s.gain = s._fadeFrom + (s._fadeTo - s._fadeFrom) * t;
        _applyVolume(s);
        if (t >= 1) {
          s._fade = _Fade.none;
          if (s._pauseAfterFade) {
            s._pauseAfterFade = false;
            unawaited(s.backend.pause());
          }
        }
      }
      final d = s.backend.duration;
      final out = s.track.fadeOut;
      if (!s.track.loop &&
          out > 0 &&
          d != null &&
          s.isPlaying &&
          !s._endFading &&
          s._fade == _Fade.none &&
          s.backend.position >= d - out) {
        s._endFading = true;
        _beginFade(s, _Fade.fadingOut, s.gain, 0, d - s.backend.position);
      }
    }
  }

  bool get _needsTicks => _tracks.values.any(
    (s) =>
        s._fade != _Fade.none ||
        (s.isPlaying && !s.track.loop && s.track.fadeOut > 0 && !s._endFading),
  );

  void _ensureTicking() {
    if (!autoTick || _disposed || _timer != null) return;
    _watch
      ..reset()
      ..start();
    var last = Duration.zero;
    _timer = Timer.periodic(const Duration(milliseconds: 32), (timer) {
      final now = _watch.elapsed;
      advance((now - last).inMicroseconds / 1e6);
      last = now;
      if (!_needsTicks) {
        timer.cancel();
        _timer = null;
        _watch.stop();
      }
    });
  }

  /// An `audio` clock source for [clock] (plug into
  /// `StageClockFactories(audio: service.clockSource)`); null when the
  /// clock's track does not exist (the clock then holds 0).
  StageClockSource? clockSource(ir.Clock clock, {required String sceneId}) {
    if (clock is! ir.AudioClock) return null;
    final s = _tracks[clock.audioTrackId];
    return s == null ? null : StageAudioClockSource(s);
  }

  /// The clock factories for a player of this service's document.
  late final StageClockFactories clockFactories = StageClockFactories(
    audio: clockSource,
  );

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _clockListeners.clear();
    await Future.wait([for (final s in _tracks.values) s.backend.dispose()]);
  }
}

/// `audio(trackId)`: the track's playback position in seconds,
/// interpolated between the player's (coarse) position updates so lyrics
/// and tracks move smoothly every frame.
///
/// While playing, the value advances by wall time × speed. Each time the
/// player reports a new position, the difference to the interpolated value
/// becomes a drift that is closed at [kAudioDriftCorrection] per second,
/// never moving the clock backwards; a drift beyond [kAudioResyncThreshold]
/// (seek, loop wrap, stall) jumps to the player's position. Paused, it is
/// the player's position. A seek resynchronises at once.
class StageAudioClockSource extends StageClockSource {
  StageAudioClockSource(this.state)
    : _generation = state.seekGeneration,
      _value = state.backend.position,
      _reported = state.backend.position;

  final StageAudioTrackState state;
  int _generation;
  double _value;
  double _reported;
  double _drift = 0;

  @override
  double get value => _value;

  @override
  bool get isActive => state.backend.playing;

  @override
  void advance(double dt) {
    final b = state.backend;
    final reported = b.position;
    if (_generation != state.seekGeneration || !b.playing) {
      _generation = state.seekGeneration;
      _value = _reported = reported;
      _drift = 0;
      return;
    }
    var next = _value + dt * b.speed;
    if (reported != _reported) {
      _reported = reported;
      _drift = reported - next;
      if (_drift.abs() > kAudioResyncThreshold) {
        _value = reported;
        _drift = 0;
        return;
      }
    }
    var correction = _drift * math.min(1.0, dt * kAudioDriftCorrection);
    final floor = -0.5 * dt * b.speed;
    if (correction < floor) correction = floor;
    _drift -= correction;
    next += correction;
    final d = b.duration;
    if (d != null && next > d) next = d;
    if (next > _value) _value = next;
  }
}
