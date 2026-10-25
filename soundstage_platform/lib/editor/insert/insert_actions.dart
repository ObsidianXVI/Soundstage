import 'dart:async';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../canvas/canvas_controller.dart';
import '../core/core.dart';
import 'asset_service.dart';
import 'editor_notices.dart';
import 'insert_nodes.dart';
import 'insert_placement.dart';

/// What the insert tools, the Assets panel, drag-and-drop and the clipboard
/// do to the document that is more than one command: store files, then
/// place them.
///
/// - **Images** become frames named after the file with an `ImagePaint`
///   fill (scale mode `fill`, focal point at the centre), role `figure` and
///   the asset's alt text (empty by default). They go at their intrinsic
///   size, scaled down to fit within 80 % of the artboard.
/// - Audio and video files only go to the library: their node kinds come
///   later.
class InsertActions {
  InsertActions(this._ref);

  final Ref _ref;

  EditorController get _ctl => _ref.read(editorControllerProvider.notifier);
  EditorState get _state => _ref.read(editorControllerProvider);
  EditorAssetService get _assets => _ref.read(editorAssetServiceProvider);

  void _say(String message) => _ref.read(editorNoticesProvider).say(message);

  // ---- Files -------------------------------------------------------------

  /// Stores [files] and adds the assets to the document (one undo step).
  /// Returns the stored assets; failures are reported.
  Future<List<ir.Asset>> addToLibrary(Iterable<EditorFile> files) async {
    final report = await ingestMedia(
      _assets,
      files,
      existing: _state.document.assets.values,
    );
    if (report.assets.isNotEmpty) {
      _ctl.execute(AddAssets(report.assets));
    }
    if (!report.ok) _say(report.summary);
    return report.assets;
  }

  /// Opens the picker for images (the Image tool).
  Future<void> pickAndInsertImages(EditorFilePicker pick) async {
    final files = await pick(accept: 'image/*', multiple: true);
    if (files.isEmpty) {
      _finish();
      return;
    }
    await insertFiles(files);
  }

  /// Stores [files] and inserts the images among them as frames (at the
  /// drop point [screen] when given, else centred in the insert parent).
  /// Audio and video go to the library only.
  Future<void> insertFiles(
    Iterable<EditorFile> files, {
    Offset? screen,
    CanvasController? canvas,
  }) async {
    final assets = await addToLibrary(files);
    final images = [
      for (final a in assets)
        if (a.kind == ir.AssetKind.image) a,
    ];
    final others = assets.length - images.length;
    if (images.isNotEmpty) {
      insertImages(images, screen: screen, canvas: canvas);
    } else {
      _finish();
    }
    if (others > 0) {
      _say(
        '$others audio/video ${others == 1 ? 'file was' : 'files were'} '
        'added to Assets. Placing them comes with the audio and video nodes.',
      );
    }
  }

  void _finish() {
    if (_state.tool != EditorTool.move) _ctl.setTool(EditorTool.move);
  }

  // ---- Placing images --------------------------------------------------------

  /// The frame an image goes into when nothing says otherwise: the one
  /// selected frame, else the selection context, else the active scene's
  /// root.
  String? defaultParent([EditorState? s]) {
    final st = s ?? _state;
    final index = ir.DocumentIndex.of(st.document);
    bool isFrame(String? id) =>
        id != null && !id.contains('/') && index.node(id) is ir.FrameNode;
    if (st.selection.length == 1 && isFrame(st.selection.single)) {
      return st.selection.single;
    }
    if (isFrame(st.selectionContext)) return st.selectionContext;
    return st.activeScene?.root.id;
  }

