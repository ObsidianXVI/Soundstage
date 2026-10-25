import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../inspector_providers.dart';
import '../property_writer.dart';
import '../section_registry.dart';
import 'appearance_style_banner.dart';
import 'paint_stack.dart';
import 'style_picker.dart';

const String _fillsPath = 'fills';

/// The fill paint stack of frames, shapes and videos (text fills are part
/// of the text inspector).
final InspectorSectionSpec fillSection = InspectorSectionSpec(
  id: 'fill',
  title: 'Fill',
  appliesTo: (info) => info.hasAppearance,
  builder: (context, info) => const _FillBody(),
  actions: (context, info) => const [
    StylePickerButton(
      kind: ir.StyleKind.paint,
      stylePath: 'fillStyleId',
      valuePath: _fillsPath,
    ),
    AddPaintButton(stackPath: _fillsPath),
  ],
);

class _FillBody extends ConsumerWidget {
  const _FillBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final style = watchStackStyle(ref, _fillsPath);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (style.applied)
          StyleBanner(
            bannerKey: const ValueKey<String>('fill-style'),
            name: style.name!,
            onDetach: () {
              // The resolved stack is the style's: keep it as local paints.
              final stack = ref.read(selectedNodesProvider).read(_fillsPath);
              scope.writer.setMany({
                _fillsPath: stack.value ?? const ir.IrValue.paints([]),
                'fillStyleId': const ir.IrValue.none(),
              });
            },
          ),
        const PaintStackEditor(stackPath: _fillsPath),
      ],
    );
  }
}
