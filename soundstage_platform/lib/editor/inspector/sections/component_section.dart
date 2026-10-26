import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../inspector_providers.dart';
import '../section_registry.dart';

/// Components (architecture §9; m3.md T3.2):
///
/// - a frame: "Create component" (the frame becomes the main, an instance
///   takes its place);
/// - an instance: its component, "Edit main component" (isolation mode),
///   "Detach", and its property values;
/// - in isolation, the main's root: its name and properties; any other layer
///   of the main: which property drives it (text, visibility, opacity).
final InspectorSectionSpec componentSection = InspectorSectionSpec(
  id: 'component',
  title: 'Component',
  appliesTo: (info) =>
      info.ids.length == 1 &&
      !info.ids.single.contains('/') &&
      info.roots == 0 &&
      info.ids.single != kIsolationStageId &&
      (info.isolated || info.kinds.contains(ir.NodeKind.instance)),
  builder: (context, info) => _ComponentBody(nodeId: info.ids.single),
);

/// The Layer header's "Create component" button, for a single frame
/// outside isolation (the Component section shows for instances and in
/// isolation only).
class CreateComponentAction extends ConsumerWidget {
  const CreateComponentAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(selectionInfoProvider);
    if (info.isolated ||
        info.ids.length != 1 ||
        info.roots != 0 ||
        info.ids.single.contains('/') ||
        info.kinds.length != 1 ||
        info.kinds.single != ir.NodeKind.frame) {
      return const SizedBox.shrink();
    }
    return SsIconButton(
      key: const ValueKey<String>('component:create'),
      icon: SsIcons.component,
      semanticLabel: 'Create component',
      tooltip: 'Create component',
      size: 24,
      iconSize: 14,
      onPressed: () => ref
          .read(editorControllerProvider.notifier)
          .execute(CreateComponent(info.ids.single)),
    );
  }
}

/// The property types a layer property can bind, and the path each drives.
const Map<ir.ComponentPropType, String> _bindPath = {
  ir.ComponentPropType.text: 'characters',
  ir.ComponentPropType.boolean: 'visible',
  ir.ComponentPropType.number: 'opacity',
};

ir.IrValue _defaultOf(ir.ComponentPropType t) => switch (t) {
  ir.ComponentPropType.boolean => const ir.IrValue.boolean(true),
  ir.ComponentPropType.number => const ir.IrValue.number(1),
  _ => const ir.IrValue.string('Text'),
};

class _ComponentBody extends ConsumerWidget {
  const _ComponentBody({required this.nodeId});

  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final st = ref.watch(editorControllerProvider);
    final doc = st.document;
    final ctl = ref.read(editorControllerProvider.notifier);
    final node = ir.DocumentIndex.of(doc).node(nodeId);
    final iso = st.isolation;

    // Inside isolation: the main's root, or one of its layers.
    if (iso != null) {
      final def = doc.components[iso.componentId];
      if (def == null) return const SizedBox.shrink();
      if (nodeId == iso.rootId) {
        return _MainFields(def: def);
      }
      if (node == null) return const SizedBox.shrink();
      return _LayerBinding(def: def, node: node);
    }

