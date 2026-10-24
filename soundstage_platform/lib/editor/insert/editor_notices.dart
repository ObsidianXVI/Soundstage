import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// Short messages from editor actions that have no widget of their own to
/// show them (a failed upload, a denied clipboard read). The editor shell
/// installs a [EditorNoticeHost], which shows them as toasts; without one
/// they are dropped (tests read [log]).
class EditorNotices {
  /// Shows [message]; set by [EditorNoticeHost].
  void Function(String message, SsToastKind kind)? sink;

  /// Every message said, newest last (tests).
  final List<String> log = [];

  void say(String message, {SsToastKind kind = SsToastKind.warning}) {
    log.add(message);
    sink?.call(message, kind);
  }
}

final editorNoticesProvider = Provider<EditorNotices>((ref) => EditorNotices());

/// Routes [editorNoticesProvider] messages to [SsToast]s above [child].
class EditorNoticeHost extends ConsumerStatefulWidget {
  const EditorNoticeHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<EditorNoticeHost> createState() => _EditorNoticeHostState();
}

class _EditorNoticeHostState extends ConsumerState<EditorNoticeHost> {
  EditorNotices? _notices;

  @override
  void initState() {
    super.initState();
    _notices = ref.read(editorNoticesProvider);
    _notices!.sink = (message, kind) {
      if (mounted) SsToast.show(context, message, kind: kind);
    };
  }

  @override
  void dispose() {
    _notices?.sink = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
