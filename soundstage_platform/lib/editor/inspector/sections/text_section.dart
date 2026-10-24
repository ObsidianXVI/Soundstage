import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../text/text_edit_controller.dart';
import '../../text/text_icons.dart';
import '../../text/text_style_target.dart';
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';
import '../section_registry.dart';
import 'appearance_style_banner.dart';
import 'paint_stack.dart';
import 'text_target.dart';

/// The text section (architecture §7, T1.8): every text field.
///
/// Its controls are the registry-driven props on `style.*` paths, read and
/// written through [TextTargetNodes] / [TextTargetWriter]: the whole text
/// outside edit mode (node-level style, Mixed when spans differ), the text
/// selection in edit mode. Strokes and effects of text are the Stroke and
/// Effects sections.
final InspectorSectionSpec textSection = InspectorSectionSpec(
  id: 'text',
  title: 'Text',
  appliesTo: (info) => info.kinds.contains(ir.NodeKind.text),
  builder: (context, info) => const TextSectionBody(),
);

/// The body of the text section: the text target scope around the controls.
class TextSectionBody extends ConsumerStatefulWidget {
  const TextSectionBody({super.key});

  @override
  ConsumerState<TextSectionBody> createState() => _TextSectionBodyState();
}

class _TextSectionBodyState extends ConsumerState<TextSectionBody> {
  TextTargetWriter? _writer;
  List<String>? _writerIds;
  TextTargetNodes? _nodes;

  @override
  Widget build(BuildContext context) {
    final scope = InspectorScope.of(context);
    final base = ref.watch(selectedNodesProvider);
    final edit = ref.watch(textEditProvider);
    return ValueListenableBuilder<TextRangeTarget?>(
      valueListenable: edit.target,
      builder: (context, target, _) {
        final nodes = _nodes = TextTargetNodes(base, target);
        if (_writer == null || _writerIds != scope.ids) {
          _writerIds = scope.ids;
          _writer = TextTargetWriter(
            scope.writer.controller,
            scope.writer.readState,
            scope.ids,
            readNodes: () => _nodes!,
            readSession: () => edit.session,
          );
        }
        return ProviderScope(
          overrides: [selectedNodesProvider.overrideWithValue(nodes)],
          child: InspectorScope(
            selection: scope.selection,
            writer: _writer!,
            child: _TextControls(editing: target != null),
          ),
        );
      },
    );
  }
}

class _TextControls extends StatelessWidget {
  const _TextControls({required this.editing});

