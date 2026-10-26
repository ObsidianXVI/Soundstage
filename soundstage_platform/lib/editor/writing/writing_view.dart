import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../core/core.dart';
import 'writing_blocks.dart';
import 'writing_field.dart';
import 'writing_note.dart';

/// The readable measure of the Writing view.
const double kWritingMeasure = 720;

/// Writing mode's surface (m5.md T5.2): the story's words in reading order,
/// scene by scene, each text node edited in place. Figures show as quiet
/// placeholders with their alt text; text outside the reading flow follows
/// each scene as "Other text". Read at the first primary breakpoint; edits
/// go to the shared base, so every breakpoint gets them.
class WritingView extends ConsumerStatefulWidget {
  const WritingView({super.key});

  @override
  ConsumerState<WritingView> createState() => _WritingViewState();
}

class _WritingViewState extends ConsumerState<WritingView> {
  late final EditorController _editor = ref.read(
    editorControllerProvider.notifier,
  );
  StageEnvironment? _env;
  Object? _envKey;
  late final TextMeasurer _sizer = stageTextMeasurer(
    () => _env?.fonts ?? StageFontTable.none,
  );

  @override
  void initState() {
    super.initState();
    // Auto-sized text is measured here while the canvas is away.
    _editor.textMeasurer = _sizer;
  }

  @override
  void dispose() {
    if (identical(_editor.textMeasurer, _sizer)) _editor.textMeasurer = null;
    super.dispose();
  }

  void _ensureEnvironment(ir.StageDocument doc) {
    final key = (doc.fonts, doc.assets);
    final last = _envKey as (Object, Object)?;
    if (_env != null && last != null && last.$1 == key.$1) return;
    _envKey = key;
    _env = StageEnvironment.forDocument(doc, mode: StageRenderMode.edit);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final doc = ref.watch(editorControllerProvider.select((s) => s.document));
    _ensureEnvironment(doc);
    final bp =
        doc.primaryBreakpoints.firstOrNull ?? doc.breakpoints.firstOrNull;
    if (bp == null || doc.scenes.isEmpty) {
      return Center(
        child: Text(
          'This story has no scenes yet. Add one in Design.',
          style: t.text.body.copyWith(color: t.colors.textSecondary),
        ),
      );
    }
    final scenes = writingScenes(_editor.resolvedFor(bp.id).resolved);
    final styles = WritingStyles.of(context);
    return ColoredBox(
      color: t.colors.surface0,
      child: ListView.builder(
        key: const ValueKey<String>('writing-view'),
        padding: const EdgeInsets.symmetric(
          horizontal: SsSpace.s6,
          vertical: SsSpace.s8,
        ),
        itemCount: scenes.length,
        itemBuilder: (context, i) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kWritingMeasure),
            child: _SceneSection(
              scene: scenes[i],
              index: i,
              breakpointId: bp.id,
              styles: styles,
            ),
          ),
        ),
      ),
    );
  }
}

/// The Writing view's text styles by role.
class WritingStyles {
  const WritingStyles._(this.body, this.headings, this.quote, this.caption);

  factory WritingStyles.of(BuildContext context) {
    final t = context.ss;
    final body = t.text.body.copyWith(
      fontSize: 17,
      height: 1.65,
      color: t.colors.textPrimary,
    );
    TextStyle heading(double size) => body.copyWith(
      fontSize: size,
      height: 1.3,
      fontWeight: FontWeight.w700,
      fontVariations: const [FontVariation('wght', 700)],
    );
    return WritingStyles._(
      body,
      [
        heading(30),
        heading(24),
        heading(20),
        heading(18),
        heading(17),
        heading(17),
      ],
      body.copyWith(fontStyle: FontStyle.italic, color: t.colors.textSecondary),
      body.copyWith(fontSize: 14, color: t.colors.textSecondary),
    );
  }

  final TextStyle body;
  final List<TextStyle> headings;
  final TextStyle quote;
  final TextStyle caption;

  TextStyle forRole(ir.NodeRole role) => switch (role) {
    ir.NodeRole.heading1 ||
    ir.NodeRole.heading2 ||
    ir.NodeRole.heading3 ||
    ir.NodeRole.heading4 ||
    ir.NodeRole.heading5 ||
    ir.NodeRole.heading6 => headings[role.index - ir.NodeRole.heading1.index],
    ir.NodeRole.quote => quote,
    ir.NodeRole.caption => caption,
    _ => body,
  };
}

