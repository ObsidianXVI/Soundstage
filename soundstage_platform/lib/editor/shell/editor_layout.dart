import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The narrowest window the full editor supports. Below it, `/edit/:id`
/// shows the content-mode screen instead.
const double kEditorMinWidth = 1024;

enum LeftPanelTab { scenes, layers, assets, tokens }

/// The editor's modes over one story (m5.md T5.1, product spec "Modes"):
/// Writing (the words), Design (layout and style), Animation (motion, with
/// the timeline open) and Publish (preview by tier, publish, export).
enum EditorMode {
  writing('Write'),
  design('Design'),
  animation('Animate'),
  publish('Publish');

  const EditorMode(this.label);

  final String label;
}

const double kLeftPanelMin = 200;
const double kLeftPanelMax = 420;
const double kRightPanelMin = 240;
const double kRightPanelMax = 480;

/// Narrowest the canvas may get when panels are widened.
const double kCanvasMinWidth = 360;

/// The expanded timeline's height range, and the canvas height it leaves
/// at least (with the 44 px toolbar).
const double kTimelineMinHeight = 120;
const double kTimelineMaxHeight = 640;
const double kTimelineDefaultHeight = 240;
const double kCanvasMinHeight = 200;

/// [height] clamped for a window [windowHeight] tall.
double clampTimelineHeight(double height, double windowHeight) {
  final max = math.max(
    kTimelineMinHeight,
    math.min(kTimelineMaxHeight, windowHeight - 44 - kCanvasMinHeight),
  );
  return height.clamp(kTimelineMinHeight, max);
}

/// Panel sizes and toggles. Lives in the root provider scope, so it is
/// remembered for the session (across route changes), not across reloads.
/// The edit scope and the tool are editor state (`EditorController`).
@immutable
class EditorLayoutState {
  const EditorLayoutState({
    this.leftWidth = 264,
    this.rightWidth = 288,
    this.leftOpen = true,
    this.rightOpen = true,
    this.timelineOpen = false,
    this.timelineHeight = kTimelineDefaultHeight,
    this.leftTab = LeftPanelTab.scenes,
    this.mode = EditorMode.design,
    this.agentOpen = false,
  });

  final double leftWidth;
  final double rightWidth;
  final bool leftOpen;
  final bool rightOpen;
  final bool timelineOpen;

  /// The expanded timeline's height (its top edge drags).
  final double timelineHeight;
  final LeftPanelTab leftTab;
  final EditorMode mode;

  /// The Agent panel shows (in every mode; m6.md T6.4).
  final bool agentOpen;

  /// Whether the timeline shows (always in Animation mode).
  bool get showsTimeline => mode == EditorMode.animation || timelineOpen;

  EditorLayoutState copyWith({
    double? leftWidth,
    double? rightWidth,
    bool? leftOpen,
    bool? rightOpen,
    bool? timelineOpen,
    double? timelineHeight,
    LeftPanelTab? leftTab,
    EditorMode? mode,
    bool? agentOpen,
  }) => EditorLayoutState(
    leftWidth: leftWidth ?? this.leftWidth,
    rightWidth: rightWidth ?? this.rightWidth,
    leftOpen: leftOpen ?? this.leftOpen,
    rightOpen: rightOpen ?? this.rightOpen,
    timelineOpen: timelineOpen ?? this.timelineOpen,
    timelineHeight: timelineHeight ?? this.timelineHeight,
    leftTab: leftTab ?? this.leftTab,
    mode: mode ?? this.mode,
    agentOpen: agentOpen ?? this.agentOpen,
  );
}

class EditorLayoutNotifier extends Notifier<EditorLayoutState> {
  @override
  EditorLayoutState build() => const EditorLayoutState();

  /// Widths are clamped to their ranges; [available] (the shell width)
  /// keeps the canvas at least [kCanvasMinWidth] wide.
  void setLeftWidth(double w, {double? available}) {
    var max = kLeftPanelMax;
    if (available != null) {
      max = math.min(
        max,
        available - (state.rightOpen ? state.rightWidth : 0) - kCanvasMinWidth,
      );
    }
    state = state.copyWith(
      leftWidth: w.clamp(kLeftPanelMin, math.max(kLeftPanelMin, max)),
    );
  }

  void setRightWidth(double w, {double? available}) {
    var max = kRightPanelMax;
    if (available != null) {
      max = math.min(
        max,
        available - (state.leftOpen ? state.leftWidth : 0) - kCanvasMinWidth,
      );
    }
    state = state.copyWith(
      rightWidth: w.clamp(kRightPanelMin, math.max(kRightPanelMin, max)),
    );
  }

  void toggleLeft() => state = state.copyWith(leftOpen: !state.leftOpen);
  void toggleRight() => state = state.copyWith(rightOpen: !state.rightOpen);

  /// In Animation mode the timeline is always open: collapsing it goes back
  /// to Design.
  void toggleTimeline() => state = state.mode == EditorMode.animation
      ? state.copyWith(mode: EditorMode.design, timelineOpen: false)
      : state.copyWith(timelineOpen: !state.timelineOpen);
  void setMode(EditorMode mode) => state = state.copyWith(mode: mode);
  void toggleAgent() => state = state.copyWith(agentOpen: !state.agentOpen);
  void setLeftTab(LeftPanelTab t) => state = state.copyWith(leftTab: t);

  /// The expanded timeline's height, clamped (see [clampTimelineHeight]
  /// for a window [available] tall).
  void setTimelineHeight(double h, {double? available}) =>
      state = state.copyWith(
        timelineHeight: available == null
            ? h.clamp(kTimelineMinHeight, kTimelineMaxHeight)
            : clampTimelineHeight(h, available),
      );
}

final editorLayoutProvider =
    NotifierProvider<EditorLayoutNotifier, EditorLayoutState>(
      EditorLayoutNotifier.new,
    );
