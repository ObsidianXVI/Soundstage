import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';

// The breakpoint manager (T1.10): a compact toolbar menu listing the
// breakpoints, with add (a tablet preset or a custom breakpoint), edit
// (name, min width, design size, inheritsFrom, primary) and remove (with
// its patches, after a confirmation). Every change is one undoable
// command; validation (`ir.validateBreakpointList`) prevents cycles, a
// dangling parent, duplicate ids and a story without a primary breakpoint.

/// The tablet preset ("Add tablet"): inherits from the widest primary
/// breakpoint and shows as an artboard.
ir.Breakpoint tabletPreset(ir.StageDocument doc, String id) {
  ir.Breakpoint? widest;
  for (final b in doc.primaryBreakpoints) {
    if (widest == null || b.minWidth > widest.minWidth) widest = b;
  }
  return ir.Breakpoint(
    id: id,
    name: 'Tablet',
    minWidth: 600,
    designSize: const ir.StageSize(width: 834, height: 1112),
    inheritsFrom: widest?.id,
    primary: true,
  );
}

/// A breakpoint named "Tablet" in [doc], if any.
ir.Breakpoint? tabletOf(ir.StageDocument doc) {
  for (final b in doc.breakpoints) {
    if (b.name.trim().toLowerCase() == 'tablet') return b;
  }
  return null;
}

/// The toolbar button that opens the breakpoint menu.
class BreakpointManagerButton extends ConsumerWidget {
  const BreakpointManagerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Builder(
      builder: (anchor) => SsIconButton(
        key: const ValueKey<String>('breakpoint-manager'),
        icon: SsIcons.tablet,
        semanticLabel: 'Breakpoints',
        tooltip: 'Breakpoints: add, edit or remove',
        onPressed: () => showSsMenu(
          anchor,
          anchor: ssGlobalRect(anchor),
          placement: SsPlacement.belowEnd,
          minWidth: 240,
          entries: breakpointMenuEntries(context, ref),
        ),
      ),
    );
  }
}

/// The breakpoint menu: one row per breakpoint (checked = shown as an
/// artboard; selecting edits it), then add entries.
List<SsMenuEntry> breakpointMenuEntries(BuildContext context, WidgetRef ref) {
  final ctl = ref.read(editorControllerProvider.notifier);
  final doc = ref.read(editorControllerProvider).document;
  final tablet = tabletOf(doc);
  return [
    const SsMenuLabel('Breakpoints'),
    for (final b in ir.breakpointsByWidth(doc.breakpoints).reversed)
      SsMenuItem(
        label: b.name,
        shortcut: '≥ ${b.minWidth.round()}',
        checked: b.primary,
        onSelected: () => editBreakpoint(context, ref, b),
      ),
    const SsMenuDivider(),
    if (tablet == null)
      SsMenuItem(
        label: 'Add tablet',
        icon: SsIcons.tablet,
        onSelected: () => ctl.execute(
          AddBreakpoint(
            tabletPreset(doc, ir.IdGenerator.forDocument(doc).next()),
          ),
        ),
      )
    else if (!tablet.primary)
      SsMenuItem(
        label: 'Show ${tablet.name} as an artboard',
        icon: SsIcons.tablet,
        onSelected: () =>
            ctl.execute(UpdateBreakpoint(tablet.copyWith(primary: true))),
      ),
    SsMenuItem(
      label: 'Add breakpoint…',
      icon: SsIcons.plus,
      onSelected: () => addBreakpoint(context, ref),
    ),
  ];
}

/// Opens the dialog for a new custom breakpoint and adds it.
Future<void> addBreakpoint(BuildContext context, WidgetRef ref) async {
  final doc = ref.read(editorControllerProvider).document;
  final draft = ir.Breakpoint(
    id: ir.IdGenerator.forDocument(doc).next(),
    name: '',
    minWidth: 1600,
    designSize: const ir.StageSize(width: 1920, height: 1080),
  );
  final r = await showSsDialog<_DialogResult>(
    context,
    builder: (_) =>
        BreakpointDialog(document: doc, initial: draft, isNew: true),
  );
  if (r is _Save) {
    ref.read(editorControllerProvider.notifier).execute(AddBreakpoint(r.value));
  }
}

/// Opens the dialog for [b]: saves the edit, or removes it after a
/// confirmation naming how many layers lose overrides.
Future<void> editBreakpoint(
  BuildContext context,
  WidgetRef ref,
  ir.Breakpoint b,
) async {
  final doc = ref.read(editorControllerProvider).document;
  final r = await showSsDialog<_DialogResult>(
    context,
    builder: (_) => BreakpointDialog(document: doc, initial: b),
  );
  if (!context.mounted) return;
  final ctl = ref.read(editorControllerProvider.notifier);
  switch (r) {
    case _Save(:final value):
      ctl.execute(UpdateBreakpoint(value));
    case _Remove():
      final n = patchedNodeCount(doc, b.id);
      final ok = await showSsConfirm(
        context,
        title: 'Remove ${b.name}?',
        message: n == 0
            ? 'No layer overrides ${b.name}. You can undo this.'
            : 'The overrides of ${b.name} on $n ${n == 1 ? 'layer' : 'layers'} '
                  'are removed too. You can undo this.',
        confirmLabel: 'Remove',
        danger: true,
      );
      if (ok) ctl.execute(RemoveBreakpoint(b.id));
    case null:
      break;
  }
}

