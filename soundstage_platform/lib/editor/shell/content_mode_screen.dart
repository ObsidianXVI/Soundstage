import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../canvas/artboard.dart';
import '../canvas/artboard_canvas.dart';
import '../canvas/camera.dart';
import '../canvas/canvas_controller.dart';
import '../core/core.dart';
import '../insert/asset_service.dart';
import '../insert/editor_notices.dart';
import '../insert/insert_actions.dart';
import '../panels/asset_actions.dart';
import '../shortcuts/shortcut_map.dart';
import '../text/rich_text_model.dart';
import '../text/text_edit_controller.dart';
import '../text/text_edit_layer.dart';

/// The widest the scene is drawn: on a tablet-width window the scene stays
/// phone-sized and centred instead of being blown up.
const double kContentSceneMaxWidth = 560;

/// The smallest touch target (logical pixels).
const double kContentTarget = 44;

/// What `/edit/:id` shows below `kEditorMinWidth` (T1.13, DECISIONS
/// "Breakpoints and small screens"): **content mode**, a calm writing
/// surface. There is no layout, styling or motion editing here: only the
/// words of the text and the media in the slots that already exist.
///
/// - One scene at a time (prev/next, swipe-free: the arrows, the keyboard's
///   Left/Right and the list below), rendered by the real runtime for the
///   smallest primary breakpoint, fitted to the width, clocks at 0.
/// - Tap a text node to edit it in place (T1.8's session in content-only
///   form: no style or link shortcuts). Decorative text is not editable.
///   Writes go to the shared base, one undo step per session.
/// - Tap an image-filled frame to replace its image (the device picker; the
///   new image goes into the layer that supplies the one shown, and the
///   paint keeps its scale mode, focal point and filters) or to edit its
///   alt text. Replacing a sound repoints only that track at a new asset.
/// - "Content" lists every editable slot, so the page works by keyboard and
///   screen reader without hunting on the picture.
///
/// It lives inside the editor's provider scope (`EditorShell`), so edits,
/// undo and the app's autosave all go through the same controller.
class ContentModeScreen extends ConsumerStatefulWidget {
  const ContentModeScreen({
    required this.title,
    required this.onPlay,
    required this.onBack,
    this.saveStatus,
    super.key,
  });

  final String title;

  /// Opens the player (`/play/:id`).
  final VoidCallback onPlay;
  final VoidCallback onBack;

  /// The app's save indicator.
  final Widget? saveStatus;

  @override
  ConsumerState<ContentModeScreen> createState() => _ContentModeScreenState();
}

enum _Panel { none, content, image }

class _ContentModeScreenState extends ConsumerState<ContentModeScreen> {
  late final CanvasController _c;
  late final EditorController _ctl = ref.read(
    editorControllerProvider.notifier,
  );
  final StageImageCache _images = StageImageCache();
  final FocusNode _keys = FocusNode(debugLabel: 'Content mode');
  StageEnvironment? _env;
  late final TextMeasurer _sizer;
  late final EditorController _editor;
  Object? _envKey;

  _Panel _panel = _Panel.none;
  String? _imageId;
  bool _noticeDismissed = false;
  bool _busy = false;

  Size _viewport = Size.zero;
  Object? _fitKey;

  @override
  void initState() {
    super.initState();
    _c = ref.read(canvasControllerProvider);
    // The full editor's camera, given back when the window widens again
    // (R2: with content mode's camera the Desktop artboard filled the view
    // where Mobile had been). None when the editor opened straight into
    // content mode: the full editor then frames its artboards.
    if (_c.framed) _c.savedEditorCamera = _c.camera.value;
    // Auto-sized text is measured with this surface's fonts.
    _sizer = stageTextMeasurer(() => _env?.fonts ?? StageFontTable.none);
    _editor = ref.read(editorControllerProvider.notifier)
      ..textMeasurer = _sizer;
  }

