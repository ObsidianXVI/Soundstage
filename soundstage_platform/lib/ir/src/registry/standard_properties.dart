// The standard property table (architecture §4.2, §5, §6, §7, §11.2).
// Internal: `PropertyRegistry.standard` is the public entry point.

import '../nodes/appearance.dart';
import '../nodes/blend_mode.dart';
import '../nodes/effect.dart';
import '../nodes/layout.dart';
import '../nodes/node.dart';
import '../nodes/node_common.dart';
import '../nodes/paint.dart';
import '../nodes/stroke.dart';
import '../nodes/text.dart';
import '../values/geometry.dart';
import '../values/ir_value.dart';
import 'lens.dart';
import 'property_descriptor.dart';

const Set<NodeKind> _all = {...NodeKind.values};
const Set<NodeKind> _frame = {NodeKind.frame};
const Set<NodeKind> _text = {NodeKind.text};
const Set<NodeKind> _shape = {NodeKind.shape};
const Set<NodeKind> _video = {NodeKind.video};
const Set<NodeKind> _embed = {NodeKind.embed};
const Set<NodeKind> _instance = {NodeKind.instance};

/// Kinds with a full `Appearance` (fills, stroke, effects, corners).
const Set<NodeKind> _appearanceKinds = {
  NodeKind.frame,
  NodeKind.shape,
  NodeKind.video,
};

/// Kinds with a stroke and effects (appearance kinds plus text).
const Set<NodeKind> _strokeKinds = {..._appearanceKinds, NodeKind.text};

const Invalidation _paint = Invalidation.paint;
const Invalidation _layout = Invalidation.layout;
const Invalidation _compositing = Invalidation.compositing;

final Codec<BlendMode> _blendC = enumC(BlendMode.values);

/// Builds every standard descriptor.
List<PropertyDescriptor> buildStandardProperties() {
  final b = _Builder();
  _commonProps(b);
  _frameProps(b);
  _appearanceProps(b);
  _strokeAndEffectProps(b);
  _shapeProps(b);
  _textProps(b);
  _videoProps(b);
  _embedProps(b);
  _instanceProps(b);
  return b.out;
}

class _Builder {
  final List<PropertyDescriptor> out = [];

  void add(
    String path,
    Set<NodeKind> kinds,
    Leaf<Node> leaf, {
    Invalidation inv = _paint,
    bool animatable = true,
    Interpolation? interpolation,
    IrValue? defaultValue,
  }) => out.add(
    PropertyDescriptor(
      pathPattern: path,
      appliesTo: kinds,
      leaf: leaf,
      invalidation: inv,
      animatable: animatable,
      interpolation: interpolation,
      defaultValue: defaultValue,
    ),
  );
}

// ---- Node lenses -------------------------------------------------------------

final Lens<Node, NodeCommon> _common = sub<Node, NodeCommon>(
  (n) => n.common,
  (n, c) => n.copyWith(common: c),
);
final Lens<Node, FrameNode> _asFrame = whenType<Node, FrameNode>();
final Lens<Node, TextNode> _asText = whenType<Node, TextNode>();
final Lens<Node, ShapeNode> _asShape = whenType<Node, ShapeNode>();
final Lens<Node, VideoNode> _asVideo = whenType<Node, VideoNode>();
final Lens<Node, EmbedNode> _asEmbed = whenType<Node, EmbedNode>();
final Lens<Node, InstanceNode> _asInstance = whenType<Node, InstanceNode>();

final Lens<Node, Appearance> _appearance = Lens<Node, Appearance>(
  (n, _) => switch (n) {
    FrameNode(:final appearance) ||
    ShapeNode(:final appearance) ||
    VideoNode(:final appearance) => appearance,
    _ => null,
  },
  (n, a, _) => switch (n) {
    FrameNode() => n.copyWith(appearance: a),
    ShapeNode() => n.copyWith(appearance: a),
    VideoNode() => n.copyWith(appearance: a),
    _ => null,
  },
);

/// Stroke, effects and their style ids, viewed as a [TextAppearance] on
/// every kind that has them, so text and the appearance kinds share paths.
final Lens<Node, TextAppearance> _strokeFx = Lens<Node, TextAppearance>(
  (n, p) {
    if (n is TextNode) return n.appearance;
    final a = _appearance.get(n, p);
    return a == null
        ? null
        : TextAppearance(
            strokes: a.strokes,
            effects: a.effects,
            strokeStyleId: a.strokeStyleId,
            effectStyleId: a.effectStyleId,
          );
  },
  (n, t, p) {
    if (n is TextNode) return n.copyWith(appearance: t);
    final a = _appearance.get(n, p);
    if (a == null) return null;
    return _appearance.set(
      n,
      a.copyWith(
        strokes: t.strokes,
        effects: t.effects,
        strokeStyleId: t.strokeStyleId,
        effectStyleId: t.effectStyleId,
      ),
      p,
    );
  },
);

// ---- Common (§4.2) -----------------------------------------------------------

