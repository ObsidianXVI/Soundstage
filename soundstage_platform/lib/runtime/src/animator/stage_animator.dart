import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../clocks/clock_source.dart';
import '../clocks/smoothing.dart';
import '../clocks/timeline_clock.dart';
import '../render/render_stage_box.dart';
import '../render/stage_environment.dart';
import 'behavior_drivers.dart';
import 'compiled_track.dart';
import 'node_registry.dart';
import 'text_style_tracks.dart';

/// Writes animated values into render objects (architecture §14, §17.1).
///
/// - [load] compiles every track of a `ResolvedDocument` into a
///   [CompiledTrack] and groups the tracks by clock.
/// - Each track's target is bound once, when its render object attaches
///   (through the [StageNodeRegistry]); tracks of scenes outside the lazy
///   window have no target and cost nothing.
/// - `opacity` and `motion.*` tracks write typed slots on the render object
///   ([RenderStageBox.setAnimatedSlot], allocation-free; a repaint boundary
///   only updates its composited layers).
/// - Every other track is offered to a [StageTypedTrackHost] render object,
///   which may apply it itself in typed form: frames and shapes take the
///   numeric and colour appearance tracks (typed paint overrides, read by
///   the paint seam at paint time), text takes its style tracks.
/// - Every other property goes through the node's
///   [RenderStageBox.nodeAnimator], which re-applies the node's animated
///   values through the property registry (allocates a node copy per
///   changed node per frame; paint or layout invalidation by what changed).
/// - **One ticker.** It runs only while something moves by itself: a
///   playing timeline, an active audio source, or a smoothed clock that has
///   not settled. Each tick advances sources, applies smoothing, and
///   evaluates the groups whose clock value changed.
/// - Scroll and pointer input arrive outside the ticker
///   ([sceneScrolled], [pointerMoved]). Unsmoothed clocks evaluate
///   immediately, so scroll-linked motion lands in the same frame as the
///   scroll (no one-frame lag).
/// - **Edit mode** freezes clocks at [clockOverrides] (the editor's
///   playhead; 0 when absent). Pointer and behaviour clocks are inert (0).
///   The ticker never runs.
///
/// Nothing here calls `setState` or rebuilds widgets.
class StageAnimator implements StageNodeListener {
  StageAnimator({
    required this.registry,
    required TickerProvider vsync,
    this.mode = StageRenderMode.play,
    this._clockOverrides = const {},
    this.factories = const StageClockFactories(),
    ir.PropertyRegistry? properties,
  }) : properties = properties ?? ir.PropertyRegistry.standard {
    _ticker = vsync.createTicker(_onTick);
    registry.listener = this;
  }

  final StageNodeRegistry registry;
  final StageRenderMode mode;
  final StageClockFactories factories;
  final ir.PropertyRegistry properties;

  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// Longest wall-time step a tick applies (after a stalled or hidden tab).
  static const double maxStep = 0.1;

  final List<_Clock> _clocks = [];
  final Map<String, _Clock> _byKey = {};
  final Map<String, List<_Binding>> _byTarget = {};
  final Map<String, _NodeTarget> _nodeTargets = {};
  final Map<String, List<StageBehaviorDriver>> _drivers = {};
  final Map<String, List<_Clock>> _scrollClocks = {};
  final Map<String, List<_Clock>> _sceneClocks = {};
  final Map<String, bool> _sceneVisible = {};
  final List<_NodeTarget> _dirty = [];
  bool _disposed = false;

  Map<String, double> _clockOverrides;

  /// Edit mode: clock values by clock id (the editor's playhead).
  Map<String, double> get clockOverrides => _clockOverrides;
  set clockOverrides(Map<String, double> value) {
    if (identical(value, _clockOverrides)) return;
    _clockOverrides = value;
    if (mode != StageRenderMode.edit) return;
    for (final c in _clocks) {
      _setValue(c, _frozenValue(c));
    }
    _flush();
  }

  bool _reducedMotion = false;

