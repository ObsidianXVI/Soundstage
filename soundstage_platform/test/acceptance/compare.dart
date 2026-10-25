// Compares two stories the way a reader sees them: each scene is resolved
// and laid out at a viewport width, and nodes are matched by layer name.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// What one node looks like at one width.
class NodeLook {
  NodeLook({
    required this.path,
    required this.kind,
    required this.rect,
    required this.visible,
    this.role,
    this.text,
    this.paragraphs,
    this.image,
    this.textBox,
    this.appearance,
  });

  final String path;
  final String kind;
  final Rect? rect;
  final bool visible;
  final ir.NodeRole? role;
  final String? text;

  /// Per paragraph: paragraph-level fields, then per span its text and
  /// merged style (font family by name, colours as 8-bit RGBA).
  final List<Map<String, Object?>>? paragraphs;

  /// Image fill: asset (by file name), scale mode, focal point.
  final Map<String, Object?>? image;

  /// Text box: auto-resize and alignment.
  final Map<String, Object?>? textBox;

  /// See [appearanceOf].
  final Map<String, Object?>? appearance;
}

/// `name#k` segments from the scene root: k counts earlier siblings with
/// the same name, so repeated names ("Label", "Title") stay distinct.
Map<String, ir.ResolvedNode> byNamePath(ir.ResolvedNode root) {
  final out = <String, ir.ResolvedNode>{};
  void walk(ir.ResolvedNode n, String path) {
    out[path] = n;
    final seen = <String, int>{};
    for (final c in n.children) {
      final name = c.node.common.name;
      final k = seen[name] = (seen[name] ?? -1) + 1;
      walk(c, '$path/$name#$k');
    }
  }

  walk(root, root.node.common.name);
  return out;
}

int _c8(double v) => (v * 255).round();

String _rgba(ir.StageColor c) =>
    '${_c8(c.r)},${_c8(c.g)},${_c8(c.b)},${_c8(c.a)}';

Object? _paints(List<ir.Paint> ps) => [
  for (final p in ps)
    switch (p) {
      ir.SolidPaint(:final color, :final opacity, :final visible) =>
        'solid ${_rgba(color)} o$opacity v$visible',
      ir.GradientPaint(:final kind, :final stops, :final handles) =>
        'gradient ${kind.name} '
            '${[for (final s in stops) '${s.position}:${_rgba(s.color)}']} '
            '${handles.start.x},${handles.start.y}→'
            '${handles.end.x},${handles.end.y}',
      ir.ImagePaint(:final scaleMode, :final focalPoint) =>
        'image ${scaleMode.name} ${focalPoint.x},${focalPoint.y}',
    },
];

Map<String, Object?> _style(ir.TextStyle s, ir.StageDocument doc) => {
  'family': s.fontFamilyId == null ? null : doc.fonts[s.fontFamilyId]?.name,
  'weight': s.fontWeight,
  'italic': s.italic,
  'size': s.fontSize,
  'lineHeight': s.lineHeight.toJson(),
  'letterSpacing': s.letterSpacing.toJson(),
  'case': s.textCase.name,
  'decoration': s.decoration.kind.name,
  'fills': _paints(s.fills),
  'paragraphSpacing': s.paragraphSpacing,
  'paragraphIndent': s.paragraphIndent,
  'list': s.listStyle.name,
};

/// The asset file name behind [assetId] (demo assets are bundled paths,
/// rebuilt ones carry the uploaded file's name).
String? assetFile(ir.StageDocument doc, String assetId) {
  final a = doc.assets[assetId];
  if (a == null) return null;
  return a.uri.startsWith('asset://') ? a.uri.split('/').last : a.name;
}

