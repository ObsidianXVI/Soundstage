// Link previews for published work (m4.md T4.3, m7.md T7.2, DECISIONS
// 26/10/26 "Head metadata" and "Handles and URLs"): the app is a
// single-page Flutter build, so crawlers would see one generic <head> for
// every page. This rewrites the shell's head with the page's title,
// description and cover image.

final RegExp _slugPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$');
final RegExp _handlePattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,28}[a-z0-9])$');

/// A page under `/@<handle>` with its Firestore document.
sealed class HeadRoute {
  const HeadRoute(this.handle);

  final String handle;

  /// The Firestore document path (under `documents/`).
  String get docPath;

  /// The page's path on the site.
  String get path;

  /// The route of [path] (a trailing slash is allowed), or null.
  static HeadRoute? parse(String path) {
    var parts = path.split('/');
    if (parts.isNotEmpty && parts.first.isEmpty) parts = parts.sublist(1);
    if (parts.isNotEmpty && parts.last.isEmpty) {
      parts = parts.sublist(0, parts.length - 1);
    }
    if (parts.isEmpty || parts.length > 3 || !parts.first.startsWith('@')) {
      return null;
    }
    final handle = parts.first.substring(1).toLowerCase();
    if (!_handlePattern.hasMatch(handle)) return null;
    final rest = parts.sublist(1);
    if (!rest.every(_slugPattern.hasMatch)) return null;
    return switch (rest) {
      [] => SiteRoute(handle),
      ['s'] => null,
      ['s', final slug] => DraftRoute(handle, slug),
      [final pub] => PublicationRoute(handle, pub),
      [final pub, final slug] => IssueRoute(handle, pub, slug),
      _ => null,
    };
  }

  /// The route of a Firestore document [name]
  /// (`projects/…/documents/sites/<h>/drafts/<slug>` and the like), or
  /// null.
  static HeadRoute? fromDocumentName(String name) {
    final i = name.indexOf('/documents/sites/');
    if (i < 0) return null;
    final parts = name.substring(i + '/documents/sites/'.length).split('/');
    return switch (parts) {
      [final h, 'drafts', final slug] => DraftRoute(h, slug),
      [final h, 'publications', final pub] => PublicationRoute(h, pub),
      [final h, 'publications', final pub, 'issues', final slug] => IssueRoute(
        h,
        pub,
        slug,
      ),
      _ => null,
    };
  }
}

/// `/@<handle>`.
class SiteRoute extends HeadRoute {
  const SiteRoute(super.handle);

  @override
  String get docPath => 'handles/$handle';

  @override
  String get path => '/@$handle';
}

/// `/@<handle>/s/<slug>`.
class DraftRoute extends HeadRoute {
  const DraftRoute(super.handle, this.slug);

  final String slug;

  @override
  String get docPath => 'sites/$handle/drafts/$slug';

  @override
  String get path => '/@$handle/s/$slug';
}

/// `/@<handle>/<pub>`.
class PublicationRoute extends HeadRoute {
  const PublicationRoute(super.handle, this.publication);

  final String publication;

  @override
  String get docPath => 'sites/$handle/publications/$publication';

  @override
  String get path => '/@$handle/$publication';
}

/// `/@<handle>/<pub>/<slug>`.
class IssueRoute extends HeadRoute {
  const IssueRoute(super.handle, this.publication, this.slug);

  final String publication;
  final String slug;

  @override
  String get docPath => 'sites/$handle/publications/$publication/issues/$slug';

  @override
  String get path => '/@$handle/$publication/$slug';
}

String _text(Map<String, Object?> fields, String name) =>
    switch (fields[name]) {
      {'stringValue': final String t} => t.trim(),
      _ => '',
    };

Map<String, Object?> _fields(Map<String, Object?> doc) =>
    (doc['fields'] as Map<String, Object?>?) ?? const {};

/// The audience of a Firestore REST record (`public` when unset).
String audienceOf(Map<String, Object?> doc) {
  final a = _text(_fields(doc), 'audience');
  return a.isEmpty ? 'public' : a;
}

