import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../interaction/snapping.dart';

/// What a canvas gesture is doing, for the overlay to draw.
enum CanvasGestureKind { none, move, reorder, resize, rotate, marquee }

/// The transient overlay state of the canvas tools (T1.4/T1.5): marquee,
/// snapping guides and gap markers, Alt measurements, the auto-layout
/// insertion indicator and drag ghost, the drop target and the painted
/// rotation cursor. Written by the canvas interaction, painted by the
/// overlay; a change repaints the overlay only (never the canvas).
///
/// Geometry is in world space (design pixels) unless named `screen`.
class InteractionModel extends ChangeNotifier {
  CanvasGestureKind gesture = CanvasGestureKind.none;

  /// The artboard (primary breakpoint id) the gesture or hover is on.
  String? breakpointId;

  /// The marquee rectangle, screen space.
  Rect? marquee;

  /// Alignment guides of the current snap.
  List<Guide> guides = const [];

  /// Equal-spacing markers of the current snap.
  List<GapMarker> gaps = const [];

  /// Alt measurements (selection → hovered node or parent).
  List<Guide> measures = const [];

  /// The auto-layout insertion indicator line.
  (Offset, Offset)? insertion;

  /// Outlines (world-space quads) of the nodes being dragged to a new slot
  /// in an auto-layout frame, following the pointer.
  List<List<Offset>> ghosts = const [];

  /// The frame a drag would drop into (highlighted).
  String? dropTargetId;

  /// Where to paint the rotation cursor (screen), and its angle (degrees).
  Offset? rotateCursor;
  double rotateCursorAngle = 0;

  /// Whether the handles of the selection are drawn (hidden while moving).
  bool get showsHandles =>
      gesture != CanvasGestureKind.move &&
      gesture != CanvasGestureKind.reorder &&
      gesture != CanvasGestureKind.marquee;

  /// Applies [edit] and repaints once.
  void update(void Function(InteractionModel m) edit) {
    edit(this);
    notifyListeners();
  }

  /// Clears the gesture visuals (keeps nothing but the hover measurement
  /// state, which the next hover recomputes).
  void clearGesture() => update((m) {
    m
      ..gesture = CanvasGestureKind.none
      ..marquee = null
      ..guides = const []
      ..gaps = const []
      ..insertion = null
      ..ghosts = const []
      ..dropTargetId = null;
  });

  /// Sets the measurement lines (repaints only when they change).
  void setMeasures(List<Guide> next, String? breakpointId) {
    if (next.isEmpty && measures.isEmpty) return;
    measures = next;
    this.breakpointId = breakpointId ?? this.breakpointId;
    notifyListeners();
  }

  /// Sets or clears the painted rotation cursor.
  void setRotateCursor(Offset? at, [double angle = 0]) {
    if (at == rotateCursor && angle == rotateCursorAngle) return;
    rotateCursor = at;
    rotateCursorAngle = angle;
    notifyListeners();
  }
}
