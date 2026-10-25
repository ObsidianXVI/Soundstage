import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart' show stageColor;
import 'package:soundstage_platform/runtime/src/paint/gradient.dart'
    show diamondMesh, gradientShader;

import '../../canvas/canvas_controller.dart';
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../property_writer.dart';
import 'paint_gradient_editor.dart';
import 'paint_image_editor.dart';
import 'paint_stack.dart';

// One paint of a stack: the 28 px row and, when expanded, its editor.

/// Blend modes offered for a paint (pass-through is a frame layer mode).
const List<EnumOption> kPaintBlendOptions = [
  EnumOption('normal', 'Normal'),
  EnumOption('darken', 'Darken'),
  EnumOption('multiply', 'Multiply'),
  EnumOption('colorBurn', 'Color burn'),
  EnumOption('lighten', 'Lighten'),
  EnumOption('screen', 'Screen'),
  EnumOption('colorDodge', 'Color dodge'),
  EnumOption('overlay', 'Overlay'),
  EnumOption('softLight', 'Soft light'),
  EnumOption('hardLight', 'Hard light'),
  EnumOption('difference', 'Difference'),
  EnumOption('exclusion', 'Exclusion'),
  EnumOption('hue', 'Hue'),
  EnumOption('saturation', 'Saturation'),
  EnumOption('color', 'Color'),
  EnumOption('luminosity', 'Luminosity'),
];

/// Replaces paint [id] of the stack by `edit(paint)` (whole-list write, one
/// undo step). [edit] returning null removes the paint.
void editStackPaint(
  BuildContext context,
  WidgetRef ref,
  String stackPath,
  String id,
  ir.Paint? Function(ir.Paint p) edit,
) {
  final scope = InspectorScope.of(context);
  final stack = readStack(ref, scope.ids, stackPath);
  if (stack == null) return;
  final next = <ir.Paint>[];
  for (final p in stack) {
    if (p.id != id) {
      next.add(p);
      continue;
    }
    final e = edit(p);
    if (e != null) next.add(e);
  }
  scope.writer.set(stackPath, ir.IrValue.paints(next));
}

/// One paint row: drag handle (tap: options menu), swatch (tap: expand),
/// hex or kind, opacity, visibility and remove.
class PaintRow extends ConsumerWidget {
  const PaintRow({
    required this.stackPath,
    required this.paintId,
    required this.displayIndex,
    required this.count,
    required this.allowImage,
    required this.locked,
    required this.onMove,
    super.key,
  });

  final String stackPath;
  final String paintId;

  /// Position in the displayed (top-first) list.
  final int displayIndex;
  final int count;
  final bool allowImage;

  /// The stack comes from a paint style: shown dimmed, not editable.
  final bool locked;

  /// Moves the paint up (-1) or down (+1) in the displayed list.
  final ValueChanged<int> onMove;

  String get _path => '$stackPath.$paintId';

