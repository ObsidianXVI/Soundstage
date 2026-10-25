import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import 'clock_commands.dart';
import 'clock_dialogs.dart';
import 'clock_fields.dart';

// The Clocks list of the scene settings (m2.md "Clocks UI"): every clock of
// the active scene with its fields, a usage count, delete (asking what to do
// with the tracks that use it) and "Add clock".

class ClocksSection extends ConsumerWidget {
  const ClocksSection({required this.scene, super.key});

  final ir.Scene scene;

  /// The selected frame of [scene] when exactly one frame is selected.
  static String? selectedFrame(EditorState s, ir.Scene scene) {
    if (s.selection.length != 1) return null;
    final id = s.selection.first;
    for (final f in sceneFrames(scene)) {
      if (f.id == id) return id;
    }
    return null;
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final state = ref.read(editorControllerProvider);
    final gen = ir.IdGenerator.forDocument(state.document);
    final clocks = await showAddClockDialog(
      context,
      ids: [gen.next(), gen.next()],
      frames: sceneFrames(scene),
      selectedFrameId: selectedFrame(state, scene),
    );
    if (clocks == null || clocks.isEmpty) return;
    ref
        .read(editorControllerProvider.notifier)
        .execute(AddClocks(scene.id, clocks));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final frameNames = {for (final f in sceneFrames(scene)) f.id: f.name};
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SsSpace.s3,
        SsSpace.s2,
        SsSpace.s3,
        SsSpace.s3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text('Clocks', style: t.text.overline)),
              SsIconButton(
                icon: SsIcons.plus,
                semanticLabel: 'Add clock',
                size: 24,
                iconSize: 14,
                onPressed: () => _add(context, ref),
              ),
            ],
          ),
          const SizedBox(height: SsSpace.s1),
          for (final c in scene.clocks)
            _ClockRow(
              key: ValueKey('clock-${c.id}'),
              scene: scene,
              clock: c,
              frameNames: frameNames,
            ),
        ],
      ),
    );
  }
}

class _ClockRow extends ConsumerWidget {
  const _ClockRow({
    required this.scene,
    required this.clock,
    required this.frameNames,
    super.key,
  });

  final ir.Scene scene;
  final ir.Clock clock;
  final Map<String, String> frameNames;

  bool get _ownScroll =>
      clock is ir.SceneScrollClock &&
      (clock as ir.SceneScrollClock).sceneId == scene.id;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ctl = ref.read(editorControllerProvider.notifier);
    final uses = tracksOnClock(scene, clock.id).length;
    ir.ClockRemoval? how = const ir.ClockRemoval.deleteTracks();
    if (uses > 0) {
      how = await showDeleteClockDialog(
        context,
        clockName: clockLabel(clock, frameNames),
        trackCount: uses,
        others: [
          for (final o in scene.clocks)
            if (o.id != clock.id) (id: o.id, name: clockLabel(o, frameNames)),
        ],
      );
    }
    if (how == null) return;
    ctl.execute(RemoveClock(scene.id, clock.id, tracks: how));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final ctl = ref.read(editorControllerProvider.notifier);
    final uses = tracksOnClock(scene, clock.id).length;
    final self = clock;

    void change(ir.Clock Function(ir.Clock) f) =>
        ctl.execute(UpdateClock(scene.id, clock.id, f));

    void smoothing(double v) => change((x) => x.copyWith(smoothing: v));

