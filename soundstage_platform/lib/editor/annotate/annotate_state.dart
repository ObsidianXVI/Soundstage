import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Annotate mode's UI state (product spec "Annotate mode"): whether the
/// author is annotating, with which mark, and the selected annotation.
@immutable
class AnnotateState {
  const AnnotateState({
    this.on = false,
    this.tool = ir.AnnotationKind.frame,
    this.selectedId,
  });

  final bool on;
  final ir.AnnotationKind tool;
  final String? selectedId;

  AnnotateState copyWith({
    bool? on,
    ir.AnnotationKind? tool,
    String? Function()? selectedId,
  }) => AnnotateState(
    on: on ?? this.on,
    tool: tool ?? this.tool,
    selectedId: selectedId == null ? this.selectedId : selectedId(),
  );
}

class AnnotateNotifier extends Notifier<AnnotateState> {
  @override
  AnnotateState build() => const AnnotateState();

  void toggle() =>
      state = state.copyWith(on: !state.on, selectedId: () => null);
  void setTool(ir.AnnotationKind tool) => state = state.copyWith(tool: tool);
  void select(String? id) => state = state.copyWith(selectedId: () => id);
}

final annotateProvider = NotifierProvider<AnnotateNotifier, AnnotateState>(
  AnnotateNotifier.new,
);

/// The marks' labels.
String annotationKindLabel(ir.AnnotationKind k) => switch (k) {
  ir.AnnotationKind.frame => 'Frame',
  ir.AnnotationKind.text => 'Text area',
  ir.AnnotationKind.arrow => 'Arrow',
  ir.AnnotationKind.path => 'Path',
  ir.AnnotationKind.comment => 'Comment',
};
