import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';
import '../section_registry.dart';
import 'appearance_blend.dart';
import 'appearance_style_banner.dart';

const String _effectsPath = 'effects';

/// The effect stack: drop and inner shadows, layer and background blur.
final InspectorSectionSpec effectsSection = InspectorSectionSpec(
  id: 'effects',
  title: 'Effects',
  appliesTo: (info) => info.hasStroke,
  builder: (context, info) => const _EffectsBody(),
  actions: (context, info) => const [_AddEffectButton()],
);

enum _Kind { dropShadow, innerShadow, layerBlur, backgroundBlur }

_Kind _kindOf(ir.Effect e) => switch (e) {
  ir.DropShadow() => _Kind.dropShadow,
  ir.InnerShadow() => _Kind.innerShadow,
  ir.LayerBlur() => _Kind.layerBlur,
  ir.BackgroundBlur() => _Kind.backgroundBlur,
};

String _kindLabel(_Kind k) => switch (k) {
  _Kind.dropShadow => 'Drop shadow',
  _Kind.innerShadow => 'Inner shadow',
  _Kind.layerBlur => 'Layer blur',
  _Kind.backgroundBlur => 'Background blur',
};

ir.Effect _defaultEffect(_Kind k, String id) => switch (k) {
  _Kind.dropShadow => ir.Effect.dropShadow(id: id),
  _Kind.innerShadow => ir.Effect.innerShadow(id: id),
  _Kind.layerBlur => ir.Effect.layerBlur(id: id),
  _Kind.backgroundBlur => ir.Effect.backgroundBlur(id: id),
};

/// The resolved value of [path] for each of [ids], at the edited breakpoint.
Map<String, ir.IrValue> _valuesOf(
  WidgetRef ref,
  Iterable<String> ids,
  String path,
) {
  final bp = ref.read(editorControllerProvider).breakpointId;
  if (bp == null) return const {};
  final index = ref
      .read(editorControllerProvider.notifier)
      .resolvedFor(bp)
      .resolved
      .nodeIndex;
  final out = <String, ir.IrValue>{};
  for (final id in ids) {
    final n = index[id];
    if (n == null) continue;
    final v = ir.resolvedPropertyValue(n, path);
    if (v != null) out[id] = v;
  }
  return out;
}

List<ir.Effect> _effectsIn(ir.IrValue? v) =>
    v is ir.EffectsValue ? v.value : const [];

/// A deterministic id (`fx<n>`) unused in any of [stacks].
String _freshId(Iterable<List<ir.Effect>> stacks) {
  final used = {
    for (final s in stacks)
      for (final e in s) e.id,
  };
  var n = used.length + 1;
  while (used.contains('fx$n')) {
    n++;
  }
  return 'fx$n';
}

/// The name of the effect style the whole selection shares, or null.
final _effectStyleProvider = Provider.autoDispose.family<String?, ReadKey>((
  ref,
  key,
) {
  final doc = ref
      .watch(editorControllerProvider.select((s) => Identity(s.document)))
      .value;
  final index = ir.DocumentIndex.of(doc);
  String? common;
  var first = true;
  for (final id in key.ids) {
    final n = index.node(id.split('/').first);
    final style = switch (n) {
      ir.FrameNode(:final appearance) ||
      ir.ShapeNode(:final appearance) ||
      ir.VideoNode(:final appearance) => appearance.effectStyleId,
      ir.TextNode(:final appearance) => appearance.effectStyleId,
      _ => null,
    };
    if (first) {
      common = style;
      first = false;
    } else if (style != common) {
      return null;
    }
  }
  if (common == null) return null;
  return doc.tokens.effectStyles[common]?.name ?? common;
}, dependencies: [editorControllerProvider]);

/// The header "+" button: a menu of effect kinds, appending a default effect
/// to the top of every selected node's stack.
class _AddEffectButton extends ConsumerWidget {
  const _AddEffectButton();

