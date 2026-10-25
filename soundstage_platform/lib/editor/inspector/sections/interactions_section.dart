import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../timeline/timeline_math.dart' show clockLabel;
import '../section_registry.dart';

/// Interactions of one layer (architecture §10.3; m3.md T3.4): "when"
/// (tap, hover in/out, scene in/out, a clock reaching a value, an audio
/// time) and "do" (play/pause/reverse/seek a timeline, play/pause/seek
/// audio, set a variable, scroll to a scene, open a link, show a layer full
/// screen). They run in the published story and the preview, not on the
/// canvas.
final InspectorSectionSpec interactionsSection = InspectorSectionSpec(
  id: 'interactions',
  title: 'Interactions',
  appliesTo: (info) => info.ids.length == 1 && !info.ids.single.contains('/'),
  builder: (context, info) => _InteractionsBody(nodeId: info.ids.single),
  actions: (context, info) => [_AddInteraction(nodeId: info.ids.single)],
);

enum _When { tap, hoverEnter, hoverLeave, sceneEnter, sceneLeave, clock, audio }

const _whenLabels = {
  _When.tap: 'On tap',
  _When.hoverEnter: 'On hover',
  _When.hoverLeave: 'On hover end',
  _When.sceneEnter: 'Scene appears',
  _When.sceneLeave: 'Scene leaves',
  _When.clock: 'Clock reaches',
  _When.audio: 'Audio reaches',
};

_When _whenOf(ir.InteractionTrigger t) => switch (t) {
  ir.TapTrigger() => _When.tap,
  ir.HoverEnterTrigger() => _When.hoverEnter,
  ir.HoverLeaveTrigger() => _When.hoverLeave,
  ir.SceneEnterTrigger() => _When.sceneEnter,
  ir.SceneLeaveTrigger() => _When.sceneLeave,
  ir.ClockReachTrigger() => _When.clock,
  ir.AudioCueTrigger() => _When.audio,
};

enum _Do {
  playTimeline,
  pauseTimeline,
  reverseTimeline,
  seekTimeline,
  playAudio,
  pauseAudio,
  seekAudio,
  setVariable,
  scrollToScene,
  openUrl,
  openLightbox,
}

const _doLabels = {
  _Do.playTimeline: 'Play timeline',
  _Do.pauseTimeline: 'Pause timeline',
  _Do.reverseTimeline: 'Reverse timeline',
  _Do.seekTimeline: 'Jump timeline to',
  _Do.playAudio: 'Play audio',
  _Do.pauseAudio: 'Pause audio',
  _Do.seekAudio: 'Jump audio to',
  _Do.setVariable: 'Set variable',
  _Do.scrollToScene: 'Go to scene',
  _Do.openUrl: 'Open link',
  _Do.openLightbox: 'Show full screen',
};

_Do _doOf(ir.Action a) => switch (a) {
  ir.PlayTimelineAction() => _Do.playTimeline,
  ir.PauseTimelineAction() => _Do.pauseTimeline,
  ir.ReverseTimelineAction() => _Do.reverseTimeline,
  ir.SeekTimelineAction() => _Do.seekTimeline,
  ir.PlayAudioAction() => _Do.playAudio,
  ir.PauseAudioAction() => _Do.pauseAudio,
  ir.SeekAudioAction() => _Do.seekAudio,
  ir.SetVariableAction() => _Do.setVariable,
  ir.ScrollToSceneAction() => _Do.scrollToScene,
  ir.OpenUrlAction() => _Do.openUrl,
  ir.OpenLightboxAction() => _Do.openLightbox,
};

/// What the editor can offer as targets for one layer: its scene's
/// timeline clocks, the story's audio tracks, variables and scenes.
class _Targets {
  _Targets(this.doc, this.nodeId) {
    final loc = ir.DocumentIndex.of(doc).locate(nodeId);
    scene = loc?.sceneIndex == null ? null : doc.scenes[loc!.sceneIndex!];
  }

  final ir.StageDocument doc;
  final String nodeId;
  late final ir.Scene? scene;

  List<ir.TimelineClock> get timelines => [
    ...?scene?.clocks.whereType<ir.TimelineClock>(),
  ];
  List<ir.Clock> get clocks => [...?scene?.clocks];
  List<ir.AudioTrack> get tracks => doc.audioTracks;
  List<ir.Variable> get variables => [
    for (final c in doc.tokens.collections) ...c.variables,
  ];

