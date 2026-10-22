import 'package:freezed_annotation/freezed_annotation.dart';

import 'values/ir_value.dart';

part 'interactions.freezed.dart';
part 'interactions.g.dart';

/// What fires an interaction (architecture §10.3; runtime M3).
@Freezed(unionKey: 'type')
sealed class InteractionTrigger with _$InteractionTrigger {
  @FreezedUnionValue('tap')
  const factory InteractionTrigger.tap() = TapTrigger;

  @FreezedUnionValue('hoverEnter')
  const factory InteractionTrigger.hoverEnter() = HoverEnterTrigger;

  @FreezedUnionValue('hoverLeave')
  const factory InteractionTrigger.hoverLeave() = HoverLeaveTrigger;

  @FreezedUnionValue('sceneEnter')
  const factory InteractionTrigger.sceneEnter() = SceneEnterTrigger;

  @FreezedUnionValue('sceneLeave')
  const factory InteractionTrigger.sceneLeave() = SceneLeaveTrigger;

  /// Fires when audio track `audioTrackId` passes `time` seconds.
  @FreezedUnionValue('audioCue')
  const factory InteractionTrigger.audioCue({
    required String audioTrackId,
    required double time,
  }) = AudioCueTrigger;

  /// Fires when clock `clockId` reaches `value`.
  @FreezedUnionValue('clockReach')
  const factory InteractionTrigger.clockReach({
    required String clockId,
    required double value,
  }) = ClockReachTrigger;

  factory InteractionTrigger.fromJson(Map<String, dynamic> json) =>
      _$InteractionTriggerFromJson(json);
}

/// What an interaction does (architecture §10.3; runtime M3).
@Freezed(unionKey: 'type')
sealed class Action with _$Action {
  @FreezedUnionValue('playTimeline')
  const factory Action.playTimeline({required String clockId}) =
      PlayTimelineAction;

  @FreezedUnionValue('pauseTimeline')
  const factory Action.pauseTimeline({required String clockId}) =
      PauseTimelineAction;

  /// `time`: seconds.
  @FreezedUnionValue('seekTimeline')
  const factory Action.seekTimeline({
    required String clockId,
    required double time,
  }) = SeekTimelineAction;

  @FreezedUnionValue('reverseTimeline')
  const factory Action.reverseTimeline({required String clockId}) =
      ReverseTimelineAction;

  @FreezedUnionValue('playAudio')
  const factory Action.playAudio({required String audioTrackId}) =
      PlayAudioAction;

  @FreezedUnionValue('pauseAudio')
  const factory Action.pauseAudio({required String audioTrackId}) =
      PauseAudioAction;

  /// `time`: seconds.
  @FreezedUnionValue('seekAudio')
  const factory Action.seekAudio({
    required String audioTrackId,
    required double time,
  }) = SeekAudioAction;

  @FreezedUnionValue('setVariable')
  const factory Action.setVariable({
    required String variableId,
    required IrValue value,
  }) = SetVariableAction;

  @FreezedUnionValue('scrollToScene')
  const factory Action.scrollToScene({required String sceneId}) =
      ScrollToSceneAction;

  @FreezedUnionValue('openUrl')
  const factory Action.openUrl({
    required String url,
    @Default(true) bool newTab,
  }) = OpenUrlAction;

  /// Opens the lightbox behaviour of frame `nodeId`.
  @FreezedUnionValue('openLightbox')
  const factory Action.openLightbox({required String nodeId}) =
      OpenLightboxAction;

  factory Action.fromJson(Map<String, dynamic> json) => _$ActionFromJson(json);
}

/// A trigger and the actions it runs, attached to any node.
@freezed
abstract class Interaction with _$Interaction {
  const factory Interaction({
    required String id,
    required InteractionTrigger trigger,
    @Default(<Action>[]) List<Action> actions,
  }) = _Interaction;

  factory Interaction.fromJson(Map<String, dynamic> json) =>
      _$InteractionFromJson(json);
}