  @override
  void dispose() {
    if (identical(_editor.textMeasurer, _sizer)) _editor.textMeasurer = null;
    _images.clear();
    _keys.dispose();
    super.dispose();
  }

  StageEnvironment _environment(ir.StageDocument doc) {
    final key = (doc.fonts, doc.assets, doc.audioTracks);
    final last = _envKey as (Object, Object, Object)?;
    if (_env == null ||
        last == null ||
        last.$1 != key.$1 ||
        last.$2 != key.$2 ||
        last.$3 != key.$3) {
      _envKey = key;
      _env = StageEnvironment.forDocument(
        doc,
        mode: StageRenderMode.edit,
        imageCache: _images,
      );
    }
    return _env!;
  }

  /// The breakpoint content mode shows: the narrowest primary one.
  ir.Breakpoint? _breakpoint(ir.StageDocument doc) {
    final boards = artboardBreakpoints(doc);
    if (boards.isEmpty) return null;
    return boards.reduce(
      (a, b) => b.designSize.width < a.designSize.width ? b : a,
    );
  }

  // ---- Camera: fit the width, scroll vertically -----------------------------------

  double _zoomFor(ir.Breakpoint bp) {
    final w = math.min(_viewport.width, kContentSceneMaxWidth);
    return bp.designSize.width <= 0 ? 1 : w / bp.designSize.width;
  }

  void _fit(ir.Breakpoint bp, {bool keepScroll = false}) {
    if (_viewport.isEmpty) return;
    final z = _zoomFor(bp);
    final w = bp.designSize.width * z;
    final y = keepScroll ? _c.camera.value.panY : 0.0;
    _c.setCamera(
      CanvasCamera(zoom: z, panX: (_viewport.width - w) / 2, panY: y),
    );
    _scrollBy(0, bp);
  }

  void _scrollBy(double dy, ir.Breakpoint? bp) {
    if (bp == null) return;
    final cam = _c.camera.value;
    final h = (_c.artboards[bp.id]?.worldRect.height ?? bp.designSize.height);
    final content = h * cam.zoom;
    final minY = math.min(0.0, _viewport.height - content);
    final y = (cam.panY + dy).clamp(minY, 0.0).toDouble();
    if (y != cam.panY) _c.setCamera(cam.copyWith(panY: y));
  }

  /// Scrolls so the node [id] is on screen (a long scene, a keyboard that
  /// took half the window).
  void _reveal(String id, ir.Breakpoint bp) {
    final r = _c.overlay.rectFor(id, bp.id);
    if (r == null || _viewport.isEmpty) return;
    final b = r.bounds;
    const pad = 24.0;
    var dy = 0.0;
    if (b.bottom > _viewport.height - pad) {
      dy = _viewport.height - pad - b.bottom;
    }
    if (b.top + dy < pad) dy = pad - b.top;
    if (dy != 0) _scrollBy(dy, bp);
  }

  // ---- Scenes -----------------------------------------------------------------------

  void _goTo(int index, ir.StageDocument doc) {
    if (doc.scenes.isEmpty) return;
    final i = index.clamp(0, doc.scenes.length - 1);
    _closeEditing();
    _ctl.setActiveScene(doc.scenes[i].id);
    _c.setCamera(_c.camera.value.copyWith(panY: 0));
    setState(() {
      _panel = _Panel.none;
      _imageId = null;
    });
  }

  void _closeEditing() {
    final s = ref.read(editorControllerProvider);
    if (s.textEditId != null || s.selection.isNotEmpty) {
      _ctl.clearSelection();
    }
  }

  // ---- Taps ---------------------------------------------------------------------------

  /// Whether [n] is a slot whose image can be replaced.
  static ir.ImagePaint? imageOf(ir.Node n) {
    if (n is ir.TextNode) return null;
    final fills = ir.PropertyRegistry.standard.get(n, 'fills');
    if (fills is! ir.PaintsValue) return null;
    for (final p in fills.value) {
      if (p is ir.ImagePaint) return p;
    }
    return null;
  }

