import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shortcuts/intents.dart';

/// The narrowest window the full editor supports. Below it, `/edit/:id`
/// shows the content-mode screen instead.
const double kEditorMinWidth = 1024;

/// Which breakpoints an edit applies to: "Both" writes through to the
/// shared (base) value; "This breakpoint" writes an override. Alt flips it
/// for one gesture. Not wired to anything yet.
enum EditScope { both, thisBreakpoint }

enum LeftPanelTab { scenes, layers, assets }

const double kLeftPanelMin = 200;
const double kLeftPanelMax = 420;
const double kRightPanelMin = 240;
const double kRightPanelMax = 480;

/// Narrowest the canvas may get when panels are widened.
const double kCanvasMinWidth = 360;

/// Panel sizes and toggles. Lives in the provider scope, so it is
/// remembered for the session (across route changes), not across reloads.
@immutable
class EditorLayoutState {
  const EditorLayoutState({
    this.leftWidth = 264,
    this.rightWidth = 288,
    this.leftOpen = true,
    this.rightOpen = true,
    this.timelineOpen = false,
    this.leftTab = LeftPanelTab.scenes,
    this.scope = EditScope.both,
    this.tool = EditorTool.move,
  });

  final double leftWidth;
  final double rightWidth;
  final bool leftOpen;
  final bool rightOpen;
  final bool timelineOpen;
  final LeftPanelTab leftTab;
  final EditScope scope;
  final EditorTool tool;

  EditorLayoutState copyWith({
    double? leftWidth,
    double? rightWidth,
    bool? leftOpen,
    bool? rightOpen,
    bool? timelineOpen,
    LeftPanelTab? leftTab,
    EditScope? scope,
    EditorTool? tool,
  }) => EditorLayoutState(
    leftWidth: leftWidth ?? this.leftWidth,
    rightWidth: rightWidth ?? this.rightWidth,
    leftOpen: leftOpen ?? this.leftOpen,
    rightOpen: rightOpen ?? this.rightOpen,
    timelineOpen: timelineOpen ?? this.timelineOpen,
    leftTab: leftTab ?? this.leftTab,
    scope: scope ?? this.scope,
    tool: tool ?? this.tool,
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
  void toggleTimeline() =>
      state = state.copyWith(timelineOpen: !state.timelineOpen);
  void setLeftTab(LeftPanelTab t) => state = state.copyWith(leftTab: t);
  void setScope(EditScope s) => state = state.copyWith(scope: s);
  void flipScope() => state = state.copyWith(
    scope: state.scope == EditScope.both
        ? EditScope.thisBreakpoint
        : EditScope.both,
  );
  void setTool(EditorTool t) => state = state.copyWith(tool: t);
}

final editorLayoutProvider =
    NotifierProvider<EditorLayoutNotifier, EditorLayoutState>(
      EditorLayoutNotifier.new,
    );