  /// A sensible new trigger of [w], or null when nothing fits.
  ir.InteractionTrigger? trigger(_When w) => switch (w) {
    _When.tap => const ir.InteractionTrigger.tap(),
    _When.hoverEnter => const ir.InteractionTrigger.hoverEnter(),
    _When.hoverLeave => const ir.InteractionTrigger.hoverLeave(),
    _When.sceneEnter => const ir.InteractionTrigger.sceneEnter(),
    _When.sceneLeave => const ir.InteractionTrigger.sceneLeave(),
    _When.clock =>
      clocks.isEmpty
          ? null
          : ir.InteractionTrigger.clockReach(
              clockId: clocks.first.id,
              value: 0,
            ),
    _When.audio =>
      tracks.isEmpty
          ? null
          : ir.InteractionTrigger.audioCue(
              audioTrackId: tracks.first.id,
              time: 0,
            ),
  };

  /// A sensible new action of [d], or null when nothing fits.
  ir.Action? action(_Do d) {
    final tl = timelines.isEmpty ? null : timelines.first.id;
    final tr = tracks.isEmpty ? null : tracks.first.id;
    return switch (d) {
      _Do.playTimeline =>
        tl == null ? null : ir.Action.playTimeline(clockId: tl),
      _Do.pauseTimeline =>
        tl == null ? null : ir.Action.pauseTimeline(clockId: tl),
      _Do.reverseTimeline =>
        tl == null ? null : ir.Action.reverseTimeline(clockId: tl),
      _Do.seekTimeline =>
        tl == null ? null : ir.Action.seekTimeline(clockId: tl, time: 0),
      _Do.playAudio =>
        tr == null ? null : ir.Action.playAudio(audioTrackId: tr),
      _Do.pauseAudio =>
        tr == null ? null : ir.Action.pauseAudio(audioTrackId: tr),
      _Do.seekAudio =>
        tr == null ? null : ir.Action.seekAudio(audioTrackId: tr, time: 0),
      _Do.setVariable =>
        variables.isEmpty
            ? null
            : ir.Action.setVariable(
                variableId: variables.first.id,
                value: _defaultFor(variables.first.type),
              ),
      _Do.scrollToScene => ir.Action.scrollToScene(
        sceneId: doc.scenes.first.id,
      ),
      _Do.openUrl => const ir.Action.openUrl(url: 'https://'),
      _Do.openLightbox => ir.Action.openLightbox(nodeId: nodeId),
    };
  }
}

ir.IrValue _defaultFor(ir.VariableType t) => switch (t) {
  ir.VariableType.number => const ir.IrValue.number(1),
  ir.VariableType.boolean => const ir.IrValue.boolean(true),
  ir.VariableType.color => const ir.IrValue.color(ir.StageColor.black),
  ir.VariableType.string ||
  ir.VariableType.fontFamily => const ir.IrValue.string(''),
};

List<ir.Interaction> _interactionsOf(ir.StageDocument doc, String id) =>
    ir.DocumentIndex.of(doc).node(id)?.common.interactions ?? const [];

class _AddInteraction extends ConsumerWidget {
  const _AddInteraction({required this.nodeId});

  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Builder(
    builder: (anchor) => SsIconButton(
      key: const ValueKey<String>('interactions:add'),
      icon: SsIcons.plus,
      semanticLabel: 'Add interaction',
      size: 24,
      iconSize: 14,
      onPressed: () {
        final doc = ref.read(editorControllerProvider).document;
        final targets = _Targets(doc, nodeId);
        final box = anchor.findRenderObject()! as RenderBox;
        showSsMenu(
          context,
          anchor: box.localToGlobal(Offset.zero) & box.size,
          placement: SsPlacement.belowEnd,
          entries: [
            for (final w in _When.values)
              SsMenuItem(
                label: _whenLabels[w]!,
                enabled: targets.trigger(w) != null,
                onSelected: () {
                  final list = _interactionsOf(doc, nodeId);
                  final id = ir.IdGenerator.forDocument(doc).next();
                  ref
                      .read(editorControllerProvider.notifier)
                      .execute(
                        SetInteractions(nodeId, [
                          ...list,
                          ir.Interaction(id: id, trigger: targets.trigger(w)!),
                        ], label: 'Add interaction'),
                      );
                },
              ),
          ],
        );
      },
    ),
  );
}

