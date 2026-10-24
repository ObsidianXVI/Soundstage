import 'dart:ui' show Offset;

import 'asset_service.dart';

/// Listens for files dragged from the desktop over the page. Returns a
/// function that stops listening. (No browser: nothing to listen to.)
void Function() listenForFileDrops({
  required void Function(Offset position) onHover,
  required void Function() onLeave,
  required void Function(List<EditorFile> files, Offset position) onDrop,
}) => () {};
