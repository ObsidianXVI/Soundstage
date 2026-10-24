import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' show Offset;

import 'package:web/web.dart' as web;

import 'asset_service.dart';

bool _hasFiles(web.DragEvent e) {
  final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
  return types.any((t) => t.toDart == 'Files');
}

/// Listens for files dragged from the desktop over the page (`dragover`,
/// `dragleave`, `drop` on the window). Positions are in CSS pixels from the
/// page's top-left, which are Flutter's logical global coordinates.
/// Returns a function that stops listening.
void Function() listenForFileDrops({
  required void Function(Offset position) onHover,
  required void Function() onLeave,
  required void Function(List<EditorFile> files, Offset position) onDrop,
}) {
  final over = ((web.Event ev) {
    final e = ev as web.DragEvent;
    if (!_hasFiles(e)) return;
    e.preventDefault(); // otherwise the browser opens the file
    e.dataTransfer?.dropEffect = 'copy';
    onHover(Offset(e.clientX.toDouble(), e.clientY.toDouble()));
  }).toJS;
  final leave = ((web.Event ev) {
    final e = ev as web.DragEvent;
    if (e.relatedTarget == null) onLeave();
  }).toJS;
  final drop = ((web.Event ev) {
    final e = ev as web.DragEvent;
    if (!_hasFiles(e)) return;
    e.preventDefault();
    final at = Offset(e.clientX.toDouble(), e.clientY.toDouble());
    final list = e.dataTransfer?.files;
    onLeave();
    if (list == null) return;
    unawaited(() async {
      final out = <EditorFile>[];
      for (var i = 0; i < list.length; i++) {
        final f = list.item(i)!;
        final buffer = await f.arrayBuffer().toDart;
        out.add((
          name: f.name,
          bytes: buffer.toDart.asUint8List(),
          mime: f.type,
        ));
      }
      if (out.isNotEmpty) onDrop(out, at);
    }());
  }).toJS;
  web.window.addEventListener('dragover', over);
  web.window.addEventListener('dragleave', leave);
  web.window.addEventListener('drop', drop);
  return () {
    web.window.removeEventListener('dragover', over);
    web.window.removeEventListener('dragleave', leave);
    web.window.removeEventListener('drop', drop);
  };
}
