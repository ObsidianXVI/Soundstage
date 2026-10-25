import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../section_registry.dart';

/// Modes of a single frame (architecture §8; m3.md "Modes on frames and
/// scenes"): one row per token collection with more than one mode, Auto
/// (inherit) or a mode, inherited by the frame's descendants.
final InspectorSectionSpec modesSection = InspectorSectionSpec(
  id: 'modes',
  title: 'Modes',
  appliesTo: (info) =>
      info.hasModes &&
      info.ids.length == 1 &&
      !info.ids.single.contains('/') &&
      info.kinds.length == 1 &&
      info.kinds.single == ir.NodeKind.frame,
  builder: (context, info) => ModeOverrideRows(nodeId: info.ids.single),
);

/// The mode rows of frame [nodeId] or scene [sceneId] (exactly one).
class ModeOverrideRows extends ConsumerWidget {
  const ModeOverrideRows({this.nodeId, this.sceneId, super.key})
    : assert((nodeId == null) != (sceneId == null));

  final String? nodeId;
  final String? sceneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final cols = ref.watch(
      editorControllerProvider.select((s) => s.document.tokens.collections),
    );
    final overrides = ref.watch(
      editorControllerProvider.select((s) {
        final doc = s.document;
        if (sceneId != null) {
          for (final sc in doc.scenes) {
            if (sc.id == sceneId) return sc.modeOverrides;
          }
          return const <String, String>{};
        }
        final n = ir.DocumentIndex.of(doc).node(nodeId!);
        return n is ir.FrameNode ? n.modeOverrides : const <String, String>{};
      }),
    );
    final ctl = ref.read(editorControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in cols)
          if (c.modes.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: SsSpace.s2),
              child: Row(
                children: [
                  SizedBox(
                    width: 76,
                    child: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.text.small.copyWith(
                        color: t.colors.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SsDropdown<String>(
                      key: ValueKey<String>('mode-override-${c.id}'),
                      semanticLabel: '${c.name} mode',
                      value: overrides[c.id] ?? '',
                      onChanged: (m) => ctl.execute(
                        TokenEdit(
                          'Set mode',
                          (d) => ir.setModeOverride(
                            d,
                            c.id,
                            m.isEmpty ? null : m,
                            nodeId: nodeId,
                            sceneId: sceneId,
                          ),
                        ),
                      ),
                      items: [
                        const SsDropdownItem(value: '', label: 'Auto'),
                        for (final m in c.modes)
                          SsDropdownItem(value: m.id, label: m.name),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
