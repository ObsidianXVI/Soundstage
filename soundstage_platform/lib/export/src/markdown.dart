import 'linear_story.dart';

/// [story] as CommonMark (architecture §16.1). [pathOf] gives each image's
/// relative path; [backlink], when the story is published, adds "View
/// interactive article on Soundstage" at the end and under each poster.
String toMarkdown(
  LinearStory story, {
  ExportPathOf? pathOf,
  Backlink? backlink,
}) {
  final out = StringBuffer('# ${_escape(story.title)}\n');
  if (story.description.trim().isNotEmpty) {
    out.write('\n${_escape(story.description.trim())}\n');
  }
  ListKind? openList;
  var ordinal = 0;
  void block(String text) {
    openList = null;
    out.write('\n$text\n');
  }

  for (final scene in story.scenes) {
    for (final b in scene.blocks) {
      switch (b) {
        case HeadingBlock(:final level, :final runs):
          // The story title is the only level-1 heading.
          block('${'#' * (level + 1).clamp(2, 6)} ${inlineMarkdown(runs)}');
        case ParagraphBlock(:final runs, list: ListKind.none):
          block(inlineMarkdown(runs));
        case ParagraphBlock(:final runs, :final list):
          if (openList != list) {
            out.write('\n');
            openList = list;
            ordinal = 0;
          }
          ordinal++;
          final marker = list == ListKind.ordered ? '$ordinal.' : '-';
          out.write('$marker ${inlineMarkdown(runs)}\n');
        case QuoteBlock(:final paragraphs):
          block(paragraphs.map((p) => '> ${inlineMarkdown(p)}').join('\n>\n'));
        case FigureBlock(:final alt, :final caption):
          final path = pathOf?.call(fileKeyOf(b)!);
          final lines = <String>[
            if (path != null) '![${_escape(alt)}](${_url(path)})',
            if (caption.isNotEmpty) '*${inlineMarkdown(caption)}*',
          ];
          if (lines.isNotEmpty) block(lines.join('\n\n'));
        case PosterBlock(:final sceneId, :final alt):
          final path = pathOf?.call(fileKeyOf(b)!);
          final lines = <String>[
            if (path != null) '![${_escape(alt)}](${_url(path)})',
            if (backlink != null)
              '[${Backlink.label}](${backlink.sceneUrl(sceneId)})',
          ];
          if (lines.isNotEmpty) block(lines.join('\n\n'));
        case TranscriptBlock(:final lines):
          block(lines.map((l) => '> ${_escape(l)}').join('  \n'));
        case AudioBlock(:final name):
          final path = pathOf?.call(fileKeyOf(b)!);
          block(
            path == null
                ? '🎧 ${_escape(name)}'
                : '🎧 [${_escape(name)}](${_url(path)})',
          );
      }
    }
  }
  if (backlink != null) {
    block('---\n\n[${Backlink.label}](${backlink.storyUrl})');
  }
  return out.toString();
}

/// Inline Markdown for [runs]: `**bold**`, `*italic*`, `~~strike~~`,
/// `[text](href)`.
String inlineMarkdown(List<InlineRun> runs) {
  final out = StringBuffer();
  for (final r in runs) {
    // Marks wrap the trimmed text, so "**word **" never happens.
    final lead = r.text.length - r.text.trimLeft().length;
    final trail = r.text.length - r.text.trimRight().length;
    final core = r.text.trim();
    if (core.isEmpty) {
      out.write(r.text);
      continue;
    }
    var t = _escape(core);
    if (r.strike) t = '~~$t~~';
    if (r.italic) t = '*$t*';
    if (r.bold) t = '**$t**';
    if (r.href != null) t = '[$t](${_url(r.href!)})';
    out
      ..write(r.text.substring(0, lead))
      ..write(t)
      ..write(r.text.substring(r.text.length - trail));
  }
  return out.toString().replaceAll('\n', '  \n');
}

String _escape(String s) =>
    s.replaceAllMapped(RegExp(r'([\\`*_\[\]#<>|])'), (m) => '\\${m[1]}');

String _url(String u) =>
    u.replaceAll(' ', '%20').replaceAll('(', '%28').replaceAll(')', '%29');
