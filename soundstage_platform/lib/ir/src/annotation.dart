import 'package:freezed_annotation/freezed_annotation.dart';

import 'values/geometry.dart';

part 'annotation.freezed.dart';
part 'annotation.g.dart';

// Annotate mode (product spec "Agents", m6 follow-up): quick low-fi marks
// the author draws to show the agent what they want. Annotations are story
// objects (the external review's "annotations are project objects"),
// private like notes: never published or exported.

@JsonEnum()
enum AnnotationKind { frame, text, arrow, path, comment }

@JsonEnum()
enum AnnotationStatus { open, inProgress, resolved }

/// One mark on an artboard. `points` are in the artboard's design pixels
/// (relative to its top-left, not the viewport): two corners for a frame or
/// a text area, start and end for an arrow, the stroke for a path, one
/// point for a comment. `breakpointId` is the artboard it was drawn on;
/// `targetIds` are layers it is about (optional); `note` is what the author
/// wants (font, colour, content, motion…).
@freezed
abstract class Annotation with _$Annotation {
  const factory Annotation({
    required String id,
    required AnnotationKind kind,
    required String sceneId,
    required String breakpointId,
    @Default(<StagePoint>[]) List<StagePoint> points,
    @Default('') String note,
    @Default(AnnotationStatus.open) AnnotationStatus status,
    @Default(<String>[]) List<String> targetIds,
  }) = _Annotation;

  factory Annotation.fromJson(Map<String, dynamic> json) =>
      _$AnnotationFromJson(json);
}
