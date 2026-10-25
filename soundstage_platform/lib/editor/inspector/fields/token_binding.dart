import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../panels/tokens_panel.dart' show variableTypeIcon;
import '../inspector_providers.dart';
import '../property_writer.dart';

// Token binding in the inspector (m3.md T3.1 "Binding"). A field whose value
// type matches a variable type gets a bind button on hover; the picker lists
// the compatible variables; a bound field shows the variable as a chip whose
// × detaches it, writing the shown value back as a literal. Binding and
// detaching are ordinary property writes, so they follow the edit scope.

/// Paths that are never bound: editor-only and semantic properties.
const Set<String> _unbindable = {
  'name',
  'locked',
  'readingOrder',
  'altText',
  'role',
};

/// The variable type a field at [path] can bind to, or null.
ir.VariableType? bindableType(String path) {
  if (_unbindable.contains(path)) return null;
  if (path.endsWith('fontFamilyId')) return ir.VariableType.fontFamily;
  final m = ir.PropertyRegistry.standard.lookup(path);
  return switch (m?.descriptor.valueType) {
    ir.IrValueType.number => ir.VariableType.number,
    ir.IrValueType.color => ir.VariableType.color,
    // Only visibility: the other switches are icon toggles too small to
    // carry a bind button.
    ir.IrValueType.boolean when path.endsWith('visible') =>
      ir.VariableType.boolean,
    _ => null,
  };
}

/// Wraps the control of a bindable [path]: a chip over it while bound, a
/// bind button on hover otherwise.
class BindableField extends ConsumerStatefulWidget {
  const BindableField({
    required this.path,
    required this.type,
    required this.source,
    required this.child,
    super.key,
  });

  final String path;
  final ir.VariableType type;
  final ValueSource source;
  final Widget child;

  @override
  ConsumerState<BindableField> createState() => _BindableFieldState();
}

class _BindableFieldState extends ConsumerState<BindableField> {
  bool _hover = false;

  PropertyWriter get _writer => InspectorScope.of(context).writer;

  void _bind(String variableId) => _writer.set(
    widget.path,
    ir.IrValue.tokenRef(ir.TokenRef(variableId: variableId)),
  );

  void _detach() {
    final v = widget.source.value;
    if (v != null) _writer.set(widget.path, v);
  }