/// The looks of every node of scene [sceneIndex] of [doc] at [width],
/// laid out by the runtime (pinned scenes at the breakpoint's design
/// height).
Future<Map<String, NodeLook>> looksAt(
  WidgetTester tester,
  ir.StageDocument doc,
  int sceneIndex,
  double width,
) async {
  final bp = ir.breakpointForWidth(doc, width)!;
  final viewport = Size(width, bp.designSize.height);
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 4000);
  final resolved = ir.resolveDocument(
    doc,
    ir.ResolveContext(viewportWidth: width),
  );
  final scene = resolved.scenes[sceneIndex];
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: StageScope(
        environment: StageEnvironment.forDocument(
          doc,
          mode: StageRenderMode.play,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: StageSceneView(
            scene: scene,
            viewportSize: viewport,
            breakpoint: resolved.breakpoint,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);

  final boxes = <String, RenderStageBox>{};
  void visit(RenderObject o) {
    if (o is RenderStageBox) boxes[o.nodeId] = o;
    o.visitChildren(visit);
  }

  tester.binding.renderViews.forEach(visit);
  final out = <String, NodeLook>{};
  for (final MapEntry(key: path, value: n) in byNamePath(scene.root).entries) {
    final box = boxes[n.id];
    Rect? rect;
    if (box != null && box.attached && box.hasSize) {
      rect = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
    }
    final node = n.node;
    List<Map<String, Object?>>? paragraphs;
    String? text;
    Map<String, Object?>? textBox;
    if (node is ir.TextNode) {
      text = node.content
          .map((p) => p.spans.map((s) => s.text).join())
          .join('\n');
      paragraphs = [
        for (var i = 0; i < (n.paragraphs?.length ?? 0); i++)
          {
            'spans': [
              for (final s in n.paragraphs![i].spans)
                {'text': s.text, ..._style(s.style, doc)},
            ],
          },
      ];
      textBox = {
        'autoResize': node.autoResize.name,
        'align': node.alignHorizontal.name,
      };
    }
    Map<String, Object?>? image;
    final fills = ir.PropertyRegistry.standard.get(node, 'fills');
    if (fills is ir.PaintsValue) {
      final img = fills.value.whereType<ir.ImagePaint>().firstOrNull;
      if (img != null) {
        image = {
          'asset': assetFile(doc, img.assetId),
          'scaleMode': img.scaleMode.name,
          'focal': '${img.focalPoint.x},${img.focalPoint.y}',
        };
      }
    }
    out[path] = NodeLook(
      path: path,
      kind: node.runtimeType.toString(),
      rect: rect,
      visible: node.common.visible,
      role: node.common.role,
      text: text,
      paragraphs: paragraphs,
      image: image,
      textBox: textBox,
      appearance: appearanceOf(node),
    );
  }
  return out;
}

/// The appearance of [node] in a comparable form (fills, strokes, radius,
/// clip, auto layout, layout child, geometry, rotation).
Map<String, Object?> appearanceOf(ir.Node node) {
  final reg = ir.PropertyRegistry.standard;
  Object? get(String p) => reg.get(node, p)?.toJson();
  return {
    'fills': switch (reg.get(node, 'fills')) {
      ir.PaintsValue(:final value) => _paints(value),
      _ => null,
    },
    'strokes': get('strokes.paints') == null
        ? null
        : [
            _paints((reg.get(node, 'strokes.paints')! as ir.PaintsValue).value),
            get('strokes.weight'),
            get('strokes.align'),
          ],
    'radius': get('cornerRadius'),
    'clip': get('clipContent'),
    'opacity': get('opacity'),
    'rotation': get('rotation'),
    'geometry': node is ir.ShapeNode ? node.geometry.toJson() : null,
  };
}

/// Every difference between scene [name] of [built] and of [target] at
/// [width]: missing or extra layers, rects more than [tolerance] apart,
/// and differing text, spans, images, text boxes, appearance and
/// visibility. Roles are compared by the caller (the demo has none).
Future<List<String>> diffScene(
  WidgetTester tester,
  ir.StageDocument built,
  ir.StageDocument target,
  String name,
  double width, {
  double tolerance = 1,
}) async {
  final bi = built.scenes.indexWhere((s) => s.name == name);
  final ti = target.scenes.indexWhere((s) => s.name == name);
  if (bi < 0 || ti < 0) return ['scene "$name" missing (built $bi, demo $ti)'];
  final b = await looksAt(tester, built, bi, width);
  final t = await looksAt(tester, target, ti, width);
  final out = <String>[];
  final w = width.round();
  for (final k in t.keys) {
    if (!b.containsKey(k)) out.add('@$w $k: missing');
  }
  for (final k in b.keys) {
    if (!t.containsKey(k)) out.add('@$w $k: extra');
  }
  String fmt(Rect? r) => r == null
      ? 'none'
      : '(${r.left.toStringAsFixed(1)}, ${r.top.toStringAsFixed(1)}, '
            '${r.width.toStringAsFixed(1)} × ${r.height.toStringAsFixed(1)})';
  for (final k in t.keys.where(b.containsKey)) {
    final x = b[k]!, y = t[k]!;
    if (x.kind != y.kind) out.add('@$w $k: kind ${x.kind} vs ${y.kind}');
    final rb = x.rect, rt = y.rect;
    final rectOk =
        (rb == null && rt == null) ||
        (rb != null &&
            rt != null &&
            (rb.left - rt.left).abs() <= tolerance &&
            (rb.top - rt.top).abs() <= tolerance &&
            (rb.right - rt.right).abs() <= tolerance &&
            (rb.bottom - rt.bottom).abs() <= tolerance);
    if (!rectOk) out.add('@$w $k: rect ${fmt(rb)} vs ${fmt(rt)}');
    void same(String what, Object? a, Object? c) {
      if ('$a' != '$c') out.add('@$w $k: $what\n    built $a\n    demo  $c');
    }

    same('visible', x.visible, y.visible);
    same('text', x.text, y.text);
    final px = x.paragraphs ?? const [], py = y.paragraphs ?? const [];
    if (px.length != py.length) {
      out.add('@$w $k: ${px.length} paragraphs vs ${py.length}');
    } else {
      for (var i = 0; i < px.length; i++) {
        same('paragraph $i', px[i], py[i]);
      }
    }
    same('image', x.image, y.image);
    same('textBox', x.textBox, y.textBox);
    same('appearance', x.appearance, y.appearance);
  }
  return out;
}
