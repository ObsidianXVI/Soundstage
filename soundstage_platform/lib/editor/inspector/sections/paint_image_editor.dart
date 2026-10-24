import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart'
    show
        StageAssetResolver,
        StageImageCache,
        StageMedia,
        bundledAssetPath,
        imageFillRect,
        localAssetId,
        stageColor;

import '../../core/core.dart';
import '../../panels/asset_actions.dart';
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../property_writer.dart';
import 'paint_gradient_editor.dart' show PointAxisField;
import 'paint_stack.dart';

// The image-paint editor (architecture §6): asset, scale mode, focal point
// (fill/fit) or crop rectangle (crop) on a preview, tile scale, quarter
// turns and the adjustments. Focal point and crop rect are normalised in
// the displayed (rotated) image, as the runtime places them.

const List<String> kImageFilterNames = [
  'exposure',
  'contrast',
  'saturation',
  'temperature',
  'tint',
  'highlights',
  'shadows',
];

const Map<String, String> _filterLabels = {
  'exposure': 'Exposure',
  'contrast': 'Contrast',
  'saturation': 'Saturation',
  'temperature': 'Temperature',
  'tint': 'Tint',
  'highlights': 'Highlights',
  'shadows': 'Shadows',
};

double _r4(double v) => (v * 1e4).roundToDouble() / 1e4;

/// The document's image assets, compared by value.
@immutable
class PaintImageAssets {
  PaintImageAssets(Iterable<ir.Asset> assets)
    : list = List.unmodifiable(assets);

  final List<ir.Asset> list;

  ir.Asset? byId(String id) {
    for (final a in list) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is PaintImageAssets && listEquals(other.list, list);

  @override
  int get hashCode => Object.hashAll(list);
}

final paintImageAssetsProvider = Provider.autoDispose<PaintImageAssets>((ref) {
  final assets = ref
      .watch(
        editorControllerProvider.select((s) => Identity(s.document.assets)),
      )
      .value;
  return PaintImageAssets(
    assets.values.where((a) => a.kind == ir.AssetKind.image),
  );
}, dependencies: [editorControllerProvider]);

// ---- Thumbnails ------------------------------------------------------------------

/// Decoded thumbnails for the inspector, separate from the canvas's cache.
final StageImageCache _thumbCache = StageImageCache(maxBytes: 32 << 20);

/// Whether [a] can be decoded here: bundled assets, and local ones once
/// browser storage is open. Others (and tests) show the placeholder.
bool _loadable(ir.Asset a) =>
    bundledAssetPath(a.uri) != null ||
    (localAssetId(a.uri) != null && StageAssetResolver.defaultLocal != null);

/// [asset] decoded through the runtime's media machinery (smallest variant
/// at least [targetWidth] px), else its dominant colour while it loads or
/// when it cannot be loaded.
class PaintAssetImage extends StatefulWidget {
  const PaintAssetImage({
    required this.asset,
    required this.targetWidth,
    this.quarterTurns = 0,
    this.fit = BoxFit.cover,
    super.key,
  });

  final ir.Asset asset;
  final double targetWidth;
  final int quarterTurns;
  final BoxFit fit;