void _commonProps(_Builder b) {
  Leaf<Node> c<A extends Object>(
    Codec<A> codec,
    A Function(NodeCommon c) get,
    NodeCommon Function(NodeCommon c, A v) set,
  ) => _common.leaf(field(codec, get, set));

  b.add(
    'name',
    _all,
    c(strC, (c) => c.name, (c, v) => c.copyWith(name: v)),
    animatable: false,
  );
  b.add(
    'visible',
    _all,
    c(boolC, (c) => c.visible, (c, v) => c.copyWith(visible: v)),
    inv: _layout,
  );
  b.add(
    'locked',
    _all,
    c(boolC, (c) => c.locked, (c, v) => c.copyWith(locked: v)),
    animatable: false,
  );
  b.add(
    'opacity',
    _all,
    c(numC, (c) => c.opacity, (c, v) => c.copyWith(opacity: v)),
    inv: _compositing,
  );
  b.add(
    'blendMode',
    _all,
    _common.leaf(
      optField(_blendC, (c) => c.blendMode, (c, v) => c.copyWith(blendMode: v)),
    ),
  );
  for (final (name, get, set)
      in <
        (
          String,
          double Function(NodeCommon),
          NodeCommon Function(NodeCommon, double),
        )
      >[
        ('x', (c) => c.x, (c, v) => c.copyWith(x: v)),
        ('y', (c) => c.y, (c, v) => c.copyWith(y: v)),
        ('width', (c) => c.width, (c, v) => c.copyWith(width: v)),
        ('height', (c) => c.height, (c, v) => c.copyWith(height: v)),
        ('rotation', (c) => c.rotation, (c, v) => c.copyWith(rotation: v)),
      ]) {
    b.add(name, _all, c(numC, get, set), inv: _layout);
  }
  b.add(
    'flipX',
    _all,
    c(boolC, (c) => c.flipX, (c, v) => c.copyWith(flipX: v)),
    inv: _layout,
  );
  b.add(
    'flipY',
    _all,
    c(boolC, (c) => c.flipY, (c, v) => c.copyWith(flipY: v)),
    inv: _layout,
  );
  b.add(
    'mask',
    _all,
    c(enumC(MaskMode.values), (c) => c.mask, (c, v) => c.copyWith(mask: v)),
    animatable: false,
  );

  // motion.* — paint-only transform.
  final motion = _common.then(
    sub<NodeCommon, MotionTransform>(
      (c) => c.motion,
      (c, m) => c.copyWith(motion: m),
    ),
  );
  for (final (name, get, set)
      in <
        (
          String,
          double Function(MotionTransform),
          MotionTransform Function(MotionTransform, double),
        )
      >[
        (
          'translateX',
          (m) => m.translateX,
          (m, v) => m.copyWith(translateX: v),
        ),
        (
          'translateY',
          (m) => m.translateY,
          (m, v) => m.copyWith(translateY: v),
        ),
        ('scaleX', (m) => m.scaleX, (m, v) => m.copyWith(scaleX: v)),
        ('scaleY', (m) => m.scaleY, (m, v) => m.copyWith(scaleY: v)),
        ('rotate', (m) => m.rotate, (m, v) => m.copyWith(rotate: v)),
        ('skewX', (m) => m.skewX, (m, v) => m.copyWith(skewX: v)),
        ('skewY', (m) => m.skewY, (m, v) => m.copyWith(skewY: v)),
        ('originX', (m) => m.originX, (m, v) => m.copyWith(originX: v)),
        ('originY', (m) => m.originY, (m, v) => m.copyWith(originY: v)),
      ]) {
    b.add(
      'motion.$name',
      _all,
      motion.leaf(field(numC, get, set)),
      inv: _compositing,
    );
  }

  // layoutChild.*
  final lc = _common.then(
    sub<NodeCommon, LayoutChild>(
      (c) => c.layoutChild,
      (c, l) => c.copyWith(layoutChild: l),
    ),
  );
  b.add(
    'layoutChild.positioning',
    _all,
    lc.leaf(
      field(
        enumC(Positioning.values),
        (l) => l.positioning,
        (l, v) => l.copyWith(positioning: v),
      ),
    ),
    inv: _layout,
  );
  final sizingC = enumC(Sizing.values);
  b.add(
    'layoutChild.horizontalSizing',
    _all,
    lc.leaf(
      field(
        sizingC,
        (l) => l.horizontalSizing,
        (l, v) => l.copyWith(horizontalSizing: v),
      ),
    ),
    inv: _layout,
  );
  b.add(
    'layoutChild.verticalSizing',
    _all,
    lc.leaf(
      field(
        sizingC,
        (l) => l.verticalSizing,
        (l, v) => l.copyWith(verticalSizing: v),
      ),
    ),
    inv: _layout,
  );
  for (final (name, get, set)
      in <
        (
          String,
          double? Function(LayoutChild),
          LayoutChild Function(LayoutChild, double?),
        )
      >[
        ('minWidth', (l) => l.minWidth, (l, v) => l.copyWith(minWidth: v)),
        ('maxWidth', (l) => l.maxWidth, (l, v) => l.copyWith(maxWidth: v)),
        ('minHeight', (l) => l.minHeight, (l, v) => l.copyWith(minHeight: v)),
        ('maxHeight', (l) => l.maxHeight, (l, v) => l.copyWith(maxHeight: v)),
      ]) {
    b.add(
      'layoutChild.$name',
      _all,
      lc.leaf(optField(numC, get, set)),
      inv: _layout,
    );
  }
  final cons = lc.then(
    sub<LayoutChild, Constraints>(
      (l) => l.constraints,
      (l, c) => l.copyWith(constraints: c),
    ),
  );
  b.add(
    'layoutChild.constraints.horizontal',
    _all,
    cons.leaf(
      field(
        enumC(HorizontalConstraint.values),
        (c) => c.horizontal,
        (c, v) => c.copyWith(horizontal: v),
      ),
    ),
    inv: _layout,
  );
  b.add(
    'layoutChild.constraints.vertical',
    _all,
    cons.leaf(
      field(
        enumC(VerticalConstraint.values),
        (c) => c.vertical,
        (c, v) => c.copyWith(vertical: v),
      ),
    ),
    inv: _layout,
  );
  final grid = lc.then(
    sub<LayoutChild, GridPlacement>(
      (l) => l.grid,
      (l, g) => l.copyWith(grid: g),
    ),
  );
  b.add(
    'layoutChild.grid.column',
    _all,
    grid.leaf(
      optField(intC(min: 0), (g) => g.column, (g, v) => g.copyWith(column: v)),
    ),
    inv: _layout,
  );
  b.add(
    'layoutChild.grid.row',
    _all,
    grid.leaf(
      optField(intC(min: 0), (g) => g.row, (g, v) => g.copyWith(row: v)),
    ),
    inv: _layout,
  );
  b.add(
    'layoutChild.grid.columnSpan',
    _all,
    grid.leaf(
      field(
        intC(min: 1),
        (g) => g.columnSpan,
        (g, v) => g.copyWith(columnSpan: v),
      ),
    ),
    inv: _layout,
  );
  b.add(
    'layoutChild.grid.rowSpan',
    _all,
    grid.leaf(
      field(intC(min: 1), (g) => g.rowSpan, (g, v) => g.copyWith(rowSpan: v)),
    ),
    inv: _layout,
  );
  final gridAlignC = enumC(GridAlign.values);
  b.add(
    'layoutChild.grid.alignX',
    _all,
    grid.leaf(
      field(gridAlignC, (g) => g.alignX, (g, v) => g.copyWith(alignX: v)),
    ),
    inv: _layout,
  );
  b.add(
    'layoutChild.grid.alignY',
    _all,
    grid.leaf(
      field(gridAlignC, (g) => g.alignY, (g, v) => g.copyWith(alignY: v)),
    ),
    inv: _layout,
  );
}

// ---- Frames (§4.4, §4.5) -----------------------------------------------------

/// A presence flag for an optional layout object: `true` creates it with
/// defaults, `false`/`none` removes it.
Leaf<FrameNode> _presence<A extends Object>(
  A? Function(FrameNode f) get,
  FrameNode Function(FrameNode f, A? a) set,
  A fallback,
) => Leaf<FrameNode>(
  Lens<FrameNode, IrValue>((f, _) => IrValue.boolean(get(f) != null), (
    f,
    v,
    _,
  ) {
    if (v is NoneValue) return set(f, null);
    if (v is! BoolValue) return null;
    return set(f, v.value ? (get(f) ?? fallback) : null);
  }),
  boolC.asNullable(),
);

void _insetsProps(
  _Builder b,
  String prefix,
  Set<NodeKind> kinds,
  Lens<Node, EdgeInsetsValue> insets,
) {
  b.add(
    prefix,
    kinds,
    insets.leaf(field(insetsC, (e) => e, (e, v) => v)),
    inv: _layout,
  );
  for (final (name, get, set)
      in <
        (
          String,
          double Function(EdgeInsetsValue),
          EdgeInsetsValue Function(EdgeInsetsValue, double),
        )
      >[
        ('top', (e) => e.top, (e, v) => e.copyWith(top: v)),
        ('right', (e) => e.right, (e, v) => e.copyWith(right: v)),
        ('bottom', (e) => e.bottom, (e, v) => e.copyWith(bottom: v)),
        ('left', (e) => e.left, (e, v) => e.copyWith(left: v)),
      ]) {
    b.add(
      '$prefix.$name',
      kinds,
      insets.leaf(field(numC, get, set)),
      inv: _layout,
    );
  }
}

