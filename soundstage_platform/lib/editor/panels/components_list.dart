import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/starter_components.dart';

/// The story's components (Assets ▸ Components; m3.md T3.2). Click inserts
/// an instance into the active scene (or, in isolation, into the main being
/// edited); the menu edits the main, renames or deletes (instances are
/// detached first).
class ComponentsList extends ConsumerStatefulWidget {
  const ComponentsList({super.key});

  @override
  ConsumerState<ComponentsList> createState() => _ComponentsListState();
}

class _ComponentsListState extends ConsumerState<ComponentsList> {
  String? _renaming;

  EditorController get _ctl => ref.read(editorControllerProvider.notifier);

  void _insert(ir.ComponentDef def) {
    final st = ref.read(editorControllerProvider);
    final iso = st.isolation;
    if (iso?.componentId == def.id) return; // not inside itself
    final parent = iso?.rootId ?? st.activeScene?.root.id;
    if (parent == null) return;
    _ctl.execute(InsertInstance(def.id, parentId: parent, x: 40, y: 40));
  }

  Future<void> _delete(ir.ComponentDef def) async {
    final ok = await showSsConfirm(
      context,
      title: 'Delete component',
      message:
          '"${def.name}" will be deleted. Its instances become plain layers.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok || !mounted) return;
    if (ref.read(editorControllerProvider).isolation?.componentId == def.id) {
      _ctl.exitComponent();
    }
    _ctl.execute(
      ComponentEdit(
        'Delete component',
        (d) =>
            ir.removeComponent(d, def.id, ids: ir.IdGenerator.forDocument(d)),
      ),
    );
  }

  void _addStarter(StarterComponent s) {
    final st = ref.read(editorControllerProvider);
    final parent = st.isolation?.rootId ?? st.activeScene?.root.id;
    if (parent == null) return;
    _ctl.execute(AddStarterComponent(s, parentId: parent));
  }

  Widget _starters(BuildContext context) {
    final t = context.ss;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SsSpace.s3,
        SsSpace.s1,
        SsSpace.s1,
        SsSpace.s1,
      ),
      child: Row(
        children: [
          Expanded(child: Text('COMPONENTS', style: t.text.overline)),
          Builder(
            builder: (anchor) => SsIconButton(
              key: const ValueKey<String>('components:starter'),
              icon: SsIcons.plus,
              semanticLabel: 'Add a starter component',
              tooltip: 'Add a starter component',
              size: 24,
              iconSize: 14,
              onPressed: () {
                final box = anchor.findRenderObject()! as RenderBox;
                showSsMenu(
                  context,
                  anchor: box.localToGlobal(Offset.zero) & box.size,
                  placement: SsPlacement.belowEnd,
                  entries: [
                    for (final s in StarterComponent.values)
                      SsMenuItem(
                        label: starterName(s),
                        icon: SsIcons.layoutTemplate,
                        onSelected: () => _addStarter(s),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _starters(context),
      Expanded(child: _list(context)),
    ],
  );

  Widget _list(BuildContext context) {
    final t = context.ss;
    final comps = ref.watch(
      editorControllerProvider.select((s) => s.document.components),
    );
    final editing = ref.watch(
      editorControllerProvider.select((s) => s.isolation?.componentId),
    );
    if (comps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(SsSpace.s4),
        child: Text(
          'No components yet. Make one from a frame (the component button '
          'in the inspector), or add a starter with +.',
          style: t.text.caption,
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: SsSpace.s2,
        vertical: SsSpace.s1,
      ),
      children: [
        for (final def in comps.values)
          SsTreeRow(
            key: ValueKey<String>('component-row-${def.id}'),
            label: def.name,
            icon: SsIcons.component,
            showToggles: false,
            selected: editing == def.id,
            startRenaming: _renaming == def.id,
            onRenameEnd: () {
              if (_renaming != null) setState(() => _renaming = null);
            },
            onRename: (name) => _ctl.execute(
              ComponentEdit(
                'Rename component',
                (d) => ir.updateComponent(
                  d,
                  def.id,
                  (c) => c.copyWith(name: name),
                ),
              ),
            ),
            onTap: () => _insert(def),
            onSecondaryTapDown: (e) => showSsContextMenu(
              context,
              position: e.globalPosition,
              entries: [
                SsMenuItem(
                  label: 'Insert instance',
                  icon: SsIcons.plus,
                  enabled: editing != def.id,
                  onSelected: () => _insert(def),
                ),
                SsMenuItem(
                  label: 'Edit main component',
                  icon: SsIcons.component,
                  onSelected: () => _ctl.enterComponent(def.id),
                ),
                SsMenuItem(
                  label: 'Rename',
                  icon: SsIcons.pencil,
                  onSelected: () => setState(() => _renaming = def.id),
                ),
                const SsMenuDivider(),
                SsMenuItem(
                  label: 'Delete',
                  icon: SsIcons.trash2,
                  danger: true,
                  onSelected: () => _delete(def),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
