import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/design_system/gallery/design_system_gallery.dart';
import 'package:soundstage_platform/runtime/runtime.dart' show StageTier;

import 'cloud/targets.dart';
import 'pages/demo_page.dart';
import 'pages/edit_page.dart';
import 'pages/not_found_page.dart';
import 'pages/play_page.dart';
import 'pages/project_page.dart';
import 'pages/published_page.dart';
import 'pages/series_page.dart';
import 'pages/site_page.dart';
import 'pages/story_list_page.dart';

bool? _flag(Uri uri, String key, String value) =>
    uri.queryParameters.containsKey(key)
    ? uri.queryParameters[key] == value
    : null;

/// Maps the pre-router `/?demo=<name>` URLs to `/demo/<name>`, keeping the
/// other query flags (`wheel`, `stats`). Returns null for any other URL.
String? redirectLegacyDemo(Uri uri) {
  if (uri.path != '/' && uri.path.isNotEmpty) return null;
  final demo = uri.queryParameters['demo'];
  if (demo == null) return null;
  final rest = Map<String, String>.of(uri.queryParameters)..remove('demo');
  return Uri(
    path: '/demo/${Uri.encodeComponent(demo)}',
    queryParameters: rest.isEmpty ? null : rest,
  ).toString();
}

/// The app's routes (path URLs):
///
/// - `/` story list
/// - `/project/:id` a project's issues
/// - `/edit/:id` editor (content mode below 1024 px)
/// - `/play/:id` the player behind the enter gate
/// - `/@<handle>` an author's published work (m7.md T7.2)
/// - `/@<handle>/s/:slug` a published one-off story
/// - `/@<handle>/:pub` a project's publication, `/@<handle>/:pub/:issue`
///   one of its issues (stories take `?tier=lite|static`, m4.md T4.6)
/// - `/demo/:name` the M0 demos; `/demo/design-system` the component gallery
GoRouter buildRouter({String initialLocation = '/'}) {
  return GoRouter(
    initialLocation: initialLocation,
    redirect: (context, state) => redirectLegacyDemo(state.uri),
    errorBuilder: (context, state) => const NotFoundPage(),
    routes: <RouteBase>[
      GoRoute(path: '/', builder: (context, state) => const StoryListPage()),
      GoRoute(
        path: '/edit/:id',
        builder: (context, state) =>
            EditPage(storyId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/project/:id',
        builder: (context, state) =>
            ProjectPage(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/play/:id',
        builder: (context, state) => PlayPage(
          storyId: state.pathParameters['id']!,
          wheelNative: _flag(state.uri, 'wheel', 'native'),
          statsOn: _flag(state.uri, 'stats', '1'),
          tier: StageTier.parse(state.uri.queryParameters['tier']),
        ),
      ),
      GoRoute(
        path: '/demo/design-system',
        builder: (context, state) => const DesignSystemGallery(),
      ),
      GoRoute(
        path: '/demo/:name',
        builder: (context, state) => DemoPage(
          name: state.pathParameters['name']!,
          wheelNative: _flag(state.uri, 'wheel', 'native'),
          statsOn: _flag(state.uri, 'stats', '1'),
        ),
      ),
      // Last: any other one-segment path; only `@<handle>` is a page.
      GoRoute(
        path: '/:who',
        builder: (context, state) => switch (_handle(state)) {
          final h? => SitePage(handle: h),
          null => const NotFoundPage(),
        },
        routes: [
          GoRoute(
            path: 's/:slug',
            builder: (context, state) => switch (_handle(state)) {
              final h? => PublishedPage(
                target: DraftTarget(h, state.pathParameters['slug']!),
                tier: StageTier.parse(state.uri.queryParameters['tier']),
              ),
              null => const NotFoundPage(),
            },
          ),
          GoRoute(
            path: ':pub',
            builder: (context, state) =>
                switch ((_handle(state), state.pathParameters['pub']!)) {
                  (final h?, final p) when isValidPublication(p) => SeriesPage(
                    publication: PublicationRef(h, p),
                  ),
                  _ => const NotFoundPage(),
                },
            routes: [
              GoRoute(
                path: ':issue',
                builder: (context, state) => switch ((
                  _handle(state),
                  state.pathParameters['pub']!,
                )) {
                  (final h?, final p) when isValidPublication(p) =>
                    PublishedPage(
                      target: IssueTarget(
                        PublicationRef(h, p),
                        state.pathParameters['issue']!,
                      ),
                      tier: StageTier.parse(state.uri.queryParameters['tier']),
                    ),
                  _ => const NotFoundPage(),
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// The handle of a `/@<handle>/…` path, or null for any other first
/// segment.
String? _handle(GoRouterState state) {
  final who = state.pathParameters['who']!;
  if (!who.startsWith('@')) return null;
  final h = who.substring(1).toLowerCase();
  return isValidHandle(h) ? h : null;
}

/// The router on an author's custom domain (m7.md T7.5): their published
/// work at clean paths, nothing else.
///
/// - `/` the handle's page
/// - `/s/:slug` a one-off story
/// - `/:pub` a publication, `/:pub/:issue` one of its issues
GoRouter buildDomainRouter(String handle, {String initialLocation = '/'}) {
  StageTier tier(GoRouterState state) =>
      StageTier.parse(state.uri.queryParameters['tier']);
  return GoRouter(
    initialLocation: initialLocation,
    errorBuilder: (context, state) => const NotFoundPage(),
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => SitePage(handle: handle),
      ),
      GoRoute(
        path: '/s/:slug',
        builder: (context, state) => PublishedPage(
          target: DraftTarget(handle, state.pathParameters['slug']!),
          tier: tier(state),
        ),
      ),
      GoRoute(
        path: '/:pub',
        builder: (context, state) => switch (state.pathParameters['pub']!) {
          final p when isValidPublication(p) => SeriesPage(
            publication: PublicationRef(handle, p),
          ),
          _ => const NotFoundPage(),
        },
        routes: [
          GoRoute(
            path: ':issue',
            builder: (context, state) => switch (state.pathParameters['pub']!) {
              final p when isValidPublication(p) => PublishedPage(
                target: IssueTarget(
                  PublicationRef(handle, p),
                  state.pathParameters['issue']!,
                ),
                tier: tier(state),
              ),
              _ => const NotFoundPage(),
            },
          ),
        ],
      ),
    ],
  );
}
