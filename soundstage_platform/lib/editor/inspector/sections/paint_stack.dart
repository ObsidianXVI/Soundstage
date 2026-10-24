import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';
import 'paint_row.dart';

// The paint stack shared by Fill (`fills`) and Stroke (`strokes.paints`).
//
// - The stack is shown top paint first (the IR is bottom → top).
// - Structural edits (add, remove, reorder, kind switch, replace) write the
//   whole list at the stack path: one undo step each.
// - Field edits write per-paint paths (`<stack>.<paintId>.<field>`), so
//   Mixed, scrub coalescing and value-source badges work per field.

// ---- Kinds and conversions ---------------------------------------------------

/// The paint kinds the kind switcher offers.
enum PaintKindChoice { solid, linear, radial, angular, diamond, image }

const Map<PaintKindChoice, String> kPaintKindLabels = {
  PaintKindChoice.solid: 'Solid',
  PaintKindChoice.linear: 'Linear',
  PaintKindChoice.radial: 'Radial',
  PaintKindChoice.angular: 'Angular',
  PaintKindChoice.diamond: 'Diamond',
  PaintKindChoice.image: 'Image',
};

PaintKindChoice paintKindOf(ir.Paint p) => switch (p) {
  ir.SolidPaint() => PaintKindChoice.solid,
  ir.GradientPaint(:final kind) => switch (kind) {
    ir.GradientKind.linear => PaintKindChoice.linear,
    ir.GradientKind.radial => PaintKindChoice.radial,
    ir.GradientKind.angular => PaintKindChoice.angular,
    ir.GradientKind.diamond => PaintKindChoice.diamond,
  },
  ir.ImagePaint() => PaintKindChoice.image,
};

ir.GradientKind? _gradientKindOf(PaintKindChoice k) => switch (k) {
  PaintKindChoice.linear => ir.GradientKind.linear,
  PaintKindChoice.radial => ir.GradientKind.radial,
  PaintKindChoice.angular => ir.GradientKind.angular,
  PaintKindChoice.diamond => ir.GradientKind.diamond,
  _ => null,
};

/// Figma's default paint colours: #D9D9D9 fills, black strokes.
ir.StageColor defaultPaintColor(String stackPath) =>
    stackPath.startsWith('strokes')
    ? ir.StageColor.black
    : ir.StageColor.fromHex('#D9D9D9');

/// The paint that "+" adds.
ir.Paint defaultPaint(String stackPath, String id) =>
    ir.Paint.solid(id: id, color: defaultPaintColor(stackPath));

/// [p] converted to [kind], keeping its id, visibility, opacity and blend:
///
/// - solid → gradient: the colour to the same colour, transparent (Figma);
/// - gradient → gradient: stops and handles are kept;
/// - anything → solid: the first stop's colour (an image: the default);
/// - anything → image: an empty image paint (asset chosen afterwards).
ir.Paint convertPaint(ir.Paint p, PaintKindChoice kind, String stackPath) {
  if (paintKindOf(p) == kind) return p;
  final grad = _gradientKindOf(kind);
  switch (kind) {
    case PaintKindChoice.solid:
      final color = switch (p) {
        ir.SolidPaint(:final color) => color,
        ir.GradientPaint(:final stops) when stops.isNotEmpty =>
          stops.first.color,
        _ => defaultPaintColor(stackPath),
      };
      return ir.Paint.solid(
        id: p.id,
        color: color,
        visible: p.visible,
        opacity: p.opacity,
        blendMode: p.blendMode,
      );
    case PaintKindChoice.image:
      return ir.Paint.image(
        id: p.id,
        assetId: '',
        visible: p.visible,
        opacity: p.opacity,
        blendMode: p.blendMode,
      );
    case PaintKindChoice.linear ||
        PaintKindChoice.radial ||
        PaintKindChoice.angular ||
        PaintKindChoice.diamond:
      if (p is ir.GradientPaint) return p.copyWith(kind: grad!);
      final c = p is ir.SolidPaint ? p.color : defaultPaintColor(stackPath);
      return ir.Paint.gradient(
        id: p.id,
        kind: grad!,
        stops: [
          ir.ColorStop(position: 0, color: c),
          ir.ColorStop(position: 1, color: c.withAlpha(0)),
        ],
        visible: p.visible,
        opacity: p.opacity,
        blendMode: p.blendMode,
      );
  }
}