  List<SsMenuEntry> _menu(BuildContext context, WidgetRef ref) => [
    SsMenuItem(
      label: 'Move up',
      icon: SsIcons.arrowUp,
      enabled: displayIndex > 0,
      onSelected: () => onMove(-1),
    ),
    SsMenuItem(
      label: 'Move down',
      icon: SsIcons.arrowDown,
      enabled: displayIndex < count - 1,
      onSelected: () => onMove(1),
    ),
    const SsMenuDivider(),
    SsMenuItem(
      label: 'Remove',
      icon: SsIcons.minus,
      onSelected: () =>
          editStackPaint(context, ref, stackPath, paintId, (_) => null),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, _path);
    final value = r.value;
    if (value is! ir.PaintValue) return const SizedBox.shrink();
    final paint = value.value;
    final uiState = PaintUi.of(context);
    final expanded = uiState.isExpanded(paintId);
    final c = context.ss.colors;
    final kind = paintKindOf(paint);

    final grip = Builder(
      builder: (gripContext) => ReorderableDragStartListener(
        index: displayIndex,
        enabled: !locked,
        child: SsTooltip(
          message: 'Drag to reorder; click for options',
          child: Semantics(
            button: true,
            label: 'Paint options',
            onTap: locked
                ? null
                : () => showSsMenu(
                    gripContext,
                    anchor: ssGlobalRect(gripContext),
                    entries: _menu(context, ref),
                  ),
            child: GestureDetector(
              key: ValueKey<String>('paint-menu:$paintId'),
              behavior: HitTestBehavior.opaque,
              onTap: locked
                  ? null
                  : () => showSsMenu(
                      gripContext,
                      anchor: ssGlobalRect(gripContext),
                      entries: _menu(context, ref),
                    ),
              child: MouseRegion(
                cursor: locked
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.grab,
                child: SizedBox(
                  width: 12,
                  height: SsSpace.controlHeight,
                  child: Center(
                    child: SsIcon(
                      SsIcons.gripVertical,
                      size: 12,
                      color: c.textDisabled,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final middle = kind == PaintKindChoice.solid
        ? PaintHexField(path: '$_path.color', enabled: !locked)
        : PaintKindDropdown(
            stackPath: stackPath,
            paintId: paintId,
            paint: paint,
            allowImage: allowImage,
            enabled: !locked,
          );

    final line = SizedBox(
      key: ValueKey<String>('paint-row:$paintId'),
      height: SsSpace.controlHeight,
      child: Row(
        children: [
          grip,
          const SizedBox(width: 2),
          Opacity(
            opacity: paint.visible ? 1 : 0.5,
            child: _SwatchDoubleClick(
              // Double-clicking a gradient's swatch edits it on the canvas.
              onDoubleClick: paint is ir.GradientPaint && !locked
                  ? () {
                      final node = gradientEditNodeId(context);
                      if (node == null) return;
                      uiState.expand(paintId);
                      ref
                          .read(canvasControllerProvider)
                          .toggleGradientEdit(
                            GradientEditTarget(node, stackPath, paintId),
                          );
                    }
                  : null,
              child: PaintSwatch(
                key: ValueKey<String>('paint-swatch:$paintId'),
                paint: paint,
                selected: expanded,
                onTap: () => uiState.toggle(paintId),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Opacity(opacity: paint.visible ? 1 : 0.5, child: middle),
          ),
          const SizedBox(width: SsSpace.s1),
          SizedBox(
            width: 52,
            child: NumberProp(
              path: '$_path.opacity',
              semanticLabel: 'Paint opacity',
              unit: '%',
              scale: 100,
              min: 0,
              max: 100,
              fractionDigits: 0,
              enabled: !locked,
            ),
          ),
          const SizedBox(width: 2),
          PaintVisibilityButton(
            path: '$_path.visible',
            paintId: paintId,
            enabled: !locked,
          ),
          SsIconButton(
            key: ValueKey<String>('paint-remove:$paintId'),
            icon: SsIcons.minus,
            semanticLabel: 'Remove paint',
            size: 24,
            iconSize: 14,
            onPressed: locked
                ? null
                : () => editStackPaint(
                    context,
                    ref,
                    stackPath,
                    paintId,
                    (_) => null,
                  ),
          ),
        ],
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: SsSpace.s1),
          child: line,
        ),
        if (expanded && !locked)
          PaintDetail(
            key: ValueKey<String>('paint-detail:$paintId'),
            stackPath: stackPath,
            paint: paint,
            allowImage: allowImage,
          ),
      ],
    );
    if (locked) {
      return Opacity(opacity: 0.5, child: IgnorePointer(child: body));
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (e.buttons == kSecondaryMouseButton) {
          showSsContextMenu(
            context,
            position: e.position,
            entries: _menu(context, ref),
          );
        }
      },
      child: body,
    );
  }
}

/// Detects a double click on its child without a double-tap recogniser
/// (which would delay every single tap on the swatch).
class _SwatchDoubleClick extends StatefulWidget {
  const _SwatchDoubleClick({required this.child, this.onDoubleClick});

  final Widget child;
  final VoidCallback? onDoubleClick;

  @override
  State<_SwatchDoubleClick> createState() => _SwatchDoubleClickState();
}

class _SwatchDoubleClickState extends State<_SwatchDoubleClick> {
  Duration? _last;

  @override
  Widget build(BuildContext context) {
    final cb = widget.onDoubleClick;
    if (cb == null) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        final last = _last;
        if (last != null &&
            e.timeStamp - last <= const Duration(milliseconds: 400)) {
          _last = null;
          // After the second tap's own toggle, so the paint stays open.
          WidgetsBinding.instance.addPostFrameCallback((_) => cb());
        } else {
          _last = e.timeStamp;
        }
      },
      child: widget.child,
    );
  }
}

/// The expanded editor of one paint: kind (solids; other kinds switch in
/// the row), blend mode, then the kind's own editor.
class PaintDetail extends ConsumerWidget {
  const PaintDetail({
    required this.stackPath,
    required this.paint,
    required this.allowImage,
    super.key,
  });

  final String stackPath;
  final ir.Paint paint;
  final bool allowImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = '$stackPath.${paint.id}';
    final w = InspectorScope.of(context).writer;
    final p = paint;
    final blend = EnumProp(
      path: '$path.blendMode',
      semanticLabel: 'Paint blend mode',
      dropdown: true,
      options: kPaintBlendOptions,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 14, bottom: SsSpace.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p is ir.SolidPaint) ...[
            _ColorPickerProp(path: '$path.color', color: p.color, writer: w),
            const SizedBox(height: SsSpace.s2),
            Row(
              children: [
                Expanded(
                  child: PaintKindDropdown(
                    stackPath: stackPath,
                    paintId: p.id,
                    paint: p,
                    allowImage: allowImage,
                    enabled: true,
                    detail: true,
                  ),
                ),
                const SizedBox(width: SsSpace.s2),
                Expanded(child: blend),
              ],
            ),
          ] else
            blend,
          const SizedBox(height: SsSpace.s2),
          if (p is ir.GradientPaint)
            PaintGradientEditor(
              key: ValueKey<String>('gradient:${p.id}'),
              stackPath: stackPath,
              paint: p,
            ),
          if (p is ir.ImagePaint)
            PaintImageEditor(
              key: ValueKey<String>('image:${p.id}'),
              stackPath: stackPath,
              paint: p,
            ),
        ],
      ),
    );
  }
}

class _ColorPickerProp extends StatelessWidget {
  const _ColorPickerProp({
    required this.path,
    required this.color,
    required this.writer,
  });

  final String path;
  final ir.StageColor color;
  final PropertyWriter writer;

  @override
  Widget build(BuildContext context) => FieldFrame.single(
    path: path,
    child: SsColorPicker(
      key: ValueKey<String>('picker:$path'),
      color: stageColor(color),
      onChangeStart: writer.beginGesture,
      onChangeEnd: writer.endGesture,
      onChanged: (c) => writer.set(path, ir.IrValue.color(stageColorOf(c))),
    ),
  );
}

/// The kind switcher. Switching rewrites the whole stack (one undo step).
class PaintKindDropdown extends ConsumerWidget {
  const PaintKindDropdown({
    required this.stackPath,
    required this.paintId,
    required this.paint,
    required this.allowImage,
    required this.enabled,
    this.detail = false,
    super.key,
  });

  final String stackPath;
  final String paintId;
  final ir.Paint paint;
  final bool allowImage;
  final bool enabled;

  /// The copy in a solid paint's expanded editor (a distinct key).
  final bool detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = paintKindOf(paint);
    return FieldFrame.single(
      path: '$stackPath.$paintId',
      child: SsDropdown<PaintKindChoice>(
        key: ValueKey<String>(
          detail ? 'paint-kind-detail:$paintId' : 'paint-kind:$paintId',
        ),
        semanticLabel: 'Paint type',
        value: kind,
        enabled: enabled,
        onChanged: (k) {
          if (k == kind) return;
          editStackPaint(
            context,
            ref,
            stackPath,
            paintId,
            (p) => convertPaint(p, k, stackPath),
          );
          PaintUi.of(context).expand(paintId);
        },
        items: [
          for (final k in PaintKindChoice.values)
            if (k != PaintKindChoice.image ||
                allowImage ||
                kind == PaintKindChoice.image)
              SsDropdownItem(value: k, label: kPaintKindLabels[k]!),
        ],
      ),
    );
  }
}

/// A solid paint's hex value: commits on Enter or blur, Escape reverts.
/// The paint's colour alpha is kept (opacity is the paint's own field).
class PaintHexField extends ConsumerStatefulWidget {
  const PaintHexField({required this.path, this.enabled = true, super.key});

