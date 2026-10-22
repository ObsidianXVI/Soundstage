/// The Stage IR: the story document model shared by the runtime and the editor.
///
/// Pure Dart. Nothing under `lib/ir/` may import `package:flutter` — see
/// `docs/architecture.md` and hard rule 2 in `AGENTS.md`.
///
/// Several type names (`Paint`, `TextStyle`, `BlendMode`, `Constraints`,
/// `Action`, …) follow the architecture spec and collide with Flutter's;
/// Flutter-side code should import this library with a prefix
/// (`import 'package:soundstage_platform/ir/ir.dart' as ir;`).
library;

// Thrown by every `fromJson` on malformed input (e.g. an unknown union `type`).
export 'package:json_annotation/json_annotation.dart'
    show CheckedFromJsonException;

export 'src/animation/easing.dart';
export 'src/animation/interpolate.dart';
export 'src/animation/track_eval.dart';
export 'src/assets.dart';
export 'src/audio.dart';
export 'src/behaviors.dart';
export 'src/breakpoint.dart';
export 'src/components.dart';
export 'src/diagnostics.dart';
export 'src/document.dart';
export 'src/interactions.dart';
export 'src/migrations/migrate.dart';
export 'src/motion.dart';
export 'src/nodes/appearance.dart';
export 'src/nodes/blend_mode.dart';
export 'src/nodes/effect.dart';
export 'src/nodes/layout.dart';
export 'src/nodes/node.dart';
export 'src/nodes/node_common.dart';
export 'src/nodes/paint.dart';
export 'src/nodes/stroke.dart';
export 'src/nodes/text.dart';
export 'src/registry/patch.dart';
export 'src/registry/property_descriptor.dart';
export 'src/registry/property_registry.dart';
export 'src/resolve/breakpoints.dart';
export 'src/resolve/resolved_tree.dart';
export 'src/resolve/resolver.dart';
export 'src/scene.dart';
export 'src/tokens.dart';
export 'src/validate/load.dart';
export 'src/validate/validate.dart';
export 'src/values/geometry.dart';
export 'src/values/ids.dart';
export 'src/values/ir_value.dart';
export 'src/values/property_path.dart';
export 'src/values/stage_color.dart';
