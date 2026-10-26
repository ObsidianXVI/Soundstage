import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/design_system/gallery/design_system_gallery.dart';
import 'package:soundstage_platform/runtime/runtime.dart' show StageTier;

import 'pages/demo_page.dart';
import 'pages/edit_page.dart';
import 'pages/not_found_page.dart';
import 'pages/play_page.dart';
import 'pages/project_page.dart';
import 'pages/published_page.dart';
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
/// - `/s/:slug` a published story (M4)
///   (both take `?tier=lite|static`, m4.md T4.6)
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
        path: '/s/:slug',
        builder: (context, state) => PublishedPage(
          slug: state.pathParameters['slug']!,
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
    ],
  );
}