/// A new paint id, unique in [doc] and deterministic for a given document
/// (a seeded generator over the document's ids: no clock, no entropy).
String freshPaintId(ir.StageDocument doc) =>
    ir.IdGenerator.forDocument(doc, random: math.Random(0)).next();

/// The style-reference path for a stack path, or null when the stack has
/// none (text fills).
String? styleIdPathFor(String stackPath) => switch (stackPath) {
  'fills' => 'fillStyleId',
  'strokes.paints' => 'strokeStyleId',
  _ => null,
};

// ---- Providers ---------------------------------------------------------------

/// The structure of a stack across the selection: which paint ids it has,
/// in IR order. Rebuilds the list only when ids are added, removed or
/// moved, not when a paint's fields change.
@immutable
class PaintStackShape {
  const PaintStackShape({
    this.exists = false,
    this.mixed = false,
    this.ids = const [],
  });

  final bool exists;

  /// The selected nodes' stacks differ.
  final bool mixed;

  /// Paint ids bottom → top.
  final List<String> ids;

  @override
  bool operator ==(Object other) =>
      other is PaintStackShape &&
      other.exists == exists &&
      other.mixed == mixed &&
      listEquals(other.ids, ids);

  @override
  int get hashCode => Object.hash(exists, mixed, Object.hashAll(ids));
}

/// The shape of [r] (a reading of a stack path).
PaintStackShape paintStackShapeOf(PropertyReading r) {
  if (!r.exists) return const PaintStackShape();
  if (r.mixed) return const PaintStackShape(exists: true, mixed: true);
  final v = r.value;
  return PaintStackShape(
    exists: true,
    ids: v is ir.PaintsValue ? [for (final p in v.value) p.id] : const [],
  );
}

/// Watches the shape of [stackPath] for the selection.
PaintStackShape watchStackShape(WidgetRef ref, String stackPath) => ref.watch(
  selectedNodesProvider.select((s) => paintStackShapeOf(s.read(stackPath))),
);

/// The paint style the selection's authored nodes reference at
/// [ReadKey.path] (`fillStyleId` / `strokeStyleId`). The resolved tree has
/// style ids cleared, so this reads the authored document.
@immutable
class PaintStyleRef {
  const PaintStyleRef({this.styleId, this.name, this.mixed = false});

  static const PaintStyleRef none = PaintStyleRef();

  /// The shared style id, when every node references the same one.
  final String? styleId;

  /// The style's name (its id when the style is missing).
  final String? name;

  /// Some nodes reference a style and others another (or none).
  final bool mixed;

  bool get applied => styleId != null && !mixed;

  @override
  bool operator ==(Object other) =>
      other is PaintStyleRef &&
      other.styleId == styleId &&
      other.name == name &&
      other.mixed == mixed;

  @override
  int get hashCode => Object.hash(styleId, name, mixed);
}

/// The style reference at [stylePath] across [s]'s authored nodes.
PaintStyleRef paintStyleRefOf(SelectedNodes s, String stylePath) {
  String? common;
  var first = true;
  for (final n in s.authored) {
    final style = switch (n) {
      ir.FrameNode(:final appearance) ||
      ir.ShapeNode(:final appearance) ||
      ir.VideoNode(:final appearance) =>
        stylePath == 'fillStyleId'
            ? appearance.fillStyleId
            : appearance.strokeStyleId,
      ir.TextNode(:final appearance) =>
        stylePath == 'strokeStyleId' ? appearance.strokeStyleId : null,
      _ => null,
    };
    if (first) {
      common = style;
      first = false;
    } else if (style != common) {
      return const PaintStyleRef(mixed: true);
    }
  }
  if (common == null) return PaintStyleRef.none;
  return PaintStyleRef(
    styleId: common,
    name: s.document.tokens.paintStyles[common]?.name ?? common,
  );
}

