import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/app/sound_demo.dart';
import 'package:soundstage_platform/runtime/runtime.dart'
    show StageAssetResolver, StageTier;

import 'gate_panel.dart';
import 'not_found_page.dart';

/// The published story at a target (null: nothing published there, or a
/// local-only build). A gated story throws [GateRequired].
final publishedStoryProvider = FutureProvider.autoDispose
    .family<PublishedStory?, PublishTarget>((ref, target) async {
      final cloud = ref.watch(cloudProvider);
      if (cloud == null) return null;
      return openPublished(
        target,
        backend: cloud.backend,
        fetch: StageAssetResolver().load,
      );
    }, retry: retryUnlessGated);

/// `/@<handle>/s/:slug` or `/@<handle>/<pub>/:issue`: a published story
/// (m4.md T4.2, m7.md T7.2) in the player behind the enter gate. Public
/// and unlisted stories open directly; password and readers-only ones
/// behind the [GatePanel] (m7.md T7.4). `?tier=lite|static` plays the
/// reduced tiers (m4.md T4.6).
class PublishedPage extends ConsumerStatefulWidget {
  const PublishedPage({
    required this.target,
    this.tier = StageTier.full,
    super.key,
  });

  final PublishTarget target;
  final StageTier tier;

  @override
  ConsumerState<PublishedPage> createState() => _PublishedPageState();
}

class _PublishedPageState extends ConsumerState<PublishedPage> {
  /// The gated story, once the reader has a pass.
  Future<PublishedStory?>? _gated;

  void _open(GatePass pass) {
    final cloud = ref.read(cloudProvider);
    if (cloud == null) return;
    setState(() {
      _gated = openPublished(
        widget.target,
        backend: cloud.backend,
        fetch: StageAssetResolver().load,
        pass: pass,
      );
    });
  }

  Widget _story(PublishedStory? story) => switch (story) {
    WholePublishedStory(:final document) => Scaffold(
      body: GatedStagePlayer(document: document, tier: widget.tier),
    ),
    final ChunkedPublishedStory story => Scaffold(
      body: ChunkedStoryPlayer(story: story, tier: widget.tier),
    ),
    null => const NotFoundPage(message: 'Story not found'),
  };

  Widget _failed(Object error) => error is GateRequired
      ? GatePanel(docPath: error.docPath, onPass: _open)
      : NotFoundPage(message: 'Could not open the story: $error');

  @override
  Widget build(BuildContext context) {
    final gated = _gated;
    if (gated != null) {
      return FutureBuilder<PublishedStory?>(
        future: gated,
        builder: (context, snap) => snap.hasError
            ? _failed(snap.error!)
            : snap.connectionState == ConnectionState.done
            ? _story(snap.data)
            : const Scaffold(body: SizedBox.shrink()),
      );
    }
    return switch (ref.watch(publishedStoryProvider(widget.target))) {
      AsyncData(:final value) => _story(value),
      AsyncError(:final error) => _failed(unwrapProviderError(error)),
      _ => const Scaffold(body: SizedBox.shrink()),
    };
  }
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
