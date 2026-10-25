/// Where the reader is in a story, independent of scene lengths: a scene
/// and how far through it (0 = its start, 1 = its end).
///
/// Used to keep the scroll position when the document or the breakpoint
/// changes and the scenes get longer or shorter.
class SceneScrollAnchor {
  const SceneScrollAnchor({
    required this.sceneId,
    required this.index,
    required this.progress,
  });

  final String sceneId;
  final int index;
  final double progress;

  @override
  String toString() => 'SceneScrollAnchor($sceneId #$index @ $progress)';
}

/// The anchor of scroll [offset] given each scene's start offset
/// ([starts], in order, parallel to [ids]) and the [end] of the content
/// (`maxScrollExtent + viewportDimension`).
SceneScrollAnchor? captureSceneAnchor({
  required List<String> ids,
  required List<double> starts,
  required double offset,
  required double end,
}) {
  if (ids.isEmpty || ids.length != starts.length) return null;
  var i = 0;
  for (var k = 0; k < starts.length; k++) {
    if (starts[k] <= offset + 0.5) i = k;
  }
  final stop = i + 1 < starts.length ? starts[i + 1] : end;
  final length = stop - starts[i];
  final progress = length <= 0
      ? 0.0
      : ((offset - starts[i]) / length).clamp(0.0, 1.0);
  return SceneScrollAnchor(sceneId: ids[i], index: i, progress: progress);
}

/// The scroll offset of [anchor] in a layout with scene [starts] (parallel
/// to [ids]) ending at [end]. The scene is found by id, or by index when
/// it was removed.
double? restoreSceneAnchor(
  SceneScrollAnchor anchor, {
  required List<String> ids,
  required List<double> starts,
  required double end,
}) {
  if (ids.isEmpty || ids.length != starts.length) return null;
  var i = ids.indexOf(anchor.sceneId);
  if (i < 0) i = anchor.index.clamp(0, ids.length - 1);
  final stop = i + 1 < starts.length ? starts[i + 1] : end;
  return starts[i] + (stop - starts[i]) * anchor.progress;
}