  void _add(BuildContext context, WidgetRef ref, _Kind kind) {
    final scope = InspectorScope.of(context);
    final stacks = {
      for (final e in _valuesOf(ref, scope.ids, _effectsPath).entries)
        e.key: _effectsIn(e.value),
    };
    if (stacks.isEmpty) return;
    final id = _freshId(stacks.values);
    scope.writer.run(
      SetProperty.values({
        for (final e in stacks.entries)
          e.key: {
            _effectsPath: ir.IrValue.effects([
              ...e.value,
              _defaultEffect(kind, id),
            ]),
          },
      }),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Builder(
      builder: (btn) => SsIconButton(
        key: const ValueKey<String>('add-effect'),
        icon: SsIcons.plus,
        semanticLabel: 'Add effect',
        size: 24,
        iconSize: 14,
        onPressed: () => showSsMenu(
          btn,
          anchor: ssGlobalRect(btn),
          placement: SsPlacement.belowEnd,
          entries: [
            for (final k in _Kind.values)
              SsMenuItem(
                label: _kindLabel(k),
                onSelected: () => _add(context, ref, k),
              ),
          ],
        ),
      ),
    );
  }
}

class _EffectsBody extends ConsumerWidget {
  const _EffectsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final w = scope.writer;
    final r = watchReading(context, ref, _effectsPath);
    final style = ref.watch(
      _effectStyleProvider(ReadKey(scope.ids, 'effectStyleId')),
    );
    final banner = style == null
        ? null
        : StyleBanner(
            bannerKey: const ValueKey<String>('effect-style'),
            name: style,
            onDetach: () => w.setMany({
              _effectsPath: r.value ?? const ir.IrValue.effects([]),
              'effectStyleId': const ir.IrValue.none(),
            }),
          );
    if (!r.exists) return banner ?? const SizedBox.shrink();
    if (r.mixed && !_sameShape(_valuesOf(ref, scope.ids, _effectsPath))) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?banner,
          _MixedStack(
            onReplace: () =>
                w.set(_effectsPath, r.value ?? const ir.IrValue.effects([])),
          ),
        ],
      );
    }
    final effects = _effectsIn(r.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?banner,
        // The IR stack runs bottom to top; the list shows the top first.
        for (var i = effects.length - 1; i >= 0; i--)
          _EffectRow(
            key: ValueKey<String>('effect:${effects[i].id}'),
            effects: effects,
            index: i,
          ),
      ],
    );
  }
}

/// Whether every node's stack has the same effects (id and kind) in the
/// same order, so the rows can be shown with per-field Mixed values.
bool _sameShape(Map<String, ir.IrValue> values) {
  List<ir.Effect>? first;
  for (final v in values.values) {
    final list = _effectsIn(v);
    if (first == null) {
      first = list;
      continue;
    }
    if (list.length != first.length) return false;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id != first[i].id ||
          list[i].runtimeType != first[i].runtimeType) {
        return false;
      }
    }
  }
  return true;
}

class _MixedStack extends StatelessWidget {
  const _MixedStack({required this.onReplace});

  final VoidCallback onReplace;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Row(
      key: const ValueKey<String>('effects-mixed'),
      children: [
        Expanded(
          child: Text(
            'Mixed',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
        ),
        SsButton(
          label: 'Replace',
          variant: SsButtonVariant.ghost,
          onPressed: onReplace,
        ),
      ],
    );
  }
}

/// One effect: a header (visibility, name, menu, remove) that expands to the
/// effect's fields. Stack edits write the whole list; field edits write the
/// per-id paths.
class _EffectRow extends ConsumerStatefulWidget {
  const _EffectRow({required this.effects, required this.index, super.key});

  final List<ir.Effect> effects;
  final int index;

  @override
  ConsumerState<_EffectRow> createState() => _EffectRowState();
}

class _EffectRowState extends ConsumerState<_EffectRow> {
  bool _open = false;

  ir.Effect get _effect => widget.effects[widget.index];