sealed class _DialogResult {
  const _DialogResult();
}

class _Save extends _DialogResult {
  const _Save(this.value);
  final ir.Breakpoint value;
}

class _Remove extends _DialogResult {
  const _Remove();
}

/// The add/edit form. Save stays disabled while the breakpoint list it
/// would produce is invalid, and the problems are listed.
class BreakpointDialog extends StatefulWidget {
  const BreakpointDialog({
    required this.document,
    required this.initial,
    this.isNew = false,
    super.key,
  });

  final ir.StageDocument document;
  final ir.Breakpoint initial;
  final bool isNew;

  @override
  State<BreakpointDialog> createState() => _BreakpointDialogState();
}

class _BreakpointDialogState extends State<BreakpointDialog> {
  late ir.Breakpoint _b = widget.initial;
  late final TextEditingController _name = TextEditingController(
    text: widget.initial.name,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<ir.Breakpoint> get _list {
    final list = [...widget.document.breakpoints];
    final i = list.indexWhere((b) => b.id == _b.id);
    if (i < 0) {
      list.add(_b);
    } else {
      list[i] = _b;
    }
    return list;
  }

  void _set(ir.Breakpoint b) => setState(() => _b = b);

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final errors = ir.validateBreakpointList(_list);
    final others = [
      for (final b in widget.document.breakpoints)
        if (b.id != _b.id) b,
    ];
    final canRemove =
        !widget.isNew &&
        ir.validateBreakpointList([
          for (final b in widget.document.breakpoints)
            if (b.id != _b.id) b,
        ]).isEmpty;
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(label, style: t.text.caption)),
          Expanded(child: child),
        ],
      ),
    );
    return SsDialog(
      title: widget.isNew ? 'Add breakpoint' : 'Edit ${widget.initial.name}',
      width: 460,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row(
            'Name',
            SsTextField(
              key: const ValueKey<String>('bp-name'),
              controller: _name,
              placeholder: 'e.g. Tablet',
              semanticLabel: 'Breakpoint name',
              autofocus: widget.isNew,
              onChanged: (v) => _set(_b.copyWith(name: v)),
            ),
          ),
          row(
            'Min width',
            SsNumberField(
              key: const ValueKey<String>('bp-min'),
              value: _b.minWidth,
              unit: 'px',
              min: 0,
              fractionDigits: 0,
              semanticLabel: 'Minimum width',
              onChanged: (v) => _set(_b.copyWith(minWidth: v)),
            ),
          ),
          row(
            'Design size',
            Row(
              children: [
                Expanded(
                  child: SsNumberField(
                    key: const ValueKey<String>('bp-w'),
                    value: _b.designSize.width,
                    label: 'W',
                    min: 1,
                    fractionDigits: 0,
                    semanticLabel: 'Design width',
                    onChanged: (v) => _set(
                      _b.copyWith(designSize: _b.designSize.copyWith(width: v)),
                    ),
                  ),
                ),
                const SizedBox(width: SsSpace.s2),
                Expanded(
                  child: SsNumberField(
                    key: const ValueKey<String>('bp-h'),
                    value: _b.designSize.height,
                    label: 'H',
                    min: 1,
                    fractionDigits: 0,
                    semanticLabel: 'Design height',
                    onChanged: (v) => _set(
                      _b.copyWith(
                        designSize: _b.designSize.copyWith(height: v),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          row(
            'Inherits from',
            SsDropdown<String>(
              key: const ValueKey<String>('bp-inherits'),
              semanticLabel: 'Inherits from',
              value: _b.inheritsFrom ?? '',
              items: [
                const SsDropdownItem(value: '', label: 'Shared base only'),
                for (final b in others)
                  SsDropdownItem(value: b.id, label: b.name),
              ],
              onChanged: (v) =>
                  _set(_b.copyWith(inheritsFrom: v.isEmpty ? null : v)),
            ),
          ),
          row(
            'Artboard (primary)',
            SsCheckbox(
              key: const ValueKey<String>('bp-primary'),
              value: _b.primary,
              label: 'Side by side',
              onChanged: (v) => _set(_b.copyWith(primary: v)),
            ),
          ),
          for (final e in errors)
            Padding(
              padding: const EdgeInsets.only(top: SsSpace.s1),
              child: Text(
                e.message,
                key: const ValueKey<String>('bp-error'),
                style: t.text.caption.copyWith(color: t.colors.danger),
              ),
            ),
        ],
      ),
      actions: [
        if (!widget.isNew)
          SsButton(
            key: const ValueKey<String>('bp-remove'),
            label: 'Remove…',
            variant: SsButtonVariant.danger,
            onPressed: canRemove
                ? () => Navigator.of(context).pop(const _Remove())
                : null,
          ),
        SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SsButton(
          key: const ValueKey<String>('bp-save'),
          label: widget.isNew ? 'Add' : 'Save',
          variant: SsButtonVariant.primary,
          onPressed: errors.isEmpty
              ? () => Navigator.of(context).pop(_Save(_b))
              : null,
        ),
      ],
    );
  }
}
