import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/commands/gesture_commands.dart';
import '../core/commands/motion_commands.dart';
import '../core/editor_controller.dart';
import '../shortcuts/shortcut_map.dart' show primaryFocusIsTextInput;
import 'easing_hook.dart';
import 'timeline_actions.dart';
import 'timeline_math.dart';
import 'timeline_model.dart';

/// Row height of the lanes (groups and properties).
const double kTimelineRowHeight = 24;

/// Height of the header (title, clock picker, transport).
const double kTimelineHeaderHeight = 32;

/// Height of the ruler.
const double kTimelineRulerHeight = 24;

/// Width of the label column (node and property names).
const double kTimelineLabelWidth = 200;

/// Keyframe hit radius and snap distance, in pixels.
const double kKeyframeHitRadius = 6;

/// The timeline (m2.md "Timeline lanes", architecture §15.1): the bottom
/// panel of the docked editor.
///
/// - Header: clock picker (the active scene's clocks), transport (play /
///   pause and loop, timeline and audio clocks only), the playhead readout,
///   the auto-key state and the collapse toggle.
/// - Ruler in clock units (0–100 % for scene scroll); drag it, or the
///   playhead, to scrub. Cmd/Ctrl+wheel zooms, the wheel pans.
/// - Lanes: virtualised rows grouped by node then animated property. A
///   lane click selects its node; selecting a node elsewhere scrolls to and
///   highlights its group.
/// - Keyframes: click, Shift-click, box-select, drag (snapping to the
///   playhead, other keyframes and ruler ticks; Shift disables it),
///   Alt-drag duplicates, Delete, Cmd+C / Cmd+V (paste at the playhead),
///   arrows nudge. One undo step per gesture. Double-click a segment for
///   its easing ([EasingHook]).
/// - Space plays or pauses (no text input focused, no canvas pan with the
///   Space hand).
/// - While auto-key is on, the panel and the playhead are tinted red.
///
/// Scrubbing writes `EditorState.playheads` only: the lanes do not rebuild
/// (the playhead line and the readout listen on their own).
class TimelinePanel extends ConsumerStatefulWidget {
  const TimelinePanel({
    required this.open,
    required this.onToggle,
    this.height = 220,
    this.onResize,
    super.key,
  });

  /// Expanded (lanes shown) or collapsed to the header.
  final bool open;
  final VoidCallback onToggle;

  /// The expanded height.
  final double height;

  /// Called with the vertical drag of the top edge (positive = down).
  final ValueChanged<double>? onResize;

  @override
  ConsumerState<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends ConsumerState<TimelinePanel>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  bool _spaceArmed = false;
  bool _pointerWhileSpace = false;

  // Kept from initState: dispose must not use ref.
  late final TimelineController _tl = ref.read(timelineControllerProvider);
  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    _tl.playing.addListener(_playingChanged);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _tl.playing.removeListener(_playingChanged);
    if (_tl.playing.value) _tl.playing.value = false;
    _ticker.dispose();
    super.dispose();
  }

  // ---- Transport --------------------------------------------------------------

  ({ir.Scene scene, ir.Clock clock, ClockSpan span})? _active() {
    final st = ref.read(editorControllerProvider);
    final scene = st.activeScene;
    final id = st.activeClockId;
    if (scene == null || id == null) return null;
    final clock = scene.clocks.firstWhere((c) => c.id == id);
    return (
      scene: scene,
      clock: clock,
      span: clockSpan(st.document, scene, clock),
    );
  }

  /// Plays or pauses the active clock (timeline and audio clocks only).
  void _togglePlay() {
    final a = _active();
    if (a == null || !a.span.playable) {
      _tl.playing.value = false;
      return;
    }
    if (!_tl.playing.value) {
      // From the end of a non-looping clock, play again from the start.
      final st = ref.read(editorControllerProvider);
      if (!_tl.loopsOn(a.clock) && st.playhead >= a.span.max) {
        _editor.setPlayhead(a.scene.id, a.clock.id, a.span.min);
      }
    }
    _tl.playing.value = !_tl.playing.value;
  }

  void _playingChanged() {
    if (_tl.playing.value) {
      _lastTick = Duration.zero;
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final a = _active();
    if (a == null || !a.span.playable) {
      _tl.playing.value = false;
      return;
    }
    final rate = switch (a.clock) {
      ir.TimelineClock(:final rate) => rate,
      _ => 1.0,
    };
    final st = ref.read(editorControllerProvider);
    var t = st.playhead + dt * rate;
    final span = a.span;
    if (t >= span.max) {
      if (_tl.loopsOn(a.clock) && span.span > 0) {
        t = span.min + (t - span.max) % span.span;
      } else {
        t = span.max;
        _tl.playing.value = false;
      }
    }
    _editor.setPlayhead(a.scene.id, a.clock.id, t);
  }

  // ---- Space ------------------------------------------------------------------

  /// Space plays or pauses on release (timeline and audio clocks), unless a
  /// text input has focus, the focused control takes Space itself (a
  /// focused button presses), or a pointer went down while it was held (the
  /// canvas's Space hand).
  bool _onKey(KeyEvent e) {
    if (e.logicalKey != LogicalKeyboardKey.space || !mounted) return false;
    if (e is KeyDownEvent) {
      final a = _active();
      _spaceArmed =
          a != null &&
          a.span.playable &&
          !primaryFocusIsTextInput() &&
          !_focusTakesSpace();
      _pointerWhileSpace = false;
    } else if (e is KeyUpEvent) {
      if (_spaceArmed && !_pointerWhileSpace) _togglePlay();
      _spaceArmed = false;
    }
    return false;
  }

  /// Whether the focused widget activates on Space (a button).
  static bool _focusTakesSpace() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    final action = Actions.maybeFind<ActivateIntent>(ctx);
    return action != null && action.isEnabled(const ActivateIntent());
  }

  void _onGlobalPointer(PointerEvent e) {
    if (e is PointerDownEvent && _spaceArmed) _pointerWhileSpace = true;
  }

  // ---- Build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final autoKey = ref.watch(
      editorControllerProvider.select((s) => s.autoKey),
    );
    final tint = c.danger;
    return Container(
      key: const ValueKey<String>('timeline'),
      height: widget.open ? widget.height : kTimelineHeaderHeight + 1,
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(
          top: BorderSide(
            color: autoKey ? tint : c.borderSubtle,
            width: autoKey ? 2 : 1,
          ),
        ),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              _Header(
                open: widget.open,
                onToggle: widget.onToggle,
                onTogglePlay: _togglePlay,
              ),
              if (widget.open) const Expanded(child: _TimelineBody()),
            ],
          ),
          if (autoKey)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  key: const ValueKey<String>('timeline-autokey-tint'),
                  color: tint.withValues(alpha: 0.05),
                ),
              ),
            ),
          if (widget.open && widget.onResize != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 5,
              child: _ResizeEdge(onDelta: widget.onResize!),
            ),
        ],
      ),
    );
  }
}