  /// Rewrites every selected node's own stack with [edit] (given the stack
  /// and the index of this effect in it), as one undo step.
  void _apply(
    List<ir.Effect> Function(List<ir.Effect> list, int index, String freshId)
    edit,
  ) {
    final scope = InspectorScope.of(context);
    final stacks = {
      for (final e in _valuesOf(ref, scope.ids, _effectsPath).entries)
        e.key: _effectsIn(e.value),
    };
    final fresh = _freshId(stacks.values);
    final writes = <String, Map<String, ir.IrValue>>{};
    for (final e in stacks.entries) {
      final i = e.value.indexWhere((x) => x.id == _effect.id);
      if (i < 0) continue;
      writes[e.key] = {
        _effectsPath: ir.IrValue.effects(edit([...e.value], i, fresh)),
      };
    }
    if (writes.isNotEmpty) scope.writer.run(SetProperty.values(writes));
  }

  void _move(int delta) => _apply((list, i, _) {
    final to = i + delta;
    if (to < 0 || to >= list.length) return list;
    list.insert(to, list.removeAt(i));
    return list;
  });

  void _duplicate() => _apply((list, i, fresh) {
    list.insert(i + 1, list[i].copyWith(id: fresh));
    return list;
  });

  void _remove() => _apply((list, i, _) => list..removeAt(i));

  void _menu(BuildContext anchor) {
    final top = widget.index == widget.effects.length - 1;
    final bottom = widget.index == 0;
    showSsMenu(
      anchor,
      anchor: ssGlobalRect(anchor),
      placement: SsPlacement.belowEnd,
      minWidth: 140,
      entries: [
        SsMenuItem(label: 'Move up', enabled: !top, onSelected: () => _move(1)),
        SsMenuItem(
          label: 'Move down',
          enabled: !bottom,
          onSelected: () => _move(-1),
        ),
        SsMenuItem(label: 'Duplicate', onSelected: _duplicate),
        const SsMenuDivider(),
        SsMenuItem(label: 'Remove', danger: true, onSelected: _remove),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final e = _effect;
    final id = e.id;
    final w = InspectorScope.of(context).writer;
    final visiblePath = 'effects.$id.visible';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 28,
          child: Row(
            children: [
              FieldFrame.single(
                path: visiblePath,
                child: SsIconButton(
                  key: ValueKey<String>('effect-visible:$id'),
                  icon: e.visible ? SsIcons.eye : SsIcons.eyeOff,
                  semanticLabel: e.visible ? 'Hide effect' : 'Show effect',
                  size: 24,
                  iconSize: 14,
                  onPressed: () =>
                      w.set(visiblePath, ir.IrValue.boolean(!e.visible)),
                ),
              ),
              Expanded(
                child: SsInteractive(
                  key: ValueKey<String>('effect-title:$id'),
                  onTap: () => setState(() => _open = !_open),
                  semanticLabel: _kindLabel(_kindOf(e)),
                  excludeSemantics: true,
                  builder: (context, states) => Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SsSpace.s1,
                      ),
                      child: Text(
                        _kindLabel(_kindOf(e)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.text.small.copyWith(
                          color: e.visible
                              ? t.colors.textPrimary
                              : t.colors.textDisabled,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Builder(
                builder: (btn) => SsIconButton(
                  key: ValueKey<String>('effect-menu:$id'),
                  icon: SsIcons.ellipsis,
                  semanticLabel: 'Effect options',
                  size: 24,
                  iconSize: 14,
                  onPressed: () => _menu(btn),
                ),
              ),
              SsIconButton(
                key: ValueKey<String>('effect-remove:$id'),
                icon: SsIcons.minus,
                semanticLabel: 'Remove effect',
                size: 24,
                iconSize: 14,
                onPressed: _remove,
              ),
            ],
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(
              left: SsSpace.s1,
              top: SsSpace.s1,
              bottom: SsSpace.s2,
            ),
            child: _EffectDetail(effect: e),
          ),
      ],
    );
  }
}

/// The fields of one effect.
class _EffectDetail extends StatelessWidget {
  const _EffectDetail({required this.effect});

  final ir.Effect effect;

  @override
  Widget build(BuildContext context) {
    final id = effect.id;
    final p = 'effects.$id';
    switch (effect) {
      case ir.LayerBlur():
      case ir.BackgroundBlur():
        return LabelRow(
          label: 'Blur',
          child: NumberProp(
            path: '$p.radius',
            semanticLabel: 'Blur radius',
            unit: 'px',
            min: 0,
          ),
        );
      case ir.DropShadow():
      case ir.InnerShadow():
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: SsSpace.s2),
              child: ColorProp(
                path: '$p.color',
                semanticLabel: 'Shadow colour',
              ),
            ),
            Grid(
              children: [
                _OffsetAxis(path: '$p.offset', x: true),
                _OffsetAxis(path: '$p.offset', x: false),
                NumberProp(
                  path: '$p.blur',
                  label: 'Blur',
                  semanticLabel: 'Blur',
                  min: 0,
                ),
                NumberProp(
                  path: '$p.spread',
                  label: 'Spread',
                  semanticLabel: 'Spread',
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: SsSpace.s2),
              child: EnumProp(
                path: '$p.blendMode',
                dropdown: true,
                semanticLabel: 'Shadow blend mode',
                options: blendModeOptions(),
              ),
            ),
            if (effect is ir.DropShadow)
              _ShowBehind(path: '$p.showBehindTransparentAreas'),
          ],
        );
    }
  }
}

/// One axis of a shadow's offset point. Writes the whole point, keeping the
/// other axis of each node (so a mixed selection keeps its other axis).
class _OffsetAxis extends ConsumerWidget {
  const _OffsetAxis({required this.path, required this.x});