  final bool editing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (editing)
        Padding(
          padding: const EdgeInsets.only(bottom: SsSpace.s2),
          child: Text(
            'Editing the selected text',
            key: const ValueKey<String>('text-editing-hint'),
            style: context.ss.text.caption,
          ),
        ),
      const _NamedStyle(),
      const LabelRow(label: 'Font', child: _FontFamilyField()),
      const Grid(
        children: [
          _WeightField(),
          NumberProp(
            path: 'style.fontSize',
            label: 'S',
            semanticLabel: 'Font size',
            min: 1,
            fractionDigits: 1,
          ),
          _LineHeightField(),
          _LetterSpacingField(),
          NumberProp(
            path: 'style.paragraphSpacing',
            label: '¶',
            semanticLabel: 'Paragraph spacing',
            min: 0,
          ),
          NumberProp(
            path: 'style.paragraphIndent',
            label: '⇥',
            semanticLabel: 'Paragraph indent',
            min: 0,
          ),
        ],
      ),
      const LabelRow(
        label: 'Style',
        child: Row(
          children: [
            BoolIconProp(
              path: 'style.italic',
              icon: TextIcons.italic,
              semanticLabel: 'Italic',
            ),
            _DecorationToggle(
              kind: 'underline',
              icon: TextIcons.underline,
              label: 'Underline',
            ),
            _DecorationToggle(
              kind: 'strikethrough',
              icon: TextIcons.strikethrough,
              label: 'Strikethrough',
            ),
          ],
        ),
      ),
      const LabelRow(
        label: 'Align',
        child: EnumProp(
          path: 'alignHorizontal',
          semanticLabel: 'Horizontal text alignment',
          iconOnly: true,
          options: [
            EnumOption('left', 'Left', icon: TextIcons.alignLeft),
            EnumOption('center', 'Centre', icon: TextIcons.alignCenter),
            EnumOption('right', 'Right', icon: TextIcons.alignRight),
            EnumOption('justified', 'Justify', icon: TextIcons.alignJustify),
          ],
        ),
      ),
      const LabelRow(
        label: 'Vertical',
        child: EnumProp(
          path: 'alignVertical',
          semanticLabel: 'Vertical text alignment',
          iconOnly: true,
          options: [
            EnumOption('top', 'Top', icon: TextIcons.alignTop),
            EnumOption('middle', 'Middle', icon: TextIcons.alignMiddle),
            EnumOption('bottom', 'Bottom', icon: TextIcons.alignBottom),
          ],
        ),
      ),
      const LabelRow(
        label: 'Resize',
        child: EnumProp(
          path: 'autoResize',
          semanticLabel: 'Auto resize',
          iconOnly: true,
          options: [
            EnumOption(
              'widthAndHeight',
              'Auto width',
              icon: SsIcons.arrowLeftRight,
            ),
            EnumOption('height', 'Auto height', icon: SsIcons.arrowUpDown),
            EnumOption('fixed', 'Fixed size', icon: SsIcons.square),
            EnumOption('truncate', 'Truncate', icon: SsIcons.ellipsis),
          ],
        ),
      ),
      const Grid(children: [_MaxLinesField(), _TruncationField()]),
      const GroupLabel('Details'),
      const LabelRow(
        label: 'Case',
        child: EnumProp(
          path: 'style.textCase',
          semanticLabel: 'Text case',
          dropdown: true,
          options: [
            EnumOption('none', 'As typed'),
            EnumOption('upper', 'UPPERCASE'),
            EnumOption('lower', 'lowercase'),
            EnumOption('title', 'Title Case'),
            EnumOption('smallCaps', 'Small caps'),
            EnumOption('smallCapsForced', 'Forced small caps'),
          ],
        ),
      ),
      const LabelRow(
        label: 'List',
        child: EnumProp(
          path: 'style.listStyle',
          semanticLabel: 'List style',
          iconOnly: true,
          options: [
            EnumOption('none', 'No list', icon: SsIcons.minus),
            EnumOption('unordered', 'Bullets', icon: TextIcons.list),
            EnumOption('ordered', 'Numbers', icon: TextIcons.listOrdered),
          ],
        ),
      ),
      const LabelRow(
        label: 'Baseline',
        child: EnumProp(
          path: 'style.baselineShift',
          semanticLabel: 'Baseline shift',
          iconOnly: true,
          options: [
            EnumOption('none', 'Normal', icon: TextIcons.baseline),
            EnumOption(
              'superscript',
              'Superscript',
              icon: TextIcons.superscript,
            ),
            EnumOption('subscript', 'Subscript', icon: TextIcons.subscript),
          ],
        ),
      ),
      const LabelRow(
        label: 'Trim',
        child: EnumProp(
          path: 'leadingTrim',
          semanticLabel: 'Leading trim',
          options: [
            EnumOption('none', 'None'),
            EnumOption('capHeight', 'Cap height'),
          ],
        ),
      ),
      const _DecorationDetails(),
      const GroupLabel('OpenType'),
      const _OpenTypeFeatures(),
      const GroupLabel('Fill'),
      const Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [AddPaintButton(stackPath: 'style.fills')],
      ),
      const PaintStackEditor(stackPath: 'style.fills'),
    ],
  );
}

// ---- Named style -----------------------------------------------------------------

/// The named text style (`textStyleId`) of the selection: its name, Mixed,
/// and Detach (the style's values become the node's own).
class _NamedStyle extends ConsumerWidget {
  const _NamedStyle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    InspectorScope.of(context);
    // Style ids are cleared in the resolved tree: read the authored nodes.
    final (id, mixed) = ref.watch(
      selectedNodesProvider.select((s) {
        String? first;
        var seen = false;
        for (final n in s.authored) {
          if (n is! ir.TextNode) continue;
          if (!seen) {
            first = n.textStyleId;
            seen = true;
          } else if (n.textStyleId != first) {
            return (null, true);
          }
        }
        return (first, false);
      }),
    );
    final w = InspectorScope.of(context).writer;
    final doc = ref.read(selectedNodesProvider).document;
    if (!mixed && id == null) return const SizedBox.shrink();
    if (mixed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: SsSpace.s2),
        child: Text(
          'Text style: Mixed',
          key: const ValueKey<String>('text-style-mixed'),
          style: context.ss.text.caption,
        ),
      );
    }
    final def = doc.tokens.textStyles[id];
    return StyleBanner(
      bannerKey: const ValueKey<String>('text-style'),
      name: def?.name ?? id!,
      onDetach: () {
        final values = <String, ir.IrValue>{
          'textStyleId': const ir.IrValue.none(),
        };
        if (def != null) {
          final carrier = ir.TextNode(
            common: const ir.NodeCommon(id: ''),
            style: def.style,
          );
          for (final f in _styleFields) {
            if (!overrideSets(def.style, f)) continue;
            final v = ir.PropertyRegistry.standard.get(carrier, 'style.$f');
            if (v != null) values['style.$f'] = v;
          }
        }
        // Node level: detaching keeps the look of the whole text.
        w.controller.execute(
          CommandBatch([
            for (final MapEntry(:key, :value) in values.entries)
              SetProperty(w.ids, key, value),
          ], label: 'Detach text style'),
        );
      },
    );
  }
}