void _frameProps(_Builder b) {
  b.add(
    'clipContent',
    _frame,
    _asFrame.leaf(
      field(boolC, (f) => f.clipContent, (f, v) => f.copyWith(clipContent: v)),
    ),
  );

  // Turning auto layout on replaces a grid, and vice versa (at most one).
  b.add(
    'autoLayout',
    _frame,
    _asFrame.leaf(
      _presence<AutoLayout>(
        (f) => f.autoLayout,
        (f, a) => f.copyWith(autoLayout: a, grid: a == null ? f.grid : null),
        const AutoLayout(),
      ),
    ),
    inv: _layout,
    animatable: false,
    defaultValue: const IrValue.boolean(false),
  );
  final al = _asFrame.then(
    present<FrameNode, AutoLayout>(
      (f) => f.autoLayout,
      (f, a) => f.copyWith(autoLayout: a),
    ),
  );
  void alField<A extends Object>(
    String name,
    Codec<A> codec,
    A Function(AutoLayout a) get,
    AutoLayout Function(AutoLayout a, A v) set,
  ) => b.add(
    'autoLayout.$name',
    _frame,
    al.leaf(field(codec, get, set)),
    inv: _layout,
  );
  alField(
    'direction',
    enumC(LayoutDirection.values),
    (a) => a.direction,
    (a, v) => a.copyWith(direction: v),
  );
  alField('wrap', boolC, (a) => a.wrap, (a, v) => a.copyWith(wrap: v));
  alField('gap', gapC, (a) => a.gap, (a, v) => a.copyWith(gap: v));
  alField(
    'counterAxisGap',
    gapC,
    (a) => a.counterAxisGap,
    (a, v) => a.copyWith(counterAxisGap: v),
  );
  _insetsProps(
    b,
    'autoLayout.padding',
    _frame,
    al.then(
      sub<AutoLayout, EdgeInsetsValue>(
        (a) => a.padding,
        (a, p) => a.copyWith(padding: p),
      ),
    ),
  );
  alField(
    'primaryAlign',
    enumC(PrimaryAlign.values),
    (a) => a.primaryAlign,
    (a, v) => a.copyWith(primaryAlign: v),
  );
  alField(
    'counterAlign',
    enumC(CounterAlign.values),
    (a) => a.counterAlign,
    (a, v) => a.copyWith(counterAlign: v),
  );
  alField(
    'rowAlign',
    enumC(RowAlign.values),
    (a) => a.rowAlign,
    (a, v) => a.copyWith(rowAlign: v),
  );
  final axisC = enumC(AxisSizing.values);
  alField(
    'primarySizing',
    axisC,
    (a) => a.primarySizing,
    (a, v) => a.copyWith(primarySizing: v),
  );
  alField(
    'counterSizing',
    axisC,
    (a) => a.counterSizing,
    (a, v) => a.copyWith(counterSizing: v),
  );
  alField(
    'strokesIncludedInLayout',
    boolC,
    (a) => a.strokesIncludedInLayout,
    (a, v) => a.copyWith(strokesIncludedInLayout: v),
  );
  alField(
    'reverseZIndex',
    boolC,
    (a) => a.reverseZIndex,
    (a, v) => a.copyWith(reverseZIndex: v),
  );

  b.add(
    'grid',
    _frame,
    _asFrame.leaf(
      _presence<GridLayout>(
        (f) => f.grid,
        (f, g) =>
            f.copyWith(grid: g, autoLayout: g == null ? f.autoLayout : null),
        const GridLayout(),
      ),
    ),
    inv: _layout,
    animatable: false,
    defaultValue: const IrValue.boolean(false),
  );
  final grid = _asFrame.then(
    present<FrameNode, GridLayout>(
      (f) => f.grid,
      (f, g) => f.copyWith(grid: g),
    ),
  );
  b.add(
    'grid.columnGap',
    _frame,
    grid.leaf(
      field(numC, (g) => g.columnGap, (g, v) => g.copyWith(columnGap: v)),
    ),
    inv: _layout,
  );
  b.add(
    'grid.rowGap',
    _frame,
    grid.leaf(field(numC, (g) => g.rowGap, (g, v) => g.copyWith(rowGap: v))),
    inv: _layout,
  );
  _insetsProps(
    b,
    'grid.padding',
    _frame,
    grid.then(
      sub<GridLayout, EdgeInsetsValue>(
        (g) => g.padding,
        (g, p) => g.copyWith(padding: p),
      ),
    ),
  );
  b.add(
    'grid.autoFlow',
    _frame,
    grid.leaf(
      field(
        enumC(GridAutoFlow.values),
        (g) => g.autoFlow,
        (g, v) => g.copyWith(autoFlow: v),
      ),
    ),
    inv: _layout,
  );
}

// ---- Paint stacks (§5, §6) ---------------------------------------------------

