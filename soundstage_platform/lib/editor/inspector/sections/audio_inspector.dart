import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../audio/waveform_peaks.dart';
import '../../core/core.dart';
import '../../insert/asset_service.dart';
import 'audio_section.dart';
import 'clock_fields.dart';
import 'lyrics_import.dart';

// The Audio view of the inspector (m2.md "Audio lane"): shown when an audio
// track is selected (EditorState.selectedAudioTrackId). The track's asset,
// scope, autoplay, loop, volume and fades, its lyrics (LRC import), and
// removing it. Every change is an `UpdateAudioTrack`; scrubbed numbers are
// one undo step per gesture.

class AudioTrackInspector extends ConsumerWidget {
  const AudioTrackInspector({required this.trackId, super.key});

  final String trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final doc = ref.watch(editorControllerProvider.select((s) => s.document));
    ir.AudioTrack? track;
    for (final a in doc.audioTracks) {
      if (a.id == trackId) track = a;
    }
    if (track == null) return const SizedBox.shrink();
    final ctl = ref.read(editorControllerProvider.notifier);
    final audioAssets = [
      for (final a in doc.assets.values)
        if (a.kind == ir.AssetKind.audio) a,
    ];

    void update(
      String what,
      ir.AudioTrack Function(ir.AudioTrack) change, {
      bool scrub = false,
    }) => ctl.execute(
      UpdateAudioTrack(
        trackId,
        change,
        label: 'Change $what',
        coalesceKey: scrub ? 'audio:$trackId:$what' : null,
      ),
    );

    final scope = track.scope;
    final story = scope is ir.StoryAudioScope;
    final sceneChoices = [
      for (final (i, s) in doc.scenes.indexed)
        SsDropdownItem<String>(
          value: s.id,
          label: s.name.isEmpty ? 'Scene ${i + 1}' : s.name,
        ),
    ];

