import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../panels/asset_actions.dart';
import 'clock_fields.dart';

// The Audio list of the scene settings (m2.md "Audio lane"): the audio
// tracks that play in the active scene (its own and the story's), selecting
// one opens its Audio view in the inspector, and "Add audio…".

/// "m:ss" for [seconds].
String formatAudioTime(double seconds) {
  final s = seconds.isFinite ? seconds.round() : 0;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The tracks that play in scene [sceneId]: story tracks and the scene's
/// own, in document order.
List<ir.AudioTrack> audioTracksOfScene(ir.StageDocument doc, String sceneId) =>
    [
      for (final t in doc.audioTracks)
        if (t.scope is ir.StoryAudioScope ||
            (t.scope is ir.SceneAudioScope &&
                (t.scope as ir.SceneAudioScope).sceneId == sceneId))
          t,
    ];

/// The name shown for the asset of [track].
String audioAssetName(ir.StageDocument doc, ir.AudioTrack track) {
  final a = doc.assets[track.assetId];
  if (a == null) return 'Missing audio';
  return a.name.isEmpty ? 'Audio ${a.id}' : a.name;
}

class AudioSection extends ConsumerWidget {
  const AudioSection({required this.scene, super.key});

  final ir.Scene scene;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final doc = ref.read(editorControllerProvider).document;
    final choice = await showAddAudioDialog(
      context,
      assets: [
        for (final a in doc.assets.values)
          if (a.kind == ir.AssetKind.audio) a,
      ],
      upload: () async {
        final added = await ref.read(assetActionsProvider).uploadAudio();
        return added.isEmpty ? null : added.first;
      },
    );
    if (choice == null) return;
    ref
        .read(editorControllerProvider.notifier)
        .execute(
          AddAudioTrack(
            choice.assetId,
            sceneId: choice.wholeStory ? null : scene.id,
            clockSceneId: scene.id,
          ),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final doc = ref.watch(editorControllerProvider.select((s) => s.document));
    final selected = ref.watch(
      editorControllerProvider.select((s) => s.selectedAudioTrackId),
    );
    final tracks = audioTracksOfScene(doc, scene.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SsSpace.s3,
        SsSpace.s2,
        SsSpace.s3,
        SsSpace.s1,
      ),
      child: Column(
        key: const ValueKey('audio-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text('Audio', style: t.text.overline)),
              SsIconButton(
                icon: SsIcons.plus,
                semanticLabel: 'Add audio',
                size: 24,
                iconSize: 14,
                onPressed: () => _add(context, ref),
              ),
            ],
          ),
          if (tracks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: SsSpace.s1),
              child: Text(
                'No audio in this scene.',
                style: t.text.caption.copyWith(color: t.colors.textDisabled),
              ),
            ),
          for (final track in tracks)
            _AudioRow(
              key: ValueKey('audio-${track.id}'),
              track: track,
              name: audioAssetName(doc, track),
              duration: doc.assets[track.assetId]?.duration,
              selected: track.id == selected,
            ),
        ],
      ),
    );
  }
}

class _AudioRow extends ConsumerWidget {
  const _AudioRow({
    required this.track,
    required this.name,
    required this.duration,
    required this.selected,
    super.key,
  });