/// Every path of a paint stack under [prefix]: the whole stack, one paint
/// by id, and each paint kind's fields.
void _paintProps(
  _Builder b,
  String prefix,
  Set<NodeKind> kinds,
  Lens<Node, List<Paint>> stack, {
  Leaf<Node>? whole,
}) {
  b.add(
    prefix,
    kinds,
    whole ?? stack.leaf(field(paintsC, (l) => l, (l, v) => v)),
  );
  final one = stack.then(
    byId<Paint>('paintId', (p) => p.id, (p, id) => p.copyWith(id: id)),
  );
  void p(String name, Leaf<Node> leaf) =>
      b.add('$prefix.<paintId>.$name', kinds, leaf);

  b.add(
    '$prefix.<paintId>',
    kinds,
    one.leaf(field(paintC, (p) => p, (p, v) => v)),
  );
  p(
    'visible',
    one.leaf(field(boolC, (p) => p.visible, (p, v) => p.copyWith(visible: v))),
  );
  p(
    'opacity',
    one.leaf(field(numC, (p) => p.opacity, (p, v) => p.copyWith(opacity: v))),
  );
  p(
    'blendMode',
    one.leaf(
      field(_blendC, (p) => p.blendMode, (p, v) => p.copyWith(blendMode: v)),
    ),
  );

  final solid = one.then(whenType<Paint, SolidPaint>());
  p(
    'color',
    solid.leaf(field(colorC, (p) => p.color, (p, v) => p.copyWith(color: v))),
  );

  final grad = one.then(whenType<Paint, GradientPaint>());
  p(
    'kind',
    grad.leaf(
      field(
        enumC(GradientKind.values),
        (g) => g.kind,
        (g, v) => g.copyWith(kind: v),
      ),
    ),
  );
  final stop = grad
      .then(
        sub<GradientPaint, List<ColorStop>>(
          (g) => g.stops,
          (g, s) => g.copyWith(stops: s),
        ),
      )
      .then(atIndex<ColorStop>('stopIndex'));
  p(
    'stops.<stopIndex>.position',
    stop.leaf(
      field(numC, (s) => s.position, (s, v) => s.copyWith(position: v)),
    ),
  );
  p(
    'stops.<stopIndex>.color',
    stop.leaf(field(colorC, (s) => s.color, (s, v) => s.copyWith(color: v))),
  );
  final handles = grad.then(
    sub<GradientPaint, GradientHandles>(
      (g) => g.handles,
      (g, h) => g.copyWith(handles: h),
    ),
  );
  p(
    'handles.start',
    handles.leaf(field(pointC, (h) => h.start, (h, v) => h.copyWith(start: v))),
  );
  p(
    'handles.end',
    handles.leaf(field(pointC, (h) => h.end, (h, v) => h.copyWith(end: v))),
  );
  p(
    'handles.width',
    handles.leaf(field(pointC, (h) => h.width, (h, v) => h.copyWith(width: v))),
  );

  final img = one.then(whenType<Paint, ImagePaint>());
  b.add(
    '$prefix.<paintId>.assetId',
    kinds,
    img.leaf(field(strC, (i) => i.assetId, (i, v) => i.copyWith(assetId: v))),
    animatable: false,
  );
  p(
    'scaleMode',
    img.leaf(
      field(
        enumC(ImageScaleMode.values),
        (i) => i.scaleMode,
        (i, v) => i.copyWith(scaleMode: v),
      ),
    ),
  );
  p(
    'focalPoint',
    img.leaf(
      field(pointC, (i) => i.focalPoint, (i, v) => i.copyWith(focalPoint: v)),
    ),
  );
  _cropRectProps(
    b,
    '$prefix.<paintId>.cropRect',
    kinds,
    img.then(
      materialised<ImagePaint, StageRect>(
        (i) => i.cropRect,
        (i, r) => i.copyWith(cropRect: r),
        const StageRect(),
      ),
    ),
  );
  p(
    'tileScale',
    img.leaf(
      field(numC, (i) => i.tileScale, (i, v) => i.copyWith(tileScale: v)),
    ),
  );
  p(
    'rotation',
    img.leaf(
      field(quarterTurnC, (i) => i.rotation, (i, v) => i.copyWith(rotation: v)),
    ),
  );
  final filters = img.then(
    sub<ImagePaint, ImageFilters>(
      (i) => i.filters,
      (i, f) => i.copyWith(filters: f),
    ),
  );
  for (final (name, get, set)
      in <
        (
          String,
          double Function(ImageFilters),
          ImageFilters Function(ImageFilters, double),
        )
      >[
        ('exposure', (f) => f.exposure, (f, v) => f.copyWith(exposure: v)),
        ('contrast', (f) => f.contrast, (f, v) => f.copyWith(contrast: v)),
        (
          'saturation',
          (f) => f.saturation,
          (f, v) => f.copyWith(saturation: v),
        ),
        (
          'temperature',
          (f) => f.temperature,
          (f, v) => f.copyWith(temperature: v),
        ),
        ('tint', (f) => f.tint, (f, v) => f.copyWith(tint: v)),
        (
          'highlights',
          (f) => f.highlights,
          (f, v) => f.copyWith(highlights: v),
        ),
        ('shadows', (f) => f.shadows, (f, v) => f.copyWith(shadows: v)),
      ]) {
    p('filters.$name', filters.leaf(field(numC, get, set)));
  }
}

/// `cropRect.x|y|width|height`. An unset crop rect reads as the full image
/// (0, 0, 1, 1); writing a field creates it.
void _cropRectProps(
  _Builder b,
  String prefix,
  Set<NodeKind> kinds,
  Lens<Node, StageRect> rect,
) {
  for (final (name, get, set)
      in <
        (
          String,
          double Function(StageRect),
          StageRect Function(StageRect, double),
        )
      >[
        ('x', (r) => r.x, (r, v) => r.copyWith(x: v)),
        ('y', (r) => r.y, (r, v) => r.copyWith(y: v)),
        ('width', (r) => r.width, (r, v) => r.copyWith(width: v)),
        ('height', (r) => r.height, (r, v) => r.copyWith(height: v)),
      ]) {
    b.add('$prefix.$name', kinds, rect.leaf(field(numC, get, set)));
  }
}

// ---- Appearance: fills and corners (§5) --------------------------------------

void _appearanceProps(_Builder b) {
  _paintProps(
    b,
    'fills',
    _appearanceKinds,
    _appearance.then(
      sub<Appearance, List<Paint>>(
        (a) => a.fills,
        (a, f) => a.copyWith(fills: f),
      ),
    ),
  );
  b.add(
    'fillStyleId',
    _appearanceKinds,
    _appearance.leaf(
      optField(
        strC,
        (a) => a.fillStyleId,
        (a, v) => a.copyWith(fillStyleId: v),
      ),
    ),
    animatable: false,
  );
  final radius = _appearance.then(
    sub<Appearance, CornerRadius>(
      (a) => a.cornerRadius,
      (a, r) => a.copyWith(cornerRadius: r),
    ),
  );
  b.add(
    'cornerRadius',
    _appearanceKinds,
    radius.leaf(field(cornerRadiusC, (r) => r, (r, v) => v)),
  );
  final perCorner = Lens<CornerRadius, CornerRadii>(
    (r, _) => switch (r) {
      CornerRadii() => r,
      UniformCornerRadius(:final radius) => CornerRadii(
        tl: radius,
        tr: radius,
        br: radius,
        bl: radius,
      ),
    },
    (r, c, _) => c,
  );
  for (final (name, get, set)
      in <
        (
          String,
          double Function(CornerRadii),
          CornerRadii Function(CornerRadii, double),
        )
      >[
        ('tl', (c) => c.tl, (c, v) => c.copyWith(tl: v)),
        ('tr', (c) => c.tr, (c, v) => c.copyWith(tr: v)),
        ('br', (c) => c.br, (c, v) => c.copyWith(br: v)),
        ('bl', (c) => c.bl, (c, v) => c.copyWith(bl: v)),
      ]) {
    b.add(
      'cornerRadius.$name',
      _appearanceKinds,
      radius.then(perCorner).leaf(field(numC, get, set)),
    );
  }
  b.add(
    'cornerSmoothing',
    _appearanceKinds,
    _appearance.leaf(
      field(
        numC,
        (a) => a.cornerSmoothing,
        (a, v) => a.copyWith(cornerSmoothing: v),
      ),
    ),
  );
}

// ---- Stroke and effects (§5) -------------------------------------------------

