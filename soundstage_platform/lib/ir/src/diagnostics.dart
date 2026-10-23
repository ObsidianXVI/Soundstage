import 'package:freezed_annotation/freezed_annotation.dart';

part 'diagnostics.freezed.dart';

/// What went wrong in a non-fatal IR operation.
enum IrDiagnosticKind {
  /// No descriptor matches the path.
  unknownPath,

  /// The path exists but not on this node (wrong kind, missing paint or
  /// effect id, index out of range), or the value has the wrong type.
  inapplicablePath,
  missingBreakpoint,
  missingComponent,
  missingVariant,
  missingComponentProp,
  componentCycle,
  missingToken,
  tokenCycle,
  missingMode,
  missingStyle,
  missingAsset,
  missingTrackTarget,

  // Validator (`validateDocument`) kinds.
  /// A node id is used twice (document-wide, or within one component).
  duplicateNodeId,

  /// Another id (breakpoint, scene, clock, track, keyframe, variable, mode,
  /// audio track, interaction, paint or effect) is used twice in its scope.
  duplicateId,

  /// A map entry's key differs from the `id` of its value.
  idMismatch,
  missingVariantSet,
  missingFont,
  missingClock,
  missingAudioTrack,
  missingScene,
  missingNode,

  /// A referenced asset exists but has the wrong kind.
  wrongAssetKind,

  /// A value is outside its meaningful range (e.g. a scene's `posterClock`
  /// outside 0–1).
  invalidValue,

  /// The document could not be parsed at all (`loadDocument`).
  invalidDocument,

  /// A line of an LRC lyrics file could not be parsed (`parseLrc`).
  invalidLyrics,
}

/// How serious a diagnostic is. Errors make a document unsafe to publish;
/// warnings are tolerated by the resolver and runtime.
enum IrSeverity { error, warning }

/// A non-fatal problem found while patching or resolving a document. The
/// editor often holds temporarily broken documents, so operations report
/// these instead of throwing.
///
/// `nodeId` is the (namespaced) node the problem is on; `path` is the
/// property path or reference involved.
@freezed
abstract class IrDiagnostic with _$IrDiagnostic {
  const factory IrDiagnostic(
    IrDiagnosticKind kind,
    String message, {
    String? nodeId,
    String? path,
    @Default(IrSeverity.error) IrSeverity severity,

    /// Where in the document the problem is, e.g.
    /// `scenes[0].root.children[2].common.interactions[0]`. Set by the
    /// validator.
    String? location,
  }) = _IrDiagnostic;

  const IrDiagnostic._();

  /// A stable machine-readable code (the kind's name).
  String get code => kind.name;
}
