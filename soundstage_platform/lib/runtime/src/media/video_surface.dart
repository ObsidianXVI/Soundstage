import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:video_player/video_player.dart';

import '../animator/behavior_drivers.dart' show kVideoTimeInput;
import '../render/render_stage_host.dart';
import 'asset_resolver.dart';

// The video player behind `VideoNode` (m3.md T3.6). Loaded with a deferred
// import (stage_video.dart), so stories without video never download it.
//
// - Source: `asset://` (bundled), `local://` (an object URL from the editor's
//   store) or http(s).
// - Trim (startTime–endTime), loop within the trim, rate, volume, muted.
// - Autoplay, and with `playWhenVisible` only while on screen.
// - Controls: none, minimal (a play/pause button that shows on hover or
//   tap), full (play/pause, time, a seek bar and mute).
// - [interactive] false (the editor canvas): shows the first frame, never
//   plays.

/// Builds the surface for [node] (the deferred library's entry point).
Widget buildVideoSurface({
  required ir.VideoNode node,
  required ir.Asset? asset,
  required StageAssetResolver resolver,
  required bool interactive,
  required bool reducedMotion,
}) => _VideoSurface(
  node: node,
  asset: asset,
  resolver: resolver,
  interactive: interactive,
  reducedMotion: reducedMotion,
);

class _VideoSurface extends StatefulWidget {
  const _VideoSurface({
    required this.node,
    required this.asset,
    required this.resolver,
    required this.interactive,
    required this.reducedMotion,
  });

  final ir.VideoNode node;
  final ir.Asset? asset;
  final StageAssetResolver resolver;
  final bool interactive;
  final bool reducedMotion;

  @override
  State<_VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<_VideoSurface> {
  VideoPlayerController? _c;
  String? _objectUrlFor;
  bool _visible = true;
  bool _hover = false;
  bool _userPaused = false;
  ScrollPosition? _scroll;
  String? _source;

  ir.VideoNode get _n => widget.node;

  RenderStageHost? _host;
  bool _seeking = false;
  double? _pendingScrub;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _host = context.findAncestorRenderObjectOfType<RenderStageHost>()
        ?..onInput = _onInput;
      final t = _host?.inputs[kVideoTimeInput];
      if (t != null) _onInput(kVideoTimeInput, t);
    });
  }

  /// A scrub clock moved: show the matching frame (one seek at a time; the
  /// latest position wins).
  void _onInput(String input, double value) {
    if (input != kVideoTimeInput || _n.scrubClockId == null) return;
    _pendingScrub = value.clamp(0.0, 1.0);
    unawaited(_drainScrub());
  }

  Future<void> _drainScrub() async {
    final c = _c;
    if (_seeking || c == null || !c.value.isInitialized) return;
    _seeking = true;
    while (_pendingScrub != null && mounted && identical(c, _c)) {
      final f = _pendingScrub!;
      _pendingScrub = null;
      final end = _n.endTime ?? c.value.duration.inMilliseconds / 1000;
      await c.seekTo(_ms(_n.startTime + (end - _n.startTime) * f));
    }
    _seeking = false;
  }

  @override
  void didUpdateWidget(_VideoSurface old) {
    super.didUpdateWidget(old);
    if (old.asset?.uri != widget.asset?.uri) {
      unawaited(_open());
      return;
    }
    _apply();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = Scrollable.maybeOf(context)?.position;
    if (!identical(s, _scroll)) {
      _scroll?.removeListener(_checkVisible);
      _scroll = s?..addListener(_checkVisible);
    }
  }

  @override
  void dispose() {
    if (_host?.onInput == _onInput) _host?.onInput = null;
    _scroll?.removeListener(_checkVisible);
    _close();
    super.dispose();
  }

  void _close() {
    _c?.removeListener(_tick);
    unawaited(_c?.dispose());
    _c = null;
    final id = _objectUrlFor;
    if (id != null) widget.resolver.local?.releaseObjectUrl(id);
    _objectUrlFor = null;
  }

  Future<void> _open() async {
    _close();
    final asset = widget.asset;
    if (asset == null) return;
    final uri = asset.uri;
    _source = uri;
    VideoPlayerController? c;
    final bundled = bundledAssetPath(uri);
    final localId = localAssetId(uri);
    if (bundled != null) {
      c = VideoPlayerController.asset(bundled);
    } else if (localId != null) {
      final url = await widget.resolver.local?.acquireObjectUrl(localId);
      if (url == null || !mounted || _source != uri) return;
      _objectUrlFor = localId;
      c = VideoPlayerController.networkUrl(Uri.parse(url));
    } else if (uri.startsWith('http://') || uri.startsWith('https://')) {
      c = VideoPlayerController.networkUrl(Uri.parse(uri));
    }
    if (c == null) return;
    try {
      await c.initialize();
    } on Object catch (e) {
      debugPrint('soundstage video: could not load "$uri": $e');
      await c.dispose();
      return;
    }
    if (!mounted || _source != uri) {
      await c.dispose();
      return;
    }
    _c = c..addListener(_tick);
    await c.seekTo(_ms(_n.startTime));
    setState(() {});
    _apply();
    _checkVisible();
    final t = _host?.inputs[kVideoTimeInput];
    if (t != null) _onInput(kVideoTimeInput, t);
  }

  Duration _ms(double s) => Duration(milliseconds: (s * 1000).round());

  void _apply() {
    final c = _c;
    if (c == null) return;
    unawaited(c.setVolume(_n.muted ? 0 : _n.volume.clamp(0.0, 1.0)));
    unawaited(c.setPlaybackSpeed(_n.playbackRate <= 0 ? 1 : _n.playbackRate));
    // Looping inside a trim is done by hand (_tick).
    unawaited(c.setLooping(_n.loop && _n.endTime == null && _n.startTime == 0));
    _syncPlaying();
  }

  bool get _shouldPlay =>
      widget.interactive &&
      _n.scrubClockId == null &&
      !_userPaused &&
      (_n.autoplay || _started) &&
      (!_n.playWhenVisible || _visible) &&
      !(widget.reducedMotion && !_started);

  /// Whether the reader started playback (a control, or autoplay ran).
  bool _started = false;

  void _syncPlaying() {
    final c = _c;
    if (c == null) return;
    if (_shouldPlay && !c.value.isPlaying) {
      unawaited(c.play());
    } else if (!_shouldPlay && c.value.isPlaying) {
      unawaited(c.pause());
    }
  }

  void _tick() {
    final c = _c;
    if (c == null || !mounted) return;
    final end = _n.endTime;
    if (end != null && c.value.position >= _ms(end)) {
      if (_n.loop) {
        unawaited(c.seekTo(_ms(_n.startTime)));
      } else {
        unawaited(c.pause());
      }
    }
    setState(() {});
  }

  void _checkVisible() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final r = box.localToGlobal(Offset.zero) & box.size;
    final view = View.of(context);
    final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final visible = r.overlaps(screen);
    if (visible != _visible) {
      _visible = visible;
      _syncPlaying();
    }
  }

  void _toggle() {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      _userPaused = true;
    } else {
      _userPaused = false;
      _started = true;
    }
    _syncPlaying();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    Widget video = ready
        ? _fit(c.value.size, VideoPlayer(c))
        : const SizedBox.expand();
    if (!widget.interactive || _n.controls == ir.VideoControls.none) {
      return video;
    }
    final playing = ready && c.value.isPlaying;
    final showButton = !playing || _hover;
    video = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Stack(
          fit: StackFit.expand,
          children: [
            video,
            if (_n.controls == ir.VideoControls.minimal && showButton)
              Center(child: _RoundButton(playing: playing)),
            if (_n.controls == ir.VideoControls.full && ready)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _FullBar(
                  controller: c,
                  start: _n.startTime,
                  end: _n.endTime,
                  onToggle: _toggle,
                ),
              ),
          ],
        ),
      ),
    );
    return Semantics(
      label: 'Video',
      button: true,
      onTap: _toggle,
      child: video,
    );
  }

  /// The video scaled like an image: fill (and crop, tile) cover the box
  /// around the focal point, fit shows it whole.
  Widget _fit(Size natural, Widget child) {
    final fit = switch (_n.scaleMode) {
      ir.ImageScaleMode.fit => BoxFit.contain,
      _ => BoxFit.cover,
    };
    final f = _n.focalPoint;
    return ClipRect(
      child: FittedBox(
        fit: fit,
        alignment: Alignment(f.x * 2 - 1, f.y * 2 - 1),
        child: SizedBox(
          width: math.max(1, natural.width),
          height: math.max(1, natural.height),
          child: child,
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.playing});

  final bool playing;

  @override
  Widget build(BuildContext context) => Container(
    width: 56,
    height: 56,
    decoration: const BoxDecoration(
      color: Color(0x99000000),
      shape: BoxShape.circle,
    ),
    child: CustomPaint(painter: _GlyphPainter(playing: playing)),
  );
}

/// A play triangle or pause bars, in white.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({required this.playing});

  final bool playing;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFFFFFFFF);
    final c = size.center(Offset.zero);
    final s = size.shortestSide * 0.32;
    if (playing) {
      canvas
        ..drawRect(Rect.fromLTWH(c.dx - s * 0.6, c.dy - s, s * 0.4, s * 2), p)
        ..drawRect(Rect.fromLTWH(c.dx + s * 0.2, c.dy - s, s * 0.4, s * 2), p);
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(c.dx - s * 0.6, c.dy - s)
          ..lineTo(c.dx + s, c.dy)
          ..lineTo(c.dx - s * 0.6, c.dy + s)
          ..close(),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.playing != playing;
}