void _strokeAndEffectProps(_Builder b) {
  final stroke = _strokeFx.then(
    sub<TextAppearance, Stroke>(
      (t) => t.strokes,
      (t, s) => t.copyWith(strokes: s),
    ),
  );
  _paintProps(
    b,
    'strokes.paints',
    _strokeKinds,
    stroke.then(
      sub<Stroke, List<Paint>>(
        (s) => s.paints,
        (s, p) => s.copyWith(paints: p),
      ),
    ),
  );
  final weight = stroke.then(
    sub<Stroke, StrokeWeight>((s) => s.weight, (s, w) => s.copyWith(weight: w)),
  );
  b.add(
    'strokes.weight',
    _strokeKinds,
    weight.leaf(field(strokeWeightC, (w) => w, (w, v) => v)),
    inv: _layout,
  );
  final perSide = Lens<StrokeWeight, PerSideStrokeWeight>(
    (w, _) => switch (w) {
      PerSideStrokeWeight() => w,
      UniformStrokeWeight(:final weight) => PerSideStrokeWeight(
        top: weight,
        right: weight,
        bottom: weight,
        left: weight,
      ),
    },
    (w, s, _) => s,
  );
  for (final (name, get, set)
      in <
        (
          String,
          double Function(PerSideStrokeWeight),
          PerSideStrokeWeight Function(PerSideStrokeWeight, double),
        )
      >[
        ('top', (w) => w.top, (w, v) => w.copyWith(top: v)),
        ('right', (w) => w.right, (w, v) => w.copyWith(right: v)),
        ('bottom', (w) => w.bottom, (w, v) => w.copyWith(bottom: v)),
        ('left', (w) => w.left, (w, v) => w.copyWith(left: v)),
      ]) {
    b.add(
      'strokes.weight.$name',
      _strokeKinds,
      weight.then(perSide).leaf(field(numC, get, set)),
      inv: _layout,
    );
  }
  b.add(
    'strokes.align',
    _strokeKinds,
    stroke.leaf(
      field(
        enumC(StrokeAlign.values),
        (s) => s.align,
        (s, v) => s.copyWith(align: v),
      ),
    ),
    inv: _layout,
  );
  b.add(
    'strokes.cap',
    _strokeKinds,
    stroke.leaf(
      field(
        enumC(StrokeCap.values),
        (s) => s.cap,
        (s, v) => s.copyWith(cap: v),
      ),
    ),
  );
  b.add(
    'strokes.join',
    _strokeKinds,
    stroke.leaf(
      field(
        enumC(StrokeJoin.values),
        (s) => s.join,
        (s, v) => s.copyWith(join: v),
      ),
    ),
  );
  b.add(
    'strokes.miterLimit',
    _strokeKinds,
    stroke.leaf(
      field(numC, (s) => s.miterLimit, (s, v) => s.copyWith(miterLimit: v)),
    ),
  );
  b.add(
    'strokes.dash',
    _strokeKinds,
    stroke.leaf(field(numbersC, (s) => s.dash, (s, v) => s.copyWith(dash: v))),
  );
  b.add(
    'strokeStyleId',
    _strokeKinds,
    _strokeFx.leaf(
      optField(
        strC,
        (t) => t.strokeStyleId,
        (t, v) => t.copyWith(strokeStyleId: v),
      ),
    ),
    animatable: false,
  );

  // Effects.
  final effects = _strokeFx.then(
    sub<TextAppearance, List<Effect>>(
      (t) => t.effects,
      (t, e) => t.copyWith(effects: e),
    ),
  );
  b.add(
    'effects',
    _strokeKinds,
    effects.leaf(field(effectsC, (l) => l, (l, v) => v)),
  );
  final one = effects.then(
    byId<Effect>('effectId', (e) => e.id, (e, id) => e.copyWith(id: id)),
  );
  void e(String name, Leaf<Effect> leaf) =>
      b.add('effects.<effectId>.$name', _strokeKinds, one.leaf(leaf));

  b.add(
    'effects.<effectId>',
    _strokeKinds,
    one.leaf(field(effectC, (e) => e, (e, v) => v)),
  );
  e(
    'visible',
    field(boolC, (e) => e.visible, (e, v) => e.copyWith(visible: v)),
  );

  Leaf<Effect> shadowField<A extends Object>(
    Codec<A> codec,
    A Function(DropShadow d) dropGet,
    A Function(InnerShadow i) innerGet,
    Effect Function(DropShadow d, A v) dropSet,
    Effect Function(InnerShadow i, A v) innerSet,
  ) => Leaf<Effect>(
    Lens<Effect, IrValue>(
      (e, _) => switch (e) {
        DropShadow() => codec.encode(dropGet(e)),
        InnerShadow() => codec.encode(innerGet(e)),
        _ => null,
      },
      (e, v, _) {
        final a = codec.decode(v);
        if (a == null) return null;
        return switch (e) {
          DropShadow() => dropSet(e, a),
          InnerShadow() => innerSet(e, a),
          _ => null,
        };
      },
    ),
    codec,
  );

  e(
    'color',
    shadowField(
      colorC,
      (d) => d.color,
      (i) => i.color,
      (d, v) => d.copyWith(color: v),
      (i, v) => i.copyWith(color: v),
    ),
  );
  e(
    'offset',
    shadowField(
      pointC,
      (d) => d.offset,
      (i) => i.offset,
      (d, v) => d.copyWith(offset: v),
      (i, v) => i.copyWith(offset: v),
    ),
  );
  e(
    'spread',
    shadowField(
      numC,
      (d) => d.spread,
      (i) => i.spread,
      (d, v) => d.copyWith(spread: v),
      (i, v) => i.copyWith(spread: v),
    ),
  );
  e(
    'blendMode',
    shadowField(
      _blendC,
      (d) => d.blendMode,
      (i) => i.blendMode,
      (d, v) => d.copyWith(blendMode: v),
      (i, v) => i.copyWith(blendMode: v),
    ),
  );
  // `blur` is a shadow's blur or a blur effect's radius (Figma calls both
  // "blur"); `radius` addresses blur effects only.
  e(
    'blur',
    Leaf<Effect>(
      Lens<Effect, IrValue>(
        (e, _) => IrValue.number(switch (e) {
          DropShadow(:final blur) || InnerShadow(:final blur) => blur,
          LayerBlur(:final radius) || BackgroundBlur(:final radius) => radius,
        }),
        (e, v, _) {
          final d = numC.decode(v);
          if (d == null) return null;
          return switch (e) {
            DropShadow() => e.copyWith(blur: d),
            InnerShadow() => e.copyWith(blur: d),
            LayerBlur() => e.copyWith(radius: d),
            BackgroundBlur() => e.copyWith(radius: d),
          };
        },
      ),
      numC,
    ),
  );
  e(
    'radius',
    Leaf<Effect>(
      Lens<Effect, IrValue>(
        (e, _) => switch (e) {
          LayerBlur(:final radius) ||
          BackgroundBlur(:final radius) => IrValue.number(radius),
          _ => null,
        },
        (e, v, _) {
          final d = numC.decode(v);
          if (d == null) return null;
          return switch (e) {
            LayerBlur() => e.copyWith(radius: d),
            BackgroundBlur() => e.copyWith(radius: d),
            _ => null,
          };
        },
      ),
      numC,
    ),
  );
  b.add(
    'effects.<effectId>.showBehindTransparentAreas',
    _strokeKinds,
    one
        .then(whenType<Effect, DropShadow>())
        .leaf(
          field(
            boolC,
            (d) => d.showBehindTransparentAreas,
            (d, v) => d.copyWith(showBehindTransparentAreas: v),
          ),
        ),
  );
  b.add(
    'effectStyleId',
    _strokeKinds,
    _strokeFx.leaf(
      optField(
        strC,
        (t) => t.effectStyleId,
        (t, v) => t.copyWith(effectStyleId: v),
      ),
    ),
    animatable: false,
  );
}

// ---- Shapes (§4.1) -----------------------------------------------------------

