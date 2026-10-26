import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'not_found_page.dart';
import 'series_page.dart' show PublishedEntryRow;

/// What a handle has published (null: unknown handle, or a local-only
/// build).
final siteProvider = FutureProvider.autoDispose.family<SiteListing?, String>((
  ref,
  handle,
) async {
  final cloud = ref.watch(cloudProvider);
  if (cloud == null) return null;
  return cloud.backend.site(handle);
});

/// `/@<handle>`: an author's publications and one-off stories (m7.md
/// T7.2).
class SitePage extends ConsumerWidget {
  const SitePage({required this.handle, super.key});

  final String handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    return switch (ref.watch(siteProvider(handle))) {
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
                  Text('@$handle', style: t.text.overline),
                  if (value.name.isNotEmpty) ...[
                    const SizedBox(height: SsSpace.s1),
                    Text(
                      value.name,
                      style: t.text.heading.copyWith(fontSize: 32, height: 1.2),
                    ),
                  ],
                  const SizedBox(height: SsSpace.s6),
                  if (value.publications.isEmpty && value.drafts.isEmpty)
                    Text(
                      'Nothing is published yet.',
                      style: t.text.body.copyWith(
                        color: t.colors.textSecondary,
                      ),
                    ),
                  if (value.publications.isNotEmpty) ...[
                    Text('PUBLICATIONS', style: t.text.overline),
                    const SizedBox(height: SsSpace.s2),
                    for (final p in value.publications)
                      PublishedEntryRow(
                        title: p.title,
                        description: p.issueCount == 1
                            ? '1 issue'
                            : '${p.issueCount} issues',
                        image: p.image,
                        route: p.route,
                      ),
                    const SizedBox(height: SsSpace.s4),
                  ],
                  if (value.drafts.isNotEmpty) ...[
                    Text('STORIES', style: t.text.overline),
                    const SizedBox(height: SsSpace.s2),
                    for (final d in value.drafts)
                      PublishedEntryRow(
                        title: d.title,
                        description: d.description,
                        image: d.image,
                        route: d.route,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      AsyncData() => const NotFoundPage(message: 'No one here by that name'),
      AsyncError(:final error) => NotFoundPage(
        message: 'Could not open the page: $error',
      ),
      _ => Scaffold(backgroundColor: t.colors.surface0),
    };
  }
}
