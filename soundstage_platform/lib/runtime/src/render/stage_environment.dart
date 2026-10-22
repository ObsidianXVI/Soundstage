import 'package:flutter/services.dart' show AssetBundle;
import 'package:soundstage_platform/ir/ir.dart' as ir;

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
    this.fonts = const StageFontTable(),
    this.media,
    this.painter = const StageAppearancePainter(),
  });

  /// The environment for [doc]: its fonts and assets, with `asset://` URIs
  /// loaded from [bundle] (default: the app bundle).
  factory StageEnvironment.forDocument(
    ir.StageDocument doc, {
    StageRenderMode mode = StageRenderMode.play,
    AssetBundle? bundle,
    StageImageCache? imageCache,
  }) => StageEnvironment(
    mode: mode,
    fonts: StageFontTable.fromDocument(doc),
    media: StageMedia(
      resolver: StageAssetResolver(assets: doc.assets, customBundle: bundle),
      cache: imageCache,
    ),
  );

  final StageRenderMode mode;
  final StageFontTable fonts;

  /// Null when images are not available (images paint nothing).
  final StageMedia? media;
  final StageAppearancePainter painter;

  StageEnvironment copyWith({StageRenderMode? mode}) => StageEnvironment(
    mode: mode ?? this.mode,
    fonts: fonts,
    media: media,
    painter: painter,
  );
}
