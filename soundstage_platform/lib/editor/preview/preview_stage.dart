import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../canvas/canvas_controller.dart' show artboardBreakpoints;
import '../core/editor_controller.dart';
import 'preview_state.dart';

/// How long after the last committed edit the preview rebuilds.
const Duration kPreviewDebounce = Duration(milliseconds: 150);

/// The design size the preview renders at for [state] in [doc]: a primary
/// breakpoint's, or the free width with the height of the breakpoint that
/// width falls in.
Size previewViewportFor(ir.StageDocument doc, PreviewState state) {
  final boards = artboardBreakpoints(doc);
  if (state.free) {
    final w = state.freeWidth;
    final bp = ir.breakpointForWidth(doc, w);
    return Size(w, bp?.designSize.height ?? 900);
  }
  final bp =
      boards.where((b) => b.id == state.breakpointId).firstOrNull ??
      boards.firstOrNull;
  if (bp == null) return const Size(1440, 900);
  return Size(bp.designSize.width, bp.designSize.height);
}

/// The live player of the preview pane (T2.6): the real `StagePlayer`
/// behind the enter gate (shown once per preview session), at the chosen
/// width, scaled down to fit.
///
/// The player is rebuilt from the editor's document [kPreviewDebounce]
/// after a committed edit; while a gesture is open (a drag, a scrub) it
/// keeps showing the last committed document. The fonts, the decoded images
/// and the audio are long-lived: a rebuild reuses them unless the
/// document's fonts, assets or audio tracks changed. The scroll position is
/// kept across rebuilds (a scene and a progress, so changed scene lengths
/// do not move the reader).
///
/// The player is read-only; nothing here writes to the editor.
class PreviewStage extends ConsumerStatefulWidget {
  const PreviewStage({this.controller, super.key});

  /// Lets the pane header restart the preview and the tests reach the
  /// player.
  final PreviewStageController? controller;

  @override
  ConsumerState<PreviewStage> createState() => _PreviewStageState();
}

/// The pane header's handle on the stage.
class PreviewStageController {
  _PreviewStageState? _state;

  /// Starts over: scroll at the top, clocks at zero, audio from the start.
  /// The enter gate is not shown again.
  void restart() => _state?._restart();

  /// The mounted player's controller (scroll, clocks).
  StagePlayerController? get player => _state?._player;

  /// How many times the player was rebuilt from a new document.
  int get rebuilds => _state?._rebuilds ?? 0;
}

class _PreviewStageState extends ConsumerState<PreviewStage> {
  final StagePlayerController _player = StagePlayerController();
  final StageImageCache _images = StageImageCache();

  late ir.StageDocument _shown;
  Timer? _timer;
  int _epoch = 0;
  int _rebuilds = 0;

  StageEnvironment? _env;
  Object? _envKey;
  StageAudioService? _audio;
  Object? _audioKey;
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _shown = ref.read(editorControllerProvider).storyDocument;
    ref.listenManual(
      editorControllerProvider.select((s) => Identity(s.storyDocument)),
      (_, _) => _schedule(),
    );
    ref.listenManual(editorControllerProvider.select((s) => s.activeSceneId), (
      _,
      id,
    ) {
      if (id != null && ref.read(previewProvider).follow) {
        _player.scrollToScene(id);
      }
    });
    ref.listenManual(previewProvider.select((s) => s.follow), (_, on) {
      final id = ref.read(editorControllerProvider).activeSceneId;
      if (on && id != null) _player.scrollToScene(id);
    });
  }

  @override
  void didUpdateWidget(PreviewStage old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      if (identical(old.controller?._state, this)) {
        old.controller?._state = null;
      }
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller?._state, this)) {
      widget.controller?._state = null;
    }
    _timer?.cancel();
    unawaited(_audio?.dispose());
    _images.clear();
    super.dispose();
  }

  /// A document change: wait for the edit to settle, then rebuild. A change
  /// inside a gesture is not committed yet, so the timer re-arms until the
  /// gesture ends.
  void _schedule() {
    _timer?.cancel();
    _timer = Timer(kPreviewDebounce, _flush);
  }

  void _flush() {
    if (!mounted) return;
    final editor = ref.read(editorControllerProvider.notifier);
    if (editor.history.inGesture) {
      _schedule();
      return;
    }
    final doc = ref.read(editorControllerProvider).storyDocument;
    if (identical(doc, _shown)) return;
    setState(() {
      _shown = doc;
      _rebuilds++;
    });
  }

  void _restart() {
    setState(() {
      _epoch++;
      _disposeAudio();
    });
  }

  void _disposeAudio() {
    unawaited(_audio?.dispose());
    _audio = null;
    _audioKey = null;
  }

  StageEnvironment _environment(ir.StageDocument doc) {
    // freezed returns a new unmodifiable view per read: compare by value.
    final key = (doc.fonts, doc.assets, doc.audioTracks);
    final last = _envKey as (Object, Object, Object)?;
    if (_env == null ||
        last == null ||
        last.$1 != key.$1 ||
        last.$2 != key.$2 ||
        last.$3 != key.$3) {
      _envKey = key;
      _env = StageEnvironment.forDocument(doc, imageCache: _images);
    }
    return _env!;
  }

  StageAudioService _audioFor(ir.StageDocument doc) {
    final key = (doc.assets, doc.audioTracks);
    final last = _audioKey as (Object, Object)?;
    if (_audio == null ||
        last == null ||
        last.$1 != key.$1 ||
        last.$2 != key.$2) {
      unawaited(_audio?.dispose());
      _audioKey = key;
      final audio = _audio = StageAudioService.forDocument(doc);
      // Past the gate the browser already allows sound: start the new
      // service (a restart, or changed audio) without another gesture.
      if (_entered) unawaited(audio.unlock());
    }
    return _audio!;
  }

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(previewProvider);
    final doc = _shown;
    final viewport = previewViewportFor(doc, preview);
    final env = _environment(doc);
    final audio = _audioFor(doc)..muted = preview.muted;
    return LayoutBuilder(
      builder: (context, box) {
        final scale = [
          box.maxWidth / viewport.width,
          box.maxHeight / viewport.height,
          1.0,
        ].reduce((a, b) => a < b ? a : b);
        final shownSize = viewport * scale;
        return Center(
          child: ClipRect(
            child: SizedBox.fromSize(
              size: shownSize,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox.fromSize(
                  size: viewport,
                  // The gate sizes itself from the media size.
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(size: viewport),
                    child: StageEnterGate(
                      document: doc,
                      environment: env,
                      audio: audio,
                      onEnter: () => _entered = true,
                      onEntered: _player.requestFocus,
                      child: StagePlayer(
                        key: ValueKey<int>(_epoch),
                        document: doc,
                        environment: env,
                        audio: audio,
                        controller: _player,
                        viewportOverride: viewport,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