void _shapeProps(_Builder b) {
  final geo = _asShape.then(
    sub<ShapeNode, ShapeGeometry>(
      (s) => s.geometry,
      (s, g) => s.copyWith(geometry: g),
    ),
  );
  final ellipse = geo.then(whenType<ShapeGeometry, EllipseGeometry>());
  b.add(
    'geometry.arcStart',
    _shape,
    ellipse.leaf(
      field(numC, (e) => e.arcStart, (e, v) => e.copyWith(arcStart: v)),
    ),
  );
  b.add(
    'geometry.arcEnd',
    _shape,
    ellipse.leaf(field(numC, (e) => e.arcEnd, (e, v) => e.copyWith(arcEnd: v))),
  );
  b.add(
    'geometry.innerRadius',
    _shape,
    ellipse.leaf(
      field(numC, (e) => e.innerRadius, (e, v) => e.copyWith(innerRadius: v)),
    ),
  );
  final pointCountC = intC(min: 3);
  b.add(
    'geometry.pointCount',
    _shape,
    geo.leaf(
      Leaf<ShapeGeometry>(
        Lens<ShapeGeometry, IrValue>(
          (g, _) => switch (g) {
            PolygonGeometry(:final pointCount) ||
            StarGeometry(:final pointCount) => pointCountC.encode(pointCount),
            _ => null,
          },
          (g, v, _) {
            final n = pointCountC.decode(v);
            if (n == null) return null;
            return switch (g) {
              PolygonGeometry() => g.copyWith(pointCount: n),
              StarGeometry() => g.copyWith(pointCount: n),
              _ => null,
            };
          },
        ),
        pointCountC,
      ),
    ),
  );
  b.add(
    'geometry.innerRatio',
    _shape,
    geo
        .then(whenType<ShapeGeometry, StarGeometry>())
        .leaf(
          field(numC, (s) => s.innerRatio, (s, v) => s.copyWith(innerRatio: v)),
        ),
  );
}

// ---- Text (§7) ---------------------------------------------------------------

final Codec<TextDecorationStyle> _decorationStyleC = enumC(
  TextDecorationStyle.values,
  {TextDecorationStyle.doubleLine: 'double'},
);

/// `style.*` on a complete [TextStyle] (the node's base style).
void _textStyleProps(_Builder b, String prefix, Lens<Node, TextStyle> style) {
  void f<A extends Object>(
    String name,
    Codec<A> codec,
    A Function(TextStyle s) get,
    TextStyle Function(TextStyle s, A v) set, {
    Invalidation inv = _layout,
  }) => b.add(
    '$prefix.$name',
    _text,
    style.leaf(field(codec, get, set)),
    inv: inv,
  );

  b.add(
    '$prefix.fontFamilyId',
    _text,
    style.leaf(
      optField(
        strC,
        (s) => s.fontFamilyId,
        (s, v) => s.copyWith(fontFamilyId: v),
      ),
    ),
    inv: _layout,
  );
  f(
    'fontWeight',
    intC(continuous: true, min: 1, max: 1000),
    (s) => s.fontWeight,
    (s, v) => s.copyWith(fontWeight: v),
  );
  f('italic', boolC, (s) => s.italic, (s, v) => s.copyWith(italic: v));
  b.add(
    '$prefix.fontVariations.<axisTag>',
    _text,
    style.leaf(
      mapEntry(
        numC,
        'axisTag',
        (s) => s.fontVariations,
        (s, m) => s.copyWith(fontVariations: m),
      ),
    ),
    inv: _layout,
  );
  f('fontSize', numC, (s) => s.fontSize, (s, v) => s.copyWith(fontSize: v));
  f(
    'lineHeight',
    lineHeightC,
    (s) => s.lineHeight,
    (s, v) => s.copyWith(lineHeight: v),
  );
  f(
    'letterSpacing',
    letterSpacingC,
    (s) => s.letterSpacing,
    (s, v) => s.copyWith(letterSpacing: v),
  );
  f(
    'paragraphSpacing',
    numC,
    (s) => s.paragraphSpacing,
    (s, v) => s.copyWith(paragraphSpacing: v),
  );
  f(
    'paragraphIndent',
    numC,
    (s) => s.paragraphIndent,
    (s, v) => s.copyWith(paragraphIndent: v),
  );
  f(
    'textCase',
    enumC(TextCase.values),
    (s) => s.textCase,
    (s, v) => s.copyWith(textCase: v),
  );
  _decorationProps(
    b,
    '$prefix.decoration',
    style.then(
      sub<TextStyle, TextDecoration>(
        (s) => s.decoration,
        (s, d) => s.copyWith(decoration: d),
      ),
    ),
  );
  _paintProps(
    b,
    '$prefix.fills',
    _text,
    style.then(
      sub<TextStyle, List<Paint>>(
        (s) => s.fills,
        (s, f) => s.copyWith(fills: f),
      ),
    ),
  );
  b.add(
    '$prefix.openType.<featureTag>',
    _text,
    style.leaf(
      mapEntry(
        intC(),
        'featureTag',
        (s) => s.openType,
        (s, m) => s.copyWith(openType: m),
      ),
    ),
    inv: _layout,
  );
  f(
    'baselineShift',
    enumC(BaselineShift.values),
    (s) => s.baselineShift,
    (s, v) => s.copyWith(baselineShift: v),
  );
  f(
    'listStyle',
    enumC(ListStyle.values),
    (s) => s.listStyle,
    (s, v) => s.copyWith(listStyle: v),
  );
}

void _decorationProps(
  _Builder b,
  String prefix,
  Lens<Node, TextDecoration> deco,
) {
  b.add(
    '$prefix.kind',
    _text,
    deco.leaf(
      field(
        enumC(TextDecorationKind.values),
        (d) => d.kind,
        (d, v) => d.copyWith(kind: v),
      ),
    ),
  );
  b.add(
    '$prefix.style',
    _text,
    deco.leaf(
      field(_decorationStyleC, (d) => d.style, (d, v) => d.copyWith(style: v)),
    ),
  );
  b.add(
    '$prefix.thickness',
    _text,
    deco.leaf(
      optField(numC, (d) => d.thickness, (d, v) => d.copyWith(thickness: v)),
    ),
  );
  b.add(
    '$prefix.color',
    _text,
    deco.leaf(optField(colorC, (d) => d.color, (d, v) => d.copyWith(color: v))),
  );
  b.add(
    '$prefix.skipInk',
    _text,
    deco.leaf(field(boolC, (d) => d.skipInk, (d, v) => d.copyWith(skipInk: v))),
  );
}