  /// `prefers-reduced-motion`: clock smoothing is off (scroll-driven
  /// tracks still map straight to the scroll position) and `autoplay` /
  /// `sceneEnter` timelines jump to their end state instead of playing.
  /// Audio is unaffected. Ignored in edit mode, where clocks are frozen.
  bool get reducedMotion => _reducedMotion;
  set reducedMotion(bool value) {
    if (value == _reducedMotion) return;
    _reducedMotion = value;
    if (mode == StageRenderMode.edit) return;
    for (final c in _clocks) {
      _applyReducedMotion(c);
      if (!value) {
        final visible = _sceneVisible[c.sceneId];
        if (visible != null) c.source.sceneVisibilityChanged(visible: visible);
      }
    }
    tick(0);
    _scheduleIfActive();
  }

  void _applyReducedMotion(_Clock c) {
    c.smoother.smoothing = _reducedMotion ? 0 : _Clock._smoothingOf(c.clock);
    c.source.reducedMotionChanged(reduced: _reducedMotion);
    c.pending = true;
  }

  /// Whether the ticker is running (tests).
  bool get isTicking => _ticker.isActive;

  /// Number of compiled tracks (tests, diagnostics).
  int get trackCount => _byTarget.values.fold(0, (n, l) => n + l.length);

  /// Number of tracks whose target is currently attached.
  int get boundTrackCount {
    var n = 0;
    for (final l in _byTarget.values) {
      for (final b in l) {
        if (b.box != null) n++;
      }
    }
    return n;
  }

  // ---- Loading ------------------------------------------------------------------

  /// Compiles [doc]'s tracks and binds them to attached render objects.
  /// Clock state (timeline playheads, smoothing) survives for clocks that
  /// keep their scene, id and definition.
  void load(ir.ResolvedDocument doc) {
    // Unbind the previous document's overrides.
    for (final list in _byTarget.values) {
      for (final b in list) {
        final box = b.box;
        if (box != null && b.slot >= 0) box.setAnimatedSlot(b.slot, double.nan);
        b.unbindTyped();
      }
    }
    for (final t in _nodeTargets.values) {
      t.box?.nodeAnimator = null;
    }
    _drivers.forEach((id, list) {
      final box = registry[id];
      if (box == null) return;
      for (final d in list) {
        d.detach(box);
      }
    });
    _drivers.clear();
    _byTarget.clear();
    _nodeTargets.clear();
    _scrollClocks.clear();
    _sceneClocks.clear();
    _dirty.clear();

    final previous = Map.of(_byKey);
    _clocks.clear();
    _byKey.clear();
    for (final scene in doc.scenes) {
      for (final clock in scene.clocks) {
        final key = '${scene.id}\u0000${clock.id}';
        final old = previous.remove(key);
        final c = old != null && old.clock == clock
            ? (old
                ..bindings.clear()
                ..drivers.clear())
            : _newClock(scene.id, clock);
        if (old != null && !identical(old, c)) old.source.dispose();
        _clocks.add(c);
        _byKey[key] = c;
        (_sceneClocks[scene.id] ??= []).add(c);
        if (clock is ir.SceneScrollClock) {
          (_scrollClocks[clock.sceneId] ??= []).add(c);
        }
        final visible = _sceneVisible[scene.id];
        if (visible != null) {
          c.source.sceneVisibilityChanged(visible: visible);
        }
      }
      // Behaviours (TextReveal, Lyrics) follow a clock like tracks do.
      for (final d in behaviorDriversFor(scene)) {
        final own = d.ownClock;
        _Clock? c;
        if (own != null) {
          final key = '${scene.id}\u0000${own.id}';
          final old = previous.remove(key);
          c = old != null && old.clock == own
              ? (old
                  ..bindings.clear()
                  ..drivers.clear())
              : _newClock(scene.id, own);
          if (old != null && !identical(old, c)) old.source.dispose();
          _clocks.add(c);
          _byKey[key] = c;
          (_sceneClocks[scene.id] ??= []).add(c);
          final visible = _sceneVisible[scene.id];
          if (visible != null) {
            c.source.sceneVisibilityChanged(visible: visible);
          }
        } else {
          c = _byKey['${scene.id}\u0000${d.clockId}'];
        }
        if (c == null) continue;
        c.drivers.add(d);
        d.update(c.value);
        for (final id in d.targetIds) {
          (_drivers[id] ??= []).add(d);
        }
      }
      for (final track in scene.tracks) {
        final clock = _byKey['${scene.id}\u0000${track.clockId}'];
        if (clock == null) continue;
        final compiled = CompiledTrack.compile(track, registry: properties);
        if (compiled.match == null || compiled.keyframes.isEmpty) continue;
        final slot = RenderStageBox.slotForPath(track.property);
        final binding = _Binding(compiled, track.target, slot, clock);
        clock.bindings.add(binding);
        (_byTarget[track.target] ??= []).add(binding);
        if (slot < 0) {
          final target = _nodeTargets[track.target] ??= _NodeTarget(
            track.target,
          );
          target.bindings.add(binding);
          binding.node = target;
        }
      }
    }
    for (final old in previous.values) {
      old.source.dispose();
    }
    for (final id in {..._byTarget.keys, ..._drivers.keys}) {
      final box = registry[id];
      if (box != null) nodeAttached(box);
    }
    _flush();
    _scheduleIfActive();
  }

