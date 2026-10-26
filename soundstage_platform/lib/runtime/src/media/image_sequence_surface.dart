import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_host.dart';
import 'asset_resolver.dart';

// An image-sequence embed (m3.md T3.6, DECISIONS 26/10/26): numbered frames
// shown one at a time — the smooth way to scrub "video" with scroll on the
// web. Input "progress" (0–1) picks the frame when it is bound to a clock;
// otherwise the frames play at the asset's rate (frameCount / duration)
// with autoplay and loop. Reduced motion and the editor canvas hold it on
// the first frame (bound progress still applies).
//
// Memory: every frame's compressed bytes are fetched once (nearest the
// playhead first), but only a small window around the playhead is decoded,
// at the size it is drawn.

/// Frames kept decoded around the playhead.
const int kSequenceDecodeWindow = 12;

/// Frames fetched at the same time.
const int _kFetchConcurrency = 4;

class StageImageSequence extends StatefulWidget {
  const StageImageSequence({
    required this.node,
    required this.asset,
    required this.resolver,
    required this.interactive,
    super.key,
  });

  final ir.EmbedNode node;
  final ir.Asset asset;
  final StageAssetResolver resolver;
  final bool interactive;

  @override
  State<StageImageSequence> createState() => _StageImageSequenceState();
}

class _StageImageSequenceState extends State<StageImageSequence>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  RenderStageHost? _host;

  List<Uint8List?> _bytes = const [];
  final Map<int, ui.Image> _decoded = {};
  final Set<int> _decoding = {};
  int _fetchCursor = 0;
  int _inFlight = 0;
  int _generation = 0;
  int? _decodeWidth;

  /// The frame to show.
  int _frame = 0;

  int get _count => math.max(1, widget.asset.frameCount ?? 1);

  bool get _bound => widget.node.inputBindings.containsKey('progress');

  double get _fps {
    final d = widget.asset.duration;
    return d == null || d <= 0 ? ir.kSequenceFrameRate : _count / d;
  }

  @override
  void initState() {
    super.initState();
    _reset(sync: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _host = context.findAncestorRenderObjectOfType<RenderStageHost>()
        ?..onInput = _onInput;
      final p = _host?.inputs['progress'];
      if (p != null) _onInput('progress', p);
    });
  }

  @override
  void didUpdateWidget(StageImageSequence old) {
    super.didUpdateWidget(old);
    if (old.asset.uri != widget.asset.uri ||
        old.asset.frameCount != widget.asset.frameCount) {
      _reset();
    } else {
      _syncPlayback();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPlayback();
  }

  void _reset({bool sync = true}) {
    _generation++;
    _clearDecoded();
    _bytes = List<Uint8List?>.filled(_count, null);
    _fetchCursor = 0;
    _inFlight = 0;
    _frame = _frame.clamp(0, _count - 1);
    _pump();
    if (sync) _syncPlayback();
  }

  void _clearDecoded() {
    for (final image in _decoded.values) {
      image.dispose();
    }
    _decoded.clear();
    _decoding.clear();
  }

  void _onInput(String input, double value) {
    if (input != 'progress') return;
    _show((value.clamp(0.0, 1.0) * (_count - 1)).round());
  }

  void _syncPlayback() {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final play =
        widget.interactive && !_bound && widget.node.autoplay && !reduced;
    if (play && !_ticker.isActive) {
      unawaited(_ticker.start());
    } else if (!play && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final n = (elapsed.inMicroseconds / 1e6 * _fps).floor();
    if (!widget.node.loop && n >= _count - 1) {
      _ticker.stop();
      _show(_count - 1);
      return;
    }
    _show(n % _count);
  }

  void _show(int frame) {
    if (frame == _frame) return;
    _frame = frame;
    _pump();
    // Clock inputs can arrive mid-frame (a host attaching during layout).
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  /// Fetches bytes nearest the playhead first and decodes the window.
  void _pump() {
    final gen = _generation;
    while (_inFlight < _kFetchConcurrency) {
      final next = _nextToFetch();
      if (next == null) break;
      _inFlight++;
      unawaited(_fetch(next, gen));
    }
    _decodeWindow();
  }

  int? _nextToFetch() {
    // The window first, then the rest in order.
    for (var d = 0; d < kSequenceDecodeWindow; d++) {
      final i = (_frame + d) % _count;
      if (_bytes[i] == null && !_fetching.contains(i)) return i;
    }
    while (_fetchCursor < _count) {
      final i = _fetchCursor++;
      if (_bytes[i] == null && !_fetching.contains(i)) return i;
    }
    return null;
  }

  final Set<int> _fetching = {};

  Future<void> _fetch(int i, int gen) async {
    _fetching.add(i);
    try {
      final data = await widget.resolver.load(
        ir.sequenceFrameUri(widget.asset, i),
      );
      if (!mounted || gen != _generation) return;
      _bytes[i] = data;
    } on Object catch (e) {
      debugPrint('soundstage sequence: frame ${i + 1} failed: $e');
    } finally {
      _fetching.remove(i);
      if (mounted && gen == _generation) {
        _inFlight--;
        _pump();
      }
    }
  }

  void _decodeWindow() {
    final width = _decodeWidth;
    if (width == null) return;
    final wanted = {
      for (var d = -2; d < kSequenceDecodeWindow - 2; d++)
        (_frame + d) % _count,
    };
    for (final i in [..._decoded.keys]) {
      if (!wanted.contains(i)) _decoded.remove(i)?.dispose();
    }
    for (final i in wanted) {
      final data = _bytes[i];
      if (data == null || _decoded.containsKey(i) || _decoding.contains(i)) {
        continue;
      }
      unawaited(_decode(i, data, width, _generation));
    }
  }

  Future<void> _decode(int i, Uint8List data, int width, int gen) async {
    _decoding.add(i);
    try {
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: width,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted || gen != _generation || width != _decodeWidth) {
        frame.image.dispose();
        return;
      }
      _decoded[i]?.dispose();
      _decoded[i] = frame.image;
      if (_nearest(_frame) == i || i == _frame) setState(() {});
    } on Object catch (e) {
      debugPrint('soundstage sequence: frame ${i + 1} did not decode: $e');
    } finally {
      _decoding.remove(i);
    }
  }

  /// The decoded frame closest before [frame] (else after it).
  int? _nearest(int frame) {
    if (_decoded.containsKey(frame)) return frame;
    int? best;
    var bestDistance = 1 << 30;
    for (final i in _decoded.keys) {
      final d = frame >= i ? frame - i : (i - frame) + _count;
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _generation++;
    if (_host?.onInput == _onInput) _host?.onInput = null;
    _ticker.dispose();
    _clearDecoded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
      final drawn = constraints.hasBoundedWidth
          ? (constraints.maxWidth * dpr).ceil()
          : null;
      final intrinsic = widget.asset.width;
      final width = math.max(
        1,
        drawn == null
            ? (intrinsic ?? 1024)
            : math.min(drawn, intrinsic ?? drawn),
      );
      // Re-decode only when the drawn size changes by more than a quarter.
      final current = _decodeWidth;
      if (current == null || (width - current).abs() > current / 4) {
        _decodeWidth = width;
        _clearDecoded();
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) _decodeWindow();
        });
      }
      final shown = _nearest(_frame);
      return RawImage(
        image: shown == null ? null : _decoded[shown],
        fit: widget.node.scaleMode == ir.ImageScaleMode.fill
            ? BoxFit.cover
            : BoxFit.contain,
        width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
        height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
      );
    },
  );
}
