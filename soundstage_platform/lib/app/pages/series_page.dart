import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'not_found_page.dart';

/// The series at a slug (null: none, or a local-only build).
final seriesProvider = FutureProvider.autoDispose.family<SeriesRecord?, String>(
  (ref, slug) async {
    final cloud = ref.watch(cloudProvider);
    if (cloud == null) return null;
    return cloud.backend.series(slug);
  },
);

/// `/series/:slug`: a project's published issues, newest first
/// (DECISIONS 26/10/26 #11). Each opens its story at `/s/<slug>`.
class SeriesPage extends ConsumerWidget {
  const SeriesPage({required this.slug, super.key});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    return switch (ref.watch(seriesProvider(slug))) {
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
                  Text('SERIES', style: t.text.overline),
                  const SizedBox(height: SsSpace.s1),
                  Text(
                    value.title.isEmpty ? slug : value.title,
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
                  for (final i in value.issues) _IssueRow(issue: i),
                ],
              ),
            ),
          ),
        ),
      ),
      AsyncData() => const NotFoundPage(message: 'Series not found'),
      AsyncError(:final error) => NotFoundPage(
        message: 'Could not open the series: $error',
      ),
      _ => Scaffold(backgroundColor: t.colors.surface0),
    };
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({required this.issue});

  final SeriesIssue issue;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s3),
      child: SsInteractive(
        semanticLabel: issue.title,
        onTap: () => context.go('/s/${issue.slug}'),
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
              if (issue.image.isNotEmpty)
                SizedBox(
                  width: 160,
                  height: 100,
                  child: Image.network(
                    issue.image,
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
                      Text(issue.title, style: t.text.title),
                      if (issue.description.isNotEmpty) ...[
                        const SizedBox(height: SsSpace.s1),
                        Text(
                          issue.description,
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