/// The draggable top edge of the expanded timeline.
class _ResizeEdge extends StatelessWidget {
  const _ResizeEdge({required this.onDelta});

  final ValueChanged<double> onDelta;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Resize timeline',
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        key: const ValueKey<String>('timeline-resize'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onDelta(d.delta.dy),
      ),
    ),
  );
}

// ---- Header ------------------------------------------------------------------------

class _Header extends ConsumerWidget {
  const _Header({
    required this.open,
    required this.onToggle,
    required this.onTogglePlay,
  });

  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onTogglePlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final tl = ref.watch(timelineControllerProvider);
    final editor = ref.read(editorControllerProvider.notifier);
    final autoKey = ref.watch(
      editorControllerProvider.select((s) => s.autoKey),
    );
    final scene = ref.watch(
      editorControllerProvider.select((s) => s.activeScene),
    );
    final clockId = ref.watch(
      editorControllerProvider.select((s) => s.activeClockId),
    );
    final doc = ref.read(editorControllerProvider).document;
    final clock = scene?.clocks.where((k) => k.id == clockId).firstOrNull;
    final span = scene == null || clock == null
        ? null
        : clockSpan(doc, scene, clock);
    final playable = span?.playable ?? false;
    return SizedBox(
      height: kTimelineHeaderHeight,
      child: Row(
        children: [
          const SizedBox(width: SsSpace.s3),
          Text('Timeline', style: t.text.bodyStrong),
          const SizedBox(width: SsSpace.s3),
          if (scene != null && clock != null) ...[
            SizedBox(
              width: 200,
              child: SsDropdown<String>(
                key: const ValueKey<String>('timeline-clock'),
                semanticLabel: 'Clock',
                value: clock.id,
                items: [
                  for (final k in scene.clocks)
                    SsDropdownItem(value: k.id, label: clockLabel(doc, k)),
                ],
                onChanged: (id) {
                  tl.playing.value = false;
                  tl.clearSelection();
                  editor.setActiveClock(scene.id, id);
                },
              ),
            ),
            const SizedBox(width: SsSpace.s2),
            ValueListenableBuilder<bool>(
              valueListenable: tl.playing,
              builder: (context, playing, _) => SsIconButton(
                key: const ValueKey<String>('timeline-play'),
                icon: playing ? SsIcons.pause : SsIcons.play,
                semanticLabel: playing ? 'Pause' : 'Play',
                tooltip: playable
                    ? null
                    : 'Play and loop apply to timeline and audio clocks',
                shortcut: 'Space',
                size: 26,
                iconSize: 14,
                onPressed: playable ? onTogglePlay : null,
              ),
            ),
            ValueListenableBuilder<Map<String, bool>>(
              valueListenable: tl.loops,
              builder: (context, _, _) => SsIconButton(
                key: const ValueKey<String>('timeline-loop'),
                icon: SsIcons.repeat,
                semanticLabel: 'Loop',
                selected: playable && tl.loopsOn(clock),
                size: 26,
                iconSize: 14,
                onPressed: playable
                    ? () => tl.setLoop(clock.id, !tl.loopsOn(clock))
                    : null,
              ),
            ),
            const SizedBox(width: SsSpace.s2),
            if (span != null) _PlayheadReadout(unit: span.unit),
            const SizedBox(width: SsSpace.s3),
            ValueListenableBuilder<SegmentRef?>(
              valueListenable: tl.easingSegment,
              builder: (context, seg, _) => seg == null
                  ? const SizedBox.shrink()
                  : EasingHook(
                      segment: seg,
                      onClose: () => tl.easingSegment.value = null,
                    ),
            ),
          ],
          const Spacer(),
          if (autoKey)
            Padding(
              padding: const EdgeInsets.only(right: SsSpace.s2),
              child: Row(
                key: const ValueKey<String>('timeline-autokey'),
                children: [
                  SsIcon(SsIcons.timer, size: 14, color: c.danger),
                  const SizedBox(width: SsSpace.s1),
                  Text(
                    'Auto-key',
                    style: t.text.caption.copyWith(color: c.danger),
                  ),
                ],
              ),
            ),
          if (open && span != null)
            SsIconButton(
              key: const ValueKey<String>('timeline-fit'),
              icon: SsIcons.expand,
              semanticLabel: 'Fit the clock in view',
              size: 24,
              iconSize: 14,
              onPressed: () => tl.setView(
                TimelineController.viewKey(scene!.id, clock!.id),
                TimelineView.fit(span, _laneWidth(context)),
              ),
            ),
          SsIconButton(
            icon: open ? SsIcons.chevronDown : SsIcons.chevronUp,
            semanticLabel: open ? 'Collapse timeline' : 'Expand timeline',
            size: 24,
            iconSize: 14,
            onPressed: onToggle,
          ),
          const SizedBox(width: SsSpace.s1),
        ],
      ),
    );
  }

  static double _laneWidth(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final w = box?.size.width ?? 800;
    return math.max(1, w - kTimelineLabelWidth);
  }
}

