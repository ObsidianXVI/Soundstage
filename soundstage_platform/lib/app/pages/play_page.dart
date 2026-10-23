import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/sound_demo.dart';

import 'not_found_page.dart';

/// `/play/:id`: the story in `StagePlayer` behind the enter gate, as the
/// demo harness plays it. `?wheel=native` and `?stats=1` work as before.
class PlayPage extends ConsumerWidget {
  const PlayPage({
    required this.storyId,
    this.wheelNative,
    this.statsOn,
    super.key,
  });

  final String storyId;
  final bool? wheelNative;
  final bool? statsOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(storyDocumentProvider(storyId))) {
      AsyncData(:final value) when value != null => Scaffold(
        body: GatedStagePlayer(
          document: value,
          coverFocal: _coverFocal(storyId),
          buildOnEnter: storyId == 'demo-spike',
          wheelNative: wheelNative,
          statsOn: statsOn,
        ),
      ),
      AsyncData() => const NotFoundPage(message: 'Story not found'),
      AsyncError(:final error) => NotFoundPage(
        message: 'Could not play the story: $error',
      ),
      _ => const Scaffold(body: SizedBox.shrink()),
    };
  }

  /// The gate cover's focal point for the bundled stories that were tuned.
  static Offset _coverFocal(String id) => switch (id) {
    'demo-spike' => const Offset(0.62, 0.40),
    'demo-sound' => const Offset(0.68, 0.42),
    _ => const Offset(0.5, 0.5),
  };
}
