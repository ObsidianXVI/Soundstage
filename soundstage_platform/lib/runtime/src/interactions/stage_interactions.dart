import 'package:soundstage_platform/ir/ir.dart' as ir;

// Interactions (architecture §10.3; m3.md T3.4): triggers on nodes run
// actions. This class only decides *when* an interaction fires; the player
// supplies what each action does ([StageInteractionHost]), so it is testable
// without one.
//
// - tap: the innermost node under the pointer that has a tap interaction.
// - hoverEnter / hoverLeave: as the pointer enters or leaves a node (or a
//   descendant of it).
// - sceneEnter / sceneLeave: when the scene holding the node starts or stops
//   being visible.
// - clockReach(clock, value) and audioCue(track, time): when the clock (for
//   audio cues, any audio clock following the track) moves across the value,
//   in either direction. The first value seen only arms the trigger.

/// What the actions do, supplied by the player.
class StageInteractionHost {
  const StageInteractionHost({
    this.playTimeline,
    this.pauseTimeline,
    this.reverseTimeline,
    this.seekTimeline,
    this.playAudio,
    this.pauseAudio,
    this.seekAudio,
    this.setVariable,
    this.scrollToScene,
    this.openUrl,
    this.openLightbox,
  });

  final void Function(String clockId)? playTimeline;
  final void Function(String clockId)? pauseTimeline;
  final void Function(String clockId)? reverseTimeline;
  final void Function(String clockId, double seconds)? seekTimeline;
  final void Function(String audioTrackId)? playAudio;
  final void Function(String audioTrackId)? pauseAudio;
  final void Function(String audioTrackId, double seconds)? seekAudio;
  final void Function(String variableId, ir.IrValue value)? setVariable;
  final void Function(String sceneId)? scrollToScene;
  final void Function(String url, {required bool newTab})? openUrl;
  final void Function(String nodeId)? openLightbox;
}

class _Reach {
  _Reach(this.target, this.actions);

  final double target;
  final List<ir.Action> actions;
}

class StageInteractions {
  StageInteractions(this.host);

  StageInteractionHost host;

  final Map<String, List<ir.Interaction>> _byNode = {};
  final Map<String, String> _sceneOf = {};
  final Map<String, List<ir.Action>> _sceneEnter = {};
  final Map<String, List<ir.Action>> _sceneLeave = {};
  final Map<String, List<_Reach>> _reachByClock = {};
  final Map<String, double> _lastClock = {};
  final Map<String, bool> _sceneVisible = {};
  Set<String> _hovered = const {};

  /// Whether any node reacts to the pointer (taps or hovers).
  bool get hasTapTriggers => _hasTap;
  bool get hasHoverTriggers => _hasHover;
  bool _hasTap = false, _hasHover = false;

  /// Indexes the interactions of [doc]. Clock and scene state carries over
  /// for ids that still exist.
  void load(ir.ResolvedDocument doc) {
    _byNode.clear();
    _sceneOf.clear();
    _sceneEnter.clear();
    _sceneLeave.clear();
    _reachByClock.clear();
    _hasTap = _hasHover = false;
    for (final scene in doc.scenes) {
      final audioClocks = <String, List<String>>{};
      for (final c in scene.clocks) {
        if (c case ir.AudioClock(:final id, :final audioTrackId)) {
          (audioClocks[audioTrackId] ??= []).add(id);
        }
      }
      void visit(ir.ResolvedNode n) {
        _sceneOf[n.id] = scene.id;
        final list = n.node.common.interactions;
        if (list.isNotEmpty) {
          _byNode[n.id] = list;
          for (final i in list) {
            switch (i.trigger) {
              case ir.TapTrigger():
                _hasTap = true;
              case ir.HoverEnterTrigger() || ir.HoverLeaveTrigger():
                _hasHover = true;
              case ir.SceneEnterTrigger():
                (_sceneEnter[scene.id] ??= []).addAll(i.actions);
              case ir.SceneLeaveTrigger():
                (_sceneLeave[scene.id] ??= []).addAll(i.actions);
              case ir.ClockReachTrigger(:final clockId, :final value):
                (_reachByClock[clockId] ??= []).add(_Reach(value, i.actions));
              case ir.AudioCueTrigger(:final audioTrackId, :final time):
                for (final c in audioClocks[audioTrackId] ?? const <String>[]) {
                  (_reachByClock[c] ??= []).add(_Reach(time, i.actions));
                }
            }
          }
        }
        n.children.forEach(visit);
      }

      visit(scene.root);
    }
    if (doc.overlay case final o?) {
      void visit(ir.ResolvedNode n) {
        final list = n.node.common.interactions;
        if (list.isNotEmpty) {
          _byNode[n.id] = list;
          for (final i in list) {
            if (i.trigger is ir.TapTrigger) _hasTap = true;
            if (i.trigger is ir.HoverEnterTrigger ||
                i.trigger is ir.HoverLeaveTrigger) {
              _hasHover = true;
            }
          }
        }
        n.children.forEach(visit);
      }

      visit(o);
    }
  }

