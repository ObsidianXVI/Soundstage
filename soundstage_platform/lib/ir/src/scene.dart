import 'package:freezed_annotation/freezed_annotation.dart';

import 'breakpoint.dart';
import 'motion.dart';
import 'nodes/node.dart';
import 'nodes/node_common.dart';
import 'nodes/paint.dart';
import 'values/ids.dart';

part 'scene.freezed.dart';
part 'scene.g.dart';

/// `pinned`: the stage is viewport-sized and held on screen for
/// `scrollLength` viewport heights. `flow`: laid out at viewport width and
/// scrolls like a page section (architecture §3.2).
@JsonEnum()
enum SceneKind { pinned, flow }

@JsonEnum()
enum SceneTransitionKind { none, overlap, crossfade }

/// How a scene enters over the previous one (runtime: M3). `amount` is in
/// viewport heights.
@freezed
abstract class SceneTransition with _$SceneTransition {
  const factory SceneTransition({
    @Default(SceneTransitionKind.none) SceneTransitionKind kind,
    @Default(0) double amount,
  }) = _SceneTransition;

  factory SceneTransition.fromJson(Map<String, dynamic> json) =>
      _$SceneTransitionFromJson(json);
}

/// A scene: one art-directed composition in the story (architecture §3.2).
///
/// - `scrollLength`: pinned only — scroll distance while pinned, in viewport
///   heights.
/// - `clocks`: the clocks this scene declares (timelines and the sources
///   tracks bind to; see `Clock`). The spec's `timelines` are the
///   `TimelineClock` entries of this list (see `lib/ir/README.md`).
/// - `background`: paint stack behind the stage.
/// - `modeOverrides`: `{ collectionId: modeId }`.
@freezed
abstract class Scene with _$Scene {
  const factory Scene({
    required String id,
    required FrameNode root,
    @Default('') String name,
    @Default(SceneKind.flow) SceneKind kind,
    @Default(0) double scrollLength,
    @Default(<Track>[]) List<Track> tracks,
    @Default(<Clock>[]) List<Clock> clocks,
    @Default(<Paint>[]) List<Paint> background,
    @Default(<String, String>{}) Map<String, String> modeOverrides,
    @Default(SceneTransition()) SceneTransition transitionIn,
  }) = _Scene;

  const Scene._();

  /// A blank pinned scene whose root frame is the size of [breakpoint]'s
  /// design viewport, with a scroll clock for the scene.
  factory Scene.blankPinned({
    required IdGenerator ids,
    required Breakpoint breakpoint,
    String name = '',
    double scrollLength = 1,
  }) {
    final sceneId = ids.next();
    return Scene(
      id: sceneId,
      name: name,
      kind: SceneKind.pinned,
      scrollLength: scrollLength,
      root: FrameNode(
        common: NodeCommon(
          id: ids.next(),
          name: 'Stage',
          width: breakpoint.designSize.width,
          height: breakpoint.designSize.height,
        ),
        clipContent: true,
      ),
      clocks: [Clock.sceneScroll(id: ids.next(), sceneId: sceneId)],
    );
  }

  factory Scene.fromJson(Map<String, dynamic> json) => _$SceneFromJson(json);

  /// The timeline clocks of this scene.
  Iterable<TimelineClock> get timelines => clocks.whereType<TimelineClock>();
}
