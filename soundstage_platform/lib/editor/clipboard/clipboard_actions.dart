import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart'
    show SsToastKind;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/asset_service.dart';
import '../insert/editor_notices.dart';
import '../insert/insert_actions.dart';
import 'clipboard_envelope.dart';
import 'content_hash.dart';
import 'system_clipboard.dart';

/// Copy, cut and paste (T1.9; DECISIONS 23/10/26 "Copy/paste").
///
/// **Copy** writes the selected nodes, with the assets, font families and
/// named styles they use, to the system clipboard as text: a versioned
/// JSON envelope `{"soundstage-clipboard": 1, ...}` (see
/// [ClipboardEnvelope]). Asset bytes travel inside it as base64 up to
/// [kClipboardInlineAssetBytes]; larger files are referenced by id and
/// paste only in the same browser profile.
///
/// **Paste** takes, in order:
/// 1. a Soundstage envelope: assets and fonts are deduplicated by content
///    hash (fonts also by family name), styles by definition, everything
///    gets new ids, and the nodes go into the selected frame (else the
///    selection's frame, else the scene root). Pasting back into the frame
///    the nodes were copied from offsets them +10/+10 (and +20/+20 the next
///    time, ...), as Figma does;
/// 2. an image on the clipboard (async Clipboard API where the browser has
///    it): an image frame, like the Image tool;
/// 3. plain text: a text node, one paragraph per line.
///
/// **Paste to replace** (Shift+Cmd+V) puts an envelope where the selection
/// is, centred on it, and removes the selection, in one step. It only
/// handles envelopes.
///
/// **Cut** is copy then delete, one undo step.
///
/// The browser may refuse to read the clipboard (permission, or no user
/// gesture): that shows a message and changes nothing.
class ClipboardActions {
  ClipboardActions(this._ref);

  final Ref _ref;

  EditorController get _ctl => _ref.read(editorControllerProvider.notifier);
  EditorState get _state => _ref.read(editorControllerProvider);
  EditorAssetService get _service => _ref.read(editorAssetServiceProvider);
  SystemClipboard get _clip => _ref.read(systemClipboardProvider);
  InsertActions get _insert => _ref.read(insertActionsProvider);

  void _say(String m, [SsToastKind k = SsToastKind.warning]) =>
      _ref.read(editorNoticesProvider).say(m, kind: k);

  final Map<String, String> _hashes = {};
  String? _pasteKey;
  int _pasteCount = 0;

  /// The nodes the last paste made (a repeated paste goes beside them, not
  /// into them).
  Set<String> _lastPasted = const {};

  // ---- Copy and cut ------------------------------------------------------------

  /// Copies the selection. Returns false when nothing was copied.
  Future<bool> copy() async {
    final doc = _state.document;
    final picked = copyableNodes(doc, _state.selection);
    if (picked.nodes.isEmpty) return false;
    final nodes = [for (final n in picked.nodes) n.toJson()];

    // References, closed over fonts and styles (which refer to assets and
    // fonts themselves).
    var refs = collectRefs(nodes);
    final fonts = <String, Map<String, dynamic>>{};
    final text = <String, Map<String, dynamic>>{};
    final paint = <String, Map<String, dynamic>>{};
    final effect = <String, Map<String, dynamic>>{};
    for (var pass = 0; pass < 3; pass++) {
      for (final id in refs[RefKind.font]!) {
        final f = doc.fonts[id];
        if (f != null) fonts[id] = f.toJson();
      }
      for (final id in refs[RefKind.textStyle]!) {
        final s = doc.tokens.textStyles[id];
        if (s != null) text[id] = s.toJson();
      }
      for (final id in refs[RefKind.paintStyle]!) {
        final s = doc.tokens.paintStyles[id];
        if (s != null) paint[id] = s.toJson();
      }
      for (final id in refs[RefKind.effectStyle]!) {
        final s = doc.tokens.effectStyles[id];
        if (s != null) effect[id] = s.toJson();
      }
      refs = collectRefs([
        ...nodes,
        ...fonts.values,
        ...text.values,
        ...paint.values,
        ...effect.values,
      ]);
    }

    // Assets: smallest first, so as many as possible travel inline.
    final wanted = [
      for (final id in refs[RefKind.asset]!)
        if (doc.assets[id] != null) doc.assets[id]!,
    ]..sort((a, b) => a.byteSize.compareTo(b.byteSize));
    final assets = <String, ClipAsset>{};
    var inline = 0;
    for (final a in wanted) {
      final bytes = await _service.bytes(a.id);
      if (bytes == null) {
        assets[a.id] = ClipAsset(a, '', null);
        continue;
      }
      final hash = contentHash(bytes);
      final fits = inline + bytes.length <= kClipboardInlineAssetBytes;
      if (fits) inline += bytes.length;
      assets[a.id] = ClipAsset(a, hash, fits ? bytes : null);
    }

    final env = ClipboardEnvelope(
      docId: doc.id,
      parentId: picked.parentId,
      nodes: nodes,
      assets: assets,
      fonts: fonts,
      textStyles: text,
      paintStyles: paint,
      effectStyles: effect,
    );
    try {
      await _clip.writeText(env.encode());
    } on ClipboardDenied {
      _say('The browser would not let the editor write to the clipboard.');
      return false;
    }
    _pasteKey = null;
    _pasteCount = 0;
    return true;
  }