  void _pick(BuildContext anchor) {
    final box = anchor.findRenderObject()! as RenderBox;
    showVariablePicker(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      type: widget.type,
      current: widget.source.variableId,
      onPick: _bind,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bound = widget.source.variableId;
    if (bound != null) {
      final name = ref.watch(
        editorControllerProvider.select(
          (s) => variableDisplayName(s.document, bound),
        ),
      );
      return Stack(
        children: [
          // Keeps the control's size; hidden under the chip.
          Visibility.maintain(visible: false, child: widget.child),
          Positioned.fill(
            child: Builder(
              builder: (anchor) => BoundVariableChip(
                name: name,
                type: widget.type,
                onTap: () => _pick(anchor),
                onDetach: _detach,
              ),
            ),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, box) =>
          box.maxWidth < 56 ? widget.child : _hoverable(),
    );
  }

  Widget _hoverable() {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_hover)
            Positioned(
              right: 2,
              top: 0,
              bottom: 0,
              child: Center(
                child: Builder(
                  builder: (anchor) => SsIconButton(
                    key: ValueKey<String>('bind-${widget.path}'),
                    icon: SsIcons.hexagon,
                    semanticLabel: 'Bind to variable',
                    tooltip: 'Bind to variable',
                    size: 20,
                    iconSize: 12,
                    onPressed: () => _pick(anchor),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "group › leaf" for variable [id], or "Missing variable".
String variableDisplayName(ir.StageDocument doc, String id) {
  for (final c in doc.tokens.collections) {
    for (final v in c.variables) {
      if (v.id == id) return v.name;
    }
  }
  return 'Missing variable';
}

/// A bound field: the variable's name in a chip; tap to rebind, × to
/// detach.
class BoundVariableChip extends StatelessWidget {
  const BoundVariableChip({
    required this.name,
    required this.type,
    required this.onTap,
    required this.onDetach,
    super.key,
  });

  final String name;
  final ir.VariableType type;
  final VoidCallback onTap;
  final VoidCallback onDetach;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return SsInteractive(
      key: const ValueKey<String>('bound-variable'),
      semanticLabel: 'Bound to $name',
      onTap: onTap,
      builder: (context, states) => Container(
        decoration: BoxDecoration(
          color: t.colors.surface3,
          borderRadius: SsRadius.brSm,
          border: Border.all(color: t.colors.accentText.withValues(alpha: 0.4)),
        ),
        padding: const EdgeInsets.only(left: SsSpace.s1),
        child: Row(
          children: [
            SsIcon(
              variableTypeIcon(type),
              size: 12,
              color: t.colors.accentText,
            ),
            const SizedBox(width: SsSpace.s1),
            Expanded(
              child: Text(
                name.replaceAll('/', ' / '),
                style: t.text.caption.copyWith(color: t.colors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SsIconButton(
              key: const ValueKey<String>('detach-variable'),
              icon: SsIcons.unlink,
              semanticLabel: 'Detach variable',
              tooltip: 'Detach',
              size: 20,
              iconSize: 12,
              onPressed: onDetach,
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the variable picker below [anchor]: a search field and the
/// variables of [type] grouped by collection. [onPick] gets the id.
SsPopoverHandle showVariablePicker(
  BuildContext context, {
  required Rect anchor,
  required ir.VariableType type,
  required ValueChanged<String> onPick,
  String? current,
}) {
  late final SsPopoverHandle handle;
  handle = showSsPopover(
    context,
    anchor: anchor,
    placement: SsPlacement.belowEnd,
    builder: (_) => _VariablePicker(
      type: type,
      current: current,
      onPick: (id) {
        handle.close();
        onPick(id);
      },
    ),
  );
  return handle;
}

class _VariablePicker extends ConsumerStatefulWidget {
  const _VariablePicker({
    required this.type,
    required this.onPick,
    this.current,
  });

  final ir.VariableType type;
  final String? current;
  final ValueChanged<String> onPick;

  @override
  ConsumerState<_VariablePicker> createState() => _VariablePickerState();
}

class _VariablePickerState extends ConsumerState<_VariablePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final cols = ref.watch(
      editorControllerProvider.select((s) => s.document.tokens.collections),
    );
    final q = _query.toLowerCase();
    final rows = <Widget>[];
    for (final c in cols) {
      final vars = [
        for (final v in c.variables)
          if (v.type == widget.type &&
              (q.isEmpty || v.name.toLowerCase().contains(q)))
            v,
      ];
      if (vars.isEmpty) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SsSpace.s2,
            SsSpace.s2,
            SsSpace.s2,
            SsSpace.s1,
          ),
          child: Text(c.name.toUpperCase(), style: t.text.overline),
        ),
      );
      for (final v in vars) {
        rows.add(
          SsInteractive(
            key: ValueKey<String>('pick-variable-${v.id}'),
            semanticLabel: v.name,
            selected: v.id == widget.current,
            onTap: () => widget.onPick(v.id),
            builder: (context, states) => Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
              color: states.contains(WidgetState.hovered)
                  ? t.colors.surface3
                  : null,
              child: Row(
                children: [
                  SsIcon(variableTypeIcon(v.type), size: 12),
                  const SizedBox(width: SsSpace.s2),
                  Expanded(
                    child: Text(
                      v.name.replaceAll('/', ' / '),
                      style: t.text.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (v.id == widget.current)
                    SsIcon(SsIcons.check, size: 12, color: t.colors.accentText),
                ],
              ),
            ),
          ),
        );
      }
    }
    return SsPopoverSurface(
      width: 240,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(SsSpace.s1),
              child: SsTextField(
                autofocus: true,
                dense: true,
                placeholder: 'Search variables',
                semanticLabel: 'Search variables',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(SsSpace.s3),
                child: Text(
                  'No ${widget.type == ir.VariableType.fontFamily ? 'font' : widget.type.name} variables. '
                  'Add them in the Tokens tab.',
                  style: t.text.caption,
                ),
              )
            else
              Flexible(child: ListView(shrinkWrap: true, children: rows)),
          ],
        ),
      ),
    );
  }
}
