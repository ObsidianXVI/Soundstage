import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/app/sound_demo.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart'
    show StageAssetResolver, StageTier;

import 'not_found_page.dart';

/// The published document at a slug (null: nothing published there, or a
/// local-only build).
final publishedDocumentProvider = FutureProvider.autoDispose
    .family<ir.StageDocument?, String>((ref, slug) async {
      final cloud = ref.watch(cloudProvider);
      if (cloud == null) return null;
      final loaded = await loadPublished(
        slug,
        backend: cloud.backend,
        fetch: StageAssetResolver().load,
      );
      return loaded?.document;
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
      switch (ref.watch(publishedDocumentProvider(slug))) {
        AsyncData(:final value?) => Scaffold(
          body: GatedStagePlayer(document: value, tier: tier),
        ),
        AsyncData() => const NotFoundPage(message: 'Story not found'),
        AsyncError(:final error) => NotFoundPage(
          message: 'Could not open the story: $error',
        ),
        _ => const Scaffold(body: SizedBox.shrink()),
      };
}