  _Clock _newClock(String sceneId, ir.Clock clock) {
    final source = createClockSource(
      clock,
      sceneId: sceneId,
      factories: factories,
    );
    final c = _Clock(sceneId, clock, source);
    if (_reducedMotion && mode != StageRenderMode.edit) {
      c.smoother.smoothing = 0;
      source.reducedMotionChanged(reduced: true);
    }
    c.value = mode == StageRenderMode.edit ? _frozenValue(c) : source.value;
    c.smoother.reset(c.value);
    return c;
  }

  double _frozenValue(_Clock c) => switch (c.clock) {
    ir.PointerClock() || ir.BehaviorClock() => 0,
    _ => _clockOverrides[c.clock.id] ?? 0,
  };

  // ---- Binding ------------------------------------------------------------------

  @override
  void nodeAttached(RenderStageBox box) {
    for (final d in _drivers[box.nodeId] ?? const <StageBehaviorDriver>[]) {
      d.attach(box);
    }
    final list = _byTarget[box.nodeId];
    if (list == null) return;
    for (final b in list) {
      b.unbindTyped();
      b.box = box;
      b.track.evaluate(b.clock.value);
      if (b.slot >= 0) {
        box.setAnimatedSlot(b.slot, b.track.scalar);
      } else if (box is StageTypedTrackHost) {
        // Typed hosts (text styles) apply the track themselves.
        final host = box as StageTypedTrackHost;
        final handle = host.bindTrack(b.track);
        if (handle != null) {
          b
            ..host = host
            ..handle = handle;
        }
      }
    }
    final target = _nodeTargets[box.nodeId];
    if (target != null) {
      target.box = box;
      final untyped = target.bindings.any((b) => b.handle == null);
      box.nodeAnimator = untyped ? target.animate : null;
    }
  }

  @override
  void nodeDetached(RenderStageBox box) {
    for (final d in _drivers[box.nodeId] ?? const <StageBehaviorDriver>[]) {
      d.detach(box);
    }
    final list = _byTarget[box.nodeId];
    if (list == null) return;
    for (final b in list) {
      if (identical(b.box, box)) {
        b.unbindTyped();
        b.box = null;
      }
    }
    final target = _nodeTargets[box.nodeId];
    if (target != null && identical(target.box, box)) target.box = null;
  }

  // ---- Inputs -------------------------------------------------------------------

