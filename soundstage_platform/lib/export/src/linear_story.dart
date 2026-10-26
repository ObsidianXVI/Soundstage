// A story as linear text (architecture §16.1, m4.md T4.5a): what the static
// exporters (Markdown, HTML, PDF) render. Pure data; built by `linearize`.

/// An inline run of text with its marks.
class InlineRun {
  const InlineRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.href,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool strike;

  /// A URL, or `#scene-<id>` for a link to another scene.
  final String? href;

  bool sameMarks(InlineRun o) =>
      bold == o.bold &&
      italic == o.italic &&
      strike == o.strike &&
      href == o.href;

  @override
  String toString() => 'InlineRun($text)';
}

enum ListKind { none, ordered, unordered }

sealed class LinearBlock {
  const LinearBlock();
}

/// A heading, level 1–6.
class HeadingBlock extends LinearBlock {
  const HeadingBlock(this.level, this.runs);

  final int level;
  final List<InlineRun> runs;
}

/// A paragraph, or one item of a list.
class ParagraphBlock extends LinearBlock {
  const ParagraphBlock(this.runs, {this.list = ListKind.none});

  final List<InlineRun> runs;
  final ListKind list;
}

/// A block quote of one or more paragraphs.
class QuoteBlock extends LinearBlock {
  const QuoteBlock(this.paragraphs);

  final List<List<InlineRun>> paragraphs;
}

/// A figure: an image asset when the node has one, else a poster of node
/// [nodeId] rendered by the exporter's host.
class FigureBlock extends LinearBlock {
  const FigureBlock({
    required this.nodeId,
    required this.sceneId,
    this.assetId,
    this.alt = '',
    this.caption = const [],
    this.width,
    this.height,
  });

  final String nodeId;
  final String sceneId;
  final String? assetId;
  final String alt;
  final List<InlineRun> caption;
  final double? width;
  final double? height;

  FigureBlock withCaption(List<InlineRun> c) => FigureBlock(
    nodeId: nodeId,
    sceneId: sceneId,
    assetId: assetId,
    alt: alt,
    caption: c,
    width: width,
    height: height,
  );
}

/// A scene shown as one picture: its poster frame at [clock].
class PosterBlock extends LinearBlock {
  const PosterBlock({
    required this.sceneId,
    required this.clock,
    required this.alt,
  });

  final String sceneId;
  final double clock;
  final String alt;
}

/// Lyrics as a transcript.
class TranscriptBlock extends LinearBlock {
  const TranscriptBlock(this.lines);

  final List<String> lines;
}

/// An audio track, as a link to its file.
class AudioBlock extends LinearBlock {
  const AudioBlock({required this.assetId, required this.name});

  final String assetId;
  final String name;
}

class LinearScene {
  const LinearScene({
    required this.id,
    required this.name,
    required this.blocks,
    this.isPoster = false,
  });

  final String id;
  final String name;
  final List<LinearBlock> blocks;

  /// Exported as a poster frame (no translatable text).
  final bool isPoster;
}

class LinearStory {
  const LinearStory({
    required this.title,
    required this.scenes,
    this.description = '',
    this.lang = 'en',
  });

  final String title;
  final String description;
  final String lang;
  final List<LinearScene> scenes;

  Iterable<LinearBlock> get blocks => scenes.expand((s) => s.blocks);
}

/// Where an export points readers for the interactive story.
class Backlink {
  const Backlink(this.storyUrl);

  /// The published story, e.g. `https://soundstage.app/s/<slug>`.
  final String storyUrl;

  static const String label = 'View interactive article on Soundstage';

  /// The URL of scene [sceneId].
  String sceneUrl(String sceneId) => '$storyUrl#scene-$sceneId';
}

/// The file a block needs: an asset id, `node-<id>` for a node poster or
/// `scene-<id>` for a scene poster. Exporters map these keys to paths.
String? fileKeyOf(LinearBlock b) => switch (b) {
  FigureBlock(:final assetId?) => assetId,
  FigureBlock(:final nodeId) => 'node-$nodeId',
  PosterBlock(:final sceneId) => 'scene-$sceneId',
  AudioBlock(:final assetId) => assetId,
  _ => null,
};

/// Maps a [fileKeyOf] key to a relative path (`assets/…`), or null when the
/// file is unavailable (the block then exports as text only).
typedef ExportPathOf = String? Function(String key);