/// The playhead's value, rebuilt on its own while scrubbing.
class _PlayheadReadout extends ConsumerWidget {
  const _PlayheadReadout({required this.unit});

  final ClockUnit unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final p = ref.watch(editorControllerProvider.select((s) => s.playhead));
    return SizedBox(
      width: 64,
      child: Text(
        formatClockValue(p, unit),
        key: const ValueKey<String>('timeline-readout'),
        style: t.text.numeric,
      ),
    );
  }
}

// ---- Body ----------------------------------------------------------------------------

/// What the body shows: the active scene, clock and span, and the rows.
class _BodyModel {
  _BodyModel(this.doc, this.scene, this.clock, this.span, this.rows);

  final ir.StageDocument doc;
  final ir.Scene scene;
  final ir.Clock clock;
  final ClockSpan span;
  final List<TimelineRow> rows;

  String get viewKey => TimelineController.viewKey(scene.id, clock.id);
}

class _TimelineBody extends ConsumerStatefulWidget {
  const _TimelineBody();

  @override
  ConsumerState<_TimelineBody> createState() => _TimelineBodyState();
}

/// A pending press in the lanes that has not become a drag yet, or the drag
/// it became.
class _LanePress {
  _LanePress({
    required this.at,
    required this.row,
    required this.hit,
    required this.shift,
    required this.alt,
  });

  final Offset at;
  final int row;
  final KeyframeRef? hit;
  final bool shift, alt;
  bool dragging = false;

  /// Shift-down on a selected keyframe: it leaves the selection on release
  /// unless the press became a drag (Shift-dragging a selection).
  bool deselectOnUp = false;

  /// Keyframe drag: the base document, grabbed time, dragged keyframes and
  /// their times, the duplicates' ids (Alt), the gesture's coalescing key.
  ir.StageDocument? base;
  double grabbedT = 0;
  Map<KeyframeRef, double> times = const {};
  Map<KeyframeRef, String> copies = const {};
  String key = '';

  /// Box select: the selection before it (Shift adds to it).
  Set<KeyframeRef> before = const {};

  /// Scrubbing the playhead line.
  bool scrub = false;
}