  /// Whether the text node [n] can be edited here.
  static bool editableText(ir.Node n) =>
      n is ir.TextNode && n.common.role != ir.NodeRole.decorative;

  void _onTap(Offset at, ir.Breakpoint bp) {
    final st = ref.read(editorControllerProvider);
    final index = ir.DocumentIndex.of(st.document);
    final resolved = ref.read(resolvedForProvider(bp.id)).resolved.nodeIndex;
    for (final hit in _c.overlay.hitTest(at)) {
      final id = hit.nodeId;
      if (id.contains('/')) continue; // instance parts: M3
      final base = index.node(id);
      if (base == null) continue;
      if (editableText(base)) {
        _editText(id);
        return;
      }
      final concrete = resolved[id]?.node ?? base;
      if (imageOf(concrete) != null) {
        _openImage(id);
        return;
      }
    }
    _closeEditing();
    if (_panel == _Panel.image) {
      setState(() {
        _panel = _Panel.none;
        _imageId = null;
      });
    }
  }

  void _editText(String id) {
    if (_panel != _Panel.none) {
      setState(() {
        _panel = _Panel.none;
        _imageId = null;
      });
    }
    _ctl.applySelection(
      SelectionState(selection: {id}, context: null, textEditId: id),
    );
  }

  void _openImage(String id) {
    _closeEditing();
    _ctl.applySelection(SelectionState(selection: {id}));
    setState(() {
      _panel = _Panel.image;
      _imageId = id;
    });
  }

  // ---- Undo and redo --------------------------------------------------------------------

  void _undo() {
    final s = ref.read(textEditProvider).session;
    if (s != null && s.undo()) return;
    _ctl.undo();
  }

  void _redo() {
    final s = ref.read(textEditProvider).session;
    if (s != null && s.redo()) return;
    _ctl.redo();
  }

  // ---- Media ----------------------------------------------------------------------------