/// Watches the paint style applied to [stackPath] (none for text fills).
PaintStyleRef watchStackStyle(WidgetRef ref, String stackPath) {
  final stylePath = styleIdPathFor(stackPath);
  if (stylePath == null) return PaintStyleRef.none;
  return ref.watch(
    selectedNodesProvider.select((s) => paintStyleRefOf(s, stylePath)),
  );
}

/// The current stack (IR order) of the selection at the edited breakpoint,
/// or null when it is mixed or absent.
List<ir.Paint>? readStack(WidgetRef ref, List<String> ids, String stackPath) {
  final r = ref.read(selectedNodesProvider).read(stackPath);
  final v = r.value;
  if (r.mixed || v is! ir.PaintsValue) return null;
  return v.value;
}

// ---- Local UI state ------------------------------------------------------------

/// What the stack editor remembers while it is shown: expanded rows, the
/// selected gradient stop per paint and the image "Adjustments" disclosure.
class PaintUiState extends ChangeNotifier {
  final Set<String> _expanded = {};
  final Map<String, int> _stops = {};
  bool _adjustments = false;

  bool isExpanded(String paintId) => _expanded.contains(paintId);

  void toggle(String paintId) {
    if (!_expanded.remove(paintId)) _expanded.add(paintId);
    notifyListeners();
  }

  void expand(String paintId) {
    if (_expanded.add(paintId)) notifyListeners();
  }

  int selectedStop(String paintId) => _stops[paintId] ?? 0;

  void selectStop(String paintId, int index) {
    if (_stops[paintId] == index) return;
    _stops[paintId] = index;
    notifyListeners();
  }

  bool get adjustmentsOpen => _adjustments;

  set adjustmentsOpen(bool open) {
    if (_adjustments == open) return;
    _adjustments = open;
    notifyListeners();
  }
}

/// Provides [PaintUiState] to the rows of one stack editor.
class PaintUi extends InheritedNotifier<PaintUiState> {
  const PaintUi({
    required PaintUiState super.notifier,
    required super.child,
    super.key,
  });

  static PaintUiState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaintUi>()!.notifier!;
}

// ---- The editor ------------------------------------------------------------------

/// The paint-stack editor shared by Fill (`stackPath: 'fills'`) and Stroke
/// (`stackPath: 'strokes.paints'`): rows with visibility, kind switcher,
/// colour/opacity, blend mode, remove and reorder, gradient stops and the
/// image-paint editor.
///
/// While the stack comes from a paint style the style's paints are shown
/// dimmed and read-only (the section shows the "Style:" banner and Detach).
class PaintStackEditor extends ConsumerStatefulWidget {
  const PaintStackEditor({
    required this.stackPath,
    this.allowImage = true,
    super.key,
  });

  /// The registry path of the paint list.
  final String stackPath;

  /// Whether the image kind is offered (strokes cannot take image paints
  /// for dashed/round-join strokes; the Stroke section decides).
  final bool allowImage;

  @override
  ConsumerState<PaintStackEditor> createState() => _PaintStackEditorState();
}

class _PaintStackEditorState extends ConsumerState<PaintStackEditor> {
  final PaintUiState _ui = PaintUiState();

  @override
  void dispose() {
    _ui.dispose();
    super.dispose();
  }

