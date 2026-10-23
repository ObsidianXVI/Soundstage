import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import 'inspector_providers.dart';

/// The inspector's write path for one selection: every control writes
/// through here, so scope routing, the Alt flip and gesture coalescing are
/// uniform.
///
/// - Writes are [SetProperty] commands over the selected ids, routed by the
///   toolbar's edit scope (Both / This breakpoint). Holding Alt flips the
///   scope for the edit; inside a scrub gesture it does not (Alt already
///   means "fine" there).
/// - A scrub or drag is bracketed by [beginGesture] / [endGesture]: the
///   commands share a coalescing key, so the whole gesture is one undo step.
class PropertyWriter {
  PropertyWriter(this.controller, this.readState, List<String> ids)
    : ids = List.unmodifiable(ids);

  final EditorController controller;

  /// The current editor state (`ref.read(editorControllerProvider)`).
  final EditorState Function() readState;
  final List<String> ids;
  int _gestures = 0;

  bool get inGesture => _gestures > 0;

  void beginGesture() {
    _gestures++;
    controller.beginGesture();
  }

  void endGesture() {
    if (_gestures == 0) return;
    _gestures--;
    controller.endGesture();
  }

  /// Runs [body] with the scope the next edit uses: flipped while Alt is
  /// down (and not mid-gesture), forced to the shared base for [shared]
  /// (names, roles and alt text are not per breakpoint).
  T _scoped<T>(bool shared, T Function() body) {
    final s = readState();
    final prevScope = s.editScope;
    final prevFlipped = s.scopeFlipped;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final flipped = shared ? false : (inGesture ? false : (prevFlipped || alt));
    final scope = shared ? EditScope.both : prevScope;
    if (scope != prevScope) controller.setEditScope(scope);
    if (flipped != prevFlipped) controller.setScopeFlipped(flipped);
    try {
      return body();
    } finally {
      if (flipped != prevFlipped) controller.setScopeFlipped(prevFlipped);
      if (scope != prevScope) controller.setEditScope(prevScope);
    }
  }

  /// Runs [command] with the scoping rules above.
  CommandResult run(EditCommand command, {bool shared = false}) =>
      _scoped(shared, () => controller.execute(command));

  /// Writes [value] at [path] on every selected node.
  CommandResult set(String path, ir.IrValue value, {bool shared = false}) =>
      run(SetProperty(ids, path, value), shared: shared);

  /// Writes several paths at once (one undo step), the same on every node.
  CommandResult setMany(
    Map<String, ir.IrValue> values, {
    bool shared = false,
  }) => run(
    SetProperty.values({
      for (final id in ids) id: Map<String, ir.IrValue>.of(values),
    }),
    shared: shared,
  );

  /// Resets [path] to what it inherits (see [ResetProperty]).
  CommandResult reset(String path) => controller.resetProperty(path, ids);

  /// Resets every path of [paths].
  void resetAll(Iterable<String> paths) {
    for (final p in paths) {
      controller.resetProperty(p, ids);
    }
  }
}

/// Provides the selection's ids and [PropertyWriter] to the controls below.
/// Dependents rebuild only when the id list changes.
class InspectorScope extends InheritedWidget {
  const InspectorScope({
    required this.selection,
    required this.writer,
    required super.child,
    super.key,
  });

  final IdList selection;
  final PropertyWriter writer;

  List<String> get ids => selection.ids;

  static InspectorScope of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<InspectorScope>();
    assert(s != null, 'No InspectorScope above this control.');
    return s!;
  }

  @override
  bool updateShouldNotify(InspectorScope old) => old.selection != selection;
}
