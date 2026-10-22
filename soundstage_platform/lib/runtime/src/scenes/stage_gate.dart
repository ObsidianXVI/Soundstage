import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../media/audio.dart';
import '../render/stage_environment.dart';
import '../render/text/text_style_mapping.dart';
import 'stage_player.dart';

/// Where the gate puts its cover image: the rectangle the [image] is drawn
/// into over [viewport], and where its [focal] point (a fraction of the
/// image) lands.
typedef GateCoverPlacement = ({Rect dest, Offset focalAt});

/// The fraction of the viewport's height, from the top, reserved for the
/// cover's focal subject (the moon): the text block lives below it.
const double kGateFocalArea = 0.42;

/// Draws [image] to cover [viewport] with its [focal] point (the moon) in
/// the upper focal area, centred horizontally on narrow viewports and a
/// little right of centre on wide ones. The image is zoomed (up to 1.6×
/// the plain cover scale) when the plain crop has no room to move the
/// subject up, so the subject never sits behind the text.
GateCoverPlacement gateCoverPlacement(Size image, Size viewport, Offset focal) {
  final cover = math.max(
    viewport.width / image.width,
    viewport.height / image.height,
  );
  final ty = viewport.height * kGateFocalArea / 2;
  final tx = viewport.width * (viewport.width < 700 ? 0.5 : 0.6);
  // The lowest the focal point can sit at scale s is
  // vh - (1 - fy) * ih * s; ask for enough scale to reach ty.
  final needed = (viewport.height - ty) / ((1 - focal.dy) * image.height);
  final scale = math.min(math.max(cover, needed), cover * 1.6);
  final w = image.width * scale, h = image.height * scale;
  final ox = (tx - focal.dx * w).clamp(viewport.width - w, 0.0);
  final oy = (ty - focal.dy * h).clamp(viewport.height - h, 0.0);
  return (
    dest: Rect.fromLTWH(ox, oy, w, h),
    focalAt: Offset(ox + focal.dx * w, oy + focal.dy * h),
  );
}

/// The default label of the enter control.
const String kStageEnterLabel = 'Enter the stage';

/// The "enter the stage" gate (architecture §10.4, §12): a full-viewport
/// overlay over [child] (the player), styled from the document (its title
/// and cover image, in the document's default font).
///
/// - It starts loading the first scene's fonts, images and the audio at
///   once.
/// - Activating it (tap/click, Enter or Space; it takes focus, and screen
///   readers see a button labelled "[label]: <title>") unlocks audio inside
///   the gesture, waits for that preload, then fades out over
///   [fadeDuration] and removes itself.
/// - While it waits after activation it shows "Loading…".
class StageEnterGate extends StatefulWidget {
  const StageEnterGate({
    super.key,
    required this.document,
    required this.environment,
    required this.child,
    this.audio,
    this.label = kStageEnterLabel,
    this.fadeDuration = const Duration(milliseconds: 600),
    this.onEntered,
    this.coverFocal = const Offset(0.5, 0.5),
    this.buildChildOnEnter = false,
    this.onReady,
    this.onEnter,
  });

  /// Called once the first scene's fonts, images and audio are loaded (the
  /// gate can be activated and will not wait).
  final VoidCallback? onReady;

  /// Called when the gate starts fading out and the player is revealed.
  final VoidCallback? onEnter;

  /// Mount [child] only when the gate starts fading out, so entry
  /// animations (a timeline that plays on scene enter) play in view rather
  /// than behind the gate. The first scene's fonts and images are already
  /// loaded by then.
  final bool buildChildOnEnter;

  /// The cover's subject (the moon, a face) as a fraction of the image.
  /// The cover is cropped so it sits above the text block ([kGateFocalArea]
  /// of the height), never behind the title.
  final Offset coverFocal;

  final ir.StageDocument document;

  /// The player's environment (fonts and media are loaded through it).
  final StageEnvironment environment;
  final StageAudioService? audio;
  final Widget child;
  final String label;
  final Duration fadeDuration;

  /// Called once the gate has faded out.
  final VoidCallback? onEntered;

  /// Fonts, images and audio of [doc]'s first scene, loaded through [env]
  /// and [audio]. Completes when all are ready (failures count as ready).
  static Future<void> preloadFirstScene(
    ir.StageDocument doc,
    StageEnvironment env, {
    StageAudioService? audio,
  }) async {
    final waits = <Future<void>>[];
    if (doc.scenes.isNotEmpty) {
      final resolved = ir.resolveDocument(doc, const ir.ResolveContext());
      final first = resolved.scenes.first;
      waits.add(env.fonts.ensureLoaded(sceneFontFamilyIds(first)));
      final media = env.media;
      if (media != null) {
        for (final id in sceneAssetIds(first)) {
          waits.add(media.ready(id));
        }
      }
    }
    final defaultFamily = doc.defaultTextStyle.fontFamilyId;
    if (defaultFamily != null) {
      waits.add(env.fonts.ensureLoaded([defaultFamily]));
    }
    final cover = doc.meta.coverAssetId;
    if (cover != null && env.media != null) {
      waits.add(env.media!.ready(cover));
    }
    if (audio != null) waits.add(audio.preload());
    await Future.wait(waits);
  }