  final String path;
  final bool enabled;

  @override
  ConsumerState<PaintHexField> createState() => _PaintHexFieldState();
}

class _PaintHexFieldState extends ConsumerState<PaintHexField> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'PaintHexField');
  ir.StageColor? _color;
  bool _mixed = false;

  String _hex() => _mixed || _color == null
      ? ''
      : _color!.toHex().substring(1, 7).toUpperCase();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = parseHexColor(_text.text);
    final current = _color;
    if (parsed == null || current == null) {
      _text.text = _hex();
      return;
    }
    final next = stageColorOf(parsed).withAlpha(current.a);
    if (_mixed || next.toHex() != current.toHex()) {
      InspectorScope.of(
        context,
      ).writer.set(widget.path, ir.IrValue.color(next));
    }
    _text.text = next.toHex().substring(1, 7).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final r = watchReading(context, ref, widget.path);
    final v = r.value;
    _color = v is ir.ColorValue ? v.value : null;
    _mixed = r.mixed;
    if (!_focus.hasFocus && _text.text != _hex()) _text.text = _hex();
    final t = context.ss;
    final c = t.colors;
    final enabled = widget.enabled && r.exists;
    return FieldFrame.single(
      path: widget.path,
      child: Container(
        key: ValueKey<String>('field:${widget.path}'),
        height: SsSpace.controlHeight,
        padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
        decoration: BoxDecoration(
          color: enabled ? c.surface2 : c.surface1,
          borderRadius: SsRadius.brMd,
          border: Border.all(
            color: _focus.hasFocus ? c.focusRing : c.border,
            width: _focus.hasFocus ? 2 : 1,
          ),
        ),
        alignment: Alignment.centerLeft,
        child: SsTextField(
          bare: true,
          controller: _text,
          focusNode: _focus,
          enabled: enabled,
          placeholder: r.mixed ? 'Mixed' : null,
          semanticLabel: 'Paint colour hex',
          revertOnEscape: true,
          releaseFocusOnSubmit: true,
          selectAllOnFocus: true,
          textStyle: t.text.numeric.copyWith(
            color: enabled ? c.textPrimary : c.textDisabled,
          ),
          onSubmitted: (_) => _commit(),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
            LengthLimitingTextInputFormatter(7),
          ],
        ),
      ),
    );
  }
}

