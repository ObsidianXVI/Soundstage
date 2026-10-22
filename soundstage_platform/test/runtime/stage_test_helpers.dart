import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// Common fields for a test node.
ir.NodeCommon common(
  String id, {
  double x = 0,
  double y = 0,
  double w = 0,
  double h = 0,
  double rotation = 0,
  bool visible = true,
  ir.LayoutChild layoutChild = const ir.LayoutChild(),
}) => ir.NodeCommon(
  id: id,
  x: x,
  y: y,
  width: w,
  height: h,
  rotation: rotation,
  visible: visible,
  layoutChild: layoutChild,
);

/// The one place tests build text nodes. The node-level `style` changes type
/// in T0.3b (`TextStyleOverride`); only this helper changes then.
ir.TextNode textNode(
  String id, {
  String text = '',
  List<ir.Paragraph>? content,
  double fontSize = 10,
  ir.LineHeight lineHeight = const ir.LineHeight.auto(),
  double paragraphSpacing = 0,
  ir.TextAutoResize autoResize = ir.TextAutoResize.widthAndHeight,
  int? maxLines,
  ir.TextTruncation truncation = ir.TextTruncation.none,
  ir.TextAlignVertical alignVertical = ir.TextAlignVertical.top,
  ir.NodeCommon? nodeCommon,
}) => ir.TextNode(
  common: nodeCommon ?? common(id),
  content:
      content ??
      [
        ir.Paragraph(spans: [ir.Span(text: text)]),
      ],
  style: ir.TextStyle(
    fontSize: fontSize,
    lineHeight: lineHeight,
    paragraphSpacing: paragraphSpacing,
  ),
  autoResize: autoResize,
  maxLines: maxLines,
  truncation: truncation,
  alignVertical: alignVertical,
);

/// A solid-filled rectangle.
ir.ShapeNode rect(String id, ir.NodeCommon c) => ir.ShapeNode(
  common: c,
  appearance: const ir.Appearance(
    fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.black)],
  ),
);

/// A frame.
ir.FrameNode frame(
  String id,
  ir.NodeCommon c, {
  List<ir.Node> children = const [],
  ir.AutoLayout? autoLayout,
  bool clip = false,
}) => ir.FrameNode(
  common: c.id == id ? c : c.copyWith(id: id),
  children: children,
  autoLayout: autoLayout,
  clipContent: clip,
);

const ir.Breakpoint kDesktop = ir.Breakpoint(
  id: 'desktop',
  name: 'Desktop',
  minWidth: 1024,
  designSize: ir.StageSize(width: 1440, height: 900),
);
const ir.Breakpoint kMobile = ir.Breakpoint(
  id: 'mobile',
  name: 'Mobile',
  minWidth: 0,
  designSize: ir.StageSize(width: 390, height: 844),
);

/// A document with one scene whose root is [root].
ir.StageDocument docWithRoot(
  ir.FrameNode root, {
  ir.SceneKind kind = ir.SceneKind.pinned,
  List<ir.Breakpoint> breakpoints = const [kDesktop, kMobile],
}) => ir.StageDocument(
  id: 'doc',
  breakpoints: breakpoints,
  baseBreakpointId: breakpoints.first.id,
  scenes: [ir.Scene(id: 's', root: root, kind: kind)],
);

/// Sets the test view to [size] logical pixels at DPR 1.
void setViewport(WidgetTester tester, Size size) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
}

/// Resolves [doc] at [viewport] width and pumps its first scene.
Future<ir.ResolvedDocument> pumpScene(
  WidgetTester tester,
  ir.StageDocument doc, {
  required Size viewport,
  StageRenderMode mode = StageRenderMode.play,
}) async {
  setViewport(tester, viewport);
  final resolved = ir.resolveDocument(
    doc,
    ir.ResolveContext(viewportWidth: viewport.width),
  );
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: StageScope(
        environment: StageEnvironment.forDocument(doc, mode: mode),
        child: Align(
          alignment: Alignment.topLeft,
          child: StageSceneView(
            scene: resolved.scenes.first,
            viewportSize: viewport,
            breakpoint: resolved.breakpoint,
          ),
        ),
      ),
    ),
  );
  return resolved;
}

/// The stage render object for node [id].
RenderStageBox stageBox(WidgetTester tester, String id) {
  RenderStageBox? found;
  void visit(RenderObject o) {
    if (found != null) return;
    if (o is RenderStageBox && o.nodeId == id) {
      found = o;
      return;
    }
    o.visitChildren(visit);
  }

  tester.binding.renderViews.forEach(visit);
  if (found == null) throw StateError('No render object for "$id"');
  return found!;
}

/// The node's box in global coordinates (exact for unrotated nodes; the
/// bounding box of the transformed box otherwise).
Rect globalRect(WidgetTester tester, String id) {
  final b = stageBox(tester, id);
  return MatrixUtils.transformRect(
    b.getTransformTo(null),
    Offset.zero & b.size,
  );
}