  @override
  State<StageEnterGate> createState() => _StageEnterGateState();
}

enum _Phase { waiting, entering, fading, done }

class _StageEnterGateState extends State<StageEnterGate> {
  late Future<void> _preload;
  _Phase _phase = _Phase.waiting;
  final FocusNode _focus = FocusNode(debugLabel: 'StageEnterGate');

  @override
  void initState() {
    super.initState();
    _preload = StageEnterGate.preloadFirstScene(
      widget.document,
      widget.environment,
      audio: widget.audio,
    );
    _preload.whenComplete(() => widget.onReady?.call());
    widget.environment.fonts.addListener(_fontLoaded);
  }

  /// Restyles the gate's own text once the document font arrives.
  void _fontLoaded(String familyId) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.environment.fonts.removeListener(_fontLoaded);
    _focus.dispose();
    super.dispose();
  }

  void _enter() {
    if (_phase != _Phase.waiting) return;
    // Inside the gesture: browsers allow audio from here on.
    unawaited(widget.audio?.unlock());
    setState(() => _phase = _Phase.entering);
    _preload.whenComplete(() {
      if (!mounted) return;
      setState(() => _phase = _Phase.fading);
      widget.onEnter?.call();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      _enter();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!widget.buildChildOnEnter ||
            _phase == _Phase.fading ||
            _phase == _Phase.done)
          widget.child,
        if (_phase != _Phase.done)
          AnimatedOpacity(
            opacity: _phase == _Phase.fading ? 0 : 1,
            duration: widget.fadeDuration,
            curve: const Cubic(0.4, 0, 0.2, 1),
            onEnd: () {
              if (_phase != _Phase.fading) return;
              setState(() => _phase = _Phase.done);
              widget.onEntered?.call();
            },
            child: IgnorePointer(
              ignoring: _phase == _Phase.fading,
              child: _face(context),
            ),
          ),
      ],
    );
  }

  Widget _face(BuildContext context) {
    final doc = widget.document;
    final env = widget.environment;
    final title = doc.meta.title.isEmpty ? 'Soundstage' : doc.meta.title;
    final base = stageTextStyle(doc.defaultTextStyle, env.fonts);
    final screen = MediaQuery.maybeSizeOf(context) ?? const Size(800, 600);
    final width = screen.width, height = screen.height;
    final titleSize = math.min((width * 0.07).clamp(32.0, 96.0), height * 0.11);
    const ink = Color(0xFFF7F1E8);
    final loading = _phase != _Phase.waiting;
    return Semantics(
      container: true,
      button: true,
      enabled: !loading,
      label: '${widget.label}: $title',
      onTap: _enter,
      excludeSemantics: true,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enter,
          child: MouseRegion(
            cursor: loading
                ? SystemMouseCursors.progress
                : SystemMouseCursors.click,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xFF0B0A10)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (doc.meta.coverAssetId != null)
                    _Cover(
                      assetId: doc.meta.coverAssetId!,
                      environment: env,
                      focal: widget.coverFocal,
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x330B0A10), Color(0xE60B0A10)],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        0,
                        24,
                        math.min(48, height * 0.08),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: base.copyWith(
                              fontSize: titleSize,
                              height: 1.05,
                              color: ink,
                              letterSpacing: -0.01 * titleSize,
                            ),
                          ),
                          if (doc.meta.description.isNotEmpty &&
                              height >= 520) ...[
                            const SizedBox(height: 16),
                            Text(
                              doc.meta.description,
                              textAlign: TextAlign.center,
                              style: base.copyWith(
                                fontSize: 17,
                                height: 1.4,
                                color: ink.withValues(alpha: 0.75),
                              ),
                            ),
                          ],
                          SizedBox(height: height >= 520 ? 40 : 20),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: ink.withValues(alpha: 0.8),
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 28,
                                vertical: 14,
                              ),
                              child: Text(
                                loading ? 'Loading…' : widget.label,
                                style: base.copyWith(
                                  fontSize: 15,
                                  color: ink,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Sound on · Enter or tap',
                            style: base.copyWith(
                              fontSize: 12,
                              color: ink.withValues(alpha: 0.55),
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The document cover, cropped to fill.
class _Cover extends StatefulWidget {
  const _Cover({
    required this.assetId,
    required this.environment,
    required this.focal,
  });

  final String assetId;
  final StageEnvironment environment;
  final Offset focal;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _obtain();
  }

  void _obtain() {
    _image = widget.environment.media?.image(
      widget.assetId,
      onReady: () {
        if (mounted) setState(_obtain);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        final p = gateCoverPlacement(
          Size(image.width.toDouble(), image.height.toDouble()),
          c.biggest,
          widget.focal,
        );
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fromRect(
              rect: p.dest,
              child: RawImage(
                image: image,
                fit: BoxFit.fill,
                opacity: const AlwaysStoppedAnimation(0.55),
              ),
            ),
          ],
        );
      },
    );
  }
}