    if (node is ir.InstanceNode) {
      final cid = ir.instanceComponentId(doc, node);
      final def = cid == null ? null : doc.components[cid];
      final set = cid == null ? null : ir.variantSetOf(doc, cid);
      final current = set == null
          ? const <String, String>{}
          : set.variants.firstWhere((v) => v.componentId == cid).values;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            def == null ? 'Missing component' : def.name,
            style: t.text.bodyStrong,
          ),
          const SizedBox(height: SsSpace.s2),
          Wrap(
            spacing: SsSpace.s2,
            runSpacing: SsSpace.s1,
            children: [
              if (def != null)
                SsButton(
                  key: const ValueKey<String>('component:edit'),
                  label: 'Edit main',
                  icon: SsIcons.component,
                  onPressed: () => ctl.enterComponent(def.id),
                ),
              SsButton(
                key: const ValueKey<String>('component:detach'),
                label: 'Detach',
                icon: SsIcons.unlink,
                onPressed: () => ctl.execute(DetachInstance(nodeId)),
              ),
            ],
          ),
          if (set != null)
            for (final MapEntry(key: axis, value: values) in set.axes.entries)
              Padding(
                padding: const EdgeInsets.only(top: SsSpace.s2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 76,
                      child: Text(
                        axis,
                        style: t.text.small.copyWith(
                          color: t.colors.textSecondary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SsDropdown<String>(
                        key: ValueKey<String>('variant-axis:$axis'),
                        semanticLabel: axis,
                        value: current[axis],
                        onChanged: (v) => ctl.execute(
                          ComponentEdit(
                            'Switch variant',
                            (d) => ir.setInstanceVariant(d, nodeId, set.id, {
                              ...current,
                              axis: v,
                            }),
                          ),
                        ),
                        items: [
                          for (final v in values)
                            SsDropdownItem(value: v, label: v),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          if (def != null)
            for (final MapEntry(key: pid, value: p) in def.properties.entries)
              Padding(
                padding: const EdgeInsets.only(top: SsSpace.s2),
                child: _PropValue(
                  label: p.name,
                  type: p.type,
                  value: node.propValues[pid] ?? p.defaultValue,
                  onChanged: (v) => ctl.execute(
                    ComponentEdit(
                      'Change ${p.name}',
                      (d) => ir.setInstanceProp(d, nodeId, pid, v),
                      coalesceKey: 'prop:$nodeId:$pid',
                    ),
                  ),
                ),
              ),
        ],
      );
    }
    if (node is ir.FrameNode) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SsTooltip(
          message: 'Make this frame a reusable component',
          child: SsButton(
            key: const ValueKey<String>('component:create'),
            label: 'Create',
            icon: SsIcons.component,
            onPressed: () => ctl.execute(CreateComponent(nodeId)),
          ),
        ),
      );
    }
    return Text(
      'Select a frame to make it a component.',
      style: t.text.caption,
    );
  }
}

/// Name and properties of the main being edited.
class _MainFields extends ConsumerWidget {
  const _MainFields({required this.def});

