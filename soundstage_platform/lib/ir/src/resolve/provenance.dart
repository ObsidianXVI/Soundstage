import 'package:freezed_annotation/freezed_annotation.dart';

import '../diagnostics.dart';
import '../values/ir_value.dart';

part 'provenance.freezed.dart';

/// The layer of the resolution pipeline a value came from (architecture
/// §11.3, §15). The inspector shows it as a value-source badge and uses it
/// for "reset to inherited".
@freezed
sealed class ProvenanceSource with _$ProvenanceSource {
  /// The node's own (shared base) value, authored in a scene or the overlay.
  const factory ProvenanceSource.base() = BaseSource;

  /// The value authored on a node of component [componentId] (a node
  /// inside an instance, or an instance's component root).
  const factory ProvenanceSource.componentDefault(String componentId) =
      ComponentDefaultSource;

  /// A breakpoint patch (`breakpointOverrides[breakpointId]`), one entry per
  /// patch along the active breakpoint's `inheritsFrom` chain.
  const factory ProvenanceSource.breakpointPatch(String breakpointId) =
      BreakpointPatchSource;

  /// A component property bound to this property
  /// (`componentBindings[path] = propId`), valued by instance [instanceId]
  /// (or the prop's default).
  const factory ProvenanceSource.componentBinding(
    String propId,
    String instanceId,
  ) = ComponentBindingSource;

  /// The instance's own value placed on its component root (geometry,
  /// visibility, opacity multiplied, …; see `Resolver`). Entries of the
  /// instance node's own chain (its base, patches, tokens) come right
  /// before it when the placement takes them over.
  const factory ProvenanceSource.instancePlacement(String instanceId) =
      InstancePlacementSource;

  /// An override patch of instance [instanceId] at inner path [innerPath]
  /// (`overrides[innerPath]`). Overrides of enclosing instances that reach
  /// into a nested one name the enclosing instance.
  const factory ProvenanceSource.instanceOverride(
    String instanceId,
    String innerPath,
  ) = InstanceOverrideSource;

  /// A token binding, resolved in mode [modeId] of the variable's
  /// collection (null when the variable is missing).
  const factory ProvenanceSource.token(String variableId, String? modeId) =
      TokenSource;

  /// The document's default text style (the base of every text cascade).
  const factory ProvenanceSource.documentDefault() = DocumentDefaultSource;

  /// A named text style (`textStyleId`).
  const factory ProvenanceSource.textStyle(String styleId) = TextStyleSource;

  /// A paint style (`fillStyleId` / `strokeStyleId`).
  const factory ProvenanceSource.paintStyle(String styleId) = PaintStyleSource;

  /// An effect style (`effectStyleId`).
  const factory ProvenanceSource.effectStyle(String styleId) =
      EffectStyleSource;

  /// A paragraph's own style (paragraph spacing, indent, list style).
  const factory ProvenanceSource.paragraphStyle(int paragraphIndex) =
      ParagraphStyleSource;

  /// An animated value from track [trackId]. Reserved for the runtime
  /// (M2), which appends it at the playhead; the IR never produces it.
  const factory ProvenanceSource.animated(String trackId) = AnimatedSource;
}

/// One layer's contribution: the value of the property after the layer
/// applied (for a layer that writes a containing value, e.g. a patch of
/// `fills` when asking about `fills.p.color`, the value at the asked path).
///
/// - `nodeId`: the authored node holding the layer, by its own (not
///   namespaced) id: the node with the patch, binding or base value, or the
///   instance for placement and overrides.
/// - `keys`: the layer's keys (patch paths, binding paths) that overlap the
///   asked path; what "reset" would remove. Empty for base values and
///   styles.
@freezed
abstract class ProvenanceEntry with _$ProvenanceEntry {
  const factory ProvenanceEntry({
    required ProvenanceSource source,
    required IrValue value,
    required String nodeId,
    @Default(<String>[]) List<String> keys,
  }) = _ProvenanceEntry;
}

/// How a resolved property got its value (`Resolver.explain`): the
/// contributing layers in pipeline order, lowest priority first, and the
/// final value.
///
/// `finalValue` agrees with the resolved document: it is
/// `resolvedPropertyValue(resolvedNode, path)`, null when the property
/// does not exist on the node. Two documented differences: text style
/// paths (`style.*`, `content.<p>.spans.<s>.style.*`) read the merged
/// cascade (document default ⊕ named style ⊕ node ⊕ paragraph ⊕ span),
/// and style references (`textStyleId`, `fillStyleId`, `strokeStyleId`,
/// `effectStyleId`), which the resolved tree clears once applied, report
/// the reference in effect. When `entries` is not empty its last value is
/// `finalValue`, except for nodes that failed to resolve (placeholders).
@freezed
abstract class Provenance with _$Provenance {
  const factory Provenance({
    required String nodeId,
    required String path,
    required List<ProvenanceEntry> entries,
    IrValue? finalValue,
    @Default(<IrDiagnostic>[]) List<IrDiagnostic> diagnostics,
  }) = _Provenance;
}