  /// Copy, then delete the copied nodes (one undo step).
  Future<void> cut() async {
    final ids = _state.selection.toList();
    if (!await copy()) return;
    _ctl.execute(DeleteNodes(ids));
  }

  // ---- Paste -----------------------------------------------------------------------

  Future<void> paste({bool replace = false}) async {
    String? text;
    try {
      text = await _clip.readText();
    } on ClipboardDenied {
      _say(
        'The browser blocked reading the clipboard. Allow clipboard access '
        'for this site, then paste again.',
      );
      return;
    }
    final env = text == null ? null : ClipboardEnvelope.tryDecode(text);
    if (env != null) {
      await _pasteEnvelope(env, text!, replace: replace);
      return;
    }
    if (replace) {
      _say('Paste to replace works with nodes copied from the editor.');
      return;
    }
    EditorFile? image;
    try {
      image = await _clip.readImage();
    } on ClipboardDenied {
      image = null; // text may still be pasteable
    }
    if (image != null) {
      await _insert.insertFiles([image]);
      return;
    }
    if (text != null && text.trim().isNotEmpty) {
      _pasteText(text);
      return;
    }
    _say('There is nothing to paste.', SsToastKind.info);
  }

  void _pasteText(String text) {
    final doc = _state.document;
    final parent = _insert.defaultParent();
    if (parent == null) return;
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    while (lines.length > 1 && lines.last.isEmpty) {
      lines.removeLast();
    }
    final wide = lines.any((l) => l.length > 60);
    final n = _nextOffset('text:$parent', same: true);
    final id = ir.IdGenerator.forDocument(doc).next();
    final first = lines.first.trim();
    final node = ir.TextNode(
      common: ir.NodeCommon(
        id: id,
        name: first.isEmpty
            ? 'Text'
            : (first.length > 24 ? '${first.substring(0, 24)}…' : first),
        x: 40.0 + 10 * n,
        y: 40.0 + 10 * n,
        width: wide ? 320 : 0,
        role: ir.NodeRole.paragraph,
      ),
      content: [
        for (final l in lines) ir.Paragraph(spans: [ir.Span(text: l)]),
      ],
      autoResize: wide
          ? ir.TextAutoResize.height
          : ir.TextAutoResize.widthAndHeight,
    );
    final r = _ctl.execute(InsertNodes(parent, [node]));
    if (!r.ok) _say(r.diagnostics.map((d) => d.message).join('\n'));
  }

  int _nextOffset(String key, {required bool same}) {
    if (!same) {
      _pasteKey = null;
      _pasteCount = 0;
      return 0;
    }
    if (_pasteKey == key) {
      return ++_pasteCount;
    }
    _pasteKey = key;
    _pasteCount = 0;
    return 0;
  }

