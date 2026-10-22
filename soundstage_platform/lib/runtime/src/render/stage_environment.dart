import 'package:flutter/services.dart' show AssetBundle;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../animator/node_registry.dart';
import '../media/asset_resolver.dart';
import '../media/fonts.dart';
import '../media/image_cache.dart';
import '../paint/appearance_painter.dart';

/// How the runtime renders: for readers (`play`) or inside the editor
/// (`edit`). In edit mode, nodes that fail to lay out or paint, and
/// placeholders for things that failed to resolve, show an error box; in
/// play mode they render nothing (architecture §17.2).
enum StageRenderMode { play, edit }

/// Everything render objects need besides their node: the render mode, the
/// font table, media access and the appearance painter. One per document.
class StageEnvironment {
  const StageEnvironment({
    this.mode = StageRenderMode.play,
    this._fonts,
    this.media,
    this.painter = const StageAppearancePainter(),
    this.nodes,
    this.audioTracks = const {},
  });

  /// The environment for [doc]: its fonts and assets, with `asset://` URIs
  /// loaded from [bundle] (default: the app bundle).
  factory StageEnvironment.forDocument(
    ir.StageDocument doc, {
    StageRenderMode mode = StageRenderMode.play,
    AssetBundle? bundle,
    StageImageCache? imageCache,
    StageFontRegistrar? registerFont,
  }) {
    final resolver = StageAssetResolver(
      assets: doc.assets,
      customBundle: bundle,
    );
    return StageEnvironment(
      mode: mode,
      fonts: StageFontTable.fromDocument(
        doc,
        resolver: resolver,
        register: registerFont,
      ),
      media: StageMedia(resolver: resolver, cache: imageCache),
      audioTracks: {for (final t in doc.audioTracks) t.id: t},
    );
  }

  final StageRenderMode mode;
  final StageFontTable? _fonts;

  /// The document's fonts ([StageFontTable.none] when not given).
  StageFontTable get fonts => _fonts ?? StageFontTable.none;

  /// The document's audio tracks by id (lyrics behaviours read their
  /// `LyricsDoc` here).
  final Map<String, ir.AudioTrack> audioTracks;

  /// Null when images are not available (images paint nothing).
  final StageMedia? media;
  final StageAppearancePainter painter;

  /// The player's `nodeId → render object` registry (T0.6); null outside a
  /// `StagePlayer`. Render objects register on attach.
  final StageNodeRegistry? nodes;

  StageEnvironment copyWith({
    StageRenderMode? mode,
    StageNodeRegistry? nodes,
  }) => StageEnvironment(
    mode: mode ?? this.mode,
    fonts: _fonts,
    media: media,
    painter: painter,
    nodes: nodes ?? this.nodes,
    audioTracks: audioTracks,
  );
}
