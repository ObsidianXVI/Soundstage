import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'not_found_page.dart';

/// The publication at a ref (null: none, or a local-only build).
final seriesProvider = FutureProvider.autoDispose
    .family<SeriesRecord?, PublicationRef>((ref, at) async {
      final cloud = ref.watch(cloudProvider);
      if (cloud == null) return null;
      return cloud.backend.series(at);
    });

/// `/@<handle>/<pub>`: a project's published issues, newest first
/// (DECISIONS 26/10/26 #11, m7.md T7.2). Each opens at
/// `/@<handle>/<pub>/<issue>`.
class SeriesPage extends ConsumerWidget {
  const SeriesPage({required this.publication, super.key});

  final PublicationRef publication;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    return switch (ref.watch(seriesProvider(publication))) {
      AsyncData(:final value?) => Scaffold(
        backgroundColor: t.colors.surface0,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: SsSpace.s4,
                  vertical: SsSpace.s8,
                ),
                children: [
                  SsInteractive(
                    semanticLabel: '@${publication.handle}',
                    onTap: () => context.go('/@${publication.handle}'),
                    builder: (context, _) =>
                        Text('@${publication.handle}', style: t.text.overline),
                  ),
                  const SizedBox(height: SsSpace.s1),
                  Text(
                    value.title.isEmpty ? publication.slug : value.title,
                    style: t.text.heading.copyWith(fontSize: 32, height: 1.2),
                  ),
                  const SizedBox(height: SsSpace.s6),
                  if (value.issues.isEmpty)
                    Text(
                      'No issues are published yet.',
                      style: t.text.body.copyWith(
                        color: t.colors.textSecondary,
                      ),
                    ),
                  for (final i in value.issues)
                    PublishedEntryRow(
                      title: i.title,
                      description: i.description,
                      image: i.image,
                      route: '${publication.route}/${i.slug}',
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      AsyncData() => const NotFoundPage(message: 'Publication not found'),
      AsyncError(:final error) => NotFoundPage(
        message: 'Could not open the publication: $error',
      ),
      _ => Scaffold(backgroundColor: t.colors.surface0),
    };
  }
}

/// A published story or publication as a card: cover, title, text.
class PublishedEntryRow extends StatelessWidget {
  const PublishedEntryRow({
    required this.title,
    required this.route,
    this.description = '',
    this.image = '',
    super.key,
  });

  final String title;
  final String route;
  final String description;
  final String image;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s3),
      child: SsInteractive(
        semanticLabel: title,
        onTap: () => context.go(route),
        builder: (context, s) => Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: s.contains(WidgetState.hovered) ? c.surface2 : c.surface1,
            borderRadius: SsRadius.brLg,
            border: Border.all(color: c.borderSubtle),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (image.isNotEmpty)
                SizedBox(
                  width: 160,
                  height: 100,
                  child: Image.network(
                    image,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(color: c.surface3),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(SsSpace.s4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: t.text.title),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: SsSpace.s1),
                        Text(
                          description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: t.text.small.copyWith(color: c.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
