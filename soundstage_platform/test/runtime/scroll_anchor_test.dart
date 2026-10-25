import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

void main() {
  const ids = ['a', 'b', 'c'];

  test('capture: scene and progress', () {
    final a = captureSceneAnchor(
      ids: ids,
      starts: [0, 1000, 3000],
      offset: 2000,
      end: 5000,
    )!;
    expect((a.sceneId, a.index), ('b', 1));
    expect(a.progress, closeTo(0.5, 1e-9));
    final last = captureSceneAnchor(
      ids: ids,
      starts: [0, 1000, 3000],
      offset: 5000,
      end: 5000,
    )!;
    expect((last.sceneId, last.progress), ('c', 1));
  });

  test('restore follows the scene when lengths change', () {
    const anchor = SceneScrollAnchor(sceneId: 'b', index: 1, progress: 0.5);
    expect(
      restoreSceneAnchor(anchor, ids: ids, starts: [0, 2000, 4000], end: 7000),
      3000,
    );
  });

  test('restore falls back to the index when the scene was removed', () {
    const anchor = SceneScrollAnchor(sceneId: 'gone', index: 1, progress: 0);
    expect(
      restoreSceneAnchor(anchor, ids: ids, starts: [0, 800, 1600], end: 2400),
      800,
    );
    const past = SceneScrollAnchor(sceneId: 'gone', index: 9, progress: 0);
    expect(
      restoreSceneAnchor(past, ids: ids, starts: [0, 800, 1600], end: 2400),
      1600,
    );
  });

  test('nothing to anchor to', () {
    expect(
      captureSceneAnchor(ids: const [], starts: const [], offset: 0, end: 0),
      isNull,
    );
  });
}