  void _run(List<ir.Action> actions) {
    final h = host;
    for (final a in actions) {
      switch (a) {
        case ir.PlayTimelineAction(:final clockId):
          h.playTimeline?.call(clockId);
        case ir.PauseTimelineAction(:final clockId):
          h.pauseTimeline?.call(clockId);
        case ir.ReverseTimelineAction(:final clockId):
          h.reverseTimeline?.call(clockId);
        case ir.SeekTimelineAction(:final clockId, :final time):
          h.seekTimeline?.call(clockId, time);
        case ir.PlayAudioAction(:final audioTrackId):
          h.playAudio?.call(audioTrackId);
        case ir.PauseAudioAction(:final audioTrackId):
          h.pauseAudio?.call(audioTrackId);
        case ir.SeekAudioAction(:final audioTrackId, :final time):
          h.seekAudio?.call(audioTrackId, time);
        case ir.SetVariableAction(:final variableId, :final value):
          h.setVariable?.call(variableId, value);
        case ir.ScrollToSceneAction(:final sceneId):
          h.scrollToScene?.call(sceneId);
        case ir.OpenUrlAction(:final url, :final newTab):
          h.openUrl?.call(url, newTab: newTab);
        case ir.OpenLightboxAction(:final nodeId):
          h.openLightbox?.call(nodeId);
      }
    }
  }

  List<ir.Action> _actions(
    String nodeId,
    bool Function(ir.InteractionTrigger) f,
  ) => [
    for (final i in _byNode[nodeId] ?? const <ir.Interaction>[])
      if (f(i.trigger)) ...i.actions,
  ];

  /// A tap on the nodes [path] (innermost first): the first with a tap
  /// interaction runs it. Returns whether one did.
  bool tap(List<String> path) {
    for (final id in path) {
      final a = _actions(id, (t) => t is ir.TapTrigger);
      if (a.isNotEmpty) {
        _run(a);
        return true;
      }
    }
    return false;
  }

  /// The pointer is over [path] (innermost first; empty when it left).
  void hover(List<String> path) {
    final now = {
      for (final id in path)
        if (_byNode.containsKey(id)) id,
    };
    for (final id in _hovered) {
      if (!now.contains(id)) {
        _run(_actions(id, (t) => t is ir.HoverLeaveTrigger));
      }
    }
    for (final id in now) {
      if (!_hovered.contains(id)) {
        _run(_actions(id, (t) => t is ir.HoverEnterTrigger));
      }
    }
    _hovered = now;
  }

  /// Scene [sceneId] is (or is no longer) visible.
  void sceneVisible(String sceneId, {required bool visible}) {
    final was = _sceneVisible[sceneId] ?? false;
    if (was == visible) return;
    _sceneVisible[sceneId] = visible;
    final a = visible ? _sceneEnter[sceneId] : _sceneLeave[sceneId];
    if (a != null) _run(a);
  }

  /// Clock [clockId] is now at [value].
  void clock(String clockId, double value) {
    final reaches = _reachByClock[clockId];
    final last = _lastClock[clockId];
    _lastClock[clockId] = value;
    if (reaches == null || last == null || last == value) return;
    final lo = last < value ? last : value;
    final hi = last < value ? value : last;
    for (final r in reaches) {
      // Half-open toward the new value: a clock resting on the target
      // fires once on arrival, not again as it leaves.
      final crossed = last < value
          ? r.target > lo && r.target <= hi
          : r.target >= lo && r.target < hi;
      if (crossed) _run(r.actions);
    }
  }

  /// The scene of node [nodeId], if known.
  String? sceneOf(String nodeId) => _sceneOf[nodeId];
}
