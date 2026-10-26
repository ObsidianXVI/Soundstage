import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:lottie/lottie.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_host.dart';

// A Lottie embed (m3.md T3.6), loaded with a deferred import. JSON and
// dotLottie bytes. Its time plays (autoplay, loop) unless input "progress"
// is bound to a clock, which then sets it (0–1). Reduced motion and the
// editor canvas hold it still (bound progress still applies).

Widget buildLottieSurface({
  required ir.EmbedNode node,
  required Uint8List bytes,
  required bool interactive,
  required bool reducedMotion,
}) => _LottieSurface(
  node: node,
  bytes: bytes,
  interactive: interactive,
  reducedMotion: reducedMotion,
);

BoxFit embedFit(ir.ImageScaleMode m) => switch (m) {
  ir.ImageScaleMode.fill => BoxFit.cover,
  _ => BoxFit.contain,
};

class _LottieSurface extends StatefulWidget {
  const _LottieSurface({
    required this.node,
    required this.bytes,
    required this.interactive,
    required this.reducedMotion,
  });

  final ir.EmbedNode node;
  final Uint8List bytes;
  final bool interactive;
  final bool reducedMotion;

  @override
  State<_LottieSurface> createState() => _LottieSurfaceState();
}

class _LottieSurfaceState extends State<_LottieSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this);
  LottieComposition? _composition;
  RenderStageHost? _host;

  bool get _bound => widget.node.inputBindings.containsKey('progress');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _host = context.findAncestorRenderObjectOfType<RenderStageHost>()
        ?..onInput = _onInput;
      final p = _host?.inputs['progress'];
      if (p != null) _onInput('progress', p);
    });
  }

  Future<void> _load() async {
    try {
      final c = await LottieComposition.fromBytes(widget.bytes);
      if (!mounted) return;
      _anim.duration = c.duration;
      setState(() => _composition = c);
      _sync();
    } on Object catch (e) {
      debugPrint('soundstage lottie: could not decode: $e');
    }
  }

  void _onInput(String input, double value) {
    if (input == 'progress') _anim.value = value.clamp(0.0, 1.0);
  }

  void _sync() {
    if (_composition == null) return;
    final play =
        widget.interactive &&
        !_bound &&
        widget.node.autoplay &&
        !widget.reducedMotion;
    if (!play) {
      _anim.stop();
      return;
    }
    if (widget.node.loop) {
      unawaited(_anim.repeat());
    } else {
      unawaited(_anim.forward());
    }
  }

  @override
  void didUpdateWidget(_LottieSurface old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      unawaited(_load());
    } else {
      _sync();
    }
  }

  @override
  void dispose() {
    if (_host?.onInput == _onInput) _host?.onInput = null;
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _composition;
    if (c == null) return const SizedBox.expand();
    return Lottie(
      composition: c,
      controller: _anim,
      fit: embedFit(widget.node.scaleMode),
    );
  }
}