class _InteractionsBody extends ConsumerWidget {
  const _InteractionsBody({required this.nodeId});

  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final doc = ref.watch(editorControllerProvider.select((s) => s.document));
    final list = _interactionsOf(doc, nodeId);
    if (list.isEmpty) {
      return Padding(
        key: const ValueKey<String>('interactions:hint'),
        padding: const EdgeInsets.only(bottom: SsSpace.s2),
        child: Text(
          'Make this layer do something when it is tapped or hovered, when '
          'its scene appears, or at a moment in a clock or song.',
          style: t.text.caption,
        ),
      );
    }
    final targets = _Targets(doc, nodeId);
    final ctl = ref.read(editorControllerProvider.notifier);
    void write(
      List<ir.Interaction> next, {
      String label = 'Change interaction',
    }) => ctl.execute(SetInteractions(nodeId, next, label: label));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < list.length; i++)
          _InteractionCard(
            key: ValueKey<String>('interaction:${list[i].id}'),
            interaction: list[i],
            targets: targets,
            onChanged: (n) => write([
              for (var j = 0; j < list.length; j++) j == i ? n : list[j],
            ]),
            onRemove: () => write([
              for (var j = 0; j < list.length; j++)
                if (j != i) list[j],
            ], label: 'Remove interaction'),
          ),
      ],
    );
  }
}