    final fields = switch (self) {
      ir.SceneScrollClock() => [
        SmoothingField(
          value: self.smoothing,
          onChangeStart: ctl.beginGesture,
          onChangeEnd: ctl.endGesture,
          onChanged: smoothing,
        ),
      ],
      ir.TimelineClock() => [
        ClockField(
          'Name',
          SsTextField(
            key: ValueKey('name-${self.name}'),
            semanticLabel: 'Clock name',
            initialValue: self.name,
            placeholder: 'Timeline',
            releaseFocusOnSubmit: true,
            onSubmitted: (v) => change(
              (x) => x is ir.TimelineClock ? x.copyWith(name: v.trim()) : x,
            ),
          ),
        ),
        TimelineFields(
          clock: self,
          onChangeStart: ctl.beginGesture,
          onChangeEnd: ctl.endGesture,
          onChange: (f) => change((x) => x is ir.TimelineClock ? f(x) : x),
        ),
        SmoothingField(
          value: self.smoothing,
          onChangeStart: ctl.beginGesture,
          onChangeEnd: ctl.endGesture,
          onChanged: smoothing,
        ),
        _PastEnd(scene: scene, clock: self),
      ],
      ir.PointerClock() => [
        PointerFields(
          frameId: self.frameId,
          axis: self.axis,
          frames: sceneFrames(scene),
          selectedFrameId: ClocksSection.selectedFrame(
            ref.watch(editorControllerProvider),
            scene,
          ),
          onFrame: (f) =>
              change((x) => x is ir.PointerClock ? x.copyWith(frameId: f) : x),
          onAxis: (a) =>
              change((x) => x is ir.PointerClock ? x.copyWith(axis: a) : x),
        ),
        SmoothingField(
          value: self.smoothing,
          onChangeStart: ctl.beginGesture,
          onChangeEnd: ctl.endGesture,
          onChanged: smoothing,
        ),
      ],
      // Behaviour (M3) and audio (T2.5) clocks are owned by their features.
      _ => [
        Padding(
          padding: const EdgeInsets.only(bottom: SsSpace.s2),
          child: Text(
            self is ir.BehaviorClock
                ? 'Read-only. Behaviours arrive in M3.'
                : 'Read-only. Follows its audio track.',
            style: t.text.caption.copyWith(color: c.textDisabled),
          ),
        ),
      ],
    };

    return Container(
      margin: const EdgeInsets.only(top: SsSpace.s2),
      padding: const EdgeInsets.all(SsSpace.s2),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: SsRadius.brMd,
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clockLabel(self, frameNames),
                      style: t.text.bodyStrong,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      uses == 1 ? 'used by 1 track' : 'used by $uses tracks',
                      style: t.text.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              if (!_ownScroll)
                SsIconButton(
                  icon: SsIcons.trash2,
                  semanticLabel: 'Delete clock',
                  size: 24,
                  iconSize: 14,
                  onPressed: () => _delete(context, ref),
                ),
            ],
          ),
          const SizedBox(height: SsSpace.s2),
          ...fields,
        ],
      ),
    );
  }
}

/// The warning chip of a timeline clock whose keyframes lie past its
/// duration, with the "Scale keyframes to fit" action.
class _PastEnd extends ConsumerWidget {
  const _PastEnd({required this.scene, required this.clock});

  final ir.Scene scene;
  final ir.TimelineClock clock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = keyframesPastEnd(scene, clock.id, clock.duration);
    if (n == 0) return const SizedBox.shrink();
    final t = context.ss;
    final c = t.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('past-end-chip'),
          padding: const EdgeInsets.symmetric(
            horizontal: SsSpace.s2,
            vertical: SsSpace.s1,
          ),
          decoration: BoxDecoration(
            borderRadius: SsRadius.brSm,
            border: Border.all(color: c.warning),
          ),
          child: Row(
            children: [
              Icon(SsIcons.triangleAlert, size: 12, color: c.warning),
              const SizedBox(width: SsSpace.s1),
              Expanded(
                child: Text(
                  n == 1
                      ? '1 keyframe past the end'
                      : '$n keyframes past the end',
                  style: t.text.caption.copyWith(color: c.warning),
                ),
              ),
            ],
          ),
        ),
        FitLeft(
          child: SsButton(
            label: 'Scale keyframes to fit',
            variant: SsButtonVariant.ghost,
            onPressed: () => ref
                .read(editorControllerProvider.notifier)
                .execute(
                  ScaleClockKeyframes(scene.id, clock.id, clock.duration),
                ),
          ),
        ),
      ],
    );
  }
}
