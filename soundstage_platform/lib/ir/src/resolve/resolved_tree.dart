import 'package:freezed_annotation/freezed_annotation.dart';

import '../breakpoint.dart';
import '../diagnostics.dart';
import '../motion.dart';
import '../nodes/node.dart';
import '../nodes/paint.dart';
import '../nodes/text.dart';
import '../scene.dart';
import '../values/ir_value.dart';

part 'resolved_tree.freezed.dart';

/// What to resolve a document for (architecture §11.3).
///
/// - `breakpointId` wins over `viewportWidth`; with neither, the base
///   breakpoint is used.
/// - `modeState`: `{ collectionId: modeId }` — interaction state (M3). It has
///   the highest mode priority (§8).
/// - `variableState`: `{ variableId: IrValue }` — variable values set by
///   interactions (M3); they replace the variable's value in every mode.
@freezed
abstract class ResolveContext with _$ResolveContext {
  const factory ResolveContext({
    double? viewportWidth,
    String? breakpointId,
    @Default(<String, String>{}) Map<String, String> modeState,
    @Default(<String, IrValue>{}) Map<String, IrValue> variableState,
  }) = _ResolveContext;
}

/// A text span with its fully merged style.
@freezed
abstract class ResolvedSpan with _$ResolvedSpan {
  const factory ResolvedSpan({
    required String text,

    /// Document default ⊕ named text style ⊕ node override ⊕ paragraph style ⊕
    /// span override,
    /// with tokens resolved. Complete: the runtime never merges styles.
    required TextStyle style,
    SpanLink? link,
  }) = _ResolvedSpan;
}

/// A paragraph with its paragraph-level settings resolved (paragraph style
/// over the node's).
@freezed
abstract class ResolvedParagraph with _$ResolvedParagraph {
  const factory ResolvedParagraph({
    required List<ResolvedSpan> spans,
    required TextAlignHorizontal alignHorizontal,
    required double paragraphSpacing,
    required double paragraphIndent,
    required ListStyle listStyle,
  }) = _ResolvedParagraph;
}

/// A node of the resolved tree: concrete values only (architecture §11.3).
///
/// - `id`: the namespaced id. Plain nodes keep their id; nodes inside an
///   instance are `<instanceId>/<innerId>`, recursively for nested
///   instances. An instance resolves to its component's root frame under
///   the instance's own id.
/// - `node`: the concrete node, never an `InstanceNode`. `node.id == id`.
///   Breakpoint overrides, token and component bindings and style ids are
///   cleared, every token and style is applied, and `FrameNode.children` is
///   always empty: the children are in [children].
/// - `sourceComponentId`: the component the node was instantiated from;
///   null outside instances.
/// - `instanceId`: the namespaced id of the innermost instance the node
///   belongs to (its own id for an instance root); null outside instances.
/// - `paragraphs`: text nodes only — every span with its merged style.
///   `(node as TextNode).style` is the merged base style.
/// - `modes`: the active mode per variable collection at this node.
/// - `isPlaceholder`: the node stands in for something that failed to
///   resolve (missing component, component cycle); there is a diagnostic.
///   The editor shows it, the player skips it (§17.2).
@freezed
abstract class ResolvedNode with _$ResolvedNode {
  const factory ResolvedNode({
    required String id,
    required Node node,
    @Default(<ResolvedNode>[]) List<ResolvedNode> children,
    String? sourceComponentId,
    String? instanceId,
    List<ResolvedParagraph>? paragraphs,
    @Default(<String, String>{}) Map<String, String> modes,
    @Default(false) bool isPlaceholder,
  }) = _ResolvedNode;
}

/// A resolved scene. `tracks` only holds tracks that apply at the active
/// breakpoint and whose target and property exist; each `Track.target` is
/// the namespaced node id (a key of the scene's nodes in
/// `ResolvedDocument.nodeIndex`) and keyframes are concrete and sorted by
/// `t`.
@freezed
abstract class ResolvedScene with _$ResolvedScene {
  const factory ResolvedScene({
    required String id,
    required String name,
    required SceneKind kind,
    required double scrollLength,
    required ResolvedNode root,
    required List<Clock> clocks,
    required List<Track> tracks,
    required List<Paint> background,
    required SceneTransition transitionIn,

    /// Active modes at the scene level.
    required Map<String, String> modes,
    @Default(SceneExportMode.auto) SceneExportMode exportAs,
    double? posterClock,
  }) = _ResolvedScene;
}

/// The output of resolution (architecture §11.3 steps 2–5): concrete values
/// only — no instances, bindings, breakpoint overrides, token refs or style
/// refs.
///
/// `nodeIndex` maps every namespaced id (all scenes and the overlay) to its
/// node. `breakpoint` is null only for a document without breakpoints.
@freezed
abstract class ResolvedDocument with _$ResolvedDocument {
  const factory ResolvedDocument({
    required Breakpoint? breakpoint,
    required List<ResolvedScene> scenes,
    required ResolvedNode? overlay,
    required Map<String, ResolvedNode> nodeIndex,
    required List<IrDiagnostic> diagnostics,
  }) = _ResolvedDocument;
}
