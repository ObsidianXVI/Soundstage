import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';

import 'text_edit_session.dart';
import 'text_style_target.dart';

/// The focus node of in-place text editing. The editor's shortcut layer and
/// the canvas treat it like a text field (bare keys type, Space does not
/// pan).
class StageTextFocusNode extends FocusNode {
  StageTextFocusNode() : super(debugLabel: 'Stage text editing');
}

/// Whether the primary focus is in-place text editing.
bool primaryFocusIsStageText() =>
    FocusManager.instance.primaryFocus is StageTextFocusNode;

/// The in-place text editing of one editor (T1.8): the active
/// [TextEditSession] (owned by the canvas's text layer) and the text
/// selection the inspector edits.
///
/// [target] is null outside edit mode; in edit mode it is the session's
/// selection (plus its pending typing style), and the inspector's text
/// section edits those spans instead of the node-level style.
class TextEditController extends ChangeNotifier {
  TextEditSession? _session;

  /// The active session, if any.
  TextEditSession? get session => _session;

  /// The text selection style edits apply to, while editing.
  final ValueNotifier<TextRangeTarget?> target = ValueNotifier(null);

  /// Makes [s] the active session (null: none).
  void setSession(TextEditSession? s) {
    if (identical(s, _session)) return;
    _session?.removeListener(_sync);
    _session = s;
    s?.addListener(_sync);
    _sync();
    notifyListeners();
  }

  void _sync() => target.value = _session?.target;

  @override
  void dispose() {
    _session?.removeListener(_sync);
    target.dispose();
    super.dispose();
  }
}

/// The text editing of the open editor (one per `ProviderScope`, like the
/// canvas controller).
final textEditProvider = Provider<TextEditController>((ref) {
  ref.watch(initialDocumentProvider);
  final c = TextEditController();
  ref.onDispose(c.dispose);
  return c;
}, dependencies: [initialDocumentProvider]);