  /// A scene's sliver laid out: its scroll progress (0–1) and whether any
  /// of it is on screen. Called from the sliver's layout, inside a layout
  /// callback, so values pushed into the scene's own nodes (including
  /// layout-class ones) apply in this frame.
  void sceneScrolled(
    String sceneId, {
    required double progress,
    required bool visible,
  }) {
    if (_disposed) return;
    if (_sceneVisible[sceneId] != visible) {
      _sceneVisible[sceneId] = visible;
      final clocks = _sceneClocks[sceneId];
      if (clocks != null && mode == StageRenderMode.play) {
        for (final c in clocks) {
          c.source.sceneVisibilityChanged(visible: visible);
        }
      }
    }
    final clocks = _scrollClocks[sceneId];
    if (clocks != null) {
      for (var i = 0; i < clocks.length; i++) {
        final c = clocks[i];
        final source = c.source;
        if (source is StageValueClockSource) source.value = progress;
        // Only the scene's own nodes may change during its layout.
        _external(c, immediate: c.sceneId == sceneId);
      }
    }
    _flush();
    _scheduleIfActive();
  }

  /// The pointer moved to [globalPosition] (hover); null when it left the
  /// player, which returns pointer clocks to 0.
  void pointerMoved(Offset? globalPosition) {
    if (_disposed || mode != StageRenderMode.play) return;
    for (final c in _clocks) {
      final source = c.source;
      if (source is! StagePointerSource) continue;
      final box = registry[source.frameId];
      var v = 0.0;
      if (globalPosition != null &&
          box != null &&
          box.attached &&
          box.hasSize) {
        final local = box.globalToLocal(globalPosition);
        final s = box.size;
        if (s.contains(local) && s.width > 0 && s.height > 0) {
          v = source.axis == ir.PointerAxis.x
              ? local.dx / s.width * 2 - 1
              : local.dy / s.height * 2 - 1;
          v = v.clamp(-1.0, 1.0);
        }
      }
      if (v != source.value) {
        source.value = v;
        _external(c, immediate: true);
      }
    }
    _flush();
    _scheduleIfActive();
  }

  /// The pointer left the player: pointer clocks return to 0.
  void pointerExited() => pointerMoved(null);

  /// A source changed from outside the ticker. Unsmoothed clocks evaluate
  /// now when [immediate]; others are picked up by the next tick.
  @pragma('vm:prefer-inline')
  void _external(_Clock c, {required bool immediate}) {
    if (mode == StageRenderMode.edit) return;
    if (c.smoother.smoothing <= 0 && immediate) {
      final v = c.source.value;
      c.smoother.reset(v);
      _setValue(c, v);
    } else {
      c.pending = true;
    }
  }

  /// Re-reads every clock source now (after a source changed outside the
  /// player, e.g. a T0.7 audio seek).
  void notifyClockChanged() {
    for (final c in _clocks) {
      c.pending = true;
    }
    _scheduleIfActive(force: true);
  }

  // ---- Control ------------------------------------------------------------------

  /// The timeline clock [clockId] (first match across scenes), for
  /// play/pause/seek. Call [notifyClockChanged] after seeking a paused
  /// timeline, or use [playTimeline] / [seekTimeline].
  StageTimelineSource? timeline(String clockId) {
    for (final c in _clocks) {
      final s = c.source;
      if (c.clock.id == clockId && s is StageTimelineSource) return s;
    }
    return null;
  }

  void playTimeline(String clockId) {
    timeline(clockId)?.play();
    notifyClockChanged();
  }

  void pauseTimeline(String clockId) => timeline(clockId)?.pause();

  void seekTimeline(String clockId, double seconds) {
    timeline(clockId)?.seek(seconds);
    notifyClockChanged();
  }

  /// The current (smoothed) value of clock [clockId], or null.
  double? clockValue(String clockId) {
    for (final c in _clocks) {
      if (c.clock.id == clockId) return c.value;
    }
    return null;
  }

  // ---- Frames -------------------------------------------------------------------

  void _scheduleIfActive({bool force = false}) {
    if (_disposed || mode != StageRenderMode.play) return;
    if (_ticker.isActive) return;
    if (force || _needsFrames()) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
  }

