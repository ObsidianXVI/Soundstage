import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../panels/layers_model.dart';
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';
import '../section_registry.dart';

/// The kind icon and spoken kind of a single selected node, or null when it
/// is gone. Recomputed per document change, compared by value.
final _nodeKindProvider = Provider.autoDispose
    .family<({IconData icon, String kind})?, String>((ref, id) {
      final doc = ref.watch(
        editorControllerProvider.select((s) => Identity(s.document)),
      );
      final bp = ref.watch(
        editorControllerProvider.select((s) => s.breakpointId),
      );
      final authored = ir.DocumentIndex.of(doc.value).node(id);
      final ir.Node? node =
          authored ??
          (bp == null
              ? null
              : ref
                    .watch(resolvedForProvider(bp))
                    .resolved
                    .nodeIndex[id]
                    ?.node);
      if (node == null) return null;
      final instance = node is ir.InstanceNode;
      return (
        icon: layerIcon(node, instance: instance),
        kind: layerKindName(node, instance: instance),
      );
    }, dependencies: [editorControllerProvider, resolvedForProvider]);

/// Name and kind, role, and alt text for figures.
final InspectorSectionSpec headerSection = InspectorSectionSpec(
  id: 'header',
  title: 'Layer',
  appliesTo: (info) => !info.isEmpty,
  collapsible: false,
  builder: (context, info) => const _Header(),
);

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final t = context.ss;
    final ids = scope.ids;
    final role = watchReading(context, ref, 'role');
    final showAlt =
        role.enumName == ir.NodeRole.figure.name ||
        ref.watch(
          selectionInfoProvider.select(
            (i) => i.kinds.contains(ir.NodeKind.video),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ids.length == 1)
          _SingleTitle(id: ids.single)
        else
          Padding(
            padding: const EdgeInsets.only(bottom: SsSpace.s2),
            child: Row(
              children: [
                const SsIcon(SsIcons.layers, size: 16),
                const SizedBox(width: SsSpace.s2),
                Text(
                  '${ids.length} layers',
                  key: const ValueKey<String>('inspector-selection-name'),
                  style: t.text.bodyStrong,
                ),
              ],
            ),
          ),
        LabelRow(
          label: 'Role',
          child: EnumProp(
            path: 'role',
            semanticLabel: 'Role',
            dropdown: true,
            shared: true,
            options: [
              for (final r in ir.NodeRole.values)
                EnumOption(r.name, roleName(r)),
            ],
          ),
        ),
        if (showAlt) const _AltText(),
      ],
    );
  }
}

class _SingleTitle extends ConsumerWidget {
  const _SingleTitle({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = ref.watch(_nodeKindProvider(id));
    final name = watchReading(context, ref, 'name');
    final text = name.value is ir.StringValue
        ? (name.value! as ir.StringValue).value
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Row(
        children: [
          SsIcon(k?.icon ?? SsIcons.square, size: 16, semanticLabel: k?.kind),
          const SizedBox(width: SsSpace.s2),
          Expanded(
            child: _NameField(
              // A new field per node: the draft belongs to one layer.
              key: ValueKey<String>('name:$id'),
              id: id,
              name: text,
              placeholder: k?.kind ?? 'Layer',
            ),
          ),
        ],
      ),
    );
  }
}

/// The layer name: commits on Enter or blur, Escape reverts.
class _NameField extends ConsumerStatefulWidget {
  const _NameField({
    required this.id,
    required this.name,
    required this.placeholder,
    super.key,
  });

  final String id;
  final String name;
  final String placeholder;

  @override
  ConsumerState<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends ConsumerState<_NameField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.name,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_NameField old) {
    super.didUpdateWidget(old);
    // Follow external renames (the Layers panel, undo) unless typing.
    if (!_focus.hasFocus && widget.name != _text.text) {
      _text.text = widget.name;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final v = _text.text;
    if (v == widget.name) return;
    ref
        .read(editorControllerProvider.notifier)
        .execute(RenameNode(widget.id, v));
  }

  @override
  Widget build(BuildContext context) {
    final style = context.ss.text.bodyStrong;
    return SsTextField(
      key: const ValueKey<String>('inspector-selection-name'),
      controller: _text,
      focusNode: _focus,
      placeholder: widget.placeholder,
      semanticLabel: 'Layer name',
      textStyle: style,
      dense: true,
      revertOnEscape: true,
      selectAllOnFocus: true,
      onSubmitted: (_) => _commit(),
    );
  }
}

class _AltText extends ConsumerStatefulWidget {
  const _AltText();

  @override
  ConsumerState<_AltText> createState() => _AltTextState();
}

class _AltTextState extends ConsumerState<_AltText> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _shown = '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    if (_text.text == _shown) return;
    final v = _text.text.trim();
    InspectorScope.of(context).writer.set(
      'altText',
      v.isEmpty ? const ir.IrValue.none() : ir.IrValue.string(v),
      shared: true,
    );
    _shown = _text.text;
  }

  @override
  Widget build(BuildContext context) {
    final r = watchReading(context, ref, 'altText');
    final v = r.value;
    final current = v is ir.StringValue ? v.value : '';
    if (!_focus.hasFocus && current != _shown) {
      _shown = current;
      _text.text = r.mixed ? '' : current;
    }
    return LabelRow(
      label: 'Alt text',
      child: FieldFrame.single(
        path: 'altText',
        child: SsTextField(
          key: const ValueKey<String>('field:altText'),
          controller: _text,
          focusNode: _focus,
          placeholder: r.mixed ? 'Mixed' : 'Describe for screen readers',
          semanticLabel: 'Alt text',
          dense: true,
          revertOnEscape: true,
          onSubmitted: (_) => _commit(),
        ),
      ),
    );
  }
}
