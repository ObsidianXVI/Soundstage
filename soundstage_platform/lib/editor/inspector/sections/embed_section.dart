import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../timeline/timeline_math.dart' show clockLabel;
import '../fields/props.dart';
import '../fields/rows.dart';
import '../property_writer.dart';
import '../section_registry.dart';

/// Lottie and Rive embeds (m3.md T3.6): scale, autoplay and loop; for Rive
/// the artboard and state machine; and clocks driving inputs (a Lottie's
/// progress, a Rive file's data-binding properties or inputs), e.g. the
/// scene's scroll.
final InspectorSectionSpec embedSection = InspectorSectionSpec(
  id: 'embed',
  title: 'Animation file',
  appliesTo: (info) =>
      info.ids.length == 1 &&
      info.kinds.length == 1 &&
      info.kinds.single == ir.NodeKind.embed,
  builder: (context, info) => _EmbedBody(nodeId: info.ids.single),
);

class _EmbedBody extends ConsumerWidget {
  const _EmbedBody({required this.nodeId});

  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final st = ref.watch(editorControllerProvider);
    final node = ir.DocumentIndex.of(st.document).node(nodeId);
    if (node is! ir.EmbedNode) return const SizedBox.shrink();
    final asset = st.document.assets[node.assetId];
    final isRive = asset?.kind == ir.AssetKind.rive;
    final w = InspectorScope.of(context).writer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${isRive ? 'Rive' : 'Lottie'} · ${asset?.name ?? 'missing file'}',
          style: t.text.caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: SsSpace.s2),
        const LabelRow(
          label: 'Scale',
          child: EnumProp(
            path: 'scaleMode',
            semanticLabel: 'Animation scale',
            options: [EnumOption('fit', 'Fit'), EnumOption('fill', 'Fill')],
          ),
        ),
        const BoolProp(path: 'autoplay', label: 'Autoplay'),
        const BoolProp(path: 'loop', label: 'Loop'),
        if (isRive) ...[
          _NameField(
            label: 'Artboard',
            path: 'artboard',
            value: node.artboard,
            writer: w,
          ),
          _NameField(
            label: 'State machine',
            path: 'stateMachine',
            value: node.stateMachine,
            writer: w,
          ),
        ],
        const SizedBox(height: SsSpace.s2),
        Text('DRIVEN BY CLOCKS', style: t.text.overline),
        const SizedBox(height: SsSpace.s1),
        if (!isRive)
          _BindingRow(
            label: 'Progress',
            input: 'progress',
            node: node,
            writer: w,
          )
        else ...[
          for (final input in node.inputBindings.keys)
            _BindingRow(
              label: input,
              input: input,
              node: node,
              writer: w,
              removable: true,
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: SsButton(
              key: const ValueKey<String>('embed:add-binding'),
              label: 'Add input',
              icon: SsIcons.plus,
              variant: SsButtonVariant.ghost,
              onPressed: () async {
                final name = await showSsPrompt(
                  context,
                  title: 'Input or property name',
                  confirmLabel: 'Add',
                );
                final clocks =
                    ref.read(editorControllerProvider).activeScene?.clocks ??
                    const <ir.Clock>[];
                if (name == null || clocks.isEmpty) return;
                w.set(
                  'inputBindings.$name',
                  ir.IrValue.string(clocks.first.id),
                  shared: true,
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

/// A Rive name field (empty: the file's default).
class _NameField extends StatelessWidget {
  const _NameField({
    required this.label,
    required this.path,
    required this.value,
    required this.writer,
  });

  final String label;
  final String path;
  final String? value;
  final PropertyWriter writer;

  @override
  Widget build(BuildContext context) => LabelRow(
    label: label,
    child: SsTextField(
      key: ValueKey<String>('embed:$path:$value'),
      semanticLabel: label,
      dense: true,
      placeholder: 'Default',
      initialValue: value ?? '',
      releaseFocusOnSubmit: true,
      onSubmitted: (v) => writer.set(
        path,
        v.trim().isEmpty
            ? const ir.IrValue.none()
            : ir.IrValue.string(v.trim()),
        shared: true,
      ),
    ),
  );
}

/// Which clock drives input [input].
class _BindingRow extends ConsumerWidget {
  const _BindingRow({
    required this.label,
    required this.input,
    required this.node,
    required this.writer,
    this.removable = false,
  });

  final String label;
  final String input;
  final ir.EmbedNode node;
  final PropertyWriter writer;
  final bool removable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clocks = ref.watch(
      editorControllerProvider.select(
        (s) => s.activeScene?.clocks ?? const <ir.Clock>[],
      ),
    );
    final doc = ref.read(editorControllerProvider).document;
    final current = node.inputBindings[input] ?? '';
    return LabelRow(
      label: label,
      child: Row(
        children: [
          Expanded(
            child: SsDropdown<String>(
              key: ValueKey<String>('embed:bind:$input'),
              semanticLabel: '$label clock',
              value: clocks.any((c) => c.id == current) ? current : '',
              onChanged: (id) => writer.set(
                'inputBindings.$input',
                id.isEmpty ? const ir.IrValue.none() : ir.IrValue.string(id),
                shared: true,
              ),
              items: [
                const SsDropdownItem(value: '', label: 'Nothing'),
                for (final c in clocks)
                  SsDropdownItem(value: c.id, label: clockLabel(doc, c)),
              ],
            ),
          ),
          if (removable)
            SsIconButton(
              icon: SsIcons.minus,
              semanticLabel: 'Remove $label',
              size: 24,
              iconSize: 12,
              onPressed: () => writer.set(
                'inputBindings.$input',
                const ir.IrValue.none(),
                shared: true,
              ),
            ),
        ],
      ),
    );
  }
}
