// Link previews for published stories (m4.md T4.3, DECISIONS 26/10/26
// "Head metadata"): the app is a single-page Flutter build, so crawlers
// would see one generic <head> for every /s/<slug>. This rewrites the
// shell's head with the story's title, description and cover image.

final RegExp _slugPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$');

/// The slug of a `/s/<slug>` path (a trailing slash is allowed), or null.
String? slugFromPath(String path) {
  final m = RegExp(r'^/s/([^/]+)/?$').firstMatch(path);
  final slug = m?.group(1);
  return slug != null && _slugPattern.hasMatch(slug) ? slug : null;
}

/// What a link preview shows.
class StoryHead {
  const StoryHead({
    required this.title,
    required this.url,
    this.description = '',
    this.image = '',
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