const List<String> _styleFields = [
  'fontFamilyId',
  'fontWeight',
  'italic',
  'fontSize',
  'lineHeight',
  'letterSpacing',
  'paragraphSpacing',
  'paragraphIndent',
  'textCase',
  'fills',
  'baselineShift',
  'listStyle',
];

// ---- Font ---------------------------------------------------------------------------

/// The document's font families plus the default.
class _FontFamilyField extends ConsumerWidget {
  const _FontFamilyField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'style.fontFamilyId';
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final fonts = ref.read(selectedNodesProvider).document.fonts;
    final v = r.value;
    final current = v is ir.StringValue ? v.value : '';
    return FieldFrame.single(
      path: path,
      child: SsDropdown<String>(
        key: const ValueKey<String>('field:$path'),
        semanticLabel: 'Font family',
        value: r.mixed ? null : current,
        mixed: r.mixed,
        enabled: r.exists,
        onChanged: (id) => w.set(
          path,
          id.isEmpty ? const ir.IrValue.none() : ir.IrValue.string(id),
        ),
        items: [
          const SsDropdownItem(value: '', label: 'Default (sans)'),
          for (final f in fonts.values)
            SsDropdownItem(
              value: f.id,
              label: _isVariable(f) ? '${f.name} (variable)' : f.name,
            ),
          if (current.isNotEmpty && !fonts.containsKey(current))
            SsDropdownItem(value: current, label: '$current (missing)'),
        ],
      ),
    );
  }
}

bool _isVariable(ir.FontFamily f) => f.faces.any((x) => x.variable);

/// The `wght` axis of [f]'s variable faces, if any.
ir.FontAxis? weightAxisOf(ir.FontFamily? f) {
  if (f == null) return null;
  for (final face in f.faces) {
    for (final a in face.axes) {
      if (a.tag == 'wght') return a;
    }
  }
  return null;
}

const Map<int, String> kNamedWeights = {
  100: 'Thin',
  200: 'Extra Light',
  300: 'Light',
  400: 'Regular',
  500: 'Medium',
  600: 'Semi Bold',
  700: 'Bold',
  800: 'Extra Bold',
  900: 'Black',
};

/// Font weight: named weights (the family's faces when it has static
/// faces), or a scrubbable number in the `wght` range for a variable font.
class _WeightField extends ConsumerWidget {
  const _WeightField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'style.fontWeight';
    final family = watchReading(context, ref, 'style.fontFamilyId');
    final fonts = ref.read(selectedNodesProvider).document.fonts;
    final fv = family.value;
    final f = !family.mixed && fv is ir.StringValue ? fonts[fv.value] : null;
    final axis = weightAxisOf(f);
    if (axis != null) {
      return NumberProp(
        path: path,
        label: 'W',
        semanticLabel: 'Font weight',
        min: axis.min,
        max: axis.max,
        fractionDigits: 0,
      );
    }
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final weight = r.number?.round();
    final available = f == null || f.faces.isEmpty
        ? kNamedWeights.keys.toList()
        : ({for (final face in f.faces) face.weight}.toList()..sort());
    return FieldFrame.single(
      path: path,
      child: SsDropdown<int>(
        key: const ValueKey<String>('field:$path'),
        semanticLabel: 'Font weight',
        value: r.mixed ? null : weight,
        mixed: r.mixed,
        enabled: r.exists,
        onChanged: (v) => w.set(path, ir.IrValue.number(v.toDouble())),
        items: [
          for (final v in {...available, ?weight}.toList()..sort())
            SsDropdownItem(value: v, label: kNamedWeights[v] ?? '$v'),
        ],
      ),
    );
  }
}

// ---- Line height and letter spacing ----------------------------------------------------