String _clock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Play/pause, time, a seek bar and mute.
class _FullBar extends StatelessWidget {
  const _FullBar({
    required this.controller,
    required this.start,
    required this.end,
    required this.onToggle,
  });

  final VideoPlayerController controller;
  final double start;
  final double? end;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    final from = Duration(milliseconds: (start * 1000).round());
    final to = end == null
        ? v.duration
        : Duration(milliseconds: (end! * 1000).round());
    final span = (to - from).inMilliseconds;
    final at = (v.position - from).inMilliseconds;
    final t = span <= 0 ? 0.0 : (at / span).clamp(0.0, 1.0);
    const white = Color(0xFFFFFFFF);
    void seekTo(double dx, double width) {
      final f = (dx / width).clamp(0.0, 1.0);
      unawaited(
        controller.seekTo(from + Duration(milliseconds: (span * f).round())),
      );
    }

    return Container(
      height: 40,
      color: const Color(0x99000000),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: onToggle,
            child: SizedBox(
              width: 28,
              height: 28,
              child: CustomPaint(painter: _GlyphPainter(playing: v.isPlaying)),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_clock(v.position - from)} / ${_clock(to - from)}',
            style: const TextStyle(color: white, fontSize: 12),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => seekTo(d.localPosition.dx, box.maxWidth),
                onHorizontalDragUpdate: (d) =>
                    seekTo(d.localPosition.dx, box.maxWidth),
                child: SizedBox(
                  height: 28,
                  child: Align(
                    child: Container(
                      height: 4,
                      color: const Color(0x55FFFFFF),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: t,
                        child: Container(color: white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => unawaited(controller.setVolume(v.volume > 0 ? 0 : 1)),
            child: Text(
              v.volume > 0 ? 'Mute' : 'Sound',
              style: const TextStyle(color: white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
