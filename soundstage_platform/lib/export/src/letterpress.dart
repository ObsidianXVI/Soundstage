import 'linear_story.dart';

// Letterpress export (architecture §16.1, m4.md T4.5d): a story as an
// `LPModule`, the Flutter-rendered article format of the Letterpress blog
// (`lib/letterpress-engine/store/modules/`), built from the same linear
// text as the other static exports. Headings, paragraphs with marks and
// links, lists, quotes, images with captions, transcripts and the
// backlink map onto LPText / LPTextSpan / LPSingleLevelListSpan /
// LPPullQuote / LPImage.

/// Letterpress' widest image, in logical pixels.
const double kLetterpressImageWidth = 600;

/// A Dart class name for [title] (`My first story!` → `MyFirstStory`).
String letterpressClassName(String title) {
  final words = title
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}');
  final name = words.join();
  if (name.isEmpty) return 'SoundstageStory';
  return RegExp(r'^[0-9]').hasMatch(name) ? 'Story$name' : name;
}

/// [s] as a single-quoted Dart string literal.
String dartString(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', '');
  return "'$escaped'";
}

/// The module source (`part of letterpress.store;`) for [story].
///
/// [assetPathOf] maps a block's file key (`fileKeyOf`) to its Flutter
/// asset path (e.g. `assets/images/soundstage/<slug>/scene-1.png`), or null
/// when it has no file; [sizeOf] gives that file's pixel size when known.
/// Scene links (`#scene-…`) become plain text unless [backlink] is given.
String toLetterpressModule(
  LinearStory story, {
  required String className,
  required String projectName,
  required DateTime date,
  String? Function(String key)? assetPathOf,
  ({int width, int height})? Function(String key)? sizeOf,
  Backlink? backlink,
}) {
  final out = <String>[];
  final listItems = <String>[];
  var listKind = ListKind.none;

  void flushList() {
    if (listItems.isEmpty) return;
    out.add(
      'LPSingleLevelListSpan(\n'
      '  listType: ${listKind == ListKind.ordered ? 'LPListType.numbered' : 'LPListType.bullet'},\n'
      '  listItems: [\n${listItems.map((i) => '${_indent(i, 4)},').join('\n')}\n  ],\n'
      ')',
    );
    listItems.clear();
    listKind = ListKind.none;
  }

  String? hrefOf(InlineRun r) {
    final h = r.href;
    if (h == null) return null;
    if (h.startsWith('#')) {
      return backlink == null ? null : '${backlink.storyUrl}$h';
    }
    return h;
  }

  String text(InlineRun r, {bool italic = false}) {
    final href = hrefOf(r);
    if (href != null) {
      return 'LPText.hyperlink(content: ${dartString(r.text)}, '
          'url: ${dartString(href)})';
    }
    final flags = [
      if (r.bold) 'isBold: true',
      if (r.italic || italic) 'isItalic: true',
      if (r.strike) 'isStrikethrough: true',
    ];
    return 'LPText.plainBody(content: ${dartString(r.text)}'
        '${flags.isEmpty ? '' : ', ${flags.join(', ')}'})';
  }

  String runs(List<InlineRun> rs, {bool italic = false}) {
    final parts = rs.where((r) => r.text.isNotEmpty).toList();
    if (parts.length == 1 && hrefOf(parts.single) == null) {
      return text(parts.single, italic: italic);
    }
    return 'LPTextSpan(\n  lpTextComponents: [\n'
        '${parts.map((r) => '    ${text(r, italic: italic)},').join('\n')}\n'
        '  ],\n)';
  }

  String? image(LinearBlock b, String key) {
    final path = assetPathOf?.call(key);
    if (path == null) return null;
    var w = kLetterpressImageWidth;
    var h = kLetterpressImageWidth * 9 / 16;
    final size = sizeOf?.call(key);
    final (iw, ih) = switch (b) {
      FigureBlock(:final width?, :final height?) => (width, height),
      _ when size != null => (size.width.toDouble(), size.height.toDouble()),
      _ => (0.0, 0.0),
    };
    if (iw > 0 && ih > 0) {
      w = iw < kLetterpressImageWidth ? iw : kLetterpressImageWidth;
      h = w * ih / iw;
    }
    return 'LPImage.asset(assetPath: ${dartString(path)}, '
        'width: ${_num(w)}, height: ${_num(h)})';
  }

  for (final scene in story.scenes) {
    for (final b in scene.blocks) {
      if (b is ParagraphBlock && b.list != ListKind.none) {
        if (listKind != b.list) flushList();
        listKind = b.list;
        listItems.add(runs(b.runs));
        continue;
      }
      flushList();
      switch (b) {
        case HeadingBlock(:final level, :final runs):
          final kind = switch (level) {
            1 => 'header1',
            2 => 'header2',
            _ => 'header3',
          };
          out.add(
            'LPText.$kind(content: ${dartString(runs.map((r) => r.text).join())})',
          );
        case ParagraphBlock(runs: final rs):
          if (rs.any((r) => r.text.trim().isNotEmpty)) out.add(runs(rs));
        case QuoteBlock(:final paragraphs):
          out.add(
            'LPPullQuote(content: ${dartString(paragraphs.map((p) => p.map((r) => r.text).join()).join('\n'))})',
          );
        case FigureBlock(:final caption):
          final img = image(b, fileKeyOf(b)!);
          if (img != null) out.add(img);
          if (caption.isNotEmpty) out.add(runs(caption, italic: true));
        case PosterBlock(:final sceneId):
          final img = image(b, fileKeyOf(b)!);
          if (img != null) out.add(img);
          if (backlink != null) {
            out.add(
              'LPText.hyperlink(content: ${dartString(Backlink.label)}, '
              'url: ${dartString(backlink.sceneUrl(sceneId))})',
            );
          }
        case TranscriptBlock(:final lines):
          out.add('LPPullQuote(content: ${dartString(lines.join('\n'))})');
        case AudioBlock(:final name):
          out.add(
            'LPText.plainBody(content: ${dartString('Audio: $name')}, '
            'isItalic: true)',
          );
      }
    }
  }
  flushList();
  if (backlink != null) {
    out.add(
      'LPText.hyperlink(content: ${dartString(Backlink.label)}, '
      'url: ${dartString(backlink.storyUrl)})',
    );
  }

  final d = 'DateTime(${date.year}, ${date.month}, ${date.day})';
  final components = out.map((c) => '${_indent(c, 12)},').join('\n');
  return '''
part of letterpress.store;

// Exported from Soundstage: "${story.title.replaceAll('\n', ' ')}".
class $className extends LPModule {
  $className({
    required bool renderWithPost,
    bool isPreviewMode = false,
  }) : super(
          title: ${dartString(story.title)},
          coverImgName: 'Infinitude',
          lastUpdate: $d,
          publicationDate: $d,
          tags: [],
          includeTableOfContents: false,
          isPreviewMode: isPreviewMode,
          projectName: ${dartString(projectName)},
          renderWithPost: renderWithPost,
          components: [
$components
          ],
        );
}
''';
}

String _indent(String s, int n) {
  final pad = ' ' * n;
  return s.split('\n').map((l) => '$pad$l').join('\n');
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
