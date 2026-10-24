import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'asset_service.dart';
import 'file_drop_platform.dart' as platform;

/// Receives files dropped on a [FileDropTarget] at global [position].
typedef FileDropHandler =
    FutureOr<void> Function(List<EditorFile> files, Offset position);

/// Routes files dragged from the desktop to the topmost [FileDropTarget]
/// under the pointer (the last one registered that contains it).
///
/// The browser reports drags at the page level; this hub turns them into
/// per-region drops and a hover position the regions highlight with.
class FileDropHub {
  FileDropHub();

  final List<_Region> _regions = [];

  /// Where a desktop drag currently is (global), or null.
  final ValueNotifier<Offset?> hover = ValueNotifier(null);

  void Function()? _stop;

  /// Starts listening to the page (idempotent).
  void attach() {
    _stop ??= platform.listenForFileDrops(
      onHover: (p) => hover.value = p,
      onLeave: () => hover.value = null,
      onDrop: (files, p) {
        dispatch(files, p);
      },
    );
  }

  void detach() {
    _stop?.call();
    _stop = null;
  }

  void _add(_Region r) => _regions.add(r);

  void _remove(_Region r) => _regions.remove(r);

  /// The region that would take a drop at [global], or null.
  Object? regionAt(Offset global) {
    for (final r in _regions.reversed) {
      if (r.contains(global)) return r.owner;
    }
    return null;
  }

  /// Hands [files] to the topmost region containing [global]. Returns
  /// whether any region took them.
  bool dispatch(List<EditorFile> files, Offset global) {
    hover.value = null;
    for (final r in _regions.reversed) {
      if (r.contains(global)) {
        unawaited(Future.sync(() => r.onDrop(files, global)));
        return true;
      }
    }
    return false;
  }
}

class _Region {
  _Region(this.owner, this.contains, this.onDrop);

  final Object owner;
  final bool Function(Offset global) contains;
  final FileDropHandler onDrop;
}

/// The editor's file-drop hub.
final fileDropHubProvider = Provider<FileDropHub>((ref) {
  final hub = FileDropHub()..attach();
  ref.onDispose(() {
    hub.detach();
    hub.hover.dispose();
  });
  return hub;
});

/// A region that accepts files dragged from the desktop. While a drag is
/// over it (and no region above it), it shows an accent outline and a
/// caption.
class FileDropTarget extends ConsumerStatefulWidget {
  const FileDropTarget({
    required this.onDrop,
    required this.child,
    this.caption = 'Drop files to add them',
    super.key,
  });

  final FileDropHandler onDrop;
  final Widget child;
  final String caption;

  @override
  ConsumerState<FileDropTarget> createState() => _FileDropTargetState();
}

class _FileDropTargetState extends ConsumerState<FileDropTarget> {
  late final FileDropHub _hub = ref.read(fileDropHubProvider);
  late final _Region _region = _Region(
    this,
    _contains,
    (files, p) => widget.onDrop(files, p),
  );

  bool _contains(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(global);
  }

  @override
  void initState() {
    super.initState();
    _hub._add(_region);
  }

  @override
  void dispose() {
    _hub._remove(_region);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<Offset?>(
              valueListenable: _hub.hover,
              builder: (_, at, _) {
                if (at == null || _hub.regionAt(at) != this) {
                  return const SizedBox.shrink();
                }
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.colors.accent.withValues(alpha: 0.08),
                    border: Border.all(color: t.colors.accent, width: 2),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SsSpace.s3,
                        vertical: SsSpace.s1,
                      ),
                      decoration: BoxDecoration(
                        color: t.colors.surface2,
                        borderRadius: BorderRadius.circular(SsSpace.s1),
                      ),
                      child: Text(widget.caption, style: t.text.small),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