  final String path;
  final bool x;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final scope = InspectorScope.of(context);
    final w = scope.writer;
    final v = r.value is ir.PointValue
        ? (r.value! as ir.PointValue).value
        : null;
    final shown = v == null ? null : (x ? v.x : v.y);
    return FieldFrame.single(
      path: path,
      child: SsNumberField(
        key: ValueKey<String>('field:$path.${x ? 'x' : 'y'}'),
        semanticLabel: x ? 'Shadow X offset' : 'Shadow Y offset',
        label: x ? 'X' : 'Y',
        value: shown == null ? null : (shown * 100).roundToDouble() / 100,
        mixed: r.mixed,
        enabled: r.exists,
        onChangeStart: w.beginGesture,
        onChangeEnd: w.endGesture,
        onChanged: (n) {
          if (!r.mixed) {
            final cur = v ?? const ir.StagePoint();
            w.set(
              path,
              ir.IrValue.point(x ? cur.copyWith(x: n) : cur.copyWith(y: n)),
            );
            return;
          }
          final current = _valuesOf(ref, scope.ids, path);
          w.run(
            SetProperty.values({
              for (final e in current.entries)
                if (e.value is ir.PointValue)
                  e.key: {
                    path: ir.IrValue.point(
                      x
                          ? (e.value as ir.PointValue).value.copyWith(x: n)
                          : (e.value as ir.PointValue).value.copyWith(y: n),
                    ),
                  },
            }),
          );
        },
      ),
    );
  }
}

/// The "Show behind transparent areas" checkbox of a drop shadow. Its label
/// wraps (the design-system checkbox's label does not).
class _ShowBehind extends ConsumerWidget {
  const _ShowBehind({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final on = r.boolean == true;
    void toggle() => w.set(path, ir.IrValue.boolean(!on));
    return FieldFrame.single(
      path: path,
      child: Row(
        key: ValueKey<String>('field:$path'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SsCheckbox(
            value: r.mixed ? null : on,
            semanticLabel: 'Show behind transparent areas',
            onChanged: r.exists ? (_) => toggle() : null,
          ),
          const SizedBox(width: SsSpace.s2),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: r.exists ? toggle : null,
              child: Text(
                'Show behind transparent areas',
                style: context.ss.text.small,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
