import 'package:soundstage_platform/ir/ir.dart';

import 'linear_story.dart';

/// [doc] as linear text (architecture §16.1, m4.md T4.5a), resolved at the
/// primary breakpoint (else the widest).
///
/// Scenes in story order. A scene exports as text when its `exportAs` is
/// `text`, or `auto` and it has role-bearing text; otherwise as a poster.
/// Inside a frame, children with a `readingOrder` come first (ascending),
/// then the rest: in tree order in auto layout and grids, else top to
/// bottom, then left to right.
LinearStory linearize(StageDocument doc) {
  final bp = _exportBreakpoint(doc);
  final resolved = resolveDocument(doc, ResolveContext(breakpointId: bp?.id));
  final scenes = <LinearScene>[];
  for (final (i, scene) in resolved.scenes.indexed) {
    final source = i < doc.scenes.length ? doc.scenes[i] : null;
    final walker = _Walker(scene.id, {
      for (final t in doc.audioTracks) t.id: t,
    });
    walker.visit(scene.root, root: true);
    final hasText = walker.hasText;
    final asPoster = switch (scene.exportAs) {
      SceneExportMode.text => false,
      SceneExportMode.poster => true,
      SceneExportMode.auto => !hasText,
    };
    final blocks = <LinearBlock>[
      if (asPoster)
        PosterBlock(
          sceneId: scene.id,
          clock: source?.effectivePosterClock ?? kDefaultPosterClock,
          alt: scene.name,
        )
      else
        ...walker.blocks,
      for (final t in doc.audioTracks)
        if (t.scope case SceneAudioScope(
          :final sceneId,
        ) when sceneId == scene.id)
          AudioBlock(assetId: t.assetId, name: _assetName(doc, t.assetId)),
    ];
    scenes.add(
      LinearScene(
        id: scene.id,
        name: scene.name,
        blocks: blocks,
        isPoster: asPoster,
      ),
    );
  }
  // Story-wide audio after the last scene.
  final storyAudio = [
    for (final t in doc.audioTracks)
      if (t.scope is StoryAudioScope)
        AudioBlock(assetId: t.assetId, name: _assetName(doc, t.assetId)),
  ];
  if (storyAudio.isNotEmpty && scenes.isNotEmpty) {
    final last = scenes.removeLast();
    scenes.add(
      LinearScene(
        id: last.id,
        name: last.name,
        blocks: [...last.blocks, ...storyAudio],
        isPoster: last.isPoster,
      ),
    );
  }
  return LinearStory(
    title: doc.meta.title.trim().isEmpty ? 'Untitled story' : doc.meta.title,
    description: doc.meta.description,
    lang: doc.meta.language,
    scenes: scenes,
  );
}

Breakpoint? _exportBreakpoint(StageDocument doc) {
  if (doc.breakpoints.isEmpty) return null;
  for (final b in doc.breakpoints) {
    if (b.primary) return b;
  }
  return doc.breakpoints.reduce(
    (a, b) => a.designSize.width >= b.designSize.width ? a : b,
  );
}

String _assetName(StageDocument doc, String assetId) {
  final a = doc.assets[assetId];
  if (a == null) return 'Audio';
  final n = a.name.trim();
  if (n.isEmpty) return 'Audio';
  final dot = n.lastIndexOf('.');
  return dot > 0 ? n.substring(0, dot) : n;
}

/// The runs of [p], adjacent runs with the same marks merged.
List<InlineRun> runsOf(ResolvedParagraph p) {
  final out = <InlineRun>[];
  for (final s in p.spans) {
    if (s.text.isEmpty) continue;
    final run = InlineRun(
      s.text,
      bold: s.style.fontWeight >= 600,
      italic: s.style.italic,
      strike: s.style.decoration.kind == TextDecorationKind.strikethrough,
      href: switch (s.link) {
        UrlLink(:final url) => url,
        SceneLink(:final sceneId) => '#scene-$sceneId',
        null => null,
      },
    );
    if (out.isNotEmpty && out.last.sameMarks(run)) {
      final prev = out.removeLast();
      out.add(
        InlineRun(
          prev.text + run.text,
          bold: run.bold,
          italic: run.italic,
          strike: run.strike,
          href: run.href,
        ),
      );
    } else {
      out.add(run);
    }
  }
  return out;
}

bool _blank(List<InlineRun> runs) => runs.every((r) => r.text.trim().isEmpty);

class _Walker {
  _Walker(this.sceneId, this.tracks);

  final String sceneId;
  final Map<String, AudioTrack> tracks;
  final List<LinearBlock> blocks = [];
  bool hasText = false;

  void visit(ResolvedNode n, {bool root = false}) {
    final node = n.node;
    final common = node.common;
    if (!common.visible || n.isPlaceholder) return;
    final role = common.role;
    if (role == NodeRole.decorative) return;
    if (!root && role == NodeRole.figure) {
      _figure(n);
      return;
    }
    switch (node) {
      case TextNode():
        _text(n, role);
      case FrameNode(:final LyricsBehavior behavior):
        // The lyrics live on the audio track; the frame's text is only the
        // line template.
        final lines = [
          for (final l
              in tracks[behavior.audioTrackId]?.lyrics?.lines ??
                  const <LyricLine>[])
            if (l.text.trim().isNotEmpty) l.text.trim(),
        ];
        if (lines.isNotEmpty) {
          hasText = true;
          blocks.add(TranscriptBlock(lines));
        }
      case FrameNode():
        for (final c in orderedChildren(n)) {
          visit(c);
        }
      case VideoNode() || EmbedNode() || ShapeNode() || InstanceNode():
        break;
    }
  }

