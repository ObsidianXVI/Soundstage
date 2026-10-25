import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../core/core.dart';
import 'inspector_providers.dart';
import 'property_writer.dart';
import 'section_registry.dart';
import 'sections/audio_inspector.dart';
import 'sections/scene_settings.dart';

export 'fields/field_frame.dart';
export 'fields/props.dart';
export 'fields/rows.dart';
export 'inspector_providers.dart';
export 'property_writer.dart';
export 'section_registry.dart';

/// The inspector (architecture §15): the right-hand panel.
///
/// - Nothing selected: the active scene's settings.
/// - A selection: the sections of [kInspectorSections] that apply to it, in
///   Figma's order, collapsible and remembered. Controls read through the
///   property registry at the edited breakpoint and write through
///   [PropertyWriter] (edit scope, Alt flip, one undo step per gesture).
class Inspector extends ConsumerStatefulWidget {
  const Inspector({super.key});

  @override
  ConsumerState<Inspector> createState() => _InspectorState();
}

class _InspectorState extends ConsumerState<Inspector> {
  PropertyWriter? _writer;

  PropertyWriter _writerFor(IdList ids) {
    final w = _writer;
    if (w != null && w.ids.length == ids.length) {
      var same = true;
      for (var i = 0; i < ids.length; i++) {
        if (w.ids[i] != ids.ids[i]) {
          same = false;
          break;
        }
      }
      if (same) return w;
    }
    return _writer = PropertyWriter(
      ref.read(editorControllerProvider.notifier),
      () => ref.read(editorControllerProvider),
      ids.ids,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    final ids = ref.watch(selectionIdsProvider);
    final audioTrack = ref.watch(
      editorControllerProvider.select((s) => s.selectedAudioTrackId),
    );
    return Container(
      key: const ValueKey<String>('inspector'),
      color: c.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: SsSpace.s3),
                child: Text('Inspector', style: context.ss.text.bodyStrong),
              ),
            ),
          ),
          Expanded(
            child: ids.isEmpty && audioTrack != null
                ? SingleChildScrollView(
                    child: AudioTrackInspector(trackId: audioTrack),
                  )
                : ids.isEmpty
                ? const _SceneInspector()
                : InspectorScope(
                    selection: ids,
                    writer: _writerFor(ids),
                    child: const _SelectionInspector(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SceneInspector extends ConsumerWidget {
  const _SceneInspector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scene = ref.watch(
      editorControllerProvider.select((s) => s.activeScene),
    );
    if (scene == null) {
      return const _Empty(
        title: 'Nothing selected',
        body: 'Select a layer to edit its properties.',
      );
    }
    return SingleChildScrollView(child: SceneSettings(scene: scene));
  }
}

class _SelectionInspector extends ConsumerWidget {
  const _SelectionInspector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(selectionInfoProvider);
    if (info.isEmpty) {
      return const _Empty(
        title: 'Layer not found',
        body: 'The selection no longer exists at this breakpoint.',
      );
    }
    final sections = [
      for (final s in kInspectorSections)
        if (s.appliesTo(info)) s,
    ];
    return ListView(
      key: const ValueKey<String>('inspector-sections'),
      padding: EdgeInsets.zero,
      children: [
        for (final s in sections)
          _SectionShell(
            key: ValueKey<String>('section:${s.id}'),
            spec: s,
            info: info,
          ),
      ],
    );
  }
}

class _SectionShell extends ConsumerWidget {
  const _SectionShell({required this.spec, required this.info, super.key});

  final InspectorSectionSpec spec;
  final SelectionInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(
      collapsedSectionsProvider.select((s) => s.contains(spec.id)),
    );
    return SsPanel(
      title: spec.title,
      collapsible: spec.collapsible,
      expanded: !collapsed,
      onExpandedChanged: (open) => ref
          .read(collapsedSectionsProvider.notifier)
          .set(spec.id, collapsed: !open),
      actions: spec.actions?.call(context, info),
      child: spec.builder(context, info),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsIcon(
              SsIcons.slidersHorizontal,
              size: 24,
              color: t.colors.textDisabled,
            ),
            const SizedBox(height: SsSpace.s3),
            Text(title, style: t.text.bodyStrong, textAlign: TextAlign.center),
            const SizedBox(height: SsSpace.s1),
            Text(body, style: t.text.caption, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
