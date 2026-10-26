import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'gate_panel.dart';
import 'not_found_page.dart';

/// The publication at a ref (null: none, or a local-only build). A gated
/// one throws [GateRequired].
final seriesProvider = FutureProvider.autoDispose
    .family<SeriesRecord?, PublicationRef>((ref, at) async {
      final cloud = ref.watch(cloudProvider);
      if (cloud == null) return null;
      final record = await cloud.backend.series(at);
      if (record != null && record.audience.gated) {
        throw GateRequired(at.docPath); // the owner, too, opens it as a reader
      }
      return record;
    }, retry: retryUnlessGated);

/// `/@<handle>/<pub>`: a project's published issues, newest first
/// (DECISIONS 26/10/26 #11, m7.md T7.2). Each opens at
/// `/@<handle>/<pub>/<issue>`. Password and readers-only publications
/// open behind the [GatePanel] (m7.md T7.4).
class SeriesPage extends ConsumerStatefulWidget {
  const SeriesPage({required this.publication, super.key});

  final PublicationRef publication;

  @override
  ConsumerState<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends ConsumerState<SeriesPage> {
  /// The gated publication, once the reader has a pass.
  SeriesRecord? _opened;

  PublicationRef get publication => widget.publication;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    if (_opened case final record?) return _page(context, record);
    return switch (ref.watch(seriesProvider(publication))) {
      AsyncData(:final value?) => _page(context, value),
      AsyncData() => const NotFoundPage(message: 'Publication not found'),
      AsyncError(:final error) => switch (unwrapProviderError(error)) {
        GateRequired(:final docPath) => GatePanel(
          docPath: docPath,
          onPass: (pass) =>
              setState(() => _opened = SeriesRecord.fromMap(pass.record)),
        ),
        final e => NotFoundPage(message: 'Could not open the publication: $e'),
      },
      _ => Scaffold(backgroundColor: t.colors.surface0),
    };
  }

  Widget _page(BuildContext context, SeriesRecord value) {
    final t = context.ss;
    return Scaffold(
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
                    style: t.text.body.copyWith(color: t.colors.textSecondary),
                  ),
                for (final i in value.issues)
                  PublishedEntryRow(
                    title: i.title,
                    description: i.description,
                    image: i.image,
                    locked: i.gated,
                    route: '${publication.route}/${i.slug}',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A published story or publication as a card: cover, title, text.
class PublishedEntryRow extends StatelessWidget {
  const PublishedEntryRow({
    required this.title,
    required this.route,
    this.description = '',
    this.image = '',
    this.locked = false,
    super.key,
  });

  final String title;
  final String route;
  final String description;
  final String image;

  /// Shows a lock: readers need a password or an invitation.
  final bool locked;

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
                      Row(
                        children: [
                          if (locked) ...[
                            SsIcon(
                              SsIcons.lock,
                              size: 14,
                              color: c.textSecondary,
                              semanticLabel: 'Private',
                            ),
                            const SizedBox(width: SsSpace.s1),
                          ],
                          Flexible(child: Text(title, style: t.text.title)),
                        ],
                      ),
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