  /// Inserts frames for image [assets] and selects them (one undo step).
  ///
  /// With a drop point [screen] and the [canvas], they go into the frame
  /// under it, centred on it (in the flow at that spot for auto layout).
  /// Otherwise they go into [defaultParent], centred, each stepped 20 px
  /// from the last.
  ///
  /// Returns the ids of the new frames.
  List<String> insertImages(
    List<ir.Asset> assets, {
    Offset? screen,
    CanvasController? canvas,
    String? parentId,
  }) {
    final st = _state;
    final doc = st.document;
    final index = ir.DocumentIndex.of(doc);
    var bp = st.breakpointId;
    InsertTarget? target;
    if (screen != null && canvas != null) {
      target = InsertPlacement(canvas, doc).targetAt(screen);
      if (target != null) bp = target.breakpointId;
    }
    final pid = target?.parentId ?? parentId ?? defaultParent(st);
    final parent = pid == null ? null : index.node(pid);
    if (pid == null || parent is! ir.FrameNode) {
      _finish();
      return const [];
    }
    final artboard = _artboardSize(doc, bp);
    final parentSize = _sizeOf(parent, artboard);
    final gen = ir.IdGenerator.forDocument(doc);
    Offset? at;
    if (target != null && !target.inFlow && canvas != null) {
      at = target.local(canvas.camera.value.toWorld(screen!));
    }
    final frames = <ir.Node>[];
    for (final (i, a) in assets.indexed) {
      final size = fitImageSize(
        Size(a.width?.toDouble() ?? 0, a.height?.toDouble() ?? 0),
        artboard,
      );
      final centre = at != null
          ? at + Offset(20.0 * i, 20.0 * i)
          : Offset(
              parentSize.width / 2 + 20.0 * i,
              parentSize.height / 2 + 20.0 * i,
            );
      final box = Rect.fromCenter(
        center: centre,
        width: size.width,
        height: size.height,
      );
      frames.add(
        buildImageFrame(
          a,
          gen.next(),
          gen.next(),
          Rect.fromLTWH(
            box.left.roundToDouble(),
            box.top.roundToDouble(),
            size.width,
            size.height,
          ),
        ),
      );
    }
    if (bp != null) _ctl.setEditingBreakpoint(bp);
    final r = _ctl.execute(InsertNodes(pid, frames, index: target?.flowIndex));
    _finish();
    if (!r.ok) {
      _say(r.diagnostics.map((d) => d.message).join('\n'));
      return const [];
    }
    return [for (final f in frames) f.id];
  }

  Size _artboardSize(ir.StageDocument doc, String? bpId) {
    for (final b in doc.breakpoints) {
      if (b.id == bpId) {
        return Size(b.designSize.width, b.designSize.height);
      }
    }
    return const Size(1440, 900);
  }

  Size _sizeOf(ir.FrameNode f, Size artboard) {
    final w = f.common.width, h = f.common.height;
    return Size(w > 0 ? w : artboard.width, h > 0 ? h : artboard.height);
  }

  // ---- Applying an asset ------------------------------------------------------

  /// Uses image asset [assetId] as the fill of the selected nodes. Returns
  /// false when nothing is selected or nothing can take a fill.
  bool applyAsFillToSelection(String assetId) {
    final sel = _state.selection.toList();
    if (sel.isEmpty) return false;
    final r = _ctl.execute(SetImageFill(sel, assetId));
    if (!r.ok) {
      _say(r.diagnostics.map((d) => d.message).join('\n'));
      return false;
    }
    return r.changed;
  }

  /// A drop of asset [assetId] at [screen] on the canvas: onto a frame or
  /// shape (not the artboard background) it becomes that node's fill;
  /// anywhere else it becomes a new image frame at the drop point.
  void dropAsset(String assetId, Offset screen, CanvasController canvas) {
    final asset = _state.document.assets[assetId];
    if (asset == null || asset.kind != ir.AssetKind.image) return;
    final doc = _state.document;
    final index = ir.DocumentIndex.of(doc);
    final hits = canvas.overlay.hitTest(screen);
    final rootId = _state.activeScene?.root.id;
    for (final h in hits) {
      if (h.nodeId == rootId || h.nodeId.contains('/')) continue;
      final n = index.node(h.nodeId);
      if (n is ir.FrameNode || n is ir.ShapeNode || n is ir.VideoNode) {
        _ctl.setEditingBreakpoint(h.breakpointId);
        final r = _ctl.execute(SetImageFill([h.nodeId], assetId));
        if (!r.ok) _say(r.diagnostics.map((d) => d.message).join('\n'));
        return;
      }
    }
    insertImages([asset], screen: screen, canvas: canvas);
  }
}

/// The insert actions of the open editor.
final insertActionsProvider = Provider<InsertActions>(
  InsertActions.new,
  dependencies: [
    editorControllerProvider,
    editorAssetServiceProvider,
    editorFilePickerProvider,
  ],
);
