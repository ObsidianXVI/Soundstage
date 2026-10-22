import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// The T0.7 sound demo (open the app with `?demo=sound`).
const String kSoundDemoAsset = 'assets/demo/sound.stage.json';

/// The sound demo document, loaded and migrated from the app bundle.
final soundDemoDocumentProvider = FutureProvider<ir.StageDocument>((
  ref,
) async {
  final text = await rootBundle.loadString(kSoundDemoAsset);
  final json = jsonDecode(text) as Map<String, Object?>;
  return ir.StageDocument.fromJsonMigrating(json);
});

/// Plays the sound demo behind the enter gate, with its audio.
class SoundDemoHarness extends ConsumerWidget {
  const SoundDemoHarness({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(soundDemoDocumentProvider)) {
      AsyncData(:final value) => _SoundStage(document: value),
      AsyncError(:final error) => Center(
        child: Text('Could not load the sound demo: $error'),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _SoundStage extends StatefulWidget {
  const _SoundStage({required this.document});

  final ir.StageDocument document;

  @override
  State<_SoundStage> createState() => _SoundStageState();
}

class _SoundStageState extends State<_SoundStage> {
  late final StageEnvironment _env = StageEnvironment.forDocument(
    widget.document,
  );
  late final StageAudioService _audio = StageAudioService.forDocument(
    widget.document,
  );

  @override
  void dispose() {
    _audio.dispose();
    _env.media?.cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StageEnterGate(
      document: widget.document,
      environment: _env,
      audio: _audio,
      child: StagePlayer(
        document: widget.document,
        environment: _env,
        audio: _audio,
      ),
    );
  }
}
