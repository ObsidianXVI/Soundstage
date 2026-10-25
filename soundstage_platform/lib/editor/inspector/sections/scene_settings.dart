import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import 'audio_section.dart';
import 'clocks_section.dart';

// The active scene's settings, shown by the Inspector when nothing is
// selected (DECISIONS: scene settings live in the Inspector only; the
// Scenes panel lists, adds, reorders and renames).

// ---- Settings ---------------------------------------------------------------

/// The settings of [scene]: kind, scroll length (pinned only), background,
/// export mode and poster clock. Each edit is a [UpdateSceneSettings]; a
/// scrub or a colour drag is one undo step.
class SceneSettings extends ConsumerWidget {
  const SceneSettings({required this.scene, super.key});

  final ir.Scene scene;

  static ir.StageColor? _solid(ir.Scene s) =>
      s.background.length == 1 && s.background.first is ir.SolidPaint
      ? (s.background.first as ir.SolidPaint).color
      : null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    final pinned = scene.kind == ir.SceneKind.pinned;
    final solid = _solid(scene);
    final mixedBackground = scene.background.isNotEmpty && solid == null;

    void update({
      String? name,
      ir.SceneKind? kind,
      double? scrollLength,
      ir.SceneExportMode? exportAs,
      ({double? value})? posterClock,
      List<ir.Paint>? background,
    }) => ctl.execute(
      UpdateSceneSettings(
        scene.id,
        name: name,
        kind: kind,
        scrollLength: scrollLength,
        exportAs: exportAs,
        posterClock: posterClock,
        background: background,
      ),
    );

    Widget field(String label, Widget control, {String? hint}) => Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: t.text.small.copyWith(color: t.colors.textSecondary),
            ),
          ),
          Expanded(child: control),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SsSpace.s3,
        SsSpace.s3,
        SsSpace.s3,
        SsSpace.s2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: SsSpace.s2),
            child: Text('Scene settings', style: t.text.overline),
          ),
          field(
            'Kind',
            SsSegmented<ir.SceneKind>(
              semanticLabel: 'Scene kind',
              expand: true,
              selected: scene.kind,
              onChanged: (k) => update(
                kind: k,
                // A pinned scene with no scroll length never scrolls.
                scrollLength:
                    k == ir.SceneKind.pinned && scene.scrollLength == 0
                    ? 1
                    : null,
              ),
              segments: const [
                SsSegment(value: ir.SceneKind.pinned, label: 'Pinned'),
                SsSegment(value: ir.SceneKind.flow, label: 'Flow'),
              ],
            ),
          ),
          if (pinned)
            field(
              'Scroll length',
              SsNumberField(
                semanticLabel: 'Scroll length',
                value: scene.scrollLength,
                unit: '×',
                min: 0,
                max: 50,
                step: 0.25,
                onChangeStart: ctl.beginGesture,
                onChangeEnd: ctl.endGesture,
                onChanged: (v) => update(scrollLength: v),
              ),
            ),
          field(
            'Background',
            Row(
              children: [
                Expanded(
                  child: SsColorField(
                    semanticLabel: 'Scene background',
                    // With no colour yet the field is "None"; typing one
                    // makes it opaque.
                    color: solid == null
                        ? const Color(0xFFFFFFFF)
                        : Color.from(
                            alpha: solid.a,
                            red: solid.r,
                            green: solid.g,
                            blue: solid.b,
                          ),
                    mixed: solid == null,
                    placeholder: mixedBackground ? 'Mixed' : 'None',
                    onChangeStart: ctl.beginGesture,
                    onChangeEnd: ctl.endGesture,
                    onChanged: (color) {
                      // The live scene, not the one this build captured: the
                      // field can commit twice before it rebuilds.
                      final doc = ref.read(editorControllerProvider).document;
                      final live = doc.scenes.where((x) => x.id == scene.id);
                      final paintId =
                          live.isNotEmpty && live.first.background.isNotEmpty
                          ? live.first.background.first.id
                          : ir.IdGenerator.forDocument(doc).next();
                      update(
                        background: [
                          ir.Paint.solid(
                            id: paintId,
                            color: ir.StageColor(
                              r: color.r,
                              g: color.g,
                              b: color.b,
                              a: color.a,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                if (scene.background.isNotEmpty)
                  SsIconButton(
                    icon: SsIcons.x,
                    semanticLabel: 'Clear background',
                    size: 24,
                    iconSize: 12,
                    onPressed: () => update(background: const []),
                  ),
              ],
            ),
          ),
          field(
            'Export as',
            SsSegmented<ir.SceneExportMode>(
              semanticLabel: 'Export as',
              expand: true,
              selected: scene.exportAs,
              onChanged: (m) => update(exportAs: m),
              segments: const [
                SsSegment(value: ir.SceneExportMode.auto, label: 'Auto'),
                SsSegment(value: ir.SceneExportMode.text, label: 'Text'),
                SsSegment(value: ir.SceneExportMode.poster, label: 'Poster'),
              ],
            ),
          ),
          field(
            'Poster clock',
            Row(
              children: [
                Expanded(
                  child: SsNumberField(
                    semanticLabel: 'Poster clock',
                    value: scene.effectivePosterClock,
                    min: 0,
                    max: 1,
                    step: 0.05,
                    enabled: scene.exportAs != ir.SceneExportMode.text,
                    onChangeStart: ctl.beginGesture,
                    onChangeEnd: ctl.endGesture,
                    onChanged: (v) => update(posterClock: (value: v)),
                  ),
                ),
                if (scene.posterClock != null)
                  SsIconButton(
                    icon: SsIcons.rotateCcw,
                    semanticLabel: 'Reset poster clock',
                    size: 24,
                    iconSize: 12,
                    onPressed: () => update(posterClock: (value: null)),
                  ),
              ],
            ),
          ),
          AudioSection(scene: scene),
          ClocksSection(scene: scene),
        ],
      ),
    );
  }
}
