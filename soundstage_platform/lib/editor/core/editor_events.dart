import 'dart:async';

/// A request to edit text node [nodeId] in place on the artboard of
/// [breakpointId] (double-click or Enter on a text node). T1.8 listens.
typedef TextEditRequest = ({String nodeId, String? breakpointId});

/// One-shot UI events of an editor that are not state: the panels and the
/// canvas listen to them (`EditorController.events`).
///
/// - [renameRequests]: Cmd+R (or F2) asked to rename a layer; the Layers
///   panel opens its inline rename field for the id.
/// - [textEditRequests]: the canvas asked to edit a text node in place
///   (`onEditTextRequested`).
///
/// Broadcast streams: events fired with no listener are dropped.
class EditorEvents {
  final StreamController<String> _rename = StreamController.broadcast(
    sync: true,
  );
  final StreamController<TextEditRequest> _textEdit =
      StreamController.broadcast(sync: true);

  Stream<String> get renameRequests => _rename.stream;

  Stream<TextEditRequest> get textEditRequests => _textEdit.stream;

  void requestRename(String nodeId) => _rename.add(nodeId);

  void requestTextEdit(String nodeId, String? breakpointId) =>
      _textEdit.add((nodeId: nodeId, breakpointId: breakpointId));
}