class _InteractionCard extends StatelessWidget {
  const _InteractionCard({
    required this.interaction,
    required this.targets,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final ir.Interaction interaction;
  final _Targets targets;
  final ValueChanged<ir.Interaction> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final i = interaction;
    final when = _whenOf(i.trigger);
    return Container(
      margin: const EdgeInsets.only(bottom: SsSpace.s2),
      padding: const EdgeInsets.all(SsSpace.s2),
      decoration: BoxDecoration(
        border: Border.all(color: t.colors.borderSubtle),
        borderRadius: SsRadius.brMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SsDropdown<_When>(
                  semanticLabel: 'When',
                  value: when,
                  onChanged: (w) {
                    final tr = targets.trigger(w);
                    if (tr != null) onChanged(i.copyWith(trigger: tr));
                  },
                  items: [
                    for (final w in _When.values)
                      if (w == when || targets.trigger(w) != null)
                        SsDropdownItem(value: w, label: _whenLabels[w]!),
                  ],
                ),
              ),
              SsIconButton(
                icon: SsIcons.trash2,
                semanticLabel: 'Remove interaction',
                size: 24,
                iconSize: 12,
                onPressed: onRemove,
              ),
            ],
          ),
          ..._triggerParams(context, i),
          for (var k = 0; k < i.actions.length; k++)
            _ActionRow(
              key: ValueKey<String>('action:${i.id}:$k'),
              action: i.actions[k],
              targets: targets,
              onChanged: (a) => onChanged(
                i.copyWith(
                  actions: [
                    for (var j = 0; j < i.actions.length; j++)
                      j == k ? a : i.actions[j],
                  ],
                ),
              ),
              onRemove: () => onChanged(
                i.copyWith(
                  actions: [
                    for (var j = 0; j < i.actions.length; j++)
                      if (j != k) i.actions[j],
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Builder(
              builder: (anchor) => SsButton(
                key: ValueKey<String>('interaction:${i.id}:add-action'),
                label: 'Add action',
                icon: SsIcons.plus,
                variant: SsButtonVariant.ghost,
                onPressed: () {
                  final box = anchor.findRenderObject()! as RenderBox;
                  showSsMenu(
                    context,
                    anchor: box.localToGlobal(Offset.zero) & box.size,
                    entries: [
                      for (final d in _Do.values)
                        SsMenuItem(
                          label: _doLabels[d]!,
                          enabled: targets.action(d) != null,
                          onSelected: () => onChanged(
                            i.copyWith(
                              actions: [...i.actions, targets.action(d)!],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _triggerParams(BuildContext context, ir.Interaction i) =>
      switch (i.trigger) {
        ir.ClockReachTrigger(:final clockId, :final value) => [
          _Param(
            label: 'Clock',
            child: SsDropdown<String>(
              semanticLabel: 'Clock',
              value: clockId,
              onChanged: (c) => onChanged(
                i.copyWith(
                  trigger: ir.InteractionTrigger.clockReach(
                    clockId: c,
                    value: value,
                  ),
                ),
              ),
              items: [
                for (final c in targets.clocks)
                  SsDropdownItem(
                    value: c.id,
                    label: clockLabel(targets.doc, c),
                  ),
              ],
            ),
          ),
          _Param(
            label: 'Value',
            child: SsNumberField(
              semanticLabel: 'Clock value',
              value: value,
              step: 0.05,
              onChanged: (v) => onChanged(
                i.copyWith(
                  trigger: ir.InteractionTrigger.clockReach(
                    clockId: clockId,
                    value: v,
                  ),
                ),
              ),
            ),
          ),
        ],
        ir.AudioCueTrigger(:final audioTrackId, :final time) => [
          _trackParam(audioTrackId, (id) {
            onChanged(
              i.copyWith(
                trigger: ir.InteractionTrigger.audioCue(
                  audioTrackId: id,
                  time: time,
                ),
              ),
            );
          }),
          _Param(
            label: 'At',
            child: SsNumberField(
              semanticLabel: 'Audio time',
              value: time,
              unit: 's',
              min: 0,
              step: 0.1,
              onChanged: (v) => onChanged(
                i.copyWith(
                  trigger: ir.InteractionTrigger.audioCue(
                    audioTrackId: audioTrackId,
                    time: v,
                  ),
                ),
              ),
            ),
          ),
        ],
        _ => const [],
      };

  Widget _trackParam(String id, ValueChanged<String> set) => _Param(
    label: 'Audio',
    child: SsDropdown<String>(
      semanticLabel: 'Audio track',
      value: id,
      onChanged: set,
      items: [
        for (final (k, tr) in targets.tracks.indexed)
          SsDropdownItem(
            value: tr.id,
            label: targets.doc.assets[tr.assetId]?.name ?? 'Track ${k + 1}',
          ),
      ],
    ),
  );
}

class _Param extends StatelessWidget {
  const _Param({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: SsSpace.s1),
    child: Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: context.ss.text.small.copyWith(
              color: context.ss.colors.textSecondary,
            ),
          ),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.targets,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final ir.Action action;
  final _Targets targets;
  final ValueChanged<ir.Action> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final d = _doOf(action);
    return Padding(
      padding: const EdgeInsets.only(top: SsSpace.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SsIcon(SsIcons.chevronRight, size: 12),
              const SizedBox(width: SsSpace.s1),
              Expanded(
                child: SsDropdown<_Do>(
                  semanticLabel: 'Action',
                  value: d,
                  onChanged: (n) {
                    final a = targets.action(n);
                    if (a != null) onChanged(a);
                  },
                  items: [
                    for (final n in _Do.values)
                      if (n == d || targets.action(n) != null)
                        SsDropdownItem(value: n, label: _doLabels[n]!),
                  ],
                ),
              ),
              SsIconButton(
                icon: SsIcons.minus,
                semanticLabel: 'Remove action',
                size: 24,
                iconSize: 12,
                onPressed: onRemove,
              ),
            ],
          ),
          ..._params(context),
        ],
      ),
    );
  }

  Widget _timelineParam(String clockId, ValueChanged<String> set) => _Param(
    label: 'Timeline',
    child: SsDropdown<String>(
      semanticLabel: 'Timeline',
      value: clockId,
      onChanged: set,
      items: [
        for (final c in targets.timelines)
          SsDropdownItem(value: c.id, label: clockLabel(targets.doc, c)),
      ],
    ),
  );

  Widget _trackParam(String id, ValueChanged<String> set) => _Param(
    label: 'Audio',
    child: SsDropdown<String>(
      semanticLabel: 'Audio track',
      value: id,
      onChanged: set,
      items: [
        for (final (k, tr) in targets.tracks.indexed)
          SsDropdownItem(
            value: tr.id,
            label: targets.doc.assets[tr.assetId]?.name ?? 'Track ${k + 1}',
          ),
      ],
    ),
  );

  Widget _seconds(String label, double v, ValueChanged<double> set) => _Param(
    label: 'At',
    child: SsNumberField(
      semanticLabel: label,
      value: v,
      unit: 's',
      min: 0,
      step: 0.1,
      onChanged: set,
    ),
  );

  List<Widget> _params(BuildContext context) => switch (action) {
    ir.PlayTimelineAction(:final clockId) => [
      _timelineParam(
        clockId,
        (c) => onChanged(ir.Action.playTimeline(clockId: c)),
      ),
    ],
    ir.PauseTimelineAction(:final clockId) => [
      _timelineParam(
        clockId,
        (c) => onChanged(ir.Action.pauseTimeline(clockId: c)),
      ),
    ],
    ir.ReverseTimelineAction(:final clockId) => [
      _timelineParam(
        clockId,
        (c) => onChanged(ir.Action.reverseTimeline(clockId: c)),
      ),
    ],
    ir.SeekTimelineAction(:final clockId, :final time) => [
      _timelineParam(
        clockId,
        (c) => onChanged(ir.Action.seekTimeline(clockId: c, time: time)),
      ),
      _seconds(
        'Timeline time',
        time,
        (v) => onChanged(ir.Action.seekTimeline(clockId: clockId, time: v)),
      ),
    ],
    ir.PlayAudioAction(:final audioTrackId) => [
      _trackParam(
        audioTrackId,
        (id) => onChanged(ir.Action.playAudio(audioTrackId: id)),
      ),
    ],
    ir.PauseAudioAction(:final audioTrackId) => [
      _trackParam(
        audioTrackId,
        (id) => onChanged(ir.Action.pauseAudio(audioTrackId: id)),
      ),
    ],
    ir.SeekAudioAction(:final audioTrackId, :final time) => [
      _trackParam(
        audioTrackId,
        (id) => onChanged(ir.Action.seekAudio(audioTrackId: id, time: time)),
      ),
      _seconds(
        'Audio time',
        time,
        (v) =>
            onChanged(ir.Action.seekAudio(audioTrackId: audioTrackId, time: v)),
      ),
    ],
    ir.SetVariableAction(:final variableId, :final value) => [
      _Param(
        label: 'Variable',
        child: SsDropdown<String>(
          semanticLabel: 'Variable',
          value: variableId,
          onChanged: (id) {
            final v = targets.variables.firstWhere((x) => x.id == id);
            onChanged(
              ir.Action.setVariable(variableId: id, value: _defaultFor(v.type)),
            );
          },
          items: [
            for (final v in targets.variables)
              SsDropdownItem(value: v.id, label: v.name),
          ],
        ),
      ),
      _Param(
        label: 'To',
        child: _VariableValue(
          value: value,
          onChanged: (v) => onChanged(
            ir.Action.setVariable(variableId: variableId, value: v),
          ),
        ),
      ),
    ],
    ir.ScrollToSceneAction(:final sceneId) => [
      _Param(
        label: 'Scene',
        child: SsDropdown<String>(
          semanticLabel: 'Scene',
          value: sceneId,
          onChanged: (id) => onChanged(ir.Action.scrollToScene(sceneId: id)),
          items: [
            for (final (k, s) in targets.doc.scenes.indexed)
              SsDropdownItem(
                value: s.id,
                label: s.name.trim().isEmpty ? 'Scene ${k + 1}' : s.name,
              ),
          ],
        ),
      ),
    ],
    ir.OpenUrlAction(:final url, :final newTab) => [
      _Param(
        label: 'Link',
        child: SsTextField(
          key: ValueKey<String>('url:$url'),
          semanticLabel: 'Link address',
          dense: true,
          initialValue: url,
          releaseFocusOnSubmit: true,
          onSubmitted: (v) =>
              onChanged(ir.Action.openUrl(url: v.trim(), newTab: newTab)),
        ),
      ),
      SsToggle(
        label: 'New tab',
        value: newTab,
        onChanged: (v) => onChanged(ir.Action.openUrl(url: url, newTab: v)),
      ),
    ],
    ir.OpenLightboxAction(:final nodeId) => [
      Padding(
        padding: const EdgeInsets.only(top: SsSpace.s1),
        child: Text(
          nodeId == targets.nodeId
              ? 'Shows this layer full screen.'
              : 'Shows another layer full screen.',
          style: context.ss.text.caption,
        ),
      ),
    ],
  };
}

/// A literal for a set-variable action, by the value's type.
class _VariableValue extends StatelessWidget {
  const _VariableValue({required this.value, required this.onChanged});

  final ir.IrValue value;
  final ValueChanged<ir.IrValue> onChanged;

  @override
  Widget build(BuildContext context) => switch (value) {
    ir.NumberValue(value: final v) => SsNumberField(
      semanticLabel: 'New value',
      value: v,
      onChanged: (x) => onChanged(ir.IrValue.number(x)),
    ),
    ir.BoolValue(value: final v) => Align(
      alignment: Alignment.centerLeft,
      child: SsToggle(
        semanticLabel: 'New value',
        value: v,
        onChanged: (x) => onChanged(ir.IrValue.boolean(x)),
      ),
    ),
    ir.ColorValue(value: final c) => SsColorField(
      semanticLabel: 'New value',
      color: Color.from(alpha: c.a, red: c.r, green: c.g, blue: c.b),
      onChanged: (x) => onChanged(
        ir.IrValue.color(ir.StageColor(r: x.r, g: x.g, b: x.b, a: x.a)),
      ),
    ),
    ir.StringValue(value: final s) => SsTextField(
      key: ValueKey<String>('var-string:$s'),
      semanticLabel: 'New value',
      dense: true,
      initialValue: s,
      releaseFocusOnSubmit: true,
      onSubmitted: (x) => onChanged(ir.IrValue.string(x)),
    ),
    _ => const SizedBox.shrink(),
  };
}
