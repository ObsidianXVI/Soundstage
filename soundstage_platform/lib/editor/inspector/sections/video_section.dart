import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../timeline/timeline_math.dart' show clockLabel;
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../property_writer.dart';
import '../section_registry.dart';

/// Video playback (m3.md T3.6): how it fills its box, controls, autoplay,
/// loop, sound, playing only while on screen, a trim, rate, volume and a
/// poster image. Plays in the preview and the published story; the canvas
/// shows its first frame.
final InspectorSectionSpec videoSection = InspectorSectionSpec(
  id: 'video',
  title: 'Video',
  appliesTo: (info) =>
      info.kinds.length == 1 && info.kinds.single == ir.NodeKind.video,
  builder: (context, info) => const _VideoBody(),
);

class _VideoBody extends StatelessWidget {
  const _VideoBody();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LabelRow(
        label: 'Scale',
        child: EnumProp(
          path: 'scaleMode',
          semanticLabel: 'Video scale',
          options: [
            EnumOption('fill', 'Fill'),
            EnumOption('fit', 'Fit'),
            EnumOption('crop', 'Crop'),
          ],
        ),
      ),
      LabelRow(
        label: 'Controls',
        child: EnumProp(
          path: 'controls',
          semanticLabel: 'Video controls',
          options: [
            EnumOption('none', 'None'),
            EnumOption('minimal', 'Button'),
            EnumOption('full', 'Full'),
          ],
        ),
      ),
      BoolProp(path: 'autoplay', label: 'Autoplay'),
      BoolProp(path: 'loop', label: 'Loop'),
      BoolProp(path: 'muted', label: 'Muted'),
      BoolProp(path: 'playWhenVisible', label: 'Pause when off screen'),
      Grid(
        children: [
          NumberProp(
            path: 'startTime',
            label: 'In',
            unit: 's',
            semanticLabel: 'Start at',
            min: 0,
            step: 0.1,
          ),
          _EndField(),
          NumberProp(
            path: 'playbackRate',
            label: '×',
            semanticLabel: 'Playback rate',
            min: 0.25,
            max: 4,
            step: 0.25,
          ),
          NumberProp(
            path: 'volume',
            label: 'Vol',
            unit: '%',
            scale: 100,
            semanticLabel: 'Volume',
            min: 0,
            max: 100,
          ),
        ],
      ),
      LabelRow(label: 'Poster', child: _PosterField()),
      LabelRow(label: 'Scrub with', child: _ScrubField()),
    ],
  );
}

/// The trim's end: empty plays to the end of the file.
class _EndField extends ConsumerWidget {
  const _EndField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'endTime';
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final v = r.value;
    return FieldFrame.single(
      path: path,
      keyframes: false,
      child: Row(
        children: [
          Expanded(
            child: SsNumberField(
              key: const ValueKey<String>('field:endTime'),
              label: 'Out',
              unit: 's',
              semanticLabel: 'End at',
              mixed: r.mixed,
              value: v is ir.NumberValue ? v.value : null,
              min: 0,
              step: 0.1,
              onChangeStart: w.beginGesture,
              onChangeEnd: w.endGesture,
              onChanged: (x) => w.set(path, ir.IrValue.number(x)),
            ),
          ),
          if (v is ir.NumberValue)
            SsIconButton(
              icon: SsIcons.x,
              semanticLabel: 'Play to the end',
              size: 24,
              iconSize: 12,
              onPressed: () => w.set(path, const ir.IrValue.none()),
            ),
        ],
      ),
    );
  }
}

/// The image shown before the video plays (and in static exports).
class _PosterField extends ConsumerWidget {
  const _PosterField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'posterAssetId';
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final assets = ref.watch(
      editorControllerProvider.select((s) => s.document.assets),
    );
    final images = [
      for (final a in assets.values)
        if (a.kind == ir.AssetKind.image) a,
    ];
    final v = r.value;
    final current = v is ir.StringValue ? v.value : '';
    return SsDropdown<String>(
      key: const ValueKey<String>('video-poster'),
      semanticLabel: 'Poster image',
      value: images.any((a) => a.id == current) ? current : '',
      onChanged: (id) => w.set(
        path,
        id.isEmpty ? const ir.IrValue.none() : ir.IrValue.string(id),
      ),
      items: [
        const SsDropdownItem(value: '', label: 'First frame'),
        for (final a in images)
          SsDropdownItem(value: a.id, label: a.name.isEmpty ? a.id : a.name),
      ],
    );
  }
}

/// A clock that drives the video's time instead of playing it (scroll
/// scrubbing; image sequences scrub more smoothly on the web).
class _ScrubField extends ConsumerWidget {
  const _ScrubField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'scrubClockId';
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final clocks = ref.watch(
      editorControllerProvider.select(
        (s) => s.activeScene?.clocks ?? const <ir.Clock>[],
      ),
    );
    final doc = ref.read(editorControllerProvider).document;
    final v = r.value;
    final current = v is ir.StringValue ? v.value : '';
    return SsDropdown<String>(
      key: const ValueKey<String>('video-scrub'),
      semanticLabel: 'Scrub with clock',
      value: clocks.any((c) => c.id == current) ? current : '',
      onChanged: (id) => w.set(
        path,
        id.isEmpty ? const ir.IrValue.none() : ir.IrValue.string(id),
      ),
      items: [
        const SsDropdownItem(value: '', label: 'Nothing (plays)'),
        for (final c in clocks)
          SsDropdownItem(value: c.id, label: clockLabel(doc, c)),
      ],
    );
  }
}