  bool _needsFrames() {
    for (var i = 0; i < _clocks.length; i++) {
      final c = _clocks[i];
      if (c.pending || c.source.isActive) return true;
      if (!c.smoother.settledOn(c.source.value)) return true;
    }
    return false;
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt < 0) dt = 0;
    if (dt > maxStep) dt = maxStep;
    tick(dt);
    if (!_needsFrames()) _ticker.stop();
  }

  /// Advances every clock by [dt] seconds and pushes changed values. The
  /// ticker calls this; tests and benchmarks may call it directly.
  void tick(double dt) {
    for (var i = 0; i < _clocks.length; i++) {
      final c = _clocks[i];
      c.pending = false;
      c.source.advance(dt);
      if (c.smoother.step(c.source.value, dt) || c.value != c.smoother.value) {
        _setValue(c, c.smoother.value);
      }
    }
    _flush();
  }

  @pragma('vm:prefer-inline')
  void _setValue(_Clock c, double v) {
    c.value = v;
    if (c.evaluatedAt == v) return;
    c.evaluatedAt = v;
    final bindings = c.bindings;
    for (var i = 0; i < bindings.length; i++) {
      final b = bindings[i];
      final box = b.box;
      if (box == null) continue;
      if (!b.track.evaluate(v)) continue;
      if (b.slot >= 0) {
        box.setAnimatedSlotFrom(b.slot, b.track.out, 0);
      } else if (b.handle != null) {
        b.host!.trackChanged(b.handle!);
      } else {
        final target = b.node!;
        if (!target.dirty) {
          target.dirty = true;
          _dirty.add(target);
        }
      }
    }
    final drivers = c.drivers;
    for (var i = 0; i < drivers.length; i++) {
      drivers[i].update(v);
    }
  }

  void _flush() {
    if (_dirty.isEmpty) return;
    for (var i = 0; i < _dirty.length; i++) {
      final t = _dirty[i];
      t.dirty = false;
      t.box?.refreshAnimatedNode();
    }
    _dirty.clear();
  }

  void dispose() {
    _disposed = true;
    _ticker.dispose();
    if (identical(registry.listener, this)) registry.listener = null;
    for (final c in _clocks) {
      c.source.dispose();
    }
  }
}

class _Clock {
  _Clock(this.sceneId, this.clock, this.source)
    : smoother = StageSmoother(smoothing: _smoothingOf(clock));

  /// The scene that declares the clock.
  final String sceneId;
  final ir.Clock clock;
  final StageClockSource source;
  final StageSmoother smoother;
  final List<_Binding> bindings = [];
  final List<StageBehaviorDriver> drivers = [];

  /// The current (smoothed) value.
  double value = 0;

  /// The value the bindings were last evaluated at (NaN: never).
  double evaluatedAt = double.nan;

  /// A source changed outside the ticker and awaits the next tick.
  bool pending = false;

  static double _smoothingOf(ir.Clock c) => switch (c) {
    ir.SceneScrollClock(:final smoothing) ||
    ir.TimelineClock(:final smoothing) ||
    ir.AudioClock(:final smoothing) ||
    ir.PointerClock(:final smoothing) ||
    ir.BehaviorClock(:final smoothing) => smoothing,
  };
}

class _Binding {
  _Binding(this.track, this.targetId, this.slot, this.clock);

  final CompiledTrack track;
  final String targetId;

  /// The typed slot (`opacity`, `motion.*`), or −1 for node-level.
  final int slot;
  final _Clock clock;

  RenderStageBox? box;
  _NodeTarget? node;

  /// A typed host applying this track itself, and its handle.
  StageTypedTrackHost? host;
  Object? handle;

  void unbindTyped() {
    final h = handle;
    if (h != null) host?.unbindTrack(h);
    host = null;
    handle = null;
  }
}

/// A node with node-level (non-slot) animated properties.
class _NodeTarget {
  _NodeTarget(this.id);

  final String id;
  final List<_Binding> bindings = [];
  RenderStageBox? box;
  bool dirty = false;

  late final ir.Node Function(ir.Node) animate = _apply;

  ir.Node _apply(ir.Node resolved) {
    var n = resolved;
    for (final b in bindings) {
      if (b.handle != null) continue;
      final v = b.track.value;
      final match = b.track.match;
      if (v == null || match == null) continue;
      n = match.set(n, v);
    }
    return n;
  }
}