  void _text(ResolvedNode n, NodeRole role) {
    final paragraphs = [
      for (final p in n.paragraphs ?? const <ResolvedParagraph>[])
        (runs: runsOf(p), list: p.listStyle),
    ].where((p) => !_blank(p.runs)).toList();
    if (paragraphs.isEmpty) return;
    switch (role) {
      case NodeRole.heading1 ||
          NodeRole.heading2 ||
          NodeRole.heading3 ||
          NodeRole.heading4 ||
          NodeRole.heading5 ||
          NodeRole.heading6:
        hasText = true;
        final level = role.index - NodeRole.heading1.index + 1;
        // A heading is one line: its paragraphs joined with spaces.
        final runs = <InlineRun>[];
        for (final (i, p) in paragraphs.indexed) {
          if (i > 0) runs.add(const InlineRun(' '));
          runs.addAll(p.runs);
        }
        blocks.add(HeadingBlock(level, runs));
      case NodeRole.quote:
        hasText = true;
        blocks.add(QuoteBlock([for (final p in paragraphs) p.runs]));
      case NodeRole.caption:
        final runs = <InlineRun>[];
        for (final (i, p) in paragraphs.indexed) {
          if (i > 0) runs.add(const InlineRun(' '));
          runs.addAll(p.runs);
        }
        final last = blocks.isEmpty ? null : blocks.last;
        if (last is FigureBlock && last.caption.isEmpty) {
          blocks[blocks.length - 1] = last.withCaption(runs);
        } else {
          hasText = true;
          blocks.add(ParagraphBlock(runs));
        }
      case NodeRole.paragraph || NodeRole.none || NodeRole.figure:
        hasText = role == NodeRole.paragraph || hasText;
        for (final p in paragraphs) {
          blocks.add(
            ParagraphBlock(
              p.runs,
              list: switch (p.list) {
                ListStyle.ordered => ListKind.ordered,
                ListStyle.unordered => ListKind.unordered,
                ListStyle.none => ListKind.none,
              },
            ),
          );
        }
      case NodeRole.decorative:
        break;
    }
  }

  void _figure(ResolvedNode n) {
    final node = n.node;
    final common = node.common;
    final asset = switch (node) {
      FrameNode(:final appearance) ||
      ShapeNode(:final appearance) => _imageOf(appearance.fills),
      VideoNode(:final posterAssetId) => posterAssetId,
      _ => null,
    };
    // A caption inside the figure (e.g. image + caption frame).
    List<InlineRun> caption = const [];
    void findCaption(ResolvedNode c) {
      if (caption.isNotEmpty) return;
      if (c.node is TextNode && c.node.common.role == NodeRole.caption) {
        final ps = c.paragraphs ?? const <ResolvedParagraph>[];
        caption = [for (final p in ps) ...runsOf(p)];
        return;
      }
      for (final k in c.children) {
        findCaption(k);
      }
    }

    for (final c in n.children) {
      findCaption(c);
    }
    // A figure frame without its own image fill but with exactly one image
    // child shows that image.
    final image = asset ?? _singleChildImage(n);
    blocks.add(
      FigureBlock(
        nodeId: n.id,
        sceneId: sceneId,
        assetId: image,
        alt: common.altText ?? '',
        caption: caption,
        width: common.width,
        height: common.height,
      ),
    );
  }
}

String? _imageOf(List<Paint> fills) {
  for (final p in fills.reversed) {
    if (p is ImagePaint && p.visible) return p.assetId;
  }
  return null;
}

String? _singleChildImage(ResolvedNode n) {
  String? found;
  var count = 0;
  void visit(ResolvedNode c) {
    final node = c.node;
    final img = switch (node) {
      FrameNode(:final appearance) ||
      ShapeNode(:final appearance) => _imageOf(appearance.fills),
      _ => null,
    };
    if (img != null) {
      found = img;
      count++;
    }
    for (final k in c.children) {
      visit(k);
    }
  }

  for (final c in n.children) {
    visit(c);
  }
  return count == 1 ? found : null;
}

/// [n]'s children in reading order (see [linearize]).
List<ResolvedNode> orderedChildren(ResolvedNode n) {
  final node = n.node;
  final flow =
      node is FrameNode && (node.autoLayout != null || node.grid != null);
  final indexed = [for (final (i, c) in n.children.indexed) (i, c)];
  int compare((int, ResolvedNode) a, (int, ResolvedNode) b) {
    final ra = a.$2.node.common.readingOrder;
    final rb = b.$2.node.common.readingOrder;
    if (ra != null || rb != null) {
      if (ra == null) return 1;
      if (rb == null) return -1;
      final c = ra.compareTo(rb);
      if (c != 0) return c;
    }
    if (!flow) {
      final ca = a.$2.node.common, cb = b.$2.node.common;
      // Rows: boxes whose tops are within half the shorter height share a
      // row and read left to right.
      final tolerance =
          0.5 * [ca.height, cb.height].reduce((x, y) => x < y ? x : y).abs();
      final dy = ca.y - cb.y;
      if (dy.abs() > tolerance) return dy < 0 ? -1 : 1;
      final dx = ca.x - cb.x;
      if (dx != 0) return dx < 0 ? -1 : 1;
    }
    return a.$1.compareTo(b.$1);
  }

  indexed.sort(compare);
  return [for (final (_, c) in indexed) c];
}