  /// Picks an image and swaps it into the slot [id] in the layer that
  /// supplies the image shown here (base, a breakpoint patch or an instance
  /// override; see [ReplaceVisibleImage]): the paint keeps its id, scale
  /// mode, focal point, crop and filters. One undo step.
  Future<void> _replaceImage(String id) async {
    if (_busy) return;
    final notices = ref.read(editorNoticesProvider);
    setState(() => _busy = true);
    try {
      final EditorFilePicker pick;
      try {
        pick = ref.read(editorFilePickerProvider);
      } on StateError {
        notices.say('Picking files is not available here.');
        return;
      }
      final files = await pick(accept: 'image/*');
      if (files.isEmpty || !mounted) return;
      final anchor = _ctl.history.lastEntry;
      final assets = await ref
          .read(insertActionsProvider)
          .addToLibrary(files.take(1));
      if (assets.isEmpty || !mounted) return;
      final bp = _breakpoint(ref.read(editorControllerProvider).document);
      if (bp == null) return;
      _ctl.resolvedFor(bp.id); // brings the memo up to date
      final r = _ctl.execute(
        ReplaceVisibleImage(
          id,
          assets.first.id,
          breakpointId: bp.id,
          resolver: _ctl.resolverFor(bp.id),
        ),
      );
      if (r.ok) {
        _ctl.squashHistoryAfter(anchor, 'Replace image');
      } else {
        notices.say(r.diagnostics.map((d) => d.message).join('\n'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setAlt(String id, String text) {
    final v = text.trim();
    final index = ir.DocumentIndex.of(
      ref.read(editorControllerProvider).document,
    );
    final current = index.node(id)?.common.altText ?? '';
    if (v == current) return;
    _ctl.execute(
      BaseScoped(
        SetProperty(
          [id],
          'altText',
          v.isEmpty ? const ir.IrValue.none() : ir.IrValue.string(v),
        ),
      ),
    );
  }

  Future<void> _replaceAudio(String trackId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(assetActionsProvider).pickAndReplaceTrack(trackId);
    } on StateError {
      ref
          .read(editorNoticesProvider)
          .say('Picking files is not available here.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Keyboard ---------------------------------------------------------------------------

  KeyEventResult _onKey(
    FocusNode node,
    KeyEvent e,
    ir.StageDocument doc,
    int index,
    ir.Breakpoint? bp,
  ) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (primaryFocusIsStageText() || primaryFocusIsTextInput()) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) _goTo(index - 1, doc);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (index < doc.scenes.length - 1) _goTo(index + 1, doc);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.pageDown) {
      _scrollBy(
        k == LogicalKeyboardKey.pageDown ? -_viewport.height * 0.8 : -80,
        bp,
      );
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.pageUp) {
      _scrollBy(
        k == LogicalKeyboardKey.pageUp ? _viewport.height * 0.8 : 80,
        bp,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- Build -----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final activeId = ref.watch(
      editorControllerProvider.select((s) => s.activeSceneId),
    );
    final history = ref.watch(
      editorControllerProvider.select((s) => s.history),
    );
    final bp = _breakpoint(doc);
    var index = doc.scenes.indexWhere((s) => s.id == activeId);
    if (index < 0 && doc.scenes.isNotEmpty) index = 0;
    final scene = index < 0 ? null : doc.scenes[index];

    ref.listen(editorControllerProvider.select((s) => s.textEditId), (_, id) {
      if (id == null || bp == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal(id, bp);
      });
    });

    return EditorNoticeHost(
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: (n, e) => _onKey(n, e, doc, index, bp),
        child: ColoredBox(
          color: c.surface0,
          child: SafeArea(
            child: Column(
              children: [
                _TopBar(
                  title: widget.title,
                  onBack: widget.onBack,
                  onPlay: widget.onPlay,
                  onUndo: history.canUndo ? _undo : null,
                  onRedo: history.canRedo ? _redo : null,
                  undoLabel: history.undoLabel,
                  redoLabel: history.redoLabel,
                ),
                _StatusStrip(
                  saveStatus: widget.saveStatus,
                  noticeDismissed: _noticeDismissed,
                  onDismissNotice: () =>
                      setState(() => _noticeDismissed = true),
                ),
                Expanded(
                  child: scene == null || bp == null
                      ? const _EmptyStory()
                      : LayoutBuilder(
                          builder: (context, box) {
                            _viewport = box.biggest;
                            final key = (
                              box.biggest,
                              scene.id,
                              bp.id,
                              bp.designSize,
                            );
                            if (_fitKey != key) {
                              _fitKey = key;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) _fit(bp, keepScroll: true);
                              });
                            }
                            return _SceneSurface(
                              controller: _c,
                              breakpoint: bp,
                              environment: _environment(doc),
                              label:
                                  'Scene ${index + 1}: ${_sceneName(scene, index)}',
                              onTap: (p) => _onTap(p, bp),
                              onScroll: (dy) => _scrollBy(dy, bp),
                            );
                          },
                        ),
                ),
                if (_panel == _Panel.image && _imageId != null)
                  _ImagePanel(
                    key: ValueKey<String>('image-panel:$_imageId'),
                    nodeId: _imageId!,
                    breakpointId: bp?.id ?? '',
                    busy: _busy,
                    onReplace: () => unawaited(_replaceImage(_imageId!)),
                    onAlt: (v) => _setAlt(_imageId!, v),
                    onClose: () {
                      _closeEditing();
                      setState(() {
                        _panel = _Panel.none;
                        _imageId = null;
                      });
                    },
                  ),
                if (_panel == _Panel.content && scene != null && bp != null)
                  _ContentList(
                    scene: scene,
                    breakpoint: bp,
                    busy: _busy,
                    onEditText: _editText,
                    onOpenImage: _openImage,
                    onReplaceAudio: (id) => unawaited(_replaceAudio(id)),
                  ),
                _PagerBar(
                  index: index,
                  count: doc.scenes.length,
                  scene: scene,
                  listOpen: _panel == _Panel.content,
                  onPrev: index > 0 ? () => _goTo(index - 1, doc) : null,
                  onNext: index >= 0 && index < doc.scenes.length - 1
                      ? () => _goTo(index + 1, doc)
                      : null,
                  onToggleList: () {
                    _closeEditing();
                    setState(() {
                      _imageId = null;
                      _panel = _panel == _Panel.content
                          ? _Panel.none
                          : _Panel.content;
                    });
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _sceneName(ir.Scene s, int index) =>
    s.name.isEmpty ? 'Scene ${index + 1}' : s.name;

// ---- Top bar and status ---------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.onPlay,
    required this.onUndo,
    required this.onRedo,
    required this.undoLabel,
    required this.redoLabel,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final String? undoLabel;
  final String? redoLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Container(
      height: kContentTarget + SsSpace.s2,
      padding: const EdgeInsets.symmetric(horizontal: SsSpace.s1),
      decoration: BoxDecoration(
        color: t.colors.surface1,
        border: Border(bottom: BorderSide(color: t.colors.borderSubtle)),
      ),
      child: Row(
        children: [
          SsIconButton(
            icon: SsIcons.arrowLeft,
            semanticLabel: 'Back to stories',
            size: kContentTarget,
            iconSize: 20,
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              title,
              key: const ValueKey<String>('content-mode-title'),
              style: t.text.bodyStrong,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SsIconButton(
            icon: SsIcons.undo2,
            semanticLabel: undoLabel == null ? 'Undo' : 'Undo $undoLabel',
            size: kContentTarget,
            iconSize: 20,
            onPressed: onUndo,
          ),
          SsIconButton(
            icon: SsIcons.redo2,
            semanticLabel: redoLabel == null ? 'Redo' : 'Redo $redoLabel',
            size: kContentTarget,
            iconSize: 20,
            onPressed: onRedo,
          ),
          SsIconButton(
            icon: SsIcons.play,
            semanticLabel: 'Preview story',
            size: kContentTarget,
            iconSize: 20,
            onPressed: onPlay,
          ),
        ],
      ),
    );
  }
}

/// The save state and the (small, dismissible) note that layout and motion
/// need a larger window.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.saveStatus,
    required this.noticeDismissed,
    required this.onDismissNotice,
  });

  final Widget? saveStatus;
  final bool noticeDismissed;
  final VoidCallback onDismissNotice;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    if (saveStatus == null && noticeDismissed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: SsSpace.s3),
      child: Row(
        children: [
          ?saveStatus,
          if (!noticeDismissed) ...[
            const SizedBox(width: SsSpace.s3),
            Expanded(
              child: Text(
                'Layout and motion need a larger window (1024 px or wider).',
                key: const ValueKey<String>('content-mode-note'),
                style: t.text.caption.copyWith(color: c.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SsIconButton(
              icon: SsIcons.x,
              semanticLabel: 'Dismiss note',
              size: kContentTarget,
              iconSize: 14,
              onPressed: onDismissNotice,
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyStory extends StatelessWidget {
  const _EmptyStory();

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s6),
        child: Text(
          'This story has no scenes yet.',
          textAlign: TextAlign.center,
          style: t.text.body.copyWith(color: t.colors.textSecondary),
        ),
      ),
    );
  }
}

// ---- The scene ------------------------------------------------------------------------

/// The active scene as readers see it (edit-mode runtime, clocks at the
/// playhead), with tap, scroll and the content-only text editing on top.
class _SceneSurface extends StatelessWidget {
  const _SceneSurface({
    required this.controller,
    required this.breakpoint,
    required this.environment,
    required this.label,
    required this.onTap,
    required this.onScroll,
  });

  final CanvasController controller;
  final ir.Breakpoint breakpoint;
  final StageEnvironment environment;
  final String label;
  final void Function(Offset at) onTap;
  final void Function(double dy) onScroll;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      container: true,
      child: Listener(
        onPointerSignal: (event) {
          GestureBinding.instance.pointerSignalResolver.register(event, (e) {
            if (e is PointerScrollEvent) onScroll(-e.scrollDelta.dy);
          });
        },
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ArtboardCanvas(
                controller: controller,
                breakpointIds: [breakpoint.id],
                children: [
                  Artboard(
                    key: ValueKey<String>('artboard-${breakpoint.id}'),
                    breakpoint: breakpoint,
                    controller: controller,
                    environment: environment,
                  ),
                ],
              ),
              GestureDetector(
                key: const ValueKey<String>('content-surface'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => onTap(d.localPosition),
                onVerticalDragUpdate: (d) => onScroll(d.delta.dy),
                child: const SizedBox.expand(),
              ),
              TextEditLayer(controller: controller, contentOnly: true),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Bottom bar -----------------------------------------------------------------------

class _PagerBar extends StatelessWidget {
  const _PagerBar({
    required this.index,
    required this.count,
    required this.scene,
    required this.listOpen,
    required this.onPrev,
    required this.onNext,
    required this.onToggleList,
  });

  final int index;
  final int count;
  final ir.Scene? scene;
  final bool listOpen;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onToggleList;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final s = scene;
    final kind = s == null
        ? ''
        : (s.kind == ir.SceneKind.pinned ? 'Pinned' : 'Flow');
    return Container(
      height: kContentTarget + SsSpace.s2,
      padding: const EdgeInsets.symmetric(horizontal: SsSpace.s1),
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          SsIconButton(
            icon: SsIcons.chevronLeft,
            semanticLabel: 'Previous scene',
            size: kContentTarget,
            iconSize: 20,
            onPressed: onPrev,
          ),
          Expanded(
            child: Semantics(
              liveRegion: true,
              label: s == null
                  ? 'No scenes'
                  : 'Scene ${index + 1} of $count, ${_sceneName(s, index)}, '
                        '$kind',
              excludeSemantics: true,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    s == null ? 'No scenes' : _sceneName(s, index),
                    key: const ValueKey<String>('content-scene-name'),
                    style: t.text.bodyStrong,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    s == null ? '' : '${index + 1} of $count  ·  $kind',
                    key: const ValueKey<String>('content-scene-kind'),
                    style: t.text.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          SsIconButton(
            icon: SsIcons.chevronRight,
            semanticLabel: 'Next scene',
            size: kContentTarget,
            iconSize: 20,
            onPressed: onNext,
          ),
          SsIconButton(
            icon: SsIcons.list,
            semanticLabel: listOpen
                ? 'Hide the scene content list'
                : 'Show the scene content list',
            size: kContentTarget,
            iconSize: 20,
            selected: listOpen,
            onPressed: onToggleList,
          ),
        ],
      ),
    );
  }
}

// ---- Panels ----------------------------------------------------------------------------

/// A 44 px tall labelled button.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return SsInteractive(
      onTap: onPressed,
      enabled: onPressed != null,
      semanticLabel: label,
      excludeSemantics: true,
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final fg = disabled
            ? c.textDisabled
            : (primary ? c.textOnAccent : c.textPrimary);
        return Container(
          height: kContentTarget,
          padding: const EdgeInsets.symmetric(horizontal: SsSpace.s4),
          decoration: BoxDecoration(
            color: primary && !disabled ? c.accent : c.surface2,
            borderRadius: SsRadius.brMd,
            border: primary ? null : Border.all(color: c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SsIcon(icon, size: 16, color: fg),
              const SizedBox(width: SsSpace.s2),
              Flexible(
                child: Text(
                  label,
                  style: t.text.bodyStrong.copyWith(color: fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PanelFrame extends StatelessWidget {
  const _PanelFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: child,
    );
  }
}

/// Replace the image of one slot and edit its alt text.
class _ImagePanel extends ConsumerStatefulWidget {
  const _ImagePanel({
    required this.nodeId,
    required this.breakpointId,
    required this.busy,
    required this.onReplace,
    required this.onAlt,
    required this.onClose,
    super.key,
  });

  final String nodeId;
  final String breakpointId;
  final bool busy;
  final VoidCallback onReplace;
  final ValueChanged<String> onAlt;
  final VoidCallback onClose;

  @override
  ConsumerState<_ImagePanel> createState() => _ImagePanelState();
}

class _ImagePanelState extends ConsumerState<_ImagePanel> {
  final TextEditingController _alt = TextEditingController();
  final FocusNode _altFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _alt.text =
        ir.DocumentIndex.of(
          ref.read(editorControllerProvider).document,
        ).node(widget.nodeId)?.common.altText ??
        '';
    _altFocus.addListener(() {
      if (!_altFocus.hasFocus) widget.onAlt(_alt.text);
    });
  }

  @override
  void dispose() {
    _alt.dispose();
    _altFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final node = ir.DocumentIndex.of(doc).node(widget.nodeId);
    final paint = node == null
        ? null
        : _ContentModeScreenState.imageOf(
            ref
                    .read(resolvedForProvider(widget.breakpointId))
                    .resolved
                    .nodeIndex[widget.nodeId]
                    ?.node ??
                node,
          );
    ir.Asset? asset;
    if (paint != null) {
      for (final a in doc.assets.values) {
        if (a.id == paint.assetId) asset = a;
      }
    }
    final name = (node?.common.name ?? '').isEmpty
        ? 'Image'
        : node!.common.name;
    return _PanelFrame(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SsIcon(SsIcons.image, size: 16),
                const SizedBox(width: SsSpace.s2),
                Expanded(
                  child: Text(
                    asset == null || asset.name.isEmpty
                        ? name
                        : '$name  ·  ${asset.name}',
                    style: t.text.bodyStrong,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SsIconButton(
                  icon: SsIcons.x,
                  semanticLabel: 'Close image options',
                  size: kContentTarget,
                  iconSize: 16,
                  onPressed: widget.onClose,
                ),
              ],
            ),
            SsTextField(
              key: const ValueKey<String>('content-alt-field'),
              controller: _alt,
              focusNode: _altFocus,
              placeholder: 'Describe the image for screen readers',
              semanticLabel: 'Alt text',
              onSubmitted: widget.onAlt,
            ),
            const SizedBox(height: SsSpace.s2),
            _ActionButton(
              label: 'Replace image',
              icon: SsIcons.imageUp,
              primary: true,
              onPressed: widget.busy ? null : widget.onReplace,
            ),
          ],
        ),
      ),
    );
  }
}

/// Every editable slot of the scene, as large rows: the keyboard and screen
/// reader path to what the picture shows.
class _ContentList extends ConsumerWidget {
  const _ContentList({
    required this.scene,
    required this.breakpoint,
    required this.busy,
    required this.onEditText,
    required this.onOpenImage,
    required this.onReplaceAudio,
  });

  final ir.Scene scene;
  final ir.Breakpoint breakpoint;
  final bool busy;
  final ValueChanged<String> onEditText;
  final ValueChanged<String> onOpenImage;
  final ValueChanged<String> onReplaceAudio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final resolved = ref.watch(resolvedForProvider(breakpoint.id));
    final rs = resolved.scene(scene.id);
    final index = ir.DocumentIndex.of(doc);

    final texts = <(String, ir.TextNode)>[];
    final images = <(String, ir.Node)>[];
    void walk(ir.ResolvedNode n) {
      if (!n.id.contains('/')) {
        final base = index.node(n.id);
        if (base is ir.TextNode) {
          if (_ContentModeScreenState.editableText(base)) {
            texts.add((n.id, base));
          }
        } else if (base != null &&
            _ContentModeScreenState.imageOf(n.node) != null) {
          images.add((n.id, base));
        }
      }
      n.children.forEach(walk);
    }

    if (rs != null) walk(rs.root);
    // Role-bearing text (headings, paragraphs, quotes) before the rest.
    final ordered = [
      for (final e in texts)
        if (e.$2.common.role != ir.NodeRole.none) e,
      for (final e in texts)
        if (e.$2.common.role == ir.NodeRole.none) e,
    ];
    final tracks = [
      for (final a in doc.audioTracks)
        if (a.scope is ir.StoryAudioScope ||
            (a.scope is ir.SceneAudioScope &&
                (a.scope as ir.SceneAudioScope).sceneId == scene.id))
          a,
    ];
    String assetName(String id) {
      for (final a in doc.assets.values) {
        if (a.id == id) return a.name.isEmpty ? 'Sound' : a.name;
      }
      return 'Sound';
    }

    final empty = ordered.isEmpty && images.isEmpty && tracks.isEmpty;
    return _PanelFrame(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.min(300, MediaQuery.sizeOf(context).height * 0.4),
        ),
        child: ListView(
          key: const ValueKey<String>('content-list'),
          padding: const EdgeInsets.symmetric(vertical: SsSpace.s1),
          shrinkWrap: true,
          children: [
            if (empty)
              Padding(
                padding: const EdgeInsets.all(SsSpace.s4),
                child: Text(
                  'Nothing to edit in this scene.',
                  style: t.text.body.copyWith(color: c.textSecondary),
                ),
              ),
            for (final (id, node) in ordered)
              _SlotRow(
                key: ValueKey<String>('slot:$id'),
                icon: SsIcons.pencil,
                caption: roleLabel(node.common.role) ?? 'Text',
                label: _snippet(node),
                semanticLabel: 'Edit text: ${_snippet(node)}',
                onTap: () => onEditText(id),
              ),
            for (final (id, node) in images)
              _SlotRow(
                key: ValueKey<String>('slot:$id'),
                icon: SsIcons.image,
                caption: 'Image',
                label: node.common.name.isEmpty ? 'Image' : node.common.name,
                semanticLabel:
                    'Image options: ${node.common.name.isEmpty ? 'image' : node.common.name}',
                onTap: () => onOpenImage(id),
              ),
            for (final a in tracks)
              _SlotRow(
                key: ValueKey<String>('slot:${a.id}'),
                icon: SsIcons.volume2,
                caption: 'Sound',
                label: assetName(a.assetId),
                semanticLabel: 'Replace sound file: ${assetName(a.assetId)}',
                trailing: 'Replace',
                onTap: busy ? null : () => onReplaceAudio(a.id),
              ),
          ],
        ),
      ),
    );
  }

  static String _snippet(ir.TextNode n) {
    final s = plainTextOf(n.content).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return 'Empty text';
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.icon,
    required this.caption,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String caption;
  final String label;
  final String semanticLabel;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return SsInteractive(
      onTap: onTap,
      enabled: onTap != null,
      semanticLabel: semanticLabel,
      excludeSemantics: true,
      builder: (context, s) => Container(
        constraints: const BoxConstraints(minHeight: kContentTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: SsSpace.s3,
          vertical: SsSpace.s2,
        ),
        color:
            s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)
            ? c.hoverLayer
            : const Color(0x00000000),
        child: Row(
          children: [
            SsIcon(icon, size: 16, color: c.textSecondary),
            const SizedBox(width: SsSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(caption, style: t.text.caption),
                  Text(
                    label,
                    style: t.text.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: t.text.small.copyWith(color: c.accentText),
              ),
          ],
        ),
      ),
    );
  }
}
