import 'package:freezed_annotation/freezed_annotation.dart';

part 'board.freezed.dart';
part 'board.g.dart';

// A draft's inspiration board (DECISIONS 26/10/26 #11): rough paper for
// quick ideating and note-taking. It belongs to the author: never
// published or exported. Images on it keep their own `local://` file
// reference (not the document's asset table), so they are stored with the
// draft but never uploaded.

@JsonEnum()
enum BoardItemKind { note, image, link }

/// One thing pinned to the board. `x`, `y`, `width`, `height` are in board
/// pixels. `text`: a note's words, or a link's title. `uri`: an image's
/// file (`local://<id>`) or a link's URL. `color`: a note's tint
/// (`#RRGGBB`).
@freezed
abstract class BoardItem with _$BoardItem {
  const factory BoardItem({
    required String id,
    required BoardItemKind kind,
    @Default(0) double x,
    @Default(0) double y,
    @Default(220) double width,
    @Default(160) double height,
    @Default('') String text,
    @Default('') String uri,
    @Default('') String color,
  }) = _BoardItem;

  factory BoardItem.fromJson(Map<String, dynamic> json) =>
      _$BoardItemFromJson(json);
}

/// The board: its items, back to front.
@freezed
abstract class InspirationBoard with _$InspirationBoard {
  const factory InspirationBoard({
    @Default(<BoardItem>[]) List<BoardItem> items,
  }) = _InspirationBoard;

  factory InspirationBoard.fromJson(Map<String, dynamic> json) =>
      _$InspirationBoardFromJson(json);
}