/// Line height: Auto, px or %.
class _LineHeightField extends ConsumerWidget {
  const _LineHeightField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'style.lineHeight';
    final r = watchReading(context, ref, path);
    final size = watchReading(context, ref, 'style.fontSize').number ?? 16;
    final w = InspectorScope.of(context).writer;
    final v = r.value;
    final lh = v is ir.LineHeightValue ? v.value : const ir.LineHeight.auto();
    final (num, unit) = switch (lh) {
      ir.AutoLineHeight() => (null, 'auto'),
      ir.PxLineHeight(:final value) => (value, 'px'),
      ir.PercentLineHeight(:final value) => (value, '%'),
    };
    void write(ir.LineHeight x) => w.set(path, ir.IrValue.lineHeight(x));
    return FieldFrame.single(
      path: path,
      child: Row(
        children: [
          Expanded(
            child: SsNumberField(
              key: const ValueKey<String>('field:$path'),
              semanticLabel: 'Line height',
              label: 'LH',
              value: r.mixed ? null : num,
              mixed: r.mixed,
              min: 0,
              enabled: r.exists,
              onChangeStart: w.beginGesture,
              onChangeEnd: w.endGesture,
              onChanged: (x) => write(
                unit == '%' ? ir.LineHeight.percent(x) : ir.LineHeight.px(x),
              ),
            ),
          ),
          const SizedBox(width: SsSpace.s1),
          SizedBox(
            width: 64,
            child: SsDropdown<String>(
              key: const ValueKey<String>('field:$path:unit'),
              semanticLabel: 'Line height unit',
              value: r.mixed ? null : unit,
              enabled: r.exists,
              onChanged: (u) => write(switch (u) {
                'px' => ir.LineHeight.px(
                  _round(
                    num == null
                        ? size * 1.2
                        : (unit == '%' ? num * size / 100 : num),
                  ),
                ),
                '%' => ir.LineHeight.percent(
                  _round(
                    num == null ? 120 : (unit == 'px' ? num / size * 100 : num),
                  ),
                ),
                _ => const ir.LineHeight.auto(),
              }),
              items: const [
                SsDropdownItem(value: 'auto', label: 'Auto'),
                SsDropdownItem(value: 'px', label: 'px'),
                SsDropdownItem(value: '%', label: '%'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

double _round(double v) => (v * 100).roundToDouble() / 100;

/// Letter spacing: px or % of the font size.
class _LetterSpacingField extends ConsumerWidget {
  const _LetterSpacingField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'style.letterSpacing';
    final r = watchReading(context, ref, path);
    final size = watchReading(context, ref, 'style.fontSize').number ?? 16;
    final w = InspectorScope.of(context).writer;
    final v = r.value;
    final ls = v is ir.LetterSpacingValue
        ? v.value
        : const ir.LetterSpacing.percent();
    final (num, percent) = switch (ls) {
      ir.PxLetterSpacing(:final value) => (value, false),
      ir.PercentLetterSpacing(:final value) => (value, true),
    };
    void write(ir.LetterSpacing x) => w.set(path, ir.IrValue.letterSpacing(x));
    return FieldFrame.single(
      path: path,
      child: Row(
        children: [
          Expanded(
            child: SsNumberField(
              key: const ValueKey<String>('field:$path'),
              semanticLabel: 'Letter spacing',
              label: 'LS',
              value: r.mixed ? null : num,
              mixed: r.mixed,
              step: 0.1,
              enabled: r.exists,
              onChangeStart: w.beginGesture,
              onChangeEnd: w.endGesture,
              onChanged: (x) => write(
                percent ? ir.LetterSpacing.percent(x) : ir.LetterSpacing.px(x),
              ),
            ),
          ),
          const SizedBox(width: SsSpace.s1),
          SizedBox(
            width: 64,
            child: SsDropdown<String>(
              key: const ValueKey<String>('field:$path:unit'),
              semanticLabel: 'Letter spacing unit',
              value: r.mixed ? null : (percent ? '%' : 'px'),
              enabled: r.exists,
              onChanged: (u) => write(
                u == '%'
                    ? ir.LetterSpacing.percent(
                        _round(percent ? num : num / size * 100),
                      )
                    : ir.LetterSpacing.px(
                        _round(percent ? num * size / 100 : num),
                      ),
              ),
              items: const [
                SsDropdownItem(value: 'px', label: 'px'),
                SsDropdownItem(value: '%', label: '%'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Box ---------------------------------------------------------------------------------

/// Max lines (empty = unlimited).
class _MaxLinesField extends ConsumerWidget {
  const _MaxLinesField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'maxLines';
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final set = r.number != null;
    return FieldFrame.single(
      path: path,
      child: Row(
        children: [
          Expanded(
            child: SsNumberField(
              key: const ValueKey<String>('field:$path'),
              semanticLabel: 'Max lines',
              label: 'Lines',
              value: r.mixed ? null : r.number,
              mixed: r.mixed,
              min: 1,
              fractionDigits: 0,
              enabled: r.exists,
              onChanged: (x) =>
                  w.set(path, ir.IrValue.number(x.roundToDouble())),
            ),
          ),
          if (set)
            SsIconButton(
              key: const ValueKey<String>('field:maxLines:clear'),
              icon: SsIcons.x,
              semanticLabel: 'No line limit',
              size: 24,
              iconSize: 12,
              onPressed: () => w.set(path, const ir.IrValue.none()),
            ),
        ],
      ),
    );
  }
}

class _TruncationField extends StatelessWidget {
  const _TruncationField();

  @override
  Widget build(BuildContext context) => const EnumCheckProp(
    path: 'truncation',
    checkedValue: 'ending',
    uncheckedValue: 'none',
    label: 'Ellipsis',
  );
}

// ---- Decoration ------------------------------------------------------------------------

class _DecorationToggle extends ConsumerWidget {
  const _DecorationToggle({
    required this.kind,
    required this.icon,
    required this.label,
  });

  final String kind;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const path = 'style.decoration.kind';
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final on = !r.mixed && r.enumName == kind;
    return SsIconButton(
      key: ValueKey<String>('field:$path:$kind'),
      icon: icon,
      semanticLabel: label,
      selected: on,
      onPressed: r.exists
          ? () => w.set(path, ir.IrValue.enumValue(on ? 'none' : kind))
          : null,
    );
  }
}

/// Decoration style, thickness and colour (shown when the text has one).
class _DecorationDetails extends ConsumerWidget {
  const _DecorationDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = watchReading(context, ref, 'style.decoration.kind');
    if (!kind.mixed && (kind.enumName ?? 'none') == 'none') {
      return const SizedBox.shrink();
    }
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabelRow(
          label: 'Line',
          child: EnumProp(
            path: 'style.decoration.style',
            semanticLabel: 'Decoration style',
            dropdown: true,
            options: [
              EnumOption('solid', 'Solid'),
              EnumOption('double', 'Double'),
              EnumOption('dotted', 'Dotted'),
              EnumOption('dashed', 'Dashed'),
              EnumOption('wavy', 'Wavy'),
            ],
          ),
        ),
        Grid(
          children: [
            NumberProp(
              path: 'style.decoration.thickness',
              label: 'T',
              semanticLabel: 'Decoration thickness',
              min: 0,
              step: 0.5,
            ),
            ColorProp(
              path: 'style.decoration.color',
              semanticLabel: 'Decoration colour',
            ),
          ],
        ),
      ],
    );
  }
}

// ---- OpenType --------------------------------------------------------------------------

/// The OpenType features offered as toggles, with their defaults (on for
/// standard ligatures, off for the rest) and labels.
const List<(String, String, bool)> kOpenTypeToggles = [
  ('liga', 'Ligatures', true),
  ('tnum', 'Tabular figures', false),
  ('smcp', 'Small caps', false),
  ('ss01', 'Stylistic set 1', false),
  ('ss02', 'Stylistic set 2', false),
  ('ss03', 'Stylistic set 3', false),
  ('ss04', 'Stylistic set 4', false),
  ('ss05', 'Stylistic set 5', false),
];

class _OpenTypeFeatures extends StatelessWidget {
  const _OpenTypeFeatures();

  @override
  Widget build(BuildContext context) => Grid(
    children: [
      for (final (tag, label, on) in kOpenTypeToggles)
        _OpenTypeToggle(tag: tag, label: label, defaultOn: on),
    ],
  );
}

class _OpenTypeToggle extends ConsumerWidget {
  const _OpenTypeToggle({
    required this.tag,
    required this.label,
    required this.defaultOn,
  });

  final String tag;
  final String label;
  final bool defaultOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = 'style.openType.$tag';
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final n = r.number;
    final on = n == null ? defaultOn : n >= 1;
    // The tag is the label (what type designers name it); the description
    // is the semantic label.
    return SsCheckbox(
      key: ValueKey<String>('field:$path'),
      label: tag,
      semanticLabel: label,
      value: r.mixed ? null : on,
      onChanged: (v) => w.set(path, ir.IrValue.number(v ? 1 : 0)),
    );
  }
}