/// Whether [audience] keeps the page private (password or readers).
bool isGatedAudience(String audience) =>
    audience == 'password' || audience == 'readers';

/// The preview of [route] from its Firestore REST document [doc], shown at
/// [url]. Private pages show only whose they are; unlisted ones are not
/// indexed.
StoryHead headFor(HeadRoute route, Map<String, Object?> doc, String url) {
  final audience = route is SiteRoute ? 'public' : audienceOf(doc);
  if (isGatedAudience(audience)) {
    return StoryHead(
      title: '@${route.handle} on Soundstage',
      description: 'A private page.',
      url: url,
      index: false,
    );
  }
  final head = _headFor(route, doc, url);
  return audience == 'unlisted' ? head.notIndexed() : head;
}

StoryHead _headFor(HeadRoute route, Map<String, Object?> doc, String url) =>
    switch (route) {
      SiteRoute(:final handle) => () {
        final name = _text(_fields(doc), 'name');
        return StoryHead(
          title: name.isEmpty ? '@$handle' : '$name (@$handle)',
          description: 'Stories by @$handle on Soundstage.',
          url: url,
        );
      }(),
      PublicationRoute() => publicationHead(doc, url),
      DraftRoute() || IssueRoute() => StoryHead.fromFirestore(doc, url),
    };

/// A publication's preview from its Firestore REST document: its title, how
/// many issues, and the newest issue's cover.
StoryHead publicationHead(Map<String, Object?> doc, String url) {
  final fields = _fields(doc);
  final issues = switch (fields['issues']) {
    {'arrayValue': {'values': final List<Object?> v}} => v,
    _ => const <Object?>[],
  };
  final first = issues.isEmpty
      ? null
      : switch (issues.first) {
          {'mapValue': {'fields': final Map<String, Object?> f}} => f,
          _ => null,
        };
  final n = issues.length;
  return StoryHead(
    title: _text(fields, 'title'),
    description: n == 0
        ? 'A publication on Soundstage.'
        : 'A publication on Soundstage: $n ${n == 1 ? 'issue' : 'issues'}.',
    image: first == null ? '' : _text(first, 'image'),
    url: url,
  );
}

/// What a link preview shows.
class StoryHead {
  const StoryHead({
    required this.title,
    required this.url,
    this.description = '',
    this.image = '',
    this.index = true,
  });

  /// From a Firestore REST document (`published/{slug}`): fields are typed
  /// values, e.g. `{"title": {"stringValue": "…"}}`.
  factory StoryHead.fromFirestore(Map<String, Object?> doc, String url) {
    final fields = (doc['fields'] as Map<String, Object?>?) ?? const {};
    String text(String name) {
      final v = fields[name];
      return v is Map && v['stringValue'] is String
          ? (v['stringValue'] as String).trim()
          : '';
    }

    return StoryHead(
      title: text('title'),
      description: text('description'),
      image: text('image'),
      url: url,
    );
  }

  final String title;
  final String description;
  final String image;
  final String url;

  /// Whether search engines may index the page.
  final bool index;

  StoryHead notIndexed() => StoryHead(
    title: title,
    description: description,
    image: image,
    url: url,
    index: false,
  );
}

const String siteName = 'Soundstage';