class _TimelineBodyState extends ConsumerState<_TimelineBody> {
  final ScrollController _rows = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'timeline');
  final ValueNotifier<Rect?> _marquee = ValueNotifier(null);
  late final _PlayheadSource _playhead = _PlayheadSource(ref);
  _LanePress? _press;
  _BodyModel? _model;
  double _laneWidth = 1;

  // Double-click tracking: the last click (a press released without a
  // drag).
  Duration? _lastClickAt;
  Offset? _lastClickPos;

  TimelineController get _tl => ref.read(timelineControllerProvider);
  EditorController get _editor => ref.read(editorControllerProvider.notifier);
  TimelineActions get _actions =>
      TimelineActions(_editor, _tl, () => ref.read(editorControllerProvider));

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      editorControllerProvider.select((s) => s.selection.firstOrNull),
      (_, id) => _revealNode(id),
    );
  }

  @override
  void dispose() {
    _rows.dispose();
    _focus.dispose();
    _marquee.dispose();
    _playhead.dispose();
    super.dispose();
  }

  /// Scrolls the group of node [id] into view (selection on the canvas).
  void _revealNode(String? id) {
    final m = _model;
    if (id == null || m == null || !_rows.hasClients) return;
    final i = m.rows.indexWhere((r) => r is GroupRow && r.nodeId == id);
    if (i < 0) return;
    final top = i * kTimelineRowHeight;
    final pos = _rows.position;
    final view = pos.viewportDimension;
    if (top >= pos.pixels && top + kTimelineRowHeight <= pos.pixels + view) {
      return;
    }
    final target = (top - kTimelineRowHeight).clamp(0.0, pos.maxScrollExtent);
    _rows.animateTo(target, duration: SsMotion.base, curve: SsMotion.easeOut);
  }

  TimelineView _view(_BodyModel m) =>
      _tl.viewOf(m.viewKey, () => TimelineView.fit(m.span, _laneWidth));

  // ---- Geometry ---------------------------------------------------------------

  int _rowAt(double dy) =>
      ((dy + (_rows.hasClients ? _rows.offset : 0)) / kTimelineRowHeight)
          .floor();

  /// The keyframe under [p] (lane coordinates) in row [row], nearest first.
  KeyframeRef? _keyframeAt(_BodyModel m, int row, Offset p) {
    if (row < 0 || row >= m.rows.length) return null;
    final r = m.rows[row];
    if (r is! LaneRow) return null;
    final v = _view(m);
    KeyframeRef? best;
    var bestD = kKeyframeHitRadius + 0.5;
    for (final k in r.track.keyframes) {
      final d = (v.xOf(k.t) - p.dx).abs();
      if (d < bestD) {
        bestD = d;
        best = (track: r.track.id, keyframe: k.id);
      }
    }
    return best;
  }

  /// The segment under [p] in row [row]: the keyframe starting it.
  SegmentRef? _segmentAt(_BodyModel m, int row, Offset p) {
    if (row < 0 || row >= m.rows.length) return null;
    final r = m.rows[row];
    if (r is! LaneRow) return null;
    final t = _view(m).tOf(p.dx);
    final kfs = r.track.keyframes;
    for (var i = 0; i < kfs.length - 1; i++) {
      if (kfs[i].t <= t && t < kfs[i + 1].t) {
        return (track: r.track.id, keyframe: kfs[i].id);
      }
    }
    return null;
  }

  bool _onPlayheadLine(_BodyModel m, Offset p) {
    final x = _view(m).xOf(ref.read(editorControllerProvider).playhead);
    return (x - p.dx).abs() <= 4;
  }

  // ---- Scrub --------------------------------------------------------------------

  void _scrubTo(_BodyModel m, double x) {
    _tl.playing.value = false;
    final t = m.span.clamp(_view(m).tOf(x));
    final max = m.span.openEnded ? math.max(m.span.max, t) : m.span.max;
    _editor.setPlayhead(m.scene.id, m.clock.id, t.clamp(m.span.min, max));
  }

  // ---- Wheel --------------------------------------------------------------------

  void _onWheel(PointerSignalEvent event, {required bool ruler}) {
    final m = _model;
    if (m == null) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is! PointerScrollEvent) return;
      final k = HardwareKeyboard.instance;
      final v = _view(m);
      if (k.isMetaPressed || k.isControlPressed) {
        final span = m.span.span > 0 ? m.span.span : 1;
        _tl.setView(
          m.viewKey,
          v.zoomAbout(
            e.localPosition.dx,
            math.exp(-e.scrollDelta.dy / 200),
            minPx: _laneWidth / (span * 20),
            maxPx: _laneWidth / (span * 0.0005),
          ),
        );
        return;
      }
      var dx = e.scrollDelta.dx;
      var dy = e.scrollDelta.dy;
      if (k.isShiftPressed && dx == 0) {
        dx = dy;
        dy = 0;
      }
      if (ruler && dx == 0) {
        dx = dy;
        dy = 0;
      }
      if (dx != 0) _tl.setView(m.viewKey, v.panBy(-dx));
      if (dy != 0 && _rows.hasClients) {
        final p = _rows.position;
        _rows.jumpTo((p.pixels + dy).clamp(0.0, p.maxScrollExtent));
      }
    });
  }

  // ---- Lane pointer ---------------------------------------------------------------

  void _onDown(PointerDownEvent e) {
    final m = _model;
    if (m == null || e.buttons != kPrimaryButton) return;
    _focus.requestFocus();
    final k = HardwareKeyboard.instance;
    final row = _rowAt(e.localPosition.dy);
    final hit = _keyframeAt(m, row, e.localPosition);
    // Double-click: a segment opens its easing, a keyframe takes the
    // playhead.
    final last = _lastClickAt, lastPos = _lastClickPos;
    _lastClickAt = null;
    if (last != null &&
        lastPos != null &&
        e.timeStamp - last < kDoubleTapTimeout &&
        (lastPos - e.localPosition).distance < kDoubleTapSlop) {
      if (hit != null) {
        final kf = keyframeOf(m.scene, hit);
        if (kf != null) _editor.setPlayhead(m.scene.id, m.clock.id, kf.t);
      } else {
        final seg = _segmentAt(m, row, e.localPosition);
        if (seg != null) _tl.easingSegment.value = seg;
      }
      _press = null;
      return;
    }
    final press = _LanePress(
      at: e.localPosition,
      row: row,
      hit: hit,
      shift: k.isShiftPressed,
      alt: k.isAltPressed,
    );
    if (hit == null && _onPlayheadLine(m, e.localPosition)) {
      press.scrub = true;
      _scrubTo(m, e.localPosition.dx);
    } else if (hit != null) {
      final sel = _tl.selection.value;
      if (press.shift) {
        if (sel.contains(hit)) {
          press.deselectOnUp = true;
        } else {
          _tl.select({...sel, hit});
        }
      } else if (!sel.contains(hit)) {
        _tl.select({hit});
      }
      _selectNodeOf(m, row, add: press.shift);
    } else {
      press.before = press.shift ? _tl.selection.value : const {};
    }
    _press = press;
  }

  void _selectNodeOf(_BodyModel m, int row, {bool add = false}) {
    if (row < 0 || row >= m.rows.length) return;
    final id = m.rows[row].nodeId;
    final st = ref.read(editorControllerProvider);
    if (add) {
      if (!st.selection.contains(id)) _editor.select({...st.selection, id});
    } else if (st.selection.length != 1 || st.selection.first != id) {
      _editor.select({id});
    }
  }

  void _onMove(PointerMoveEvent e) {
    final p = _press;
    final m = _model;
    if (p == null || m == null) return;
    if (p.scrub) {
      _scrubTo(m, e.localPosition.dx);
      return;
    }
    if (!p.dragging) {
      if ((e.localPosition - p.at).distance < kTouchSlop / 3) return;
      p.dragging = true;
      if (p.hit != null) {
        if (!_tl.selection.value.contains(p.hit)) return _cancelPress();
        _startKeyframeDrag(m, p);
      }
    }
    if (p.hit != null) {
      _dragKeyframes(m, p, e.localPosition);
    } else {
      _boxSelect(m, p, e.localPosition);
    }
  }

  void _onUp(PointerUpEvent e) {
    final p = _press;
    final m = _model;
    _press = null;
    if (p == null || m == null) return;
    if (p.scrub) return;
    if (!p.dragging) {
      _lastClickAt = e.timeStamp;
      _lastClickPos = e.localPosition;
    }
    if (p.dragging) {
      if (p.hit != null) {
        _editor.endGesture();
        _tl.snapGuide.value = null;
      } else {
        _marquee.value = null;
      }
      return;
    }
    if (p.hit != null) {
      if (p.deselectOnUp) {
        _tl.select(Set.of(_tl.selection.value)..remove(p.hit));
      } else if (!p.shift) {
        // A plain click on a keyframe of a multi-selection selects it alone.
        _tl.select({p.hit!});
      }
      return;
    }
    // A click on an empty lane: select its node, clear keyframes.
    if (!p.shift) _tl.clearSelection();
    _selectNodeOf(m, p.row, add: p.shift);
  }

  void _cancelPress() {
    final p = _press;
    _press = null;
    if (p == null) return;
    if (p.dragging && p.hit != null && p.base != null) {
      _editor.execute(
        GestureStep(
          label: 'Move keyframes',
          coalesceKey: p.key,
          base: p.base!,
          edit: (st) => ir.EditResult(document: st.document, changed: false),
        ),
      );
      _editor.endGesture();
    }
    _tl.snapGuide.value = null;
    _marquee.value = null;
  }

  void _startKeyframeDrag(_BodyModel m, _LanePress p) {
    final sel = existingKeyframes(m.scene, _tl.selection.value);
    p.times = {for (final r in sel) r: keyframeOf(m.scene, r)!.t};
    p.grabbedT = p.times[p.hit] ?? 0;
    p.base = ref.read(editorControllerProvider).document;
    p.key = 'kfdrag:${identityHashCode(p)}';
    if (p.alt) {
      final used = <String, Set<String>>{
        for (final t in m.scene.tracks)
          if (sel.any((r) => r.track == t.id))
            t.id: {for (final k in t.keyframes) k.id},
      };
      p.copies = {
        for (final r in sel)
          r: () {
            final id = freshMotionId(used[r.track]!);
            used[r.track]!.add(id);
            return id;
          }(),
      };
    }
    _editor.beginGesture();
  }

  void _dragKeyframes(_BodyModel m, _LanePress p, Offset at) {
    final v = _view(m);
    final st = ref.read(editorControllerProvider);
    final dragged = p.times.keys.toSet();
    final others = <double>[
      for (final t in m.scene.tracks)
        if (t.clockId == m.clock.id)
          for (final k in t.keyframes)
            if (p.alt || !dragged.contains((track: t.id, keyframe: k.id))) k.t,
    ];
    final snap = !HardwareKeyboard.instance.isShiftPressed;
    final r = keyframeDragDelta(
      grabbedT: p.grabbedT,
      rawDelta: (at.dx - p.at.dx) / v.pxPerUnit,
      dragged: p.times.values,
      range: m.span,
      view: v,
      candidates: snap
          ? dragSnapCandidates(
              playhead: st.playhead,
              others: others,
              view: v,
              width: _laneWidth,
              unit: m.span.unit,
            )
          : const [],
      snap: snap,
      thresholdPx: kKeyframeHitRadius,
    );
    _tl.snapGuide.value = r.target;
    final sceneId = m.scene.id;
    final delta = r.delta;
    if (p.alt) {
      final adds = <String, List<ir.Keyframe>>{};
      for (final MapEntry(key: ref, value: t) in p.times.entries) {
        final k = keyframeOf(m.scene, ref)!;
        (adds[ref.track] ??= []).add(
          k.copyWith(id: p.copies[ref]!, t: t + delta),
        );
      }
      _editor.execute(
        GestureStep(
          label: 'Duplicate ${_n(adds)}',
          coalesceKey: p.key,
          base: p.base!,
          edit: (s) => ir.addKeyframes(s.document, sceneId, adds),
        ),
      );
      _tl.select({
        for (final MapEntry(key: ref, value: id) in p.copies.entries)
          (track: ref.track, keyframe: id),
      });
    } else {
      final times = <String, Map<String, double>>{};
      for (final MapEntry(key: ref, value: t) in p.times.entries) {
        (times[ref.track] ??= {})[ref.keyframe] = t + delta;
      }
      _editor.execute(
        GestureStep(
          label: 'Move ${_n(times)}',
          coalesceKey: p.key,
          base: p.base!,
          edit: (s) => ir.moveKeyframes(s.document, sceneId, times),
        ),
      );
    }
  }

  static String _n(Map<String, Object> byTrack) {
    var n = 0;
    for (final v in byTrack.values) {
      n += switch (v) {
        final List<Object?> l => l.length,
        final Map<Object?, Object?> mm => mm.length,
        _ => 1,
      };
    }
    return n == 1 ? 'keyframe' : '$n keyframes';
  }

  void _boxSelect(_BodyModel m, _LanePress p, Offset at) {
    final rect = Rect.fromPoints(p.at, at);
    _marquee.value = rect;
    final v = _view(m);
    final scroll = _rows.hasClients ? _rows.offset : 0.0;
    final first = ((rect.top + scroll) / kTimelineRowHeight).floor();
    final last = ((rect.bottom + scroll) / kTimelineRowHeight).floor();
    final out = {...p.before};
    for (var i = math.max(0, first); i <= last && i < m.rows.length; i++) {
      final r = m.rows[i];
      if (r is! LaneRow) continue;
      for (final k in r.track.keyframes) {
        final x = v.xOf(k.t);
        if (x >= rect.left - 3 && x <= rect.right + 3) {
          out.add((track: r.track.id, keyframe: k.id));
        }
      }
    }
    _tl.select(out);
  }

  // ---- Keys -----------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    final mod = k.isMetaPressed || k.isControlPressed;
    final key = e.logicalKey;
    final has = _tl.selection.value.isNotEmpty;
    bool done(bool ok) => ok;
    final handled = switch (key) {
      LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace
          when has && !mod =>
        done(_actions.deleteSelected()),
      LogicalKeyboardKey.arrowLeft when has && !mod => done(
        _actions.nudgeSelected(-1, big: k.isShiftPressed),
      ),
      LogicalKeyboardKey.arrowRight when has && !mod => done(
        _actions.nudgeSelected(1, big: k.isShiftPressed),
      ),
      LogicalKeyboardKey.keyC when mod && has => done(_actions.copySelected()),
      LogicalKeyboardKey.keyV when mod && _tl.clipboard.isNotEmpty => done(
        _actions.paste(),
      ),
      LogicalKeyboardKey.keyA when mod => done(_actions.selectAll()),
      LogicalKeyboardKey.escape when has => done(() {
        _tl.clearSelection();
        return true;
      }()),
      _ => false,
    };
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // ---- Build ------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final tl = ref.watch(timelineControllerProvider);
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final sceneId = ref.watch(
      editorControllerProvider.select((s) => s.activeSceneId),
    );
    final clockId = ref.watch(
      editorControllerProvider.select((s) => s.activeClockId),
    );
    final scene = doc.scenes.where((s) => s.id == sceneId).firstOrNull;
    final clock = scene?.clocks.where((k) => k.id == clockId).firstOrNull;
    if (scene == null || clock == null) {
      _model = null;
      return Center(child: Text('No scene', style: t.text.caption));
    }
    return ValueListenableBuilder<Set<String>>(
      valueListenable: tl.collapsed,
      builder: (context, collapsed, _) {
        final m = _model = _BodyModel(
          doc,
          scene,
          clock,
          clockSpan(doc, scene, clock),
          buildTimelineRows(doc, scene, clock.id, collapsed: collapsed),
        );
        return TapRegion(
          onTapOutside: (_) {
            if (_focus.hasFocus) _focus.unfocus();
          },
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _onKey,
            child: LayoutBuilder(
              builder: (context, box) {
                _laneWidth = math.max(1, box.maxWidth - kTimelineLabelWidth);
                // Created here, not while painting: painters only read it.
                _view(m);
                return Column(
                  children: [
                    SizedBox(
                      height: kTimelineRulerHeight,
                      child: Row(
                        children: [
                          Container(
                            width: kTimelineLabelWidth,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(color: c.borderSubtle),
                                bottom: BorderSide(color: c.borderSubtle),
                              ),
                            ),
                          ),
                          Expanded(
                            child: _Ruler(
                              model: m,
                              playhead: _playhead,
                              onScrub: (x) => _scrubTo(m, x),
                              onWheel: (e) => _onWheel(e, ruler: true),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: m.rows.isEmpty
                          ? _EmptyLanes(clock: clock)
                          : _lanes(context, m),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _lanes(BuildContext context, _BodyModel m) {
    final tl = _tl;
    return Stack(
      children: [
        ListView.builder(
          key: const ValueKey<String>('timeline-rows'),
          controller: _rows,
          itemExtent: kTimelineRowHeight,
          itemCount: m.rows.length,
          itemBuilder: (context, i) => _RowTile(
            key: ValueKey<String>(switch (m.rows[i]) {
              GroupRow(:final nodeId) => 'group:$nodeId',
              LaneRow(:final track) => 'lane:${track.id}',
            }),
            row: m.rows[i],
            viewKey: m.viewKey,
            onToggle: tl.toggleGroup,
            onSelectNode: (id) => _editor.select({id}),
          ),
        ),
        Positioned(
          left: kTimelineLabelWidth,
          top: 0,
          right: 0,
          bottom: 0,
          child: Listener(
            key: const ValueKey<String>('timeline-lanes'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: (_) => _cancelPress(),
            onPointerSignal: (e) => _onWheel(e, ruler: false),
            child: CustomPaint(
              painter: _LaneOverlayPainter(
                model: m,
                timeline: tl,
                marquee: _marquee,
                playhead: _playhead,
                colors: context.ss.colors,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }
}

/// The active playhead and auto-key flag as a listenable (the overlay
/// repaints on scrub without rebuilding anything).
class _PlayheadSource extends ChangeNotifier {
  _PlayheadSource(this._ref) {
    _sub = _ref.listenManual(
      editorControllerProvider.select((s) => (s.playhead, s.autoKey)),
      (_, _) => notifyListeners(),
    );
  }

  final WidgetRef _ref;
  late final ProviderSubscription<(double, bool)> _sub;

  double get value => _ref.read(editorControllerProvider).playhead;
  bool get autoKey => _ref.read(editorControllerProvider).autoKey;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

class _EmptyLanes extends StatelessWidget {
  const _EmptyLanes({required this.clock});

  final ir.Clock clock;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s4),
        child: Text(
          'Nothing is animated on this clock yet. Turn on auto-key and change '
          'a property, or add a keyframe with ◇ in the inspector.',
          textAlign: TextAlign.center,
          style: t.text.caption,
        ),
      ),
    );
  }
}

// ---- Ruler ------------------------------------------------------------------------------

class _Ruler extends ConsumerWidget {
  const _Ruler({
    required this.model,
    required this.playhead,
    required this.onScrub,
    required this.onWheel,
  });

  final _BodyModel model;
  final _PlayheadSource playhead;
  final ValueChanged<double> onScrub;
  final ValueChanged<PointerSignalEvent> onWheel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tl = ref.watch(timelineControllerProvider);
    return Listener(
      key: const ValueKey<String>('timeline-ruler'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (e.buttons == kPrimaryButton) onScrub(e.localPosition.dx);
      },
      onPointerMove: (e) {
        if (e.buttons == kPrimaryButton) onScrub(e.localPosition.dx);
      },
      onPointerSignal: onWheel,
      child: CustomPaint(
        painter: _RulerPainter(
          model: model,
          timeline: tl,
          playhead: playhead,
          colors: context.ss.colors,
          text: context.ss.text.caption,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.model,
    required this.timeline,
    required this.playhead,
    required this.colors,
    required this.text,
  }) : super(repaint: Listenable.merge([timeline.views, playhead]));

  final _BodyModel model;
  final TimelineController timeline;
  final _PlayheadSource playhead;
  final SsColors colors;
  final TextStyle text;

  @override
  void paint(Canvas canvas, Size size) {
    final v =
        timeline.views.value[model.viewKey] ??
        TimelineView.fit(model.span, size.width);
    final unit = model.span.unit;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surface1);
    // The clock's span, lighter than outside it.
    final x0 = v.xOf(model.span.min).clamp(0.0, size.width);
    final x1 = v.xOf(model.span.max).clamp(0.0, size.width);
    canvas.drawRect(
      Rect.fromLTRB(x0, 0, x1, size.height),
      Paint()..color = colors.surface2,
    );
    final steps = rulerSteps(v, unit);
    final line = Paint()
      ..color = colors.border
      ..strokeWidth = 1;
    for (final tick in rulerTicks(v, size.width, unit)) {
      final x = v.xOf(tick.t).roundToDouble() + 0.5;
      final h = tick.major ? 10.0 : 4.0;
      canvas.drawLine(Offset(x, size.height - h), Offset(x, size.height), line);
      if (tick.major) {
        final tp = TextPainter(
          text: TextSpan(
            text: formatClockValue(tick.t, unit, step: steps.major),
            style: text,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + 3, 1));
        tp.dispose();
      }
    }
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      line,
    );
    // The playhead's head.
    final px = v.xOf(playhead.value);
    final color = playhead.autoKey ? colors.danger : colors.accent;
    final head = Path()
      ..moveTo(px - 5, size.height - 9)
      ..lineTo(px + 5, size.height - 9)
      ..lineTo(px, size.height)
      ..close();
    canvas.drawPath(head, Paint()..color = color);
    canvas.drawLine(
      Offset(px, 0),
      Offset(px, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      !identical(old.model, model) || old.colors != colors;
}

// ---- Rows ---------------------------------------------------------------------------

class _RowTile extends ConsumerWidget {
  const _RowTile({
    required this.row,
    required this.viewKey,
    required this.onToggle,
    required this.onSelectNode,
    super.key,
  });

  final TimelineRow row;
  final String viewKey;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onSelectNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final tl = ref.watch(timelineControllerProvider);
    final row = this.row;
    final selected = ref.watch(
      editorControllerProvider.select((s) => s.selection.contains(row.nodeId)),
    );
    final group = row is GroupRow;
    final label = switch (row) {
      GroupRow(:final name, :final collapsed) => Row(
        children: [
          SsIconButton(
            key: ValueKey<String>('timeline-toggle:${row.nodeId}'),
            icon: collapsed ? SsIcons.chevronRight : SsIcons.chevronDown,
            semanticLabel: collapsed ? 'Expand $name' : 'Collapse $name',
            size: 20,
            iconSize: 12,
            onPressed: () => onToggle(row.nodeId),
          ),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.text.small.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      LaneRow(:final label) => Padding(
        padding: const EdgeInsets.only(left: 28),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.text.small.copyWith(color: c.textSecondary),
        ),
      ),
    };
    final highlight = selected
        ? c.selection.withValues(alpha: group ? 0.22 : 0.10)
        : (group ? c.surface2 : null);
    return Container(
      color: highlight,
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelectNode(row.nodeId),
            child: Container(
              key: ValueKey<String>(
                group
                    ? 'timeline-group:${row.nodeId}'
                    : 'timeline-label:${(row as LaneRow).track.id}',
              ),
              width: kTimelineLabelWidth,
              padding: const EdgeInsets.only(
                left: SsSpace.s1,
                right: SsSpace.s2,
              ),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: c.borderSubtle)),
              ),
              child: label,
            ),
          ),
          Expanded(
            child: CustomPaint(
              painter: _LanePainter(
                row: row,
                viewKey: viewKey,
                timeline: tl,
                colors: c,
                scene: ref.read(editorControllerProvider).activeScene,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

/// One lane's keyframes (a group row draws its tracks' keyframes small).
class _LanePainter extends CustomPainter {
  _LanePainter({
    required this.row,
    required this.viewKey,
    required this.timeline,
    required this.colors,
    required this.scene,
  }) : super(repaint: Listenable.merge([timeline.views, timeline.selection]));

  final TimelineRow row;
  final String viewKey;
  final TimelineController timeline;
  final SsColors colors;
  final ir.Scene? scene;

  @override
  void paint(Canvas canvas, Size size) {
    final v = timeline.views.value[viewKey];
    if (v == null) return;
    final cy = size.height / 2;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()..color = colors.borderSubtle,
    );
    final row = this.row;
    if (row is GroupRow) {
      final dot = Paint()..color = colors.textDisabled;
      for (final t in scene?.tracks ?? const <ir.Track>[]) {
        if (!row.trackIds.contains(t.id)) continue;
        for (final k in t.keyframes) {
          final x = v.xOf(k.t);
          if (x < -4 || x > size.width + 4) continue;
          _diamond(canvas, Offset(x, cy), 3.5, dot);
        }
      }
      return;
    }
    if (row is! LaneRow) return;
    final kfs = row.track.keyframes;
    final sel = timeline.selection.value;
    // Segments: a bar between keyframes; a hold is dashed-looking (thin).
    final bar = Paint()
      ..color = colors.border
      ..strokeWidth = 2;
    for (var i = 0; i < kfs.length - 1; i++) {
      final a = v.xOf(kfs[i].t), b = v.xOf(kfs[i + 1].t);
      if (b < 0 || a > size.width) continue;
      canvas.drawLine(
        Offset(a, cy),
        Offset(b, cy),
        kfs[i].easing is ir.HoldEasing
            ? (Paint()..color = colors.borderSubtle)
            : bar,
      );
    }
    final fill = Paint()..color = colors.textSecondary;
    final selFill = Paint()..color = colors.accent;
    final outline = Paint()
      ..color = colors.surface1
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final k in kfs) {
      final x = v.xOf(k.t);
      if (x < -6 || x > size.width + 6) continue;
      final on = sel.contains((track: row.track.id, keyframe: k.id));
      _diamond(canvas, Offset(x, cy), 5, on ? selFill : fill);
      _diamond(canvas, Offset(x, cy), 5, outline);
    }
  }

  static void _diamond(Canvas canvas, Offset c, double r, Paint p) {
    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close(),
      p,
    );
  }

  @override
  bool shouldRepaint(_LanePainter old) =>
      !identical(old.row, row) ||
      old.viewKey != viewKey ||
      old.colors != colors ||
      !identical(old.scene, scene);
}

/// The playhead line, the snap guide and the box-select rectangle over the
/// lanes.
class _LaneOverlayPainter extends CustomPainter {
  _LaneOverlayPainter({
    required this.model,
    required this.timeline,
    required this.marquee,
    required this.playhead,
    required this.colors,
  }) : super(
         repaint: Listenable.merge([
           timeline.views,
           timeline.snapGuide,
           marquee,
           playhead,
         ]),
       );

  final _BodyModel model;
  final TimelineController timeline;
  final ValueNotifier<Rect?> marquee;
  final _PlayheadSource playhead;
  final SsColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final v = timeline.views.value[model.viewKey];
    if (v == null) return;
    final guide = timeline.snapGuide.value;
    if (guide != null) {
      final x = v.xOf(guide);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = colors.warning
          ..strokeWidth = 1,
      );
    }
    final px = v.xOf(playhead.value);
    canvas.drawLine(
      Offset(px, 0),
      Offset(px, size.height),
      Paint()
        ..color = playhead.autoKey ? colors.danger : colors.accent
        ..strokeWidth = 1,
    );
    final m = marquee.value;
    if (m != null) {
      canvas.drawRect(
        m,
        Paint()..color = colors.accent.withValues(alpha: 0.12),
      );
      canvas.drawRect(
        m,
        Paint()
          ..color = colors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_LaneOverlayPainter old) =>
      !identical(old.model, model) || old.colors != colors;
}