/// `…style.*` on a partial [TextStyleOverride] (spans). Every field is
/// nullable: `none` clears it back to "inherit".
void _textOverrideProps(
  _Builder b,
  String prefix,
  Lens<Node, TextStyleOverride> o,
) {
  void f<A extends Object>(
    String name,
    Codec<A> codec,
    A? Function(TextStyleOverride s) get,
    TextStyleOverride Function(TextStyleOverride s, A? v) set, {
    Invalidation inv = _layout,
  }) => b.add(
    '$prefix.$name',
    _text,
    o.leaf(optField(codec, get, set)),
    inv: inv,
  );

  f(
    'fontFamilyId',
    strC,
    (s) => s.fontFamilyId,
    (s, v) => s.copyWith(fontFamilyId: v),
  );
  f(
    'fontWeight',
    intC(continuous: true, min: 1, max: 1000),
    (s) => s.fontWeight,
    (s, v) => s.copyWith(fontWeight: v),
  );
  f('italic', boolC, (s) => s.italic, (s, v) => s.copyWith(italic: v));
  b.add(
    '$prefix.fontVariations.<axisTag>',
    _text,
    o.leaf(
      mapEntry(
        numC,
        'axisTag',
        (s) => s.fontVariations,
        (s, m) => s.copyWith(fontVariations: m),
      ),
    ),
    inv: _layout,
  );
  f('fontSize', numC, (s) => s.fontSize, (s, v) => s.copyWith(fontSize: v));
  f(
    'lineHeight',
    lineHeightC,
    (s) => s.lineHeight,
    (s, v) => s.copyWith(lineHeight: v),
  );
  f(
    'letterSpacing',
    letterSpacingC,
    (s) => s.letterSpacing,
    (s, v) => s.copyWith(letterSpacing: v),
  );
  f(
    'paragraphSpacing',
    numC,
    (s) => s.paragraphSpacing,
    (s, v) => s.copyWith(paragraphSpacing: v),
  );
  f(
    'paragraphIndent',
    numC,
    (s) => s.paragraphIndent,
    (s, v) => s.copyWith(paragraphIndent: v),
  );
  f(
    'textCase',
    enumC(TextCase.values),
    (s) => s.textCase,
    (s, v) => s.copyWith(textCase: v),
  );
  _decorationProps(
    b,
    '$prefix.decoration',
    o.then(
      materialised<TextStyleOverride, TextDecoration>(
        (s) => s.decoration,
        (s, d) => s.copyWith(decoration: d),
        const TextDecoration(),
      ),
    ),
  );
  _paintProps(
    b,
    '$prefix.fills',
    _text,
    o.then(
      present<TextStyleOverride, List<Paint>>(
        (s) => s.fills,
        (s, f) => s.copyWith(fills: f),
      ),
    ),
    whole: o.leaf(
      optField(paintsC, (s) => s.fills, (s, v) => s.copyWith(fills: v)),
    ),
  );
  b.add(
    '$prefix.openType.<featureTag>',
    _text,
    o.leaf(
      mapEntry(
        intC(),
        'featureTag',
        (s) => s.openType,
        (s, m) => s.copyWith(openType: m),
      ),
    ),
    inv: _layout,
  );
  f(
    'baselineShift',
    enumC(BaselineShift.values),
    (s) => s.baselineShift,
    (s, v) => s.copyWith(baselineShift: v),
  );
  f(
    'listStyle',
    enumC(ListStyle.values),
    (s) => s.listStyle,
    (s, v) => s.copyWith(listStyle: v),
  );
}

/// The plain text of [content]: spans concatenated, paragraphs joined by
/// `\n` (Figma's `characters`).
String textCharacters(List<Paragraph> content) =>
    content.map((p) => p.spans.map((s) => s.text).join()).join('\n');

/// [content] with its text replaced by [text]. Each line becomes a
/// paragraph with one span; paragraph `i` keeps the style of existing
/// paragraph `i` (or the last one), and every span takes the style and link
/// of the first span (Figma restyles replaced characters from the first
/// character).
List<Paragraph> withCharacters(List<Paragraph> content, String text) {
  final firstSpan = content
      .expand((p) => p.spans)
      .cast<Span?>()
      .firstWhere((_) => true, orElse: () => null);
  final lines = text.split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      Paragraph(
        style: content.isEmpty
            ? null
            : content[i < content.length ? i : content.length - 1].style,
        spans: [
          Span(
            text: lines[i],
            style: firstSpan?.style ?? const TextStyleOverride(),
            link: firstSpan?.link,
          ),
        ],
      ),
  ];
}

void _textProps(_Builder b) {
  void t<A extends Object>(
    String name,
    Codec<A> codec,
    A Function(TextNode t) get,
    TextNode Function(TextNode t, A v) set,
  ) => b.add(name, _text, _asText.leaf(field(codec, get, set)), inv: _layout);

  t('characters', strC, (n) => textCharacters(n.content), (n, v) {
    return n.copyWith(content: withCharacters(n.content, v));
  });
  b.add(
    'textStyleId',
    _text,
    _asText.leaf(
      optField(
        strC,
        (n) => n.textStyleId,
        (n, v) => n.copyWith(textStyleId: v),
      ),
    ),
    inv: _layout,
    animatable: false,
  );
  t(
    'autoResize',
    enumC(TextAutoResize.values),
    (n) => n.autoResize,
    (n, v) => n.copyWith(autoResize: v),
  );
  b.add(
    'maxLines',
    _text,
    _asText.leaf(
      optField(
        intC(min: 1),
        (n) => n.maxLines,
        (n, v) => n.copyWith(maxLines: v),
      ),
    ),
    inv: _layout,
  );
  t(
    'truncation',
    enumC(TextTruncation.values),
    (n) => n.truncation,
    (n, v) => n.copyWith(truncation: v),
  );
  t(
    'alignHorizontal',
    enumC(TextAlignHorizontal.values),
    (n) => n.alignHorizontal,
    (n, v) => n.copyWith(alignHorizontal: v),
  );
  t(
    'alignVertical',
    enumC(TextAlignVertical.values),
    (n) => n.alignVertical,
    (n, v) => n.copyWith(alignVertical: v),
  );
  t(
    'leadingTrim',
    enumC(LeadingTrim.values),
    (n) => n.leadingTrim,
    (n, v) => n.copyWith(leadingTrim: v),
  );

  _textStyleProps(
    b,
    'style',
    _asText.then(
      sub<TextNode, TextStyle>((n) => n.style, (n, s) => n.copyWith(style: s)),
    ),
  );

  final paragraph = _asText
      .then(
        sub<TextNode, List<Paragraph>>(
          (n) => n.content,
          (n, c) => n.copyWith(content: c),
        ),
      )
      .then(atIndex<Paragraph>('paragraphIndex'));
  final pStyle = paragraph.then(
    materialised<Paragraph, ParagraphStyle>(
      (p) => p.style,
      (p, s) => p.copyWith(style: s),
      const ParagraphStyle(),
    ),
  );
  const pp = 'content.<paragraphIndex>.style';
  b.add(
    '$pp.alignHorizontal',
    _text,
    pStyle.leaf(
      optField(
        enumC(TextAlignHorizontal.values),
        (s) => s.alignHorizontal,
        (s, v) => s.copyWith(alignHorizontal: v),
      ),
    ),
    inv: _layout,
  );
  b.add(
    '$pp.paragraphSpacing',
    _text,
    pStyle.leaf(
      optField(
        numC,
        (s) => s.paragraphSpacing,
        (s, v) => s.copyWith(paragraphSpacing: v),
      ),
    ),
    inv: _layout,
  );
  b.add(
    '$pp.paragraphIndent',
    _text,
    pStyle.leaf(
      optField(
        numC,
        (s) => s.paragraphIndent,
        (s, v) => s.copyWith(paragraphIndent: v),
      ),
    ),
    inv: _layout,
  );
  b.add(
    '$pp.listStyle',
    _text,
    pStyle.leaf(
      optField(
        enumC(ListStyle.values),
        (s) => s.listStyle,
        (s, v) => s.copyWith(listStyle: v),
      ),
    ),
    inv: _layout,
  );

  final span = paragraph
      .then(
        sub<Paragraph, List<Span>>(
          (p) => p.spans,
          (p, s) => p.copyWith(spans: s),
        ),
      )
      .then(atIndex<Span>('spanIndex'));
  const sp = 'content.<paragraphIndex>.spans.<spanIndex>';
  b.add(
    '$sp.text',
    _text,
    span.leaf(field(strC, (s) => s.text, (s, v) => s.copyWith(text: v))),
    inv: _layout,
  );
  _textOverrideProps(
    b,
    '$sp.style',
    span.then(
      sub<Span, TextStyleOverride>(
        (s) => s.style,
        (s, o) => s.copyWith(style: o),
      ),
    ),
  );
}

