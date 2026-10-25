import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';
import 'package:soundstage_platform/editor/core/editor_state.dart';
import 'package:soundstage_platform/editor/core/text_size_sync.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../insert/canvas_drop.dart';
import '../insert/insert_tool_layer.dart';
import '../interaction/canvas_interaction.dart';
import '../overlay/canvas_overlay.dart';
import '../shortcuts/shortcut_map.dart' show reclaimShortcutFocus;
import '../text/text_edit_controller.dart';
import '../text/text_edit_layer.dart';
import 'artboard.dart';
import 'artboard_canvas.dart';
import 'artboard_chrome.dart';
import 'canvas_controller.dart';

/// Wheel/pinch delta (pixels) that zooms by a factor of e.
const double kWheelZoomScale = 240;

/// The editor canvas (m1.md "Canvas"): one artboard per primary
/// breakpoint side by side, seen through a custom camera, with the overlay
/// on top.
///
/// Camera input:
/// - pan: trackpad two-finger scroll (wheel without Cmd/Ctrl), Space-drag,
///   middle-drag, or a primary drag with the hand tool;
/// - zoom: Cmd/Ctrl+wheel and trackpad pinch, about the pointer;
/// - keyboard zoom (Cmd+=, Cmd+-, Cmd+0, Shift+1, Shift+2) goes through
///   [CanvasController] from the shell's shortcut actions, animated.
///
/// Selection and transform tools are [CanvasInteraction] (T1.4/T1.5),
/// between the overlay and the artboard chrome.
///
/// The canvas frames every artboard (at most 100%) once they first lay out.
class EditorCanvas extends ConsumerStatefulWidget {
  const EditorCanvas({super.key});

  @override
  ConsumerState<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends ConsumerState<EditorCanvas>
    with TickerProviderStateMixin {
  late CanvasController _c = ref.read(canvasControllerProvider);

  bool _space = false;
  int? _panPointer;
  double _lastPinchScale = 1;
  StageEnvironment? _env;
  late final TextMeasurer _sizer;
  late final EditorController _editor;
  Object? _envKey;

  /// Decoded images and failed loads, kept across environment changes (an
  /// asset added or replaced keeps every other image decoded; a changed
  /// asset record retries its failed load at once).
  final StageImageCache _images = StageImageCache();

  @override
  void initState() {
    super.initState();
    _c.attachTicker(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    // Back from content mode: the camera this editor had before it.
    final saved = _c.savedEditorCamera;
    if (saved != null) {
      _c.savedEditorCamera = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _c.setCamera(saved);
      });
    }
    // Auto-sized text is measured with this surface's fonts.
    _sizer = stageTextMeasurer(() => _env?.fonts ?? StageFontTable.none);
    _editor = ref.read(editorControllerProvider.notifier)
      ..textMeasurer = _sizer;
  }

  @override
  void dispose() {
    if (identical(_editor.textMeasurer, _sizer)) _editor.textMeasurer = null;
    HardwareKeyboard.instance.removeHandler(_onKey);
    _c.detachTicker();
    _images.clear();
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.space) {
      final down = e is! KeyUpEvent;
      if (down && _typing()) return false;
      if (down != _space) setState(() => _space = down);
    }
    return false;
  }

  static bool _typing() {
    if (primaryFocusIsStageText()) return true;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  static bool get _zoomModifier {
    final k = HardwareKeyboard.instance;
    return k.isControlPressed || k.isMetaPressed;
  }

  void _onSignal(PointerSignalEvent event) {
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is PointerScrollEvent) {
        if (_zoomModifier) {
          _c.zoomAbout(
            e.localPosition,
            math.exp(-e.scrollDelta.dy / kWheelZoomScale),
          );
        } else {
          var d = e.scrollDelta;
          if (HardwareKeyboard.instance.isShiftPressed && d.dx == 0) {
            d = Offset(d.dy, 0);
          }
          _c.panBy(-d);
        }
      } else if (e is PointerScaleEvent) {
        _c.zoomAbout(e.localPosition, e.scale);
      }
    });
  }

  bool _pansWith(PointerDownEvent e) {
    if (e.buttons & kMiddleMouseButton != 0) return true;
    if (e.buttons & kPrimaryButton == 0) return false;
    return _space ||
        ref.read(editorControllerProvider.select((s) => s.tool)) ==
            EditorTool.hand;
  }

  void _onDown(PointerDownEvent e) {
    // Figma-style: a click on the canvas takes focus off any chrome text
    // field, so Cmd+C/V and the other editor shortcuts work again.
    reclaimShortcutFocus(e.position);
    if (_panPointer == null && _pansWith(e)) {
      setState(() => _panPointer = e.pointer);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer == _panPointer) _c.panBy(e.delta);
  }

  void _onUp(PointerEvent e) {
    if (e.pointer == _panPointer) setState(() => _panPointer = null);
  }

  StageEnvironment _environment(ir.StageDocument doc) {
    // freezed returns a new unmodifiable view of a list on every read, so
    // these never compare identical; compare by value (short lists of
    // shared objects). A new environment relays out every text node.
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

  void _frameOnce() {
    if (_c.framed || !mounted) return;
    if (_c.zoomToFit(animate: false, maxZoom: 1)) {
      _c.framed = true;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _frameOnce());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(canvasControllerProvider);
    if (!identical(controller, _c)) {
      // A new document opened in this editor: a fresh canvas state.
      _c = controller..attachTicker(this);
    }
    final c = context.ss.colors;
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final tool = ref.watch(editorControllerProvider.select((s) => s.tool));
    final boards = artboardBreakpoints(doc);
    final env = _environment(doc);
    if (!_c.framed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _frameOnce());
    }
    final grabbing = _panPointer != null;
    final cursor = grabbing
        ? SystemMouseCursors.grabbing
        : (_space || tool == EditorTool.hand)
        ? SystemMouseCursors.grab
        : MouseCursor.defer;
    return Semantics(
      label: 'Canvas',
      container: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: _onSignal,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onUp,
        onPointerPanZoomStart: (_) => _lastPinchScale = 1,
        onPointerPanZoomUpdate: (e) {
          _c.panBy(e.localPanDelta);
          if (e.scale > 0 && e.scale != _lastPinchScale) {
            _c.zoomAbout(e.localPosition, e.scale / _lastPinchScale);
            _lastPinchScale = e.scale;
          }
        },
        child: MouseRegion(
          cursor: cursor,
          child: ClipRect(
            child: ColoredBox(
              color: c.surface0,
              child: CanvasDropTarget(
                controller: _c,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ArtboardCanvas(
                      controller: _c,
                      breakpointIds: [for (final b in boards) b.id],
                      children: [
                        for (final b in boards)
                          Artboard(
                            key: ValueKey<String>('artboard-${b.id}'),
                            breakpoint: b,
                            controller: _c,
                            environment: env,
                          ),
                      ],
                    ),
                    CanvasOverlay(controller: _c),
                    CanvasInteraction(controller: _c, pansWith: _pansWith),
                    InsertToolLayer(controller: _c, pansWith: _pansWith),
                    TextEditLayer(controller: _c),
                    ArtboardChrome(controller: _c, breakpoints: boards),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