  Future<void> _pasteEnvelope(
    ClipboardEnvelope env,
    String text, {
    required bool replace,
  }) async {
    var doc = _state.document;
    final index = ir.DocumentIndex.of(doc);
    final sel = [
      for (final id in _state.selection)
        if (!id.contains('/') && index.node(id) != null) id,
    ];
    // Where it goes.
    String? parent;
    int? at;
    var replaceIds = <String>[];
    if (replace && sel.isNotEmpty) {
      final top = copyableNodes(doc, sel);
      if (top.nodes.isEmpty) return;
      replaceIds = [for (final n in top.nodes) n.id];
      final loc = index.locate(replaceIds.first)!;
      parent = loc.parentId;
      at = loc.index;
    } else {
      parent = _insert.defaultParent();
      // The frame that was copied is not a place to paste a copy of itself:
      // go beside it.
      final p = parent;
      if (p != null &&
          (_lastPasted.contains(p) ||
              (env.docId == doc.id &&
                  env.nodes.any((n) => (n['common'] as Map)['id'] == p)))) {
        parent = index.locate(p)?.parentId ?? p;
      }
    }
    if (parent == null) return;

    // Assets, fonts and styles, resolved against this story.
    final gen = ir.IdGenerator.forDocument(doc);
    final sameDoc = env.docId == doc.id;
    final addAssets = <String, ir.Asset>{};
    final assetMap = <String, String>{};
    var missing = 0;
    for (final e in env.assets.entries) {
      final r = await _resolveAsset(e.key, e.value, doc, sameDoc, addAssets);
      if (r == null) {
        missing++;
        assetMap[e.key] = e.key;
      } else {
        assetMap[e.key] = r;
      }
    }
    doc = _state.document; // the store awaits may have let it move on
    String mapAsset(String id) => assetMap[id] ?? id;

    final fontMap = <String, String>{};
    final addFonts = <String, ir.FontFamily>{};
    for (final e in env.fonts.entries) {
      final fam = ir.FontFamily.fromJson(
        rewriteRefs(e.value, (k, id) => k == RefKind.asset ? mapAsset(id) : id)!
            as Map<String, dynamic>,
      );
      if (sameDoc && doc.fonts.containsKey(e.key)) {
        fontMap[e.key] = e.key;
        continue;
      }
      final existing = fontFamilyNamed(doc, fam.name);
      if (existing != null) {
        fontMap[e.key] = existing.id;
        final base = addFonts[existing.id] ?? existing;
        final faces = [...base.faces];
        for (final f in fam.faces) {
          final clash = faces.any(
            (x) =>
                x.italic == f.italic &&
                x.variable == f.variable &&
                (f.variable || x.weight == f.weight),
          );
          if (!clash) faces.add(f);
        }
        if (faces.length != base.faces.length) {
          addFonts[existing.id] = base.copyWith(faces: faces);
        }
      } else {
        final id = gen.next();
        fontMap[e.key] = id;
        addFonts[id] = fam.copyWith(id: id);
      }
    }

    String refMap(RefKind k, String id) => switch (k) {
      RefKind.asset => mapAsset(id),
      RefKind.font => fontMap[id] ?? id,
      _ => id,
    };

    Map<String, T> styles<T>(
      Map<String, Map<String, dynamic>> src,
      Map<String, T> existing,
      T Function(Map<String, dynamic>) parse,
      Map<String, String> idMap,
    ) {
      final add = <String, T>{};
      for (final e in src.entries) {
        final def = parse(
          rewriteRefs(e.value, refMap)! as Map<String, dynamic>,
        );
        if (sameDoc && existing.containsKey(e.key)) {
          idMap[e.key] = e.key;
          continue;
        }
        String? same;
        for (final x in {...existing, ...add}.entries) {
          if (x.value == def) same = x.key;
        }
        if (same != null) {
          idMap[e.key] = same;
        } else {
          final id = gen.next();
          idMap[e.key] = id;
          add[id] = def;
        }
      }
      return add;
    }

    final textMap = <String, String>{}, paintMap = <String, String>{};
    final effectMap = <String, String>{};
    final addText = styles(
      env.textStyles,
      doc.tokens.textStyles,
      ir.TextStyleDef.fromJson,
      textMap,
    );
    final addPaint = styles(
      env.paintStyles,
      doc.tokens.paintStyles,
      ir.PaintStyleDef.fromJson,
      paintMap,
    );
    final addEffect = styles(
      env.effectStyles,
      doc.tokens.effectStyles,
      ir.EffectStyleDef.fromJson,
      effectMap,
    );

    final nodes = [
      for (final n in env.nodes)
        rewriteRefs(
              n,
              (k, id) => switch (k) {
                RefKind.asset => mapAsset(id),
                RefKind.font => fontMap[id] ?? id,
                RefKind.textStyle => textMap[id] ?? id,
                RefKind.paintStyle => paintMap[id] ?? id,
                RefKind.effectStyle => effectMap[id] ?? id,
              },
            )!
            as Map<String, dynamic>,
    ];

    // Placement.
    var dx = 0.0, dy = 0.0;
    if (replaceIds.isNotEmpty) {
      final from = _union([
        for (final id in replaceIds) index.node(id)!.common,
      ]);
      final to = _union([for (final n in nodes) ir.Node.fromJson(n).common]);
      if (from != null && to != null) {
        dx = (from.center.dx - to.center.dx).roundToDouble();
        dy = (from.center.dy - to.center.dy).roundToDouble();
      }
      _nextOffset('', same: false);
    } else {
      final inPlace = sameDoc && env.parentId == parent;
      final n = _nextOffset('env:${text.hashCode}:$parent', same: inPlace);
      if (inPlace) {
        dx = dy = 10.0 * (n + 1);
      }
    }

    final r = _ctl.execute(
      PasteNodes(
        PastePayload(
          nodes: nodes,
          sourceDocId: env.docId,
          assets: addAssets,
          fonts: addFonts,
          textStyles: addText,
          paintStyles: addPaint,
          effectStyles: addEffect,
        ),
        parent,
        index: at,
        dx: dx,
        dy: dy,
        replaceIds: replaceIds,
      ),
    );
    if (!r.ok) {
      _say(r.diagnostics.map((d) => d.message).join('\n'));
      return;
    }
    _lastPasted = r.selectionAfter ?? const {};
    if (missing > 0) {
      _say(
        '$missing ${missing == 1 ? 'file' : 'files'} could not be pasted: '
        'too large to travel in the clipboard, and not stored in this '
        'browser.',
      );
    }
  }