  void _reorder(int from, int target) {
    // Display indices (top first); [target] is the final index.
    final scope = InspectorScope.of(context);
    final stack = readStack(ref, scope.ids, widget.stackPath);
    if (stack == null) return;
    final display = stack.reversed.toList();
    if (target == from || target < 0 || target >= display.length) return;
    final p = display.removeAt(from);
    display.insert(target, p);
    scope.writer.set(
      widget.stackPath,
      ir.IrValue.paints(display.reversed.toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = InspectorScope.of(context);
    final shape = watchStackShape(ref, widget.stackPath);
    final style = watchStackStyle(ref, widget.stackPath);
    if (!shape.exists) return const SizedBox.shrink();
    if (shape.mixed || style.mixed) {
      return PaintStackMixedRow(stackPath: widget.stackPath);
    }
    if (shape.ids.isEmpty) return const SizedBox.shrink();
    final locked = style.applied;
    final display = shape.ids.reversed.toList();
    final count = display.length;
    Widget row(int i) => PaintRow(
      key: ValueKey<String>('paint:${display[i]}'),
      stackPath: widget.stackPath,
      paintId: display[i],
      displayIndex: i,
      count: count,
      allowImage: widget.allowImage,
      locked: locked,
      onMove: (delta) => _reorder(i, i + delta),
    );
    return PaintUi(
      notifier: _ui,
      child: Padding(
        padding: const EdgeInsets.only(bottom: SsSpace.s1),
        child: ReorderableListView(
          key: ValueKey<String>('paint-stack:${widget.stackPath}'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          padding: EdgeInsets.zero,
          // The dragged row is built in the overlay: give it the scope.
          proxyDecorator: (child, index, animation) => InspectorScope(
            selection: scope.selection,
            writer: scope.writer,
            child: PaintUi(
              notifier: _ui,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.ss.colors.surface2,
                  borderRadius: SsRadius.brSm,
                ),
                child: child,
              ),
            ),
          ),
          onReorderItem: locked ? (_, _) {} : _reorder,
          children: [for (var i = 0; i < count; i++) row(i)],
        ),
      ),
    );
  }
}

/// The single muted row shown when the selected nodes' stacks differ.
class PaintStackMixedRow extends ConsumerWidget {
  const PaintStackMixedRow({required this.stackPath, super.key});

  final String stackPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    return Padding(
      key: const ValueKey<String>('paint-stack-mixed'),
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: SizedBox(
        height: SsSpace.controlHeight,
        child: Row(
          children: [
            const SizedBox(width: 14),
            const SsColorSwatch(color: Color(0x00000000), mixed: true),
            const SizedBox(width: SsSpace.s2),
            Expanded(
              child: Text(
                'Mixed',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.text.small.copyWith(color: t.colors.textSecondary),
              ),
            ),
            SsButton(
              key: const ValueKey<String>('paint-stack-replace'),
              label: 'Replace',
              variant: SsButtonVariant.ghost,
              onPressed: () => replaceWithDefault(context, ref, stackPath),
            ),
          ],
        ),
      ),
    );
  }
}

/// Writes one default paint as the whole stack of every selected node.
void replaceWithDefault(BuildContext context, WidgetRef ref, String stack) {
  final w = InspectorScope.of(context).writer;
  final doc = ref.read(editorControllerProvider).document;
  w.set(stack, ir.IrValue.paints([defaultPaint(stack, freshPaintId(doc))]));
}

/// The "+" button for a section header: appends a default paint on top of
/// the stack at [stackPath] (Figma: #D9D9D9 for fills, black for strokes).
/// On a mixed selection it replaces every stack with that one paint.
class AddPaintButton extends ConsumerWidget {
  const AddPaintButton({required this.stackPath, super.key});

  final String stackPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final shape = watchStackShape(ref, stackPath);
    final style = watchStackStyle(ref, stackPath);
    final label = stackPath == 'fills' ? 'Add fill' : 'Add paint';
    return SsIconButton(
      key: ValueKey<String>('add-paint:$stackPath'),
      icon: SsIcons.plus,
      semanticLabel: label,
      tooltip: label,
      size: 24,
      iconSize: 14,
      onPressed: !shape.exists || style.applied
          ? null
          : () {
              if (shape.mixed || style.mixed) {
                replaceWithDefault(context, ref, stackPath);
                return;
              }
              final stack = readStack(ref, scope.ids, stackPath) ?? const [];
              final doc = ref.read(editorControllerProvider).document;
              scope.writer.set(
                stackPath,
                ir.IrValue.paints([
                  ...stack,
                  defaultPaint(stackPath, freshPaintId(doc)),
                ]),
              );
            },
    );
  }
}