    return Padding(
      key: const ValueKey('audio-inspector'),
      padding: const EdgeInsets.all(SsSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SsIcon(SsIcons.music, size: 14, color: t.colors.textSecondary),
              const SizedBox(width: SsSpace.s2),
              Expanded(
                child: Text(
                  audioAssetName(doc, track),
                  style: t.text.bodyStrong,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SsIconButton(
                icon: SsIcons.x,
                semanticLabel: 'Close audio settings',
                size: 24,
                iconSize: 12,
                onPressed: () => ctl.selectAudioTrack(null),
              ),
            ],
          ),
          const SizedBox(height: SsSpace.s2),
          WaveformPreview(assetId: track.assetId),
          const SizedBox(height: SsSpace.s3),
          ClockField(
            'Sound',
            SsDropdown<String>(
              semanticLabel: 'Sound',
              value: audioAssets.any((a) => a.id == track!.assetId)
                  ? track.assetId
                  : null,
              hint: 'Missing audio',
              items: [
                for (final a in audioAssets)
                  SsDropdownItem(
                    value: a.id,
                    label: a.name.isEmpty ? 'Audio ${a.id}' : a.name,
                  ),
              ],
              onChanged: (id) =>
                  update('sound', (x) => x.copyWith(assetId: id)),
            ),
          ),
          ClockField(
            'Plays in',
            SsSegmented<bool>(
              semanticLabel: 'Plays in',
              expand: true,
              selected: story,
              onChanged: (whole) {
                if (whole == story) return;
                final active = ref.read(editorControllerProvider).activeSceneId;
                update(
                  'scope',
                  (x) => x.copyWith(
                    scope: whole
                        ? const ir.AudioScope.story()
                        : ir.AudioScope.scene(active ?? doc.scenes.first.id),
                  ),
                );
              },
              segments: const [
                SsSegment(value: false, label: 'Scene'),
                SsSegment(value: true, label: 'Story'),
              ],
            ),
          ),
          if (scope is ir.SceneAudioScope)
            ClockField(
              'Scene',
              SsDropdown<String>(
                semanticLabel: 'Scene',
                value: scope.sceneId,
                items: sceneChoices,
                onChanged: (id) => update(
                  'scope',
                  (x) => x.copyWith(scope: ir.AudioScope.scene(id)),
                ),
              ),
            ),
          ClockField(
            'Autoplay',
            Align(
              alignment: Alignment.centerLeft,
              child: SsToggle(
                value: track.autoplay,
                semanticLabel: 'Autoplay',
                onChanged: (v) =>
                    update('autoplay', (x) => x.copyWith(autoplay: v)),
              ),
            ),
          ),
          ClockField(
            'Loop',
            Align(
              alignment: Alignment.centerLeft,
              child: SsToggle(
                value: track.loop,
                semanticLabel: 'Loop',
                onChanged: (v) => update('loop', (x) => x.copyWith(loop: v)),
              ),
            ),
          ),
          ClockField(
            'Volume',
            SsNumberField(
              semanticLabel: 'Volume',
              label: 'V',
              value: track.volume * 100,
              unit: '%',
              min: 0,
              max: 100,
              step: 5,
              fractionDigits: 0,
              onChangeStart: ctl.beginGesture,
              onChangeEnd: ctl.endGesture,
              onChanged: (v) => update(
                'volume',
                (x) => x.copyWith(volume: (v / 100).clamp(0.0, 1.0)),
                scrub: true,
              ),
            ),
          ),
          ClockField(
            'Fade in',
            SsNumberField(
              semanticLabel: 'Fade in',
              label: 'I',
              value: track.fadeIn,
              unit: 's',
              min: 0,
              max: 60,
              step: 0.1,
              onChangeStart: ctl.beginGesture,
              onChangeEnd: ctl.endGesture,
              onChanged: (v) =>
                  update('fade in', (x) => x.copyWith(fadeIn: v), scrub: true),
            ),
          ),
          ClockField(
            'Fade out',
            SsNumberField(
              semanticLabel: 'Fade out',
              label: 'O',
              value: track.fadeOut,
              unit: 's',
              min: 0,
              max: 60,
              step: 0.1,
              onChangeStart: ctl.beginGesture,
              onChangeEnd: ctl.endGesture,
              onChanged: (v) => update(
                'fade out',
                (x) => x.copyWith(fadeOut: v),
                scrub: true,
              ),
            ),
          ),
          const SizedBox(height: SsSpace.s2),
          Text('Lyrics', style: t.text.overline),
          const SizedBox(height: SsSpace.s2),
          LyricsImport(track: track),
          const SizedBox(height: SsSpace.s3),
          FitLeft(
            child: SsButton(
              label: 'Remove audio',
              icon: SsIcons.trash2,
              onPressed: () => ctl.execute(RemoveAudioTrack(trackId)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small waveform of audio asset [assetId], from its peaks (computed on
/// first request for assets that lack them). Empty while loading or when
/// the file cannot be decoded.
class WaveformPreview extends ConsumerWidget {
  const WaveformPreview({required this.assetId, super.key});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ss.colors;
    final peaks = ref.watch(audioPeaksProvider(assetId)).asData?.value;
    return Container(
      key: const ValueKey('waveform-preview'),
      height: 40,
      decoration: BoxDecoration(color: c.surface2, borderRadius: SsRadius.brSm),
      child: peaks == null || peaks.length == 0
          ? null
          : CustomPaint(
              painter: WaveformPainter(peaks, c.accent),
              size: Size.infinite,
            ),
    );
  }
}

/// Draws [peaks] as mirrored bars, one per pixel column, each the loudest
/// bucket under it.
class WaveformPainter extends CustomPainter {
  const WaveformPainter(this.peaks, this.color);

  final WaveformPeaks peaks;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || peaks.duration <= 0) return;
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    final mid = size.height / 2;
    final columns = size.width.floor();
    for (var x = 0; x < columns; x++) {
      final a = peaks.peakIn(
        x / columns * peaks.duration,
        (x + 1) / columns * peaks.duration,
      );
      final h = (a * mid).clamp(0.5, mid);
      canvas.drawLine(Offset(x + 0.5, mid - h), Offset(x + 0.5, mid + h), p);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.peaks != peaks || old.color != color;
}