  final ir.ComponentDef def;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    void edit(String label, ir.ComponentDef Function(ir.ComponentDef) f) => ctl
        .execute(ComponentEdit(label, (d) => ir.updateComponent(d, def.id, f)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SsTextField(
          key: ValueKey<String>('component-name:${def.name}'),
          semanticLabel: 'Component name',
          dense: true,
          initialValue: def.name,
          releaseFocusOnSubmit: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) {
              edit('Rename component', (c) => c.copyWith(name: v.trim()));
            }
          },
        ),
        const SizedBox(height: SsSpace.s3),
        _Variants(def: def),
        const SizedBox(height: SsSpace.s3),
        Row(
          children: [
            Expanded(child: Text('PROPERTIES', style: t.text.overline)),
            Builder(
              builder: (anchor) => SsIconButton(
                key: const ValueKey<String>('component:add-prop'),
                icon: SsIcons.plus,
                semanticLabel: 'Add property',
                size: 24,
                iconSize: 14,
                onPressed: () {
                  final box = anchor.findRenderObject()! as RenderBox;
                  showSsMenu(
                    context,
                    anchor: box.localToGlobal(Offset.zero) & box.size,
                    placement: SsPlacement.belowEnd,
                    entries: [
                      for (final type in _bindPath.keys)
                        SsMenuItem(
                          label: switch (type) {
                            ir.ComponentPropType.text => 'Text',
                            ir.ComponentPropType.boolean => 'Show / hide',
                            _ => 'Number',
                          },
                          onSelected: () {
                            final id = ir.IdGenerator.forDocument(
                              ref.read(editorControllerProvider).document,
                            ).next();
                            final base = switch (type) {
                              ir.ComponentPropType.text => 'Text',
                              ir.ComponentPropType.boolean => 'Visible',
                              _ => 'Number',
                            };
                            var name = base;
                            for (
                              var i = 2;
                              def.properties.values.any((p) => p.name == name);
                              i++
                            ) {
                              name = '$base $i';
                            }
                            edit(
                              'Add property',
                              (c) => c.copyWith(
                                properties: {
                                  ...c.properties,
                                  id: ir.ComponentPropDef(
                                    name: name,
                                    type: type,
                                    defaultValue: _defaultOf(type),
                                  ),
                                },
                              ),
                            );
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        if (def.properties.isEmpty)
          Text(
            'Properties let each instance change a text, show or hide a '
            'layer, or set its opacity.',
            style: t.text.caption,
          ),
        for (final MapEntry(key: pid, value: p) in def.properties.entries)
          Padding(
            padding: const EdgeInsets.only(top: SsSpace.s2),
            child: Row(
              children: [
                Expanded(
                  child: _PropValue(
                    label: p.name,
                    type: p.type,
                    value: p.defaultValue,
                    onChanged: (v) => edit(
                      'Change default',
                      (c) => c.copyWith(
                        properties: {
                          ...c.properties,
                          pid: p.copyWith(defaultValue: v),
                        },
                      ),
                    ),
                  ),
                ),
                SsIconButton(
                  icon: SsIcons.minus,
                  semanticLabel: 'Remove ${p.name}',
                  size: 24,
                  iconSize: 12,
                  onPressed: () => edit(
                    'Remove property',
                    (c) =>
                        c.copyWith(properties: {...c.properties}..remove(pid)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The main's variant set: its values, and "Add variant".
class _Variants extends ConsumerWidget {
  const _Variants({required this.def});

  final ir.ComponentDef def;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    final set = ir.variantSetOf(
      ref.watch(editorControllerProvider.select((s) => s.document)),
      def.id,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('VARIANTS', style: t.text.overline),
        const SizedBox(height: SsSpace.s1),
        if (set != null)
          for (final MapEntry(key: axis, value: values) in set.axes.entries)
            Text('$axis: ${values.join(', ')}', style: t.text.caption),
        Align(
          alignment: Alignment.centerLeft,
          child: SsButton(
            key: const ValueKey<String>('component:add-variant'),
            label: 'Add variant',
            icon: SsIcons.plus,
            variant: SsButtonVariant.ghost,
            onPressed: () => ctl.execute(
              ComponentEdit('Add variant', (d) {
                final ids = ir.IdGenerator.forDocument(d);
                return ir.addVariant(
                  d,
                  def.id,
                  newComponentId: ids.next(),
                  setId: ids.next(),
                  ids: ids,
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

/// Which property drives a layer of the main being edited.
class _LayerBinding extends ConsumerWidget {
  const _LayerBinding({required this.def, required this.node});

  final ir.ComponentDef def;
  final ir.Node node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    final options = [
      for (final MapEntry(key: pid, value: p) in def.properties.entries)
        if (_bindPath[p.type] case final path?)
          if (path != 'characters' || node is ir.TextNode) (pid, p, path),
    ];
    if (options.isEmpty) {
      return Text(
        'Add properties on the component (select its top frame) to let '
        'instances change this layer.',
        style: t.text.caption,
      );
    }
    final bound = node.common.componentBindings;
    String current = '';
    for (final (pid, _, path) in options) {
      if (bound[path] == pid) current = pid;
    }
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(
            'Driven by',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
        ),
        Expanded(
          child: SsDropdown<String>(
            key: const ValueKey<String>('component:bind'),
            semanticLabel: 'Component property',
            value: current,
            onChanged: (pid) {
              final paths = {for (final o in options) o.$1: o.$3};
              ctl.execute(
                ComponentEdit(
                  'Bind to property',
                  (d) => ir.updateNode(d, node.id, (n) {
                    final b = {...n.common.componentBindings}
                      ..removeWhere((_, v) => paths.containsKey(v));
                    if (pid.isNotEmpty) b[paths[pid]!] = pid;
                    return n.copyWith(
                      common: n.common.copyWith(componentBindings: b),
                    );
                  }),
                ),
              );
            },
            items: [
              const SsDropdownItem(value: '', label: 'Nothing'),
              for (final (pid, p, _) in options)
                SsDropdownItem(value: pid, label: p.name),
            ],
          ),
        ),
      ],
    );
  }
}

/// A property value editor by type.
class _PropValue extends StatelessWidget {
  const _PropValue({
    required this.label,
    required this.type,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final ir.ComponentPropType type;
  final ir.IrValue value;
  final ValueChanged<ir.IrValue> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final control = switch ((type, value)) {
      (ir.ComponentPropType.boolean, final v) => Align(
        alignment: Alignment.centerLeft,
        child: SsToggle(
          semanticLabel: label,
          value: v is ir.BoolValue && v.value,
          onChanged: (x) => onChanged(ir.IrValue.boolean(x)),
        ),
      ),
      (ir.ComponentPropType.number, final v) => SsNumberField(
        semanticLabel: label,
        value: v is ir.NumberValue ? v.value : 0,
        onChanged: (x) => onChanged(ir.IrValue.number(x)),
      ),
      (_, final v) => SsTextField(
        key: ValueKey<String>(
          'prop:$label:${v is ir.StringValue ? v.value : ''}',
        ),
        semanticLabel: label,
        dense: true,
        initialValue: v is ir.StringValue ? v.value : '',
        releaseFocusOnSubmit: true,
        onSubmitted: (x) => onChanged(ir.IrValue.string(x)),
      ),
    };
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
        ),
        Expanded(child: control),
      ],
    );
  }
}