  static _Box? _union(Iterable<ir.NodeCommon> cs) {
    _Box? u;
    for (final c in cs) {
      final b = _Box(c.x, c.y, c.x + c.width, c.y + c.height);
      u = u == null ? b : u.join(b);
    }
    return u;
  }

  /// The id in this story that asset [id] of the envelope becomes, or null
  /// when it cannot be had. New files are stored; [add] collects the table
  /// entries to add.
  Future<String?> _resolveAsset(
    String id,
    ClipAsset ca,
    ir.StageDocument doc,
    bool sameDoc,
    Map<String, ir.Asset> add,
  ) async {
    ir.Asset withMeta(ir.Asset stored) =>
        stored.copyWith(alt: ca.asset.alt, credit: ca.asset.credit);
    if (sameDoc && doc.assets.containsKey(id)) return id;
    final data = ca.data;
    if (data != null) {
      final hash = contentHash(data);
      for (final a in doc.assets.values) {
        if (a.kind != ca.asset.kind || a.byteSize != data.length) continue;
        if (await _hashOf(a) == hash) return a.id;
      }
      for (final a in add.values) {
        if (a.byteSize == data.length &&
            a.kind == ca.asset.kind &&
            await _hashOf(a) == hash) {
          return a.id;
        }
      }
      try {
        final stored = await _service.add(
          data,
          ca.asset.mime,
          name: ca.asset.name,
        );
        add[stored.id] = withMeta(stored);
        return stored.id;
      } on AssetServiceException catch (e) {
        _say('${ca.asset.name}: ${e.message}');
        return null;
      }
    }
    // By reference: only the same browser profile has the file.
    if (doc.assets.containsKey(id)) return id;
    final stored = await _service.stored(id);
    if (stored == null) return null;
    add[id] = withMeta(stored);
    return id;
  }

  Future<String> _hashOf(ir.Asset a) async {
    final key = '${a.id}:${a.byteSize}:${a.width}:${a.height}';
    final cached = _hashes[key];
    if (cached != null) return cached;
    final Uint8List? bytes = await _service.bytes(a.id);
    return _hashes[key] = bytes == null ? '' : contentHash(bytes);
  }
}

class _Box {
  const _Box(this.left, this.top, this.right, this.bottom);

  final double left, top, right, bottom;

  _Box join(_Box o) => _Box(
    left < o.left ? left : o.left,
    top < o.top ? top : o.top,
    right > o.right ? right : o.right,
    bottom > o.bottom ? bottom : o.bottom,
  );

  ({double dx, double dy}) get center =>
      (dx: (left + right) / 2, dy: (top + bottom) / 2);
}

final clipboardActionsProvider = Provider<ClipboardActions>(
  ClipboardActions.new,
  dependencies: [editorControllerProvider, insertActionsProvider],
);