String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// [html] (the app shell) with its title and description replaced and the
/// Open Graph and Twitter card tags added before `</head>`.
String injectHead(String html, StoryHead head) {
  final title = head.title.isEmpty ? siteName : head.title;
  final description = head.description.length > 300
      ? '${head.description.substring(0, 297)}…'
      : head.description;
  String meta(String attr, String key, String value) =>
      '  <meta $attr="$key" content="${escapeHtml(value)}">\n';
  final tags = StringBuffer()
    ..write(meta('property', 'og:type', 'article'))
    ..write(meta('property', 'og:site_name', siteName))
    ..write(meta('property', 'og:title', title))
    ..write(meta('property', 'og:url', head.url));
  if (description.isNotEmpty) {
    tags.write(meta('property', 'og:description', description));
  }
  if (head.image.isNotEmpty) {
    tags.write(meta('property', 'og:image', head.image));
  }
  tags
    ..write(
      meta(
        'name',
        'twitter:card',
        head.image.isEmpty ? 'summary' : 'summary_large_image',
      ),
    )
    ..write('  <link rel="canonical" href="${escapeHtml(head.url)}">\n');
  if (!head.index) tags.write(meta('name', 'robots', 'noindex'));

  var out = html.replaceFirst(
    RegExp(r'<title>[\s\S]*?</title>'),
    '<title>${escapeHtml(title)}</title>',
  );
  final descTag = RegExp(r'<meta name="description"[^>]*>');
  final desc = '<meta name="description" content="${escapeHtml(description)}">';
  out = descTag.hasMatch(out)
      ? out.replaceFirst(descTag, desc)
      : out.replaceFirst('</head>', '  $desc\n</head>');
  return out.replaceFirst('</head>', '$tags</head>');
}

/// A published page in the sitemap: its path and when it last changed.
typedef SitemapEntry = ({String path, String? lastModified});

/// Whether [host] is one of the app's own hosts (not an author's custom
/// domain).
bool isAppHost(String host) =>
    host.isEmpty ||
    host == 'localhost' ||
    host == '127.0.0.1' ||
    host.endsWith('.web.app') ||
    host.endsWith('.firebaseapp.com') ||
    host.endsWith('.run.app');

/// [path] on [handle]'s custom domain as the site path it shows
/// (`/s/x` → `/@<handle>/s/x`; `/` → `/@<handle>`); `/@…` paths stay.
String domainPath(String handle, String path) {
  if (path.startsWith('/@')) return path;
  return path == '/' || path.isEmpty ? '/@$handle' : '/@$handle$path';
}

/// [path] (`/@<handle>/…`) as a link on [handle]'s custom domain.
String localPath(String handle, String path) {
  final prefix = '/@$handle';
  if (path == prefix) return '/';
  return path.startsWith('$prefix/') ? path.substring(prefix.length) : path;
}

/// The public entries of a Firestore REST `runQuery` reply (a list of
/// `{"document": {...}}`; `updatedAt` is a timestamp value; unlisted and
/// private pages are left out).
List<SitemapEntry> sitemapEntries(Object? reply) {
  final rows = reply is List ? reply : const <Object?>[];
  return [
    for (final r in rows.whereType<Map<String, Object?>>())
      if (r['document'] case {'name': final String name} && final Map d)
        if (HeadRoute.fromDocumentName(name) case final route?)
          if (audienceOf(d.cast<String, Object?>()) == 'public')
            (
              path: route.path,
              lastModified: switch (d['fields']) {
                {'updatedAt': {'timestampValue': final String t}} => t,
                _ => null,
              },
            ),
  ];
}

/// `sitemap.xml` for [site] (no trailing slash): the home page, every
/// handle with published work, and every published page. On a custom
/// domain ([handle] given) only that handle's pages, at the domain's paths.
String sitemapXml(
  String site,
  Iterable<SitemapEntry> entries, {
  String? handle,
}) {
  final list = [
    for (final e in entries)
      if (handle == null)
        e
      else if (HeadRoute.parse(e.path)?.handle == handle)
        (path: localPath(handle, e.path), lastModified: e.lastModified),
  ];
  final handles = {
    for (final e in list)
      if (HeadRoute.parse(e.path) case final r?) r.handle,
  };
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
    ..writeln('  <url><loc>${escapeHtml('$site/')}</loc></url>');
  if (handle == null) {
    for (final h in handles) {
      out.writeln('  <url><loc>${escapeHtml('$site/@$h')}</loc></url>');
    }
  }
  for (final e in list) {
    out.write('  <url><loc>${escapeHtml('$site${e.path}')}</loc>');
    if (e.lastModified case final t?) {
      out.write('<lastmod>${escapeHtml(t)}</lastmod>');
    }
    out.writeln('</url>');
  }
  out.writeln('</urlset>');
  return out.toString();
}
