import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:soundstage_platform/ir/ir.dart' as ir;
// Unprefixed for freezed's generated nested copyWith.
import 'package:soundstage_platform/ir/ir.dart' show $StageDocumentCopyWith;

import 'component_isolation.dart';

part 'editor_state.freezed.dart';

/// Where a `SetProperty` writes (architecture §15, DECISIONS 23/10/26).
///
/// - `both` (default): the shared base, clearing that path's patches on the
///   primary breakpoints, so every primary artboard shows the value.
/// - `thisBreakpoint`: a patch on the breakpoint of the edited artboard.
enum EditScope {
  both,
  thisBreakpoint;

  EditScope get flipped => this == both ? thisBreakpoint : both;
}

/// The active canvas tool. Insert tools land in T1.9.
enum EditorTool {
  move,
  hand,
  frame,
  text,
  rectangle,
  ellipse,
  polygon,
  star,
  line,
  image,
}

/// The undo/redo availability the toolbar shows.
@freezed
abstract class HistoryStatus with _$HistoryStatus {
  const factory HistoryStatus({
    @Default(false) bool canUndo,
    @Default(false) bool canRedo,
    String? undoLabel,
    String? redoLabel,
  }) = _HistoryStatus;
}

/// The editor's state (architecture §15): the document plus everything the
/// panels, canvas and inspector share. Camera (zoom/pan per artboard) and
/// panel layout are UI state and live with the canvas and shell.
///
/// - `selection`: selected node ids in selection order (a `LinkedHashSet`).
///   Ids are authored ids, or resolved `<instanceId>/<innerId>` ids inside
///   instances.
/// - `selectionContext`: the frame whose children a plain click selects
///   (Figma's selection level); null means the active scene's root.
/// - `textEditId`: the text node being edited in place, if any.
/// - `activeSceneId`, `editingBreakpointId`: the scene on the canvas and the
///   artboard (its primary breakpoint) being edited.
/// - `artboardWidths`: the free preview width of each artboard that is not
///   at its design width (mirrored from the canvas), so edits know the
///   breakpoint in effect there ([breakpointId]).
/// - `editScope` plus `scopeFlipped` (Alt held): see [effectiveScope].
/// - `autoKey`: a write to an animatable property that has no track
///   creates one, with a keyframe at the playhead (m2.md "Writing values
///   while animated").
/// - `playheads`: the playhead of each clock of each scene
///   (`sceneId → clockId → value`, in the clock's units). A clock without
///   one sits at 0 ([playheadOf]). Playheads are view state: changing one is
///   not an undoable edit.
/// - `selectedAudioTrackId`: the audio track selected in the Scene
///   settings' Audio list or the audio lane, shown by the inspector's Audio
///   view. It is a separate notion from [selection] (audio tracks are not
///   nodes): selecting a node, or changing scene, clears it, and so does
///   removing the track.
/// - `activeClocks`: the clock the timeline shows per scene
///   (`sceneId → clockId`); see [activeClockOf].
/// - `revision`: a number identifying the document version (never reused,
///   restored by undo/redo); `savedRevision` is the last saved one.
/// - `history`: what undo/redo would do.
@freezed
abstract class EditorState with _$EditorState {
  const factory EditorState({
    required ir.StageDocument document,

    /// Isolation mode (component_isolation.dart): [document] is then the
    /// view, and [storyDocument] the story.
    ComponentIsolation? isolation,
    @Default(<String>{}) Set<String> selection,
    String? selectionContext,
    String? textEditId,
    String? selectedAudioTrackId,
    String? hoverId,
    String? activeSceneId,
    String? editingBreakpointId,
    @Default(<String, double>{}) Map<String, double> artboardWidths,
    @Default(EditScope.both) EditScope editScope,
    @Default(false) bool scopeFlipped,
    @Default(EditorTool.move) EditorTool tool,
    @Default(false) bool autoKey,
    @Default(<String, Map<String, double>>{})
    Map<String, Map<String, double>> playheads,
    @Default(<String, String>{}) Map<String, String> activeClocks,
    @Default(0) int revision,
    @Default(0) int savedRevision,
    @Default(HistoryStatus()) HistoryStatus history,
  }) = _EditorState;

