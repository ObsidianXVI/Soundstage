import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../media/image_sequence_surface.dart';
import '../media/lottie_surface.dart' deferred as lottie;
import '../media/rive_surface.dart' deferred as rive;
import '../render/stage_environment.dart';

Future<void>? _lottieLoaded;
Future<void>? _riveLoaded;

/// An embed node's content (m3.md T3.6): its asset's bytes shown by the
/// Lottie or Rive runtime, each a deferred library fetched only when a story
/// uses it, or an image sequence's frames.
class StageEmbedView extends StatefulWidget {
  const StageEmbedView({
    required this.node,
    required this.environment,
    super.key,
  });

  final ir.EmbedNode node;
  final StageEnvironment environment;

  @override
  State<StageEmbedView> createState() => _StageEmbedViewState();
}

class _StageEmbedViewState extends State<StageEmbedView> {
  Uint8List? _bytes;
  ir.AssetKind? _kind;
  String? _uri;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(StageEmbedView old) {
    super.didUpdateWidget(old);
    if (old.node.assetId != widget.node.assetId) unawaited(_load());
  }

  Future<void> _load() async {
    final media = widget.environment.media;
    final asset = media?.resolver.asset(widget.node.assetId);
    if (media == null || asset == null) return;
    final uri = asset.uri;
    _uri = uri;
    if (asset.kind == ir.AssetKind.imageSequence) {
      setState(() => _kind = asset.kind);
      return;
    }
    try {
      final library = switch (asset.kind) {
        ir.AssetKind.rive => _riveLoaded ??= rive.loadLibrary(),
        _ => _lottieLoaded ??= lottie.loadLibrary(),
      };
      final results = await Future.wait<Object?>([
        library,
        media.resolver.load(uri),
      ]);
      if (!mounted || _uri != uri) return;
      setState(() {
        _bytes = results[1]! as Uint8List;
        _kind = asset.kind;
      });
    } on Object catch (e) {
      debugPrint('soundstage embed: could not load "$uri": $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.environment.media;
    final asset = media?.resolver.asset(widget.node.assetId);
    if (_kind == ir.AssetKind.imageSequence && media != null && asset != null) {
      return StageImageSequence(
        node: widget.node,
        asset: asset,
        resolver: media.resolver,
        interactive: widget.environment.mode == StageRenderMode.play,
      );
    }
    final bytes = _bytes;
    if (bytes == null) return const SizedBox.expand();
    final interactive = widget.environment.mode == StageRenderMode.play;
    return _kind == ir.AssetKind.rive
        ? rive.buildRiveSurface(
            node: widget.node,
            bytes: bytes,
            interactive: interactive,
          )
        : lottie.buildLottieSurface(
            node: widget.node,
            bytes: bytes,
            interactive: interactive,
            reducedMotion:
                MediaQuery.maybeDisableAnimationsOf(context) ?? false,
          );
  }
}