class _SceneSection extends StatelessWidget {
  const _SceneSection({
    required this.scene,
    required this.index,
    required this.breakpointId,
    required this.styles,
  });

  final WritingScene scene;
  final int index;
  final String breakpointId;
  final WritingStyles styles;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final other = scene.other.toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s8),
      child: Column(
        key: ValueKey<String>('writing-scene:${scene.id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WritingNoted(
            id: scene.id,
            child: Text(
              '${index + 1} · ${scene.name.isEmpty ? 'Scene ${index + 1}' : scene.name}'
                  .toUpperCase(),
              style: t.text.overline,
            ),
          ),
          const SizedBox(height: SsSpace.s1),
          Divider(height: SsSpace.s4, color: t.colors.borderSubtle),
          if (scene.flow.isEmpty)
            Text(
              'No text in this scene.',
              style: t.text.body.copyWith(color: t.colors.textDisabled),
            ),
          for (final b in scene.flow)
            WritingNoted(
              key: ValueKey<String>('noted:${b.nodeId}'),
              id: b.nodeId.split('/').first,
              child: _block(context, b),
            ),
          if (other.isNotEmpty) ...[
            const SizedBox(height: SsSpace.s3),
            Text('Other text in this scene', style: t.text.caption),
            const SizedBox(height: SsSpace.s1),
            for (final b in other)
              Container(
                margin: const EdgeInsets.only(bottom: SsSpace.s2),
                padding: const EdgeInsets.all(SsSpace.s3),
                decoration: BoxDecoration(
                  border: Border.all(color: t.colors.borderSubtle),
                  borderRadius: BorderRadius.circular(SsRadius.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (b.label.isNotEmpty)
                      Text(b.label, style: t.text.caption),
                    _field(b, styles.body),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _block(BuildContext context, WritingBlock b) {
    final t = context.ss;
    if (b.kind == WritingBlockKind.figure) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: SsSpace.s3),
        padding: const EdgeInsets.symmetric(
          horizontal: SsSpace.s3,
          vertical: SsSpace.s2,
        ),
        decoration: BoxDecoration(
          color: t.colors.surface1,
          borderRadius: BorderRadius.circular(SsRadius.md),
        ),
        child: Row(
          children: [
            SsIcon(SsIcons.image, size: 16, color: t.colors.textSecondary),
            const SizedBox(width: SsSpace.s2),
            Expanded(
              child: Text(
                b.label.isEmpty ? 'Figure (no alt text)' : b.label,
                style: t.text.small.copyWith(color: t.colors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    final style = styles.forRole(b.role);
    final field = _field(b, style);
    final top = switch (b.role) {
      ir.NodeRole.heading1 || ir.NodeRole.heading2 => SsSpace.s5,
      ir.NodeRole.heading3 ||
      ir.NodeRole.heading4 ||
      ir.NodeRole.heading5 ||
      ir.NodeRole.heading6 => SsSpace.s4,
      _ => SsSpace.s2,
    };
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: SsSpace.s2),
      child: b.role == ir.NodeRole.quote
          ? Container(
              padding: const EdgeInsets.only(left: SsSpace.s3),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: t.colors.border, width: 3),
                ),
              ),
              child: field,
            )
          : field,
    );
  }

  Widget _field(WritingBlock b, TextStyle style) {
    final field = WritingField(
      key: ValueKey<String>('writing-field:${b.nodeId}'),
      nodeId: b.nodeId,
      breakpointId: breakpointId,
      style: style,
      readOnly: b.readOnly,
      semanticLabel: [
        _roleLabel(b.role),
        if (b.label.isNotEmpty) b.label,
      ].join(': '),
    );
    if (!b.readOnly) return field;
    return SsTooltip(message: 'Edit on the component', child: field);
  }
}

String _roleLabel(ir.NodeRole role) => switch (role) {
  ir.NodeRole.heading1 => 'Heading 1',
  ir.NodeRole.heading2 => 'Heading 2',
  ir.NodeRole.heading3 => 'Heading 3',
  ir.NodeRole.heading4 => 'Heading 4',
  ir.NodeRole.heading5 => 'Heading 5',
  ir.NodeRole.heading6 => 'Heading 6',
  ir.NodeRole.quote => 'Quote',
  ir.NodeRole.caption => 'Caption',
  ir.NodeRole.decorative => 'Decorative text',
  _ => 'Text',
};
