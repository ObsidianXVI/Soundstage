import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/app/sound_demo.dart';
import 'package:soundstage_platform/runtime/runtime.dart'
    show StageAssetResolver, StageTier;

import 'not_found_page.dart';

/// The published story at a slug (null: nothing published there, or a
/// local-only build).
final publishedStoryProvider = FutureProvider.autoDispose
    .family<PublishedStory?, String>((ref, slug) async {
      final cloud = ref.watch(cloudProvider);
      if (cloud == null) return null;
      return openPublished(
        slug,
        backend: cloud.backend,
        fetch: StageAssetResolver().load,
      );
    });

/// `/s/:slug`: a published story (m4.md T4.2) in the player behind the
/// enter gate. Anyone can open it; the document and assets are public.
/// `?tier=lite|static` plays the reduced tiers (m4.md T4.6).
class PublishedPage extends ConsumerWidget {
  const PublishedPage({
    required this.slug,
    this.tier = StageTier.full,
    super.key,
  });

  final String slug;
  final StageTier tier;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(publishedStoryProvider(slug))) {
        AsyncData(value: WholePublishedStory(:final document)) => Scaffold(
          body: GatedStagePlayer(document: document, tier: tier),
        ),
        AsyncData(value: final ChunkedPublishedStory story) => Scaffold(
          body: ChunkedStoryPlayer(story: story, tier: tier),
        ),
        AsyncData() => const NotFoundPage(message: 'Story not found'),
        AsyncError(:final error) => NotFoundPage(
          message: 'Could not open the story: $error',
        ),
        _ => const Scaffold(body: SizedBox.shrink()),
      };
}

/// A chunked published story (architecture §17.3, m4.md T4.4): the first
/// scene is fetched before the gate shows; every other scene as the
/// reader's lazy window reaches it, with the one after it.
class ChunkedStoryPlayer extends StatefulWidget {
  const ChunkedStoryPlayer({
    required this.story,
    this.tier = StageTier.full,
    super.key,
  });

  final ChunkedPublishedStory story;
  final StageTier tier;

  @override
  State<ChunkedStoryPlayer> createState() => _ChunkedStoryPlayerState();
}

class _ChunkedStoryPlayerState extends State<ChunkedStoryPlayer> {
  bool _ready = false;
  Object? _error;

  ChunkedPublishedStory get _story => widget.story;

  @override
  void initState() {
    super.initState();
    final scenes = _story.chunked.document.scenes;
    unawaited(
      Future.wait([
        for (final s in scenes.take(2)) _story.loadScene(s.id),
      ]).then(
        (_) {
          if (mounted) setState(() => _ready = true);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = e);
        },
      ),
    );
  }

  void _near(String sceneId) {
    final scenes = _story.chunked.document.scenes;
    final i = scenes.indexWhere((s) => s.id == sceneId);
    if (i < 0) return;
    for (final s in scenes.skip(i).take(2)) {
      unawaited(
        _story.loadScene(s.id).then((changed) {
          if (changed && mounted) setState(() {});
        }, onError: (Object _) {}), // the stub stays; the next approach retries
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error case final e?) {
      return NotFoundPage(message: 'Could not open the story: $e');
    }
    if (!_ready) return const SizedBox.shrink();
    return GatedStagePlayer(
      document: _story.chunked.document,
      tier: widget.tier,
      onSceneNear: _near,
    );
  }
}
