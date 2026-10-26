import 'linear_story.dart';

/// [story] as one standalone, semantic HTML file with light inline CSS
/// (architecture §16.1). [pathOf] and [backlink] as in `toMarkdown`.
String toHtml(LinearStory story, {ExportPathOf? pathOf, Backlink? backlink}) {
  final body = StringBuffer();
  if (story.description.trim().isNotEmpty) {
    body.writeln('<p class="lede">${escapeHtml(story.description.trim())}</p>');
  }
  ListKind? openList;
  void closeList() {
    if (openList == null) return;
    body.writeln(openList == ListKind.ordered ? '</ol>' : '</ul>');
    openList = null;
  }

  for (final scene in story.scenes) {
    closeList();
    body.writeln('<section id="scene-${escapeHtml(scene.id)}">');
    for (final b in scene.blocks) {
      if (b is! ParagraphBlock || b.list == ListKind.none) closeList();
      switch (b) {
        case HeadingBlock(:final level, :final runs):
          final h = (level + 1).clamp(2, 6);
          body.writeln('<h$h>${inlineHtml(runs)}</h$h>');
        case ParagraphBlock(:final runs, list: ListKind.none):
          body.writeln('<p>${inlineHtml(runs)}</p>');
        case ParagraphBlock(:final runs, :final list):
          if (openList != list) {
            closeList();
            body.writeln(list == ListKind.ordered ? '<ol>' : '<ul>');
            openList = list;
          }
          body.writeln('<li>${inlineHtml(runs)}</li>');
        case QuoteBlock(:final paragraphs):
          body
            ..writeln('<blockquote>')
            ..writeAll([
              for (final p in paragraphs) '<p>${inlineHtml(p)}</p>',
            ], '\n')
            ..writeln('\n</blockquote>');
        case FigureBlock(
          :final alt,
          :final caption,
          :final width,
          :final height,
        ):
          final path = pathOf?.call(fileKeyOf(b)!);
          if (path == null && caption.isEmpty) break;
          body.writeln('<figure>');
          if (path != null) {
            final size = width != null && height != null && width > 0
                ? ' width="${width.round()}" height="${height.round()}"'
                : '';
            body.writeln(
              '<img src="${escapeHtml(path)}" alt="${escapeHtml(alt)}"'
              '$size loading="lazy">',
            );
          }
          if (caption.isNotEmpty) {
            body.writeln('<figcaption>${inlineHtml(caption)}</figcaption>');
          }
          body.writeln('</figure>');
        case PosterBlock(:final sceneId, :final alt):
          final path = pathOf?.call(fileKeyOf(b)!);
          if (path == null && backlink == null) break;
          body.writeln('<figure class="poster">');
          if (path != null) {
            final img =
                '<img src="${escapeHtml(path)}" alt="${escapeHtml(alt)}" '
                'loading="lazy">';
            body.writeln(
              backlink == null
                  ? img
                  : '<a href="${escapeHtml(backlink.sceneUrl(sceneId))}">$img</a>',
            );
          }
          if (backlink != null) {
            body.writeln(
              '<figcaption><a href="${escapeHtml(backlink.sceneUrl(sceneId))}">'
              '${Backlink.label}</a></figcaption>',
            );
          }
          body.writeln('</figure>');
        case TranscriptBlock(:final lines):
          body
            ..writeln('<blockquote class="transcript">')
            ..writeln(lines.map(escapeHtml).join('<br>\n'))
            ..writeln('</blockquote>');
        case AudioBlock(:final name):
          final path = pathOf?.call(fileKeyOf(b)!);
          body.writeln(
            path == null
                ? '<p class="audio">${escapeHtml(name)}</p>'
                : '<figure class="audio"><figcaption>${escapeHtml(name)}'
                      '</figcaption><audio controls preload="none" '
                      'src="${escapeHtml(path)}"></audio></figure>',
          );
      }
    }
    closeList();
    body.writeln('</section>');
  }
  if (backlink != null) {
    body.writeln(
      '<footer><a href="${escapeHtml(backlink.storyUrl)}">'
      '${Backlink.label}</a></footer>',
    );
  }
  final title = escapeHtml(story.title);
  final description = story.description.trim().isEmpty
      ? ''
      : '\n<meta name="description" content="${escapeHtml(story.description.trim())}">';
  return '''
<!doctype html>
<html lang="${escapeHtml(story.lang)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>$description
<style>$kExportCss</style>
</head>
<body>
<article>
<h1>$title</h1>
$body</article>
</body>
</html>
''';
}

/// The export's light stylesheet: readable measure, responsive media.
const String kExportCss = '''
body{margin:0;background:#fff;color:#1a1a1f;font:18px/1.6 Georgia,"Times New Roman",serif}
article{max-width:42rem;margin:0 auto;padding:3rem 1.25rem 4rem}
h1,h2,h3,h4,h5,h6{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.2;margin:2.2em 0 .6em}
h1{font-size:2.4rem;margin-top:0}
p,ul,ol,blockquote,figure{margin:0 0 1.2em}
.lede{font-size:1.2rem;color:#4a4a55}
blockquote{border-left:3px solid #c9c9d2;padding-left:1rem;color:#3a3a44;font-style:italic}
figure{margin-left:0;margin-right:0}
img{max-width:100%;height:auto;display:block;border-radius:4px}
figcaption{font-size:.9rem;color:#5a5a66;margin-top:.5em}
audio{width:100%;margin-top:.4em}
a{color:#2853c7}
footer{margin-top:3rem;padding-top:1rem;border-top:1px solid #e2e2e8;font-family:system-ui,sans-serif;font-size:.95rem}
''';

/// Inline HTML for [runs].
String inlineHtml(List<InlineRun> runs) {
  final out = StringBuffer();
  for (final r in runs) {
    var t = escapeHtml(r.text).replaceAll('\n', '<br>');
    if (r.strike) t = '<s>$t</s>';
    if (r.italic) t = '<em>$t</em>';
    if (r.bold) t = '<strong>$t</strong>';
    if (r.href != null) {
      final external = !r.href!.startsWith('#');
      t =
          '<a href="${escapeHtml(r.href!)}"'
          '${external ? ' rel="noopener"' : ''}>$t</a>';
    }
    out.write(t);
  }
  return out.toString();
}

String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