  @override
  State<PaintAssetImage> createState() => _PaintAssetImageState();
}

class _PaintAssetImageState extends State<PaintAssetImage> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _image = _obtain();
  }

  @override
  void didUpdateWidget(PaintAssetImage old) {
    super.didUpdateWidget(old);
    if (old.asset.uri != widget.asset.uri || old.asset.id != widget.asset.id) {
      _image?.dispose();
      _image = _obtain();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  ui.Image? _obtain() {
    final a = widget.asset;
    if (!_loadable(a)) return null;
    final media = StageMedia(
      resolver: StageAssetResolver(assets: {a.id: a}),
      cache: _thumbCache,
    );
    // The cache may evict and dispose its copy: keep our own handle.
    return media
        .image(a.id, targetWidth: widget.targetWidth, onReady: _ready)
        ?.clone();
  }

  void _ready() {
    if (!mounted) return;
    final img = _obtain();
    if (img == null) return;
    setState(() {
      _image?.dispose();
      _image = img;
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      final c = widget.asset.placeholder?.dominantColor;
      return ColoredBox(
        color: c == null ? context.ss.colors.surface3 : stageColor(c),
        child: const SizedBox.expand(),
      );
    }
    return RotatedBox(
      quarterTurns: widget.quarterTurns,
      child: RawImage(image: img, fit: widget.fit),
    );
  }
}

/// The swatch thumbnail of an image paint's asset.
class PaintAssetThumb extends ConsumerWidget {
  const PaintAssetThumb({
    required this.assetId,
    required this.targetWidth,
    super.key,
  });

  final String assetId;
  final double targetWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(
      paintImageAssetsProvider.select((a) => a.byId(assetId)),
    );
    if (asset == null) {
      return ColoredBox(
        color: context.ss.colors.surface3,
        child: Center(
          child: SsIcon(
            SsIcons.image,
            size: 10,
            color: context.ss.colors.textDisabled,
          ),
        ),
      );
    }
    return PaintAssetImage(asset: asset, targetWidth: targetWidth);
  }
}

// ---- The editor --------------------------------------------------------------------

class PaintImageEditor extends ConsumerWidget {
  const PaintImageEditor({
    required this.stackPath,
    required this.paint,
    super.key,
  });

  final String stackPath;
  final ir.ImagePaint paint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = '$stackPath.${paint.id}';
    final asset = ref.watch(
      paintImageAssetsProvider.select((a) => a.byId(paint.assetId)),
    );
    final w = InspectorScope.of(context).writer;
    final mode = paint.scaleMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _AssetChooser(path: path, paint: paint, asset: asset),
        const SizedBox(height: SsSpace.s2),
        EnumProp(
          path: '$path.scaleMode',
          semanticLabel: 'Image scale mode',
          options: const [
            EnumOption('fill', 'Fill'),
            EnumOption('fit', 'Fit'),
            EnumOption('crop', 'Crop'),
            EnumOption('tile', 'Tile'),
          ],
        ),
        const SizedBox(height: SsSpace.s2),
        if (asset == null)
          _EmptyImage(path: path, paint: paint)
        else if (mode != ir.ImageScaleMode.tile) ...[
          PaintImagePreview(path: path, paint: paint, asset: asset),
          const SizedBox(height: SsSpace.s2),
        ],
        if (mode == ir.ImageScaleMode.fill || mode == ir.ImageScaleMode.fit)
          LabelRow(
            label: 'Focal point',
            child: Row(
              children: [
                Expanded(
                  child: PointAxisField(
                    path: '$path.focalPoint',
                    axis: Axis.horizontal,
                    label: 'X',
                    semanticLabel: 'Focal point X',
                    min: 0,
                    max: 100,
                  ),
                ),
                const SizedBox(width: SsSpace.s2),
                Expanded(
                  child: PointAxisField(
                    path: '$path.focalPoint',
                    axis: Axis.vertical,
                    label: 'Y',
                    semanticLabel: 'Focal point Y',
                    min: 0,
                    max: 100,
                  ),
                ),
              ],
            ),
          ),
        if (mode == ir.ImageScaleMode.crop) ...[
          Grid(
            children: [
              for (final (f, l, s) in const [
                ('x', 'X', 'Crop left'),
                ('y', 'Y', 'Crop top'),
                ('width', 'W', 'Crop width'),
                ('height', 'H', 'Crop height'),
              ])
                NumberProp(
                  path: '$path.cropRect.$f',
                  label: l,
                  semanticLabel: s,
                  unit: '%',
                  scale: 100,
                  min: 0,
                  max: 100,
                  fractionDigits: 1,
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(bottom: SsSpace.s2),
              child: SsButton(
                key: ValueKey<String>('image-reset-crop:${paint.id}'),
                label: 'Reset crop',
                icon: SsIcons.rotateCcw,
                variant: SsButtonVariant.ghost,
                onPressed: paint.cropRect == null
                    ? null
                    : () => w.set(
                        path,
                        ir.IrValue.paint(paint.copyWith(cropRect: null)),
                      ),
              ),
            ),
          ),
        ],
        if (mode == ir.ImageScaleMode.tile)
          LabelRow(
            label: 'Tile scale',
            child: NumberProp(
              path: '$path.tileScale',
              semanticLabel: 'Tile scale',
              unit: '×',
              min: 0.01,
              step: 0.1,
              fractionDigits: 2,
            ),
          ),
        LabelRow(
          label: 'Rotation',
          child: _RotationProp(path: '$path.rotation'),
        ),
        _Adjustments(path: path, paint: paint),
      ],
    );
  }
}

