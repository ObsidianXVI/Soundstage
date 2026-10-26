// Behaviours driven by clocks (architecture §9): TextReveal and Lyrics.
// The animator owns them like tracks: each listens to one clock and binds
// to render objects through the node registry.

import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_box.dart';
import '../render/render_stage_host.dart';
import '../render/render_stage_lyrics.dart';
import '../render/render_stage_text.dart';
import '../render/text/text_reveal.dart';

/// A behaviour that follows a clock and writes into render objects.
abstract class StageBehaviorDriver {
  /// The scene clock id it follows, or null when it brings its own
  /// [ownClock].
  String? get clockId;

  /// A clock the animator creates for this driver (lyrics follow their
  /// track's audio position even without a declared audio clock).
  ir.Clock? get ownClock => null;

  /// Node ids it binds to.
  List<String> get targetIds;

  void attach(RenderStageBox box);
  void detach(RenderStageBox box);

  /// The clock's (smoothed) value changed.
  void update(double value);
}

/// The ids of the text nodes inside [frame], depth first (TextReveal
/// members).
List<String> revealMemberIds(ir.ResolvedNode frame) {
  final out = <String>[];
  void visit(ir.ResolvedNode n) {
    for (final c in n.children) {
      if (c.node is ir.TextNode) out.add(c.id);
      visit(c);
    }
  }

  visit(frame);
  return out;
}

/// The drivers of [scene]'s behaviours (TextReveal and Lyrics frames).
List<StageBehaviorDriver> behaviorDriversFor(ir.ResolvedScene scene) {
  final out = <StageBehaviorDriver>[];
  void visit(ir.ResolvedNode n) {
    final node = n.node;
    if (node is ir.FrameNode) {
      switch (node.behavior) {
        case final ir.TextRevealBehavior b:
          final members = revealMemberIds(n);
          if (members.isNotEmpty) out.add(TextRevealDriver(b, members));
        case final ir.LyricsBehavior b:
          for (final c in n.children) {
            if (c.node is ir.TextNode) {
              out.add(LyricsDriver(b, frameId: n.id, templateId: c.id));
              break;
            }
          }
        default:
          break;
      }
    }
    // Media driven by clocks (m3.md T3.6): embed inputs, video scrubbing.
    switch (node) {
      case ir.EmbedNode(:final inputBindings):
        inputBindings.forEach(
          (input, clockId) => out.add(HostInputDriver(n.id, input, clockId)),
        );
      case ir.VideoNode(:final scrubClockId?):
        out.add(HostInputDriver(n.id, kVideoTimeInput, scrubClockId));
      default:
        break;
    }
    for (final c in n.children) {
      visit(c);
    }
  }

  visit(scene.root);
  return out;
}

/// The host input a video's scrub clock drives (its 0–1 progress).
const String kVideoTimeInput = '__time__';

/// Feeds a clock into input [input] of the media node [nodeId] (an embed's
/// Lottie progress or Rive state-machine input, a video's scrub position);
/// see [RenderStageHost.setInput].
class HostInputDriver extends StageBehaviorDriver {
  HostInputDriver(this.nodeId, this.input, this.clockId);

  final String nodeId;
  final String input;

  @override
  final String clockId;

  RenderStageHost? _box;

  /// The clock's last value (the box may attach after it was set).
  double? _last;

  @override
  List<String> get targetIds => [nodeId];

  @override
  void attach(RenderStageBox box) {
    if (box is! RenderStageHost) return;
    _box = box;
    final v = _last;
    if (v != null) box.setInput(input, v);
  }

  @override
  void detach(RenderStageBox box) {
    if (identical(box, _box)) _box = null;
  }

  @override
  void update(double value) {
    _last = value;
    _box?.setInput(input, value);
  }
}

/// Node ids that behaviours repaint every frame (repaint boundaries).
Set<String> behaviorTargetIds(ir.ResolvedScene scene) => {
  for (final d in behaviorDriversFor(scene)) ...d.targetIds,
};

/// TextReveal: reveals the units of every text node inside the frame, in
/// order, as one staggered sequence over the clock's `range` (see
/// `text_reveal.dart` for the timing and the default look). Paint only.
class TextRevealDriver extends StageBehaviorDriver {
  TextRevealDriver(this.behavior, this.memberIds)
    : _boxes = List.filled(memberIds.length, null),
      _members = [];

  final ir.TextRevealBehavior behavior;
  final List<String> memberIds;
  final List<RenderStageText?> _boxes;
  final List<_RevealMember> _members;

  double _progress = 0;
  RevealTiming _timing = RevealTiming(0, 0);
  final List<int> _first = [];

  /// The reveal progress (0–1) through the range.
  double get progress => _progress;

  @override
  String get clockId => behavior.clockId;

  @override
  List<String> get targetIds => memberIds;

  @override
  void attach(RenderStageBox box) {
    final i = memberIds.indexOf(box.nodeId);
    if (i < 0 || box is! RenderStageText) return;
    _boxes[i] = box;
    while (_members.length <= i) {
      _members.add(_RevealMember(this, _members.length));
    }
    box.reveal = _members[i];
  }

  @override
  void detach(RenderStageBox box) {
    final i = memberIds.indexOf(box.nodeId);
    if (i < 0 || !identical(_boxes[i], box)) return;
    _boxes[i] = null;
    if (box is RenderStageText) box.reveal = null;
  }

  @override
  void update(double value) {
    final p = revealProgress(behavior.range, value);
    if (p == _progress) return;
    _progress = p;
    for (final b in _boxes) {
      b?.markNeedsPaint();
    }
  }

  /// Recounts the members' units (their layouts are current at paint).
  void _recount() {
    _first.clear();
    var n = 0;
    for (final b in _boxes) {
      _first.add(n);
      n += b == null ? 0 : b.revealUnitCount(behavior.unit);
    }
    if (n != _timing.count) _timing = RevealTiming(n, behavior.stagger);
  }

  /// The linear progress of member [member]'s unit [i].
  double unitProgress(int member, int i) {
    if (member >= _first.length) _recount();
    return _timing.unit(_first[member] + i, _progress);
  }
}

class _RevealMember implements StageTextRevealPaint {
  _RevealMember(this.driver, this.index);

  final TextRevealDriver driver;
  final int index;

  @override
  ir.TextRevealUnit get unit => driver.behavior.unit;

  @override
  void beginPaint() => driver._recount();

  @override
  double unitProgress(int i) => driver.unitProgress(index, i);
}

/// Lyrics: pushes the audio time of the behaviour's track into the
/// frame's [RenderStageLyrics] (bound under the template text's id).
class LyricsDriver extends StageBehaviorDriver {
  LyricsDriver(
    this.behavior, {
    required this.frameId,
    required this.templateId,
  });

  final ir.LyricsBehavior behavior;
  final String frameId;
  final String templateId;
  RenderStageLyrics? _box;
  double _time = 0;

  @override
  String? get clockId => null;

  @override
  ir.Clock get ownClock => ir.Clock.audio(
    id: '__lyrics/$frameId',
    audioTrackId: behavior.audioTrackId,
  );

  @override
  List<String> get targetIds => [templateId];

  @override
  void attach(RenderStageBox box) {
    if (box is! RenderStageLyrics) return;
    _box = box..time = _time;
  }

  @override
  void detach(RenderStageBox box) {
    if (identical(_box, box)) _box = null;
  }

  @override
  void update(double value) {
    _time = value;
    _box?.time = value;
  }
}
