/// StagePlayer: renders a Stage IR document. See `docs/architecture.md` §14
/// and `lib/runtime/README.md`.
///
/// Import the IR with a prefix next to this library
/// (`import 'package:soundstage_platform/ir/ir.dart' as ir;`): several IR
/// names collide with Flutter's.
library;

export 'src/media/asset_resolver.dart';
export 'src/media/fonts.dart';
export 'src/media/image_cache.dart';
export 'src/paint/appearance_painter.dart';
export 'src/paint/image_scale.dart';
export 'src/paint/stage_color.dart';
export 'src/render/layout/auto_layout.dart';
export 'src/render/layout/constraints.dart';
export 'src/render/render_stage_box.dart';
export 'src/render/render_stage_frame.dart';
export 'src/render/render_stage_scene.dart';
export 'src/render/render_stage_shape.dart';
export 'src/render/render_stage_text.dart';
export 'src/render/shape_geometry.dart';
export 'src/render/stage_environment.dart';
export 'src/render/text/stage_text_layout.dart';
export 'src/render/text/text_style_mapping.dart';
export 'src/widgets/stage_node_widget.dart';
export 'src/widgets/stage_scene_view.dart';