// ---- Asset chooser -----------------------------------------------------------------

void _openAssetMenu(
  BuildContext anchor,
  WidgetRef ref,
  PropertyWriter w,
  String path,
  String current,
) {
  final assets = ref.read(paintImageAssetsProvider).list;
  showSsMenu(
    anchor,
    anchor: ssGlobalRect(anchor),
    matchAnchorWidth: true,
    minWidth: 160,
    entries: [
      if (assets.isEmpty) const SsMenuLabel('No images in this document'),
      for (final a in assets)
        SsMenuItem(
          label: a.name.isEmpty ? a.id : a.name,
          icon: SsIcons.image,
          checked: a.id == current,
          onSelected: () => w.set('$path.assetId', ir.IrValue.string(a.id)),
        ),
      const SsMenuDivider(),
      SsMenuItem(
        label: 'Upload…',
        icon: SsIcons.imagePlus,
        onSelected: () => unawaited(_uploadAndUse(ref, w, path)),
      ),
    ],
  );
}

/// Picks an image file, adds it to the library and makes the paint use it.
Future<void> _uploadAndUse(WidgetRef ref, PropertyWriter w, String path) async {
  final asset = await ref.read(assetActionsProvider).uploadImage();
  if (asset != null) w.set('$path.assetId', ir.IrValue.string(asset.id));
}

class _AssetChooser extends ConsumerWidget {
  const _AssetChooser({
    required this.path,
    required this.paint,
    required this.asset,
  });