/// The eye toggle of a paint.
class PaintVisibilityButton extends ConsumerWidget {
  const PaintVisibilityButton({
    required this.path,
    required this.paintId,
    this.enabled = true,
    super.key,
  });

  final String path;
  final String paintId;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final visible = r.boolean ?? true;
    return FieldFrame.single(
      path: path,
      child: SsIconButton(
        key: ValueKey<String>('paint-visible:$paintId'),
        icon: visible ? SsIcons.eye : SsIcons.eyeOff,
        semanticLabel: visible ? 'Hide paint' : 'Show paint',
        size: 24,
        iconSize: 14,
        onPressed: enabled && r.exists
            ? () => w.set(path, ir.IrValue.boolean(!(visible && !r.mixed)))
            : null,
      ),
    );
  }
}

/// A preview of [paint] over the transparency checkerboard: its colour,
/// gradient (drawn by the runtime's shaders) or image thumbnail.
class PaintSwatch extends StatelessWidget {
  const PaintSwatch({
    required this.paint,
    this.size = 20,
    this.selected = false,
    this.onTap,
    super.key,
  });

  final ir.Paint paint;
  final double size;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    final p = paint;
    final Widget fill = switch (p) {
      ir.SolidPaint(:final color) => ColoredBox(
        color: stageColor(color, p.opacity),
        child: const SizedBox.expand(),
      ),
      ir.GradientPaint() => CustomPaint(
        painter: PaintGradientPreviewPainter(p),
        child: const SizedBox.expand(),
      ),
      ir.ImagePaint(:final assetId) => Opacity(
        opacity: p.opacity.clamp(0.0, 1.0),
        child: PaintAssetThumb(assetId: assetId, targetWidth: size * 3),
      ),
    };
    final swatch = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: SsRadius.brSm,
        border: Border.all(
          color: selected ? c.focusRing : c.border,
          width: selected ? 2 : 1,
        ),
      ),
      child: SsCheckerboard(cell: 4, borderRadius: SsRadius.brSm, child: fill),
    );
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '${kPaintKindLabels[paintKindOf(p)]} paint, edit',
      onTap: onTap,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: swatch),
      ),
    );
  }
}

/// Draws a gradient paint into its box with the runtime's own shaders, so
/// the swatch matches the canvas.
class PaintGradientPreviewPainter extends CustomPainter {
  const PaintGradientPreviewPainter(this.gradient);

  final ir.GradientPaint gradient;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final opacity = gradient.opacity.clamp(0.0, 1.0);
    if (gradient.kind == ir.GradientKind.diamond) {
      final mesh = diamondMesh(gradient, size, opacity);
      if (mesh == null) return;
      final v = mesh.toVertices();
      canvas.drawVertices(v, ui.BlendMode.srcOver, Paint());
      v.dispose();
      return;
    }
    final shader = gradientShader(gradient, size, opacity);
    if (shader == null) return;
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(PaintGradientPreviewPainter old) =>
      old.gradient != gradient;
}