  const EditorState._();

  /// A state for [document]: its first scene active and its first primary
  /// breakpoint (else the first) edited.
  factory EditorState.initial(ir.StageDocument document) => EditorState(
    document: document,
    activeSceneId: document.scenes.isEmpty ? null : document.scenes.first.id,
    editingBreakpointId: defaultBreakpointId(document),
  );

  /// The story: [document], or while isolated the view folded back. What is
  /// saved, previewed and exported.
  ir.StageDocument get storyDocument {
    final iso = isolation;
    return iso == null ? document : foldIsolation(document, iso);
  }

  /// The scope the next edit uses: [editScope], flipped while Alt is held.
  EditScope get effectiveScope => scopeFlipped ? editScope.flipped : editScope;

  /// Whether the document differs from the last saved revision.
  bool get isDirty => revision != savedRevision;

  /// The active scene, or null.
  ir.Scene? get activeScene {
    for (final s in document.scenes) {
      if (s.id == activeSceneId) return s;
    }
    return null;
  }

  /// The edited artboard (its primary breakpoint's id):
  /// [editingBreakpointId] when it exists, else the document's default.
  String? get artboardId {
    final id = editingBreakpointId;
    if (id != null && document.breakpoints.any((b) => b.id == id)) return id;
    return defaultBreakpointId(document);
  }

  /// The breakpoint in effect on the edited artboard, which edits, the
  /// inspector and provenance use (DECISIONS wave D: "what you edit is what
  /// you see"): the artboard's own breakpoint at its design width, else the
  /// breakpoint its free width falls in.
  String? get breakpointId => effectiveBreakpointOf(artboardId);

  /// The breakpoint in effect on the artboard of [artboardId] (see
  /// [breakpointId]).
  String? effectiveBreakpointOf(String? artboardId) {
    if (artboardId == null) return null;
    final w = artboardWidths[artboardId];
    if (w == null) return artboardId;
    return ir.breakpointForWidth(document, w)?.id ?? artboardId;
  }

  /// Ids of the primary breakpoints (the side-by-side artboards).
  Set<String> get primaryBreakpointIds => {
    for (final b in document.primaryBreakpoints) b.id,
  };

  /// The playheads of scene [sceneId] (`clockId → value`; absent clocks
  /// are at 0). This map is what the canvas freezes the scene's clocks at.
  Map<String, double> clockValuesOf(String? sceneId) =>
      playheads[sceneId] ?? const <String, double>{};

  /// The playhead of clock [clockId] of scene [sceneId] (0 when unset).
  double playheadOf(String? sceneId, String clockId) =>
      playheads[sceneId]?[clockId] ?? 0;

  /// The clock the timeline shows for scene [sceneId]: the one chosen in
  /// [activeClocks] while the scene still has it, else the scene's own
  /// scroll clock (m2.md "Playheads"), else its first clock. Null for a
  /// scene without clocks.
  String? activeClockOf(String? sceneId) {
    ir.Scene? scene;
    for (final s in document.scenes) {
      if (s.id == sceneId) scene = s;
    }
    if (scene == null || scene.clocks.isEmpty) return null;
    final chosen = activeClocks[sceneId];
    if (chosen != null && scene.clocks.any((c) => c.id == chosen)) {
      return chosen;
    }
    for (final c in scene.clocks) {
      if (c is ir.SceneScrollClock && c.sceneId == scene.id) return c.id;
    }
    return scene.clocks.first.id;
  }

  /// The active scene's active clock (see [activeClockOf]).
  String? get activeClockId => activeClockOf(activeSceneId);

  /// The playhead of the active scene's active clock (0 when unset).
  double get playhead {
    final clock = activeClockId;
    return clock == null ? 0 : playheadOf(activeSceneId, clock);
  }
}

/// The first primary breakpoint of [doc], else its first breakpoint.
String? defaultBreakpointId(ir.StageDocument doc) {
  for (final b in doc.breakpoints) {
    if (b.primary) return b.id;
  }
  return doc.breakpoints.isEmpty ? null : doc.breakpoints.first.id;
}