  final ir.AudioTrack track;
  final String name;
  final double? duration;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final story = track.scope is ir.StoryAudioScope;
    final meta = [
      story ? 'Story' : 'This scene',
      if (duration != null) formatAudioTime(duration!),
      if (track.lyrics != null) 'Lyrics',
    ].join(' · ');
    return SsInteractive(
      selected: selected,
      semanticLabel: 'Audio $name',
      semanticValue: selected ? 'Selected' : null,
      excludeSemantics: true,
      onTap: () => ref
          .read(editorControllerProvider.notifier)
          .selectAudioTrack(selected ? null : track.id),
      builder: (context, s) => Container(
        margin: const EdgeInsets.only(top: SsSpace.s1),
        padding: const EdgeInsets.symmetric(
          horizontal: SsSpace.s2,
          vertical: SsSpace.s1,
        ),
        decoration: BoxDecoration(
          color: selected
              ? c.accent.withValues(alpha: 0.18)
              : s.contains(WidgetState.hovered)
              ? c.surface2
              : c.surface1,
          borderRadius: SsRadius.brMd,
          border: Border.all(color: selected ? c.accent : c.borderSubtle),
        ),
        child: Row(
          children: [
            SsIcon(SsIcons.music, size: 14, color: c.textSecondary),
            const SizedBox(width: SsSpace.s2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: t.text.bodyStrong,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    meta,
                    style: t.text.caption.copyWith(color: c.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Add audio dialog -------------------------------------------------------------

/// What the Add audio dialog chose.
typedef AddAudioChoice = ({String assetId, bool wholeStory});

/// Asks which audio file to add and where it plays: one of [assets] (the
/// document's audio) or a new file from [upload] (the picker; null when
/// cancelled or refused). Resolves to the choice, or null when cancelled.
Future<AddAudioChoice?> showAddAudioDialog(
  BuildContext context, {
  required List<ir.Asset> assets,
  required Future<ir.Asset?> Function() upload,
}) => showSsDialog<AddAudioChoice>(
  context,
  builder: (ctx) => _AddAudioDialog(assets: assets, upload: upload),
);

class _AddAudioDialog extends StatefulWidget {
  const _AddAudioDialog({required this.assets, required this.upload});

  final List<ir.Asset> assets;
  final Future<ir.Asset?> Function() upload;

  @override
  State<_AddAudioDialog> createState() => _AddAudioDialogState();
}

class _AddAudioDialogState extends State<_AddAudioDialog> {
  String? _asset;
  bool _story = false;
  bool _busy = false;

  Future<void> _upload() async {
    setState(() => _busy = true);
    final added = await widget.upload();
    if (!mounted) return;
    if (added == null) {
      setState(() => _busy = false);
      return;
    }
    Navigator.of(context).pop((assetId: added.id, wholeStory: _story));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return SsDialog(
      title: 'Add audio',
      width: 340,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClockField(
            'Plays in',
            SsSegmented<bool>(
              semanticLabel: 'Plays in',
              expand: true,
              selected: _story,
              onChanged: (v) => setState(() => _story = v),
              segments: const [
                SsSegment(value: false, label: 'This scene'),
                SsSegment(value: true, label: 'Whole story'),
              ],
            ),
            stacked: true,
          ),
          Text(
            'Audio in this story',
            style: t.text.small.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: SsSpace.s1),
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: BoxDecoration(
              border: Border.all(color: c.borderSubtle),
              borderRadius: SsRadius.brSm,
            ),
            child: widget.assets.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(SsSpace.s2),
                    child: Text(
                      'No audio yet. Upload a file.',
                      style: t.text.caption.copyWith(color: c.textDisabled),
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final a in widget.assets)
                        SsInteractive(
                          selected: a.id == _asset,
                          semanticLabel: a.name.isEmpty ? a.id : a.name,
                          excludeSemantics: true,
                          onTap: () => setState(() => _asset = a.id),
                          builder: (context, s) => Container(
                            key: ValueKey('audio-choice-${a.id}'),
                            color: a.id == _asset
                                ? c.accent.withValues(alpha: 0.18)
                                : s.contains(WidgetState.hovered)
                                ? c.surface2
                                : null,
                            padding: const EdgeInsets.symmetric(
                              horizontal: SsSpace.s2,
                              vertical: SsSpace.s1,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    a.name.isEmpty ? a.id : a.name,
                                    style: t.text.body,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (a.duration != null)
                                  Text(
                                    formatAudioTime(a.duration!),
                                    style: t.text.caption.copyWith(
                                      color: c.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: SsSpace.s2),
          FitLeft(
            child: SsButton(
              label: _busy ? 'Uploading…' : 'Upload file…',
              icon: SsIcons.plus,
              onPressed: _busy ? null : _upload,
            ),
          ),
        ],
      ),
      actions: [
        SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SsButton(
          label: 'Add audio',
          variant: SsButtonVariant.primary,
          onPressed: _asset == null
              ? null
              : () => Navigator.of(
                  context,
                ).pop((assetId: _asset!, wholeStory: _story)),
        ),
      ],
    );
  }
}
