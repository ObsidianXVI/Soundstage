import 'dart:typed_data';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/asset_service.dart';

/// The board's size in board pixels.
const Size kBoardSize = Size(4000, 3000);

/// Note tints the board offers (`#RRGGBB`).
const List<String> kNoteColors = [
  '#FFF3A3',
  '#FFD6A5',
  '#C8F2C2',
  '#BFE3FF',
  '#E6CCFF',
];

/// The draft's inspiration board (DECISIONS 26/10/26 #11): rough paper for
/// quick ideas. Notes, links and images go anywhere; drag to move, the
/// corner to resize, double-click empty paper for a note. Private to the
/// author: never published or exported.
class BoardView extends ConsumerStatefulWidget {
  const BoardView({super.key});

  @override
  ConsumerState<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends ConsumerState<BoardView> {
  final GlobalKey _paper = GlobalKey();
  final TransformationController _view = TransformationController(
    Matrix4.translationValues(-40, -40, 0),
  );
  String _color = kNoteColors.first;
  int _n = 0;

  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  String _newId() =>
      'b${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_n++}';

  /// The board point at the middle of what is in view.
  Offset _centre() {
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? const Size(800, 600);
    return _view.toScene(size.center(Offset.zero));
  }

  /// [topLeft], stepped down and right past items already there, so new
  /// items never hide each other.
  Offset _free(Offset topLeft) {
    final items = ref.read(editorControllerProvider).document.board.items;
    var p = topLeft;
    for (var guard = 0; guard < 50; guard++) {
      final taken = items.any(
        (i) => (i.x - p.dx).abs() < 16 && (i.y - p.dy).abs() < 16,
      );
      if (!taken) break;
      p += const Offset(28, 28);
    }
    return p;
  }

  Offset? _boardPoint(Offset global) {
    final box = _paper.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  void _addNote([Offset? at]) {
    final c = at ?? _centre();
    final p = _free(Offset(c.dx - 110, c.dy - 80));
    _editor.execute(
      AddBoardItem(
        ir.BoardItem(
          id: _newId(),
          kind: ir.BoardItemKind.note,
          x: p.dx,
          y: p.dy,
          color: _color,
        ),
      ),
    );
  }

  void _addLink() {
    final c = _centre();
    final p = _free(Offset(c.dx - 140, c.dy - 40));
    _editor.execute(
      AddBoardItem(
        ir.BoardItem(
          id: _newId(),
          kind: ir.BoardItemKind.link,
          x: p.dx,
          y: p.dy,
          width: 280,
          height: 88,
        ),
      ),
    );
  }

  Future<void> _addImages() async {
    final EditorFilePicker pick;
    final EditorAssetService store;
    try {
      pick = ref.read(editorFilePickerProvider);
      store = ref.read(editorAssetServiceProvider);
    } on Object {
      return; // no file access here (tests, a bare editor)
    }
    final files = await pick(accept: 'image/*', multiple: true);
    var p = _centre();
    for (final f in files) {
      if (!f.mime.startsWith('image/')) continue;
      final asset = await store.add(f.bytes, f.mime, name: f.name);
      final w = (asset.width ?? 300).clamp(80, 360).toDouble();
      final h = asset.width != null && asset.height != null
          ? w * asset.height! / asset.width!
          : 220.0;
      final at = _free(Offset(p.dx - w / 2, p.dy - h / 2));
      _editor.execute(
        AddBoardItem(
          ir.BoardItem(
            id: _newId(),
            kind: ir.BoardItemKind.image,
            x: at.dx,
            y: at.dy,
            width: w,
            height: h,
            uri: asset.uri,
            text: f.name,
          ),
        ),
      );
      p += const Offset(24, 24);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final items = ref.watch(
      editorControllerProvider.select((s) => s.document.board.items),
    );
    return ColoredBox(
      key: const ValueKey<String>('board-view'),
      color: t.colors.surface0,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _view,
              constrained: false,
              minScale: 0.25,
              maxScale: 2,
              boundaryMargin: const EdgeInsets.all(400),
              child: GestureDetector(
                onDoubleTapDown: (d) => _addNote(d.localPosition),
                child: SizedBox.fromSize(
                  key: _paper,
                  size: kBoardSize,
                  child: CustomPaint(
                    painter: _Dots(t.colors.borderSubtle),
                    child: Stack(
                      children: [
                        for (final item in items)
                          _BoardCard(
                            key: ValueKey<String>('board:${item.id}'),
                            item: item,
                            toBoard: _boardPoint,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: SsSpace.s3,
            top: SsSpace.s3,
            child: Container(
              padding: const EdgeInsets.all(SsSpace.s1),
              decoration: BoxDecoration(
                color: t.colors.surface1,
                borderRadius: BorderRadius.circular(SsRadius.md),
                border: Border.all(color: t.colors.borderSubtle),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SsButton(
                    key: const ValueKey<String>('board-add-note'),
                    label: 'Note',
                    icon: SsIcons.stickyNote,
                    variant: SsButtonVariant.ghost,
                    onPressed: _addNote,
                  ),
                  for (final c in kNoteColors)
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Semantics(
                        button: true,
                        selected: c == _color,
                        label: 'Note colour $c',
                        child: Container(
                          width: 16,
                          height: 16,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: _hex(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: c == _color
                                  ? t.colors.textPrimary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: SsSpace.s1),
                  SsButton(
                    key: const ValueKey<String>('board-add-link'),
                    label: 'Link',
                    icon: SsIcons.link,
                    variant: SsButtonVariant.ghost,
                    onPressed: _addLink,
                  ),
                  SsButton(
                    label: 'Image',
                    icon: SsIcons.imagePlus,
                    variant: SsButtonVariant.ghost,
                    onPressed: _addImages,
                  ),
                ],
              ),
            ),
          ),
          if (items.isEmpty)
            Center(
              child: IgnorePointer(
                child: Text(
                  'Rough paper for this draft: notes, links and images.\n'
                  'Double-click anywhere to jot a note. Only you see it.',
                  textAlign: TextAlign.center,
                  style: t.text.body.copyWith(color: t.colors.textSecondary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Color _hex(String hex) {
  try {
    final c = ir.StageColor.fromHex(hex);
    return Color.from(alpha: c.a, red: c.r, green: c.g, blue: c.b);
  } on FormatException {
    return const Color(0xFFFFF3A3);
  }
}

class _Dots extends CustomPainter {
  const _Dots(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var x = 0.0; x < size.width; x += 32) {
      for (var y = 0.0; y < size.height; y += 32) {
        canvas.drawCircle(Offset(x, y), 1, p);
      }
    }
  }

  @override
  bool shouldRepaint(_Dots old) => old.color != color;
}

/// One item on the board.
class _BoardCard extends ConsumerStatefulWidget {
  const _BoardCard({required this.item, required this.toBoard, super.key});

  final ir.BoardItem item;
  final Offset? Function(Offset global) toBoard;

  @override
  ConsumerState<_BoardCard> createState() => _BoardCardState();
}

class _BoardCardState extends ConsumerState<_BoardCard> {
  late final TextEditingController _text = TextEditingController(
    text: _textOf(widget.item),
  );
  final FocusNode _focus = FocusNode(debugLabel: 'board item');
  bool _hover = false;
  Offset? _grab;
  ir.BoardItem? _start;
  Future<Uint8List?>? _image;

  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  static String _textOf(ir.BoardItem i) =>
      i.kind == ir.BoardItemKind.link ? i.uri : i.text;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _editor.beginGesture();
      } else {
        _editor.endGesture();
      }
    });
    _loadImage();
  }

  void _loadImage() {
    final uri = widget.item.uri;
    if (widget.item.kind != ir.BoardItemKind.image ||
        !uri.startsWith('local://')) {
      return;
    }
    try {
      _image = ref
          .read(editorAssetServiceProvider)
          .bytes(uri.substring('local://'.length));
    } on Object {
      _image = null;
    }
  }

  @override
  void didUpdateWidget(_BoardCard old) {
    super.didUpdateWidget(old);
    final now = _textOf(widget.item);
    if (!_focus.hasFocus && now != _text.text) _text.text = now;
    if (old.item.uri != widget.item.uri) _loadImage();
  }

  @override
  void dispose() {
    if (_focus.hasFocus) _editor.endGesture();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _dragStart(Offset global) {
    _grab = widget.toBoard(global);
    _start = widget.item;
    _editor
      ..beginGesture()
      ..execute(BringBoardItemToFront(widget.item.id));
  }

  void _dragEnd() {
    _grab = null;
    _start = null;
    _editor.endGesture();
  }

  void _move(Offset global, {required bool resize}) {
    final grab = _grab, start = _start;
    final now = widget.toBoard(global);
    if (grab == null || start == null || now == null) return;
    final d = now - grab;
    _editor.execute(
      UpdateBoardItem(
        resize
            ? start.copyWith(
                width: (start.width + d.dx).clamp(80, 1200),
                height: (start.height + d.dy).clamp(48, 1200),
              )
            : start.copyWith(
                x: (start.x + d.dx).clamp(0, kBoardSize.width - 40),
                y: (start.y + d.dy).clamp(0, kBoardSize.height - 40),
              ),
      ),
    );
  }

  void _typed(String v) {
    final i = widget.item;
    _editor.execute(
      UpdateBoardItem(
        i.kind == ir.BoardItemKind.link
            ? i.copyWith(uri: v)
            : i.copyWith(text: v),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final i = widget.item;
    final note = i.kind == ir.BoardItemKind.note;
    final paper = note
        ? _hex(i.color.isEmpty ? kNoteColors.first : i.color)
        : t.colors.surface1;
    final ink = note ? const Color(0xFF1A1A1F) : t.colors.textPrimary;
    final body = switch (i.kind) {
      ir.BoardItemKind.image => FutureBuilder<Uint8List?>(
        future: _image,
        builder: (_, snap) => snap.data == null
            ? Center(child: SsIcon(SsIcons.image, color: t.colors.textDisabled))
            : Image.memory(
                snap.data!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
      ),
      ir.BoardItemKind.link => Padding(
        padding: const EdgeInsets.all(SsSpace.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SsIcon(SsIcons.link, size: 14, color: t.colors.accent),
            const SizedBox(width: SsSpace.s1),
            Expanded(
              child: TextField(
                key: ValueKey<String>('board-text:${i.id}'),
                controller: _text,
                focusNode: _focus,
                maxLines: null,
                style: t.text.small.copyWith(color: t.colors.accent),
                decoration: InputDecoration.collapsed(
                  hintText: 'Paste a link',
                  hintStyle: t.text.small.copyWith(
                    color: t.colors.textDisabled,
                  ),
                ),
                onChanged: _typed,
              ),
            ),
          ],
        ),
      ),
      ir.BoardItemKind.note => Padding(
        padding: const EdgeInsets.all(SsSpace.s3),
        child: TextField(
          key: ValueKey<String>('board-text:${i.id}'),
          controller: _text,
          focusNode: _focus,
          maxLines: null,
          expands: true,
          style: t.text.body.copyWith(color: ink),
          decoration: InputDecoration.collapsed(
            hintText: 'An idea…',
            hintStyle: t.text.body.copyWith(color: ink.withValues(alpha: 0.4)),
          ),
          onChanged: _typed,
        ),
      ),
    };
    return Positioned(
      left: i.x,
      top: i.y,
      width: i.width,
      height: i.height,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          // Double-clicks on an item are its own (not a new note).
          onDoubleTap: () {},
          // From the press, not from where the slop was crossed.
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) => _dragStart(d.globalPosition),
          onPanUpdate: (d) => _move(d.globalPosition, resize: false),
          onPanEnd: (_) => _dragEnd(),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: paper,
              borderRadius: BorderRadius.circular(SsRadius.md),
              border: Border.all(color: t.colors.borderSubtle),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              children: [
                Positioned.fill(child: body),
                if (_hover) ...[
                  Positioned(
                    right: 2,
                    top: 2,
                    child: SsIconButton(
                      key: ValueKey<String>('board-remove:${i.id}'),
                      icon: SsIcons.x,
                      semanticLabel: 'Remove from board',
                      size: 24,
                      onPressed: () => _editor.execute(RemoveBoardItem(i.id)),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      // From the press, not from where the slop was crossed.
                      dragStartBehavior: DragStartBehavior.down,
                      onPanStart: (d) => _dragStart(d.globalPosition),
                      onPanUpdate: (d) => _move(d.globalPosition, resize: true),
                      onPanEnd: (_) => _dragEnd(),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeDownRight,
                        child: Container(
                          width: 16,
                          height: 16,
                          alignment: Alignment.bottomRight,
                          child: SsIcon(
                            SsIcons.gripHorizontal,
                            size: 12,
                            color: ink.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
