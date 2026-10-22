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
}

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
  }) = _IrDiagnostic;
}
