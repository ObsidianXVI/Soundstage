import '../diagnostics.dart';
import '../nodes/node.dart';
import '../tokens.dart';
import '../values/ir_value.dart';
import 'property_registry.dart';

/// Applies [patch] to [node] through the registry (architecture §3.1, §9).
///
/// - `IrValue.none()` clears a nullable property.
/// - A `tokenRef` value binds the path to that token (it is written to
///   `common.bindings`, and resolved with the other bindings).
/// - Any other value is written and removes a token binding on the exact
///   same path, so a patch detaches the property from its token at that
///   level (Figma: editing a bound value detaches the variable).
/// - Unknown and inapplicable paths are skipped and reported in
///   [diagnostics]; nothing throws.
///
/// [onApplied] is called with every path that was written.
Node applyPatch(
  Node node,
  Patch patch, {
  List<IrDiagnostic>? diagnostics,
  PropertyRegistry? registry,
  void Function(String path)? onApplied,
}) {
  final reg = registry ?? PropertyRegistry.standard;
  var n = node;
  for (final MapEntry(key: path, :value) in patch.entries) {
    final match = reg.lookup(path);
    if (match == null) {
      diagnostics?.add(
        IrDiagnostic(
          IrDiagnosticKind.unknownPath,
          'No property is registered at "$path".',
          nodeId: node.id,
          path: path,
        ),
      );
      continue;
    }
    if (value is TokenRefValue) {
      if (match.get(n) == null) {
        diagnostics?.add(_inapplicable(node.id, path));
        continue;
      }
      n = n.copyWith(
        common: n.common.copyWith(
          bindings: {...n.common.bindings, path: value.value},
        ),
      );
      onApplied?.call(path);
      continue;
    }
    final next = match.trySet(n, value);
    if (next == null) {
      diagnostics?.add(_inapplicable(node.id, path));
      continue;
    }
    n = next;
    if (n.common.bindings.containsKey(path)) {
      n = n.copyWith(
        common: n.common.copyWith(
          bindings: Map<String, TokenRef>.of(n.common.bindings)..remove(path),
        ),
      );
    }
    onApplied?.call(path);
  }
  return n;
}

IrDiagnostic _inapplicable(String nodeId, String path) => IrDiagnostic(
  IrDiagnosticKind.inapplicablePath,
  'Property "$path" does not exist on this node or the value has the wrong '
  'type.',
  nodeId: nodeId,
  path: path,
);