// ---- Video and embeds (§6, §4.1) ---------------------------------------------

void _videoProps(_Builder b) {
  b.add(
    'assetId',
    {NodeKind.video, NodeKind.embed},
    Leaf<Node>(
      Lens<Node, IrValue>(
        (n, _) => switch (n) {
          VideoNode(:final assetId) ||
          EmbedNode(:final assetId) => IrValue.string(assetId),
          _ => null,
        },
        (n, v, _) {
          final s = strC.decode(v);
          if (s == null) return null;
          return switch (n) {
            VideoNode() => n.copyWith(assetId: s),
            EmbedNode() => n.copyWith(assetId: s),
            _ => null,
          };
        },
      ),
      strC,
    ),
    animatable: false,
  );
  final scaleC = enumC(ImageScaleMode.values);
  b.add(
    'scaleMode',
    {NodeKind.video, NodeKind.embed},
    Leaf<Node>(
      Lens<Node, IrValue>(
        (n, _) => switch (n) {
          VideoNode(:final scaleMode) ||
          EmbedNode(:final scaleMode) => scaleC.encode(scaleMode),
          _ => null,
        },
        (n, v, _) {
          final s = scaleC.decode(v);
          if (s == null) return null;
          return switch (n) {
            VideoNode() => n.copyWith(scaleMode: s),
            EmbedNode() => n.copyWith(scaleMode: s),
            _ => null,
          };
        },
      ),
      scaleC,
    ),
    inv: _layout,
  );
  b.add(
    'focalPoint',
    _video,
    _asVideo.leaf(
      field(pointC, (v) => v.focalPoint, (v, p) => v.copyWith(focalPoint: p)),
    ),
  );
  _cropRectProps(
    b,
    'cropRect',
    _video,
    _asVideo.then(
      materialised<VideoNode, StageRect>(
        (v) => v.cropRect,
        (v, r) => v.copyWith(cropRect: r),
        const StageRect(),
      ),
    ),
  );
  b.add(
    'posterAssetId',
    _video,
    _asVideo.leaf(
      optField(
        strC,
        (v) => v.posterAssetId,
        (v, s) => v.copyWith(posterAssetId: s),
      ),
    ),
    animatable: false,
  );
  b.add(
    'muted',
    _video,
    _asVideo.leaf(field(boolC, (v) => v.muted, (v, m) => v.copyWith(muted: m))),
    animatable: false,
  );
  for (final (name, get, setV, setE)
      in <
        (
          String,
          bool Function(Node),
          Node Function(VideoNode, bool),
          Node Function(EmbedNode, bool),
        )
      >[
        (
          'autoplay',
          (n) => n is VideoNode ? n.autoplay : (n as EmbedNode).autoplay,
          (v, x) => v.copyWith(autoplay: x),
          (e, x) => e.copyWith(autoplay: x),
        ),
        (
          'loop',
          (n) => n is VideoNode ? n.loop : (n as EmbedNode).loop,
          (v, x) => v.copyWith(loop: x),
          (e, x) => e.copyWith(loop: x),
        ),
      ]) {
    b.add(
      name,
      {NodeKind.video, NodeKind.embed},
      Leaf<Node>(
        Lens<Node, IrValue>(
          (n, _) =>
              n is VideoNode || n is EmbedNode ? IrValue.boolean(get(n)) : null,
          (n, v, _) {
            final x = boolC.decode(v);
            if (x == null) return null;
            return switch (n) {
              VideoNode() => setV(n, x),
              EmbedNode() => setE(n, x),
              _ => null,
            };
          },
        ),
        boolC,
      ),
      animatable: false,
    );
  }
}

void _embedProps(_Builder b) {
  b.add(
    'artboard',
    _embed,
    _asEmbed.leaf(
      optField(strC, (e) => e.artboard, (e, v) => e.copyWith(artboard: v)),
    ),
    animatable: false,
  );
  b.add(
    'stateMachine',
    _embed,
    _asEmbed.leaf(
      optField(
        strC,
        (e) => e.stateMachine,
        (e, v) => e.copyWith(stateMachine: v),
      ),
    ),
    animatable: false,
  );
  b.add(
    'inputs.<inputName>',
    _embed,
    _asEmbed.leaf(
      mapEntry(
        anyC,
        'inputName',
        (e) => e.inputs,
        (e, m) => e.copyWith(inputs: m),
      ),
    ),
  );
  b.add(
    'inputBindings.<inputName>',
    _embed,
    _asEmbed.leaf(
      mapEntry(
        strC,
        'inputName',
        (e) => e.inputBindings,
        (e, m) => e.copyWith(inputBindings: m),
      ),
    ),
    animatable: false,
  );
}

// ---- Instances (§9) ----------------------------------------------------------

void _instanceProps(_Builder b) {
  // Instance swap: points the instance at a component (a variant source
  // becomes a component source).
  b.add(
    'componentId',
    _instance,
    _asInstance.leaf(
      Leaf<InstanceNode>(
        Lens<InstanceNode, IrValue>(
          (i, _) => switch (i.source) {
            ComponentSource(:final componentId) => IrValue.string(componentId),
            VariantSource() => null,
          },
          (i, v, _) {
            final id = strC.decode(v);
            return id == null
                ? null
                : i.copyWith(source: InstanceSource.component(id));
          },
        ),
        strC,
      ),
    ),
    inv: _layout,
    animatable: false,
  );
  b.add(
    'variantValues.<axis>',
    _instance,
    _asInstance
        .then(
          Lens<InstanceNode, VariantSource>(
            (i, _) => switch (i.source) {
              final VariantSource v => v,
              ComponentSource() => null,
            },
            (i, v, _) => i.copyWith(source: v),
          ),
        )
        .leaf(
          mapEntry(
            strC,
            'axis',
            (v) => v.variantValues,
            (v, m) => v.copyWith(variantValues: m),
          ),
        ),
    inv: _layout,
    animatable: false,
  );
  b.add(
    'propValues.<propId>',
    _instance,
    _asInstance.leaf(
      mapEntry(
        anyC,
        'propId',
        (i) => i.propValues,
        (i, m) => i.copyWith(propValues: m),
      ),
    ),
    inv: _layout,
    animatable: false,
  );
}