  final String path;
  final ir.ImagePaint paint;
  final ir.Asset? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final w = InspectorScope.of(context).writer;
    final a = asset;
    final name = a == null
        ? (paint.assetId.isEmpty ? 'Choose image…' : 'Missing image')
        : (a.name.isEmpty ? a.id : a.name);
    return FieldFrame.single(
      path: '$path.assetId',
      child: Builder(
        builder: (anchor) => SsInteractive(
          key: ValueKey<String>('image-asset:${paint.id}'),
          onTap: () => _openAssetMenu(anchor, ref, w, path, paint.assetId),
          semanticLabel: 'Image',
          semanticValue: name,
          semanticHint: 'Opens the list of images',
          excludeSemantics: true,
          builder: (context, s) => Container(
            height: SsSpace.controlHeight,
            padding: const EdgeInsets.only(left: 4, right: SsSpace.s1),
            decoration: BoxDecoration(
              color: s.contains(WidgetState.hovered)
                  ? Color.alphaBlend(c.hoverLayer, c.surface2)
                  : c.surface2,
              borderRadius: SsRadius.brMd,
              border: Border.all(
                color: s.contains(WidgetState.focused) ? c.focusRing : c.border,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: SsRadius.brSm,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: PaintAssetThumb(
                      assetId: paint.assetId,
                      targetWidth: 60,
                    ),
                  ),
                ),
                const SizedBox(width: SsSpace.s2),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.text.small.copyWith(
                      color: a == null ? c.textSecondary : c.textPrimary,
                    ),
                  ),
                ),
                SsIcon(SsIcons.chevronDown, size: 14, color: c.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The dashed "choose an image" placeholder of an image paint with no
/// (or a missing) asset.
class _EmptyImage extends ConsumerWidget {
  const _EmptyImage({required this.path, required this.paint});

  final String path;
  final ir.ImagePaint paint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final w = InspectorScope.of(context).writer;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Builder(
        builder: (anchor) => SsInteractive(
          key: ValueKey<String>('image-empty:${paint.id}'),
          onTap: () => _openAssetMenu(anchor, ref, w, path, paint.assetId),
          semanticLabel: 'Choose an image',
          builder: (context, s) => CustomPaint(
            painter: _DashedBorderPainter(
              color: s.contains(WidgetState.hovered)
                  ? t.colors.borderStrong
                  : t.colors.border,
            ),
            child: SizedBox(
              height: 72,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SsIcon(
                      SsIcons.imagePlus,
                      size: 16,
                      color: t.colors.textSecondary,
                    ),
                    const SizedBox(height: SsSpace.s1),
                    Text(
                      paint.assetId.isEmpty
                          ? 'Choose an image'
                          : 'Image not found',
                      style: t.text.caption,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.5),
      const Radius.circular(SsRadius.md),
    );
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in (Path()..addRRect(rrect)).computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, math.min(d + 4, m.length)), p);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

// ---- Preview, focal point and crop ---------------------------------------------------

enum _CropDrag { move, topLeft, topRight, bottomLeft, bottomRight }

/// The image at its displayed aspect with the focal-point handle (fill and
/// fit; in fill, the node's visible window is outlined) or the crop
/// rectangle (crop). Click or drag to set; a drag is one undo step;
/// double-click resets the focal point to the centre.
class PaintImagePreview extends ConsumerStatefulWidget {
  const PaintImagePreview({
    required this.path,
    required this.paint,
    required this.asset,
    super.key,
  });

  final String path;
  final ir.ImagePaint paint;
  final ir.Asset asset;

  @override
  ConsumerState<PaintImagePreview> createState() => _PaintImagePreviewState();
}

class _PaintImagePreviewState extends ConsumerState<PaintImagePreview> {
  // Double-click is detected from pointer timestamps, so a single click
  // acts at once (a DoubleTapGestureRecognizer would delay it).
  Duration _downAt = Duration.zero;
  Duration? _lastTap;
  bool _gesture = false;
  _CropDrag? _crop;
  Offset _cropStart = Offset.zero;
  ir.StageRect _cropFrom = const ir.StageRect();

  PropertyWriter get _w => InspectorScope.of(context).writer;
  String get _focalPath => '${widget.path}.focalPoint';
  bool get _isCrop => widget.paint.scaleMode == ir.ImageScaleMode.crop;

  @override
  void dispose() {
    if (_gesture) _w.endGesture();
    super.dispose();
  }

  void _setFocal(Offset local, Size size) {
    final p = ir.StagePoint(
      x: _r4((local.dx / size.width).clamp(0.0, 1.0)),
      y: _r4((local.dy / size.height).clamp(0.0, 1.0)),
    );
    if (p == widget.paint.focalPoint) return;
    _w.set(_focalPath, ir.IrValue.point(p));
  }

  void _writeCrop(ir.StageRect r) {
    final p = widget.path;
    _w.setMany({
      '$p.cropRect.x': ir.IrValue.number(_r4(r.x)),
      '$p.cropRect.y': ir.IrValue.number(_r4(r.y)),
      '$p.cropRect.width': ir.IrValue.number(_r4(r.width)),
      '$p.cropRect.height': ir.IrValue.number(_r4(r.height)),
    });
  }

  ir.StageRect get _cropRect => widget.paint.cropRect ?? const ir.StageRect();

  _CropDrag? _cropHit(Offset local, Size size) {
    final r = _cropRect;
    final rect = Rect.fromLTWH(
      r.x * size.width,
      r.y * size.height,
      r.width * size.width,
      r.height * size.height,
    );
    const slop = 10.0;
    bool near(Offset a) => (a - local).distance <= slop;
    if (near(rect.topLeft)) return _CropDrag.topLeft;
    if (near(rect.topRight)) return _CropDrag.topRight;
    if (near(rect.bottomLeft)) return _CropDrag.bottomLeft;
    if (near(rect.bottomRight)) return _CropDrag.bottomRight;
    if (rect.contains(local)) return _CropDrag.move;
    return null;
  }

  void _dragCrop(Offset local, Size size) {
    final mode = _crop;
    if (mode == null) return;
    final d = Offset(
      (local.dx - _cropStart.dx) / size.width,
      (local.dy - _cropStart.dy) / size.height,
    );
    final f = _cropFrom;
    const minSize = 0.05;
    var l = f.x, t = f.y, r = f.x + f.width, b = f.y + f.height;
    switch (mode) {
      case _CropDrag.move:
        final dx = d.dx.clamp(-l, 1 - r);
        final dy = d.dy.clamp(-t, 1 - b);
        l += dx;
        r += dx;
        t += dy;
        b += dy;
      case _CropDrag.topLeft:
        l = (l + d.dx).clamp(0.0, r - minSize);
        t = (t + d.dy).clamp(0.0, b - minSize);
      case _CropDrag.topRight:
        r = (r + d.dx).clamp(l + minSize, 1.0);
        t = (t + d.dy).clamp(0.0, b - minSize);
      case _CropDrag.bottomLeft:
        l = (l + d.dx).clamp(0.0, r - minSize);
        b = (b + d.dy).clamp(t + minSize, 1.0);
      case _CropDrag.bottomRight:
        r = (r + d.dx).clamp(l + minSize, 1.0);
        b = (b + d.dy).clamp(t + minSize, 1.0);
    }
    _writeCrop(ir.StageRect(x: l, y: t, width: r - l, height: b - t));
  }

  void _tap(Offset local, Size size) {
    if (_isCrop) return;
    final now = _downAt;
    final last = _lastTap;
    _lastTap = now;
    if (last != null && now - last < kDoubleTapTimeout) {
      _lastTap = null;
      const centre = ir.StagePoint(x: 0.5, y: 0.5);
      if (widget.paint.focalPoint != centre) {
        _w.set(_focalPath, const ir.IrValue.point(centre));
      }
      return;
    }
    _setFocal(local, size);
  }

  void _start(Offset local, Size size) {
    if (_isCrop) {
      _crop = _cropHit(local, size);
      if (_crop == null) return;
      _cropStart = local;
      _cropFrom = _cropRect;
    }
    _gesture = true;
    _w.beginGesture();
    if (!_isCrop) _setFocal(local, size);
  }

  void _update(Offset local, Size size) {
    if (!_gesture) return;
    if (_isCrop) {
      _dragCrop(local, size);
    } else {
      _setFocal(local, size);
    }
  }

  void _end() {
    _crop = null;
    if (!_gesture) return;
    _gesture = false;
    _w.endGesture();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final p = widget.paint;
    final turns = (((p.rotation / 90).round() % 4) + 4) % 4;
    final iw = a.width, ih = a.height;
    var aspect = 16 / 9;
    if (iw != null && ih != null && iw > 0 && ih > 0) {
      aspect = turns.isOdd ? ih / iw : iw / ih;
    }
    final wr = watchReading(context, ref, 'width');
    final hr = watchReading(context, ref, 'height');
    final node =
        !wr.mixed && !hr.mixed && (wr.number ?? 0) > 0 && (hr.number ?? 0) > 0
        ? Size(wr.number!, hr.number!)
        : null;
    final colors = context.ss.colors;
    return LayoutBuilder(
      builder: (context, box) {
        final maxW = box.maxWidth;
        final h = (maxW / aspect).clamp(72.0, 160.0);
        final size = Size(math.min(maxW, h * aspect), h);
        Rect? window;
        if (p.scaleMode == ir.ImageScaleMode.fill && node != null) {
          final dst = imageFillRect(node, size, p.focalPoint);
          if (dst.width > 0 && dst.height > 0) {
            window = Rect.fromLTWH(
              -dst.left / dst.width * size.width,
              -dst.top / dst.height * size.height,
              node.width / dst.width * size.width,
              node.height / dst.height * size.height,
            );
          }
        }
        final c = _cropRect;
        final crop = _isCrop
            ? Rect.fromLTWH(
                c.x * size.width,
                c.y * size.height,
                c.width * size.width,
                c.height * size.height,
              )
            : null;
        final focal = _isCrop
            ? null
            : Offset(
                p.focalPoint.x.clamp(0.0, 1.0) * size.width,
                p.focalPoint.y.clamp(0.0, 1.0) * size.height,
              );
        return Center(
          child: FieldFrame(
            paths: _isCrop
                ? [
                    for (final f in ['x', 'y', 'width', 'height'])
                      '${widget.path}.cropRect.$f',
                  ]
                : [_focalPath],
            child: Semantics(
              label: _isCrop ? 'Crop area' : 'Focal point',
              value: _isCrop
                  ? '${(c.width * 100).round()}% by '
                        '${(c.height * 100).round()}%'
                  : '${(p.focalPoint.x * 100).round()}%, '
                        '${(p.focalPoint.y * 100).round()}%',
              child: Listener(
                onPointerDown: (e) => _downAt = e.timeStamp,
                child: GestureDetector(
                  key: ValueKey<String>('image-preview:${p.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _tap(d.localPosition, size),
                  onPanStart: (d) => _start(d.localPosition, size),
                  onPanUpdate: (d) => _update(d.localPosition, size),
                  onPanEnd: (_) => _end(),
                  onPanCancel: _end,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.precise,
                    child: ClipRRect(
                      borderRadius: SsRadius.brSm,
                      child: SizedBox.fromSize(
                        size: size,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            SsCheckerboard(
                              cell: 6,
                              child: PaintAssetImage(
                                asset: a,
                                targetWidth: size.width * 2,
                                quarterTurns: turns,
                                fit: BoxFit.fill,
                              ),
                            ),
                            CustomPaint(
                              painter: _PreviewOverlayPainter(
                                focal: focal,
                                window: window,
                                crop: crop,
                                light: colors.textOnAccent,
                                dark: colors.scrim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PreviewOverlayPainter extends CustomPainter {
  const _PreviewOverlayPainter({
    required this.focal,
    required this.window,
    required this.crop,
    required this.light,
    required this.dark,
  });

  final Offset? focal;
  final Rect? window;
  final Rect? crop;
  final Color light;
  final Color dark;

  void _dimOutside(Canvas canvas, Size size, Rect r, double alpha) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(path, Paint()..color = dark.withValues(alpha: alpha));
    canvas.drawRect(
      r.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = light.withValues(alpha: 0.8),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = window;
    if (w != null) _dimOutside(canvas, size, w, 0.3);
    final c = crop;
    if (c != null) {
      _dimOutside(canvas, size, c, 0.5);
      final handle = Paint()..color = light;
      final edge = Paint()
        ..style = PaintingStyle.stroke
        ..color = dark;
      for (final p in [c.topLeft, c.topRight, c.bottomLeft, c.bottomRight]) {
        final r = Rect.fromCenter(center: p, width: 7, height: 7);
        canvas
          ..drawRect(r, handle)
          ..drawRect(r, edge);
      }
    }
    final f = focal;
    if (f != null) {
      final faint = Paint()
        ..strokeWidth = 1
        ..color = light.withValues(alpha: 0.35);
      canvas
        ..drawLine(Offset(0, f.dy), Offset(size.width, f.dy), faint)
        ..drawLine(Offset(f.dx, 0), Offset(f.dx, size.height), faint)
        ..drawCircle(
          f,
          7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = dark,
        )
        ..drawCircle(
          f,
          7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = light,
        )
        ..drawCircle(f, 1.5, Paint()..color = light);
    }
  }

  @override
  bool shouldRepaint(_PreviewOverlayPainter old) =>
      old.focal != focal ||
      old.window != window ||
      old.crop != crop ||
      old.light != light ||
      old.dark != dark;
}

// ---- Rotation ------------------------------------------------------------------------

class _RotationProp extends ConsumerWidget {
  const _RotationProp({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final v = r.number;
    return FieldFrame.single(
      path: path,
      child: SsSegmented<int>(
        key: ValueKey<String>('field:$path'),
        semanticLabel: 'Image rotation',
        expand: true,
        selected: r.mixed || v == null ? null : v.round(),
        onChanged: r.exists
            ? (deg) => w.set(path, ir.IrValue.number(deg.toDouble()))
            : null,
        segments: [
          for (final d in const [0, 90, 180, 270])
            SsSegment(value: d, label: '$d°', semanticLabel: '$d degrees'),
        ],
      ),
    );
  }
}

// ---- Adjustments -------------------------------------------------------------------

class _Adjustments extends StatelessWidget {
  const _Adjustments({required this.path, required this.paint});

  final String path;
  final ir.ImagePaint paint;

  @override
  Widget build(BuildContext context) {
    final ui = PaintUi.of(context);
    final open = ui.adjustmentsOpen;
    final t = context.ss;
    final f = paint.filters;
    final any = f != const ir.ImageFilters();
    final w = InspectorScope.of(context).writer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: SsSpace.controlHeight,
          child: Row(
            children: [
              Expanded(
                child: SsInteractive(
                  key: ValueKey<String>('image-adjustments:${paint.id}'),
                  onTap: () => ui.adjustmentsOpen = !open,
                  semanticLabel: 'Adjustments',
                  semanticValue: open ? 'expanded' : 'collapsed',
                  excludeSemantics: true,
                  builder: (context, s) => Row(
                    children: [
                      SsIcon(
                        open ? SsIcons.chevronDown : SsIcons.chevronRight,
                        size: 12,
                        color: t.colors.textSecondary,
                      ),
                      const SizedBox(width: SsSpace.s1),
                      Flexible(
                        child: Text(
                          'Adjustments',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.text.small.copyWith(
                            color: s.contains(WidgetState.hovered)
                                ? t.colors.textPrimary
                                : t.colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (any)
                SsButton(
                  key: ValueKey<String>('image-filters-reset:${paint.id}'),
                  label: 'Reset all',
                  variant: SsButtonVariant.ghost,
                  onPressed: () => w.setMany({
                    for (final n in kImageFilterNames)
                      '$path.filters.$n': const ir.IrValue.number(0),
                  }),
                ),
            ],
          ),
        ),
        if (open)
          for (final n in kImageFilterNames)
            PaintFilterSlider(
              path: '$path.filters.$n',
              label: _filterLabels[n]!,
            ),
      ],
    );
  }
}

/// A compact −100…100 slider for one image adjustment (stored −1…1).
///
/// Drag (one undo step) or click to set, double-click to reset to 0,
/// arrows to step (Shift: ×10). 24 px high.
class PaintFilterSlider extends ConsumerStatefulWidget {
  const PaintFilterSlider({required this.path, required this.label, super.key});

  final String path;
  final String label;

  @override
  ConsumerState<PaintFilterSlider> createState() => _PaintFilterSliderState();
}

class _PaintFilterSliderState extends ConsumerState<PaintFilterSlider> {
  final FocusNode _focus = FocusNode(debugLabel: 'PaintFilterSlider');
  // Double-click is detected from pointer timestamps, so a single click
  // acts at once (a DoubleTapGestureRecognizer would delay it).
  Duration _downAt = Duration.zero;
  Duration? _lastTap;
  bool _dragging = false;
  bool _focused = false;
  double _value = 0;

  PropertyWriter get _w => InspectorScope.of(context).writer;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    if (_dragging) _w.endGesture();
    _focus.dispose();
    super.dispose();
  }

  void _set(double v) {
    final x = (v.clamp(-1.0, 1.0) * 100).roundToDouble() / 100;
    if (x == _value) return;
    _value = x;
    _w.set(widget.path, ir.IrValue.number(x));
  }

  double _at(double dx, double width) => (dx / math.max(1, width)) * 2 - 1;

  void _step(int dir) {
    final s = HardwareKeyboard.instance.isShiftPressed ? 0.1 : 0.01;
    _set(_value + dir * s);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowUp) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowDown) {
      _step(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final r = watchReading(context, ref, widget.path);
    _value = r.number ?? 0;
    final t = context.ss;
    final c = t.colors;
    final shown = r.mixed ? '–' : '${(_value * 100).round()}';
    final enabled = r.exists;
    return FieldFrame.single(
      path: widget.path,
      child: SizedBox(
        height: SsSpace.controlHeightSm,
        child: Row(
          children: [
            SizedBox(
              width: 76,
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.text.small.copyWith(color: c.textSecondary),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final width = box.maxWidth;
                  return Focus(
                    focusNode: _focus,
                    canRequestFocus: enabled,
                    onKeyEvent: enabled ? _onKey : null,
                    child: Semantics(
                      slider: true,
                      label: widget.label,
                      value: shown,
                      increasedValue: '${((_value + 0.01) * 100).round()}',
                      decreasedValue: '${((_value - 0.01) * 100).round()}',
                      onIncrease: enabled ? () => _step(1) : null,
                      onDecrease: enabled ? () => _step(-1) : null,
                      child: Listener(
                        onPointerDown: (e) => _downAt = e.timeStamp,
                        child: GestureDetector(
                          key: ValueKey<String>('slider:${widget.path}'),
                          behavior: HitTestBehavior.opaque,
                          onTapUp: !enabled
                              ? null
                              : (d) {
                                  _focus.requestFocus();
                                  final now = _downAt;
                                  final last = _lastTap;
                                  _lastTap = now;
                                  if (last != null &&
                                      now - last < kDoubleTapTimeout) {
                                    _lastTap = null;
                                    _set(0);
                                    return;
                                  }
                                  _set(_at(d.localPosition.dx, width));
                                },
                          onHorizontalDragStart: !enabled
                              ? null
                              : (d) {
                                  _focus.requestFocus();
                                  _dragging = true;
                                  _w.beginGesture();
                                  _set(_at(d.localPosition.dx, width));
                                },
                          onHorizontalDragUpdate: !enabled
                              ? null
                              : (d) => _set(_at(d.localPosition.dx, width)),
                          onHorizontalDragEnd: (_) {
                            if (!_dragging) return;
                            _dragging = false;
                            _w.endGesture();
                          },
                          onHorizontalDragCancel: () {
                            if (!_dragging) return;
                            _dragging = false;
                            _w.endGesture();
                          },
                          child: MouseRegion(
                            cursor: enabled
                                ? SystemMouseCursors.resizeLeftRight
                                : SystemMouseCursors.basic,
                            child: CustomPaint(
                              size: Size(width, SsSpace.controlHeightSm),
                              painter: _SliderPainter(
                                value: r.mixed ? null : _value,
                                focused: _focused,
                                track: c.border,
                                tick: c.borderStrong,
                                active: c.accent,
                                thumb: enabled ? c.textPrimary : c.textDisabled,
                                thumbEdge: c.surface0,
                                ring: c.focusRing,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                shown,
                textAlign: TextAlign.right,
                style: t.text.numeric.copyWith(
                  color: _value == 0 ? c.textSecondary : c.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderPainter extends CustomPainter {
  const _SliderPainter({
    required this.value,
    required this.focused,
    required this.track,
    required this.tick,
    required this.active,
    required this.thumb,
    required this.thumbEdge,
    required this.ring,
  });

  final double? value;
  final bool focused;
  final Color track;
  final Color tick;
  final Color active;
  final Color thumb;
  final Color thumbEdge;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    const r = 5.0;
    final cy = size.height / 2;
    final left = r, right = size.width - r;
    final span = math.max(0.0, right - left);
    final mid = left + span / 2;
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, cy - 1, right, cy + 1),
          const Radius.circular(1),
        ),
        Paint()..color = track,
      )
      ..drawRect(Rect.fromLTWH(mid - 0.5, cy - 4, 1, 8), Paint()..color = tick);
    final v = value;
    if (v == null) return;
    final x = mid + v.clamp(-1.0, 1.0) * span / 2;
    canvas
      ..drawRect(
        Rect.fromLTRB(math.min(mid, x), cy - 1, math.max(mid, x), cy + 1),
        Paint()..color = active,
      )
      ..drawCircle(Offset(x, cy), r + 1, Paint()..color = thumbEdge)
      ..drawCircle(Offset(x, cy), r, Paint()..color = thumb);
    if (focused) {
      canvas.drawCircle(
        Offset(x, cy),
        r + 2.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ring,
      );
    }
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.value != value ||
      old.focused != focused ||
      old.track != track ||
      old.active != active ||
      old.thumb != thumb ||
      old.ring != ring;
}
