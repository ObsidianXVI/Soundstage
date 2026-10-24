import 'dart:convert';
import 'dart:typed_data';

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// The marker key every Soundstage clipboard text starts with.
const String kClipboardMarker = 'soundstage-clipboard';

/// The envelope version this build reads and writes.
const int kClipboardVersion = 1;

/// Asset bytes are embedded (base64) in the clipboard text until their
/// total reaches this many raw bytes (about 10.7 MB of text). Assets past
/// it travel as references by id: they paste only in the same browser
/// profile, where the asset store still has the file.
const int kClipboardInlineAssetBytes = 8 * 1024 * 1024;

/// What a reference in a node, style or font points at.
enum RefKind { asset, font, textStyle, paintStyle, effectStyle }

const Map<String, RefKind> _keyKinds = {
  'assetId': RefKind.asset,
  'posterAssetId': RefKind.asset,
  'fontFamilyId': RefKind.font,
  'textStyleId': RefKind.textStyle,
  'fillStyleId': RefKind.paintStyle,
  'strokeStyleId': RefKind.paintStyle,
  'effectStyleId': RefKind.effectStyle,
};

RefKind? _kindOfKey(String key) {
  final k = _keyKinds[key];
  if (k != null) return k;
  // A patch path: "fills.<paintId>.assetId", "style.fontFamilyId".
  final dot = key.lastIndexOf('.');
  return dot < 0 ? null : _keyKinds[key.substring(dot + 1)];
}

/// Walks serialised IR [json], calling [visit] for every reference to an
/// asset, font family or named style (a field like `assetId`, or a patch
/// entry at a path ending in one). Returns the json with each reference
/// replaced by what [visit] returned.
Object? rewriteRefs(Object? json, String Function(RefKind, String) visit) {
  switch (json) {
    case final Map<String, dynamic> m:
      return {
        for (final e in m.entries) e.key: _rewriteEntry(e.key, e.value, visit),
      };
    case final List<dynamic> l:
      return [for (final e in l) rewriteRefs(e, visit)];
    default:
      return json;
  }
}

Object? _rewriteEntry(
  String key,
  Object? v,
  String Function(RefKind, String) visit,
) {
  final kind = _kindOfKey(key);
  if (kind != null) {
    if (v is String) return visit(kind, v);
    if (v is Map<String, dynamic> && v['type'] == 'string') {
      final inner = v['value'];
      if (inner is String) return {...v, 'value': visit(kind, inner)};
    }
  }
  return rewriteRefs(v, visit);
}

/// The ids [json] refers to, by kind.
Map<RefKind, Set<String>> collectRefs(Iterable<Object?> json) {
  final out = {for (final k in RefKind.values) k: <String>{}};
  for (final j in json) {
    rewriteRefs(j, (kind, id) {
      out[kind]!.add(id);
      return id;
    });
  }
  return out;
}

/// An asset in the envelope: its table entry, its content hash, and its
/// bytes unless they were left out for size ([data] null).
class ClipAsset {
  const ClipAsset(this.asset, this.hash, this.data);

  factory ClipAsset.fromJson(Map<String, dynamic> j) => ClipAsset(
    ir.Asset.fromJson(j['asset'] as Map<String, dynamic>),
    j['hash'] as String? ?? '',
    j['data'] is String ? base64Decode(j['data'] as String) : null,
  );

  final ir.Asset asset;
  final String hash;
  final Uint8List? data;

  Map<String, Object?> toJson() => {
    'asset': asset.toJson(),
    'hash': hash,
    if (data != null) 'data': base64Encode(data!),
  };
}

/// The clipboard format (`{"soundstage-clipboard": 1, ...}`): top-level
/// [nodes] in document order, with the [assets], [fonts] and named
/// [styles] they use, so they paste into any story.
///
/// - [docId]: the story copied from; [parentId]: the frame all the nodes
///   were in (null when they were in different frames). Both let a paste
///   in the same place offset itself.
/// - Everything is plain JSON of the IR.
class ClipboardEnvelope {
  const ClipboardEnvelope({
    required this.docId,
    required this.parentId,
    required this.nodes,
    this.assets = const {},
    this.fonts = const {},
    this.textStyles = const {},
    this.paintStyles = const {},
    this.effectStyles = const {},
  });

  final String docId;
  final String? parentId;
  final List<Map<String, dynamic>> nodes;
  final Map<String, ClipAsset> assets;
  final Map<String, Map<String, dynamic>> fonts;
  final Map<String, Map<String, dynamic>> textStyles;
  final Map<String, Map<String, dynamic>> paintStyles;
  final Map<String, Map<String, dynamic>> effectStyles;

  /// The clipboard text. The marker is the first key.
  String encode() => jsonEncode({
    kClipboardMarker: kClipboardVersion,
    'docId': docId,
    'parentId': parentId,
    'nodes': nodes,
    'assets': {for (final e in assets.entries) e.key: e.value.toJson()},
    'fonts': fonts,
    'styles': {
      'text': textStyles,
      'paint': paintStyles,
      'effect': effectStyles,
    },
  });

  /// Whether [text] is (probably) an envelope.
  static bool looksLike(String text) =>
      text.trimLeft().startsWith('{"$kClipboardMarker"');

  /// Parses [text], or returns null when it is not a readable envelope of
  /// this version.
  static ClipboardEnvelope? tryDecode(String text) {
    if (!looksLike(text)) return null;
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (j[kClipboardMarker] != kClipboardVersion) return null;
      Map<String, Map<String, dynamic>> table(Object? o) => {
        for (final e in (o as Map<String, dynamic>? ?? const {}).entries)
          e.key: e.value as Map<String, dynamic>,
      };
      final styles = j['styles'] as Map<String, dynamic>? ?? const {};
      return ClipboardEnvelope(
        docId: j['docId'] as String? ?? '',
        parentId: j['parentId'] as String?,
        nodes: [
          for (final n in j['nodes'] as List<dynamic>)
            n as Map<String, dynamic>,
        ],
        assets: {
          for (final e
              in (j['assets'] as Map<String, dynamic>? ?? const {}).entries)
            e.key: ClipAsset.fromJson(e.value as Map<String, dynamic>),
        },
        fonts: table(j['fonts']),
        textStyles: table(styles['text']),
        paintStyles: table(styles['paint']),
        effectStyles: table(styles['effect']),
      );
    } on Object {
      return null;
    }
  }
}

/// The top-level nodes of [ids] in document order (a node under another
/// selected node is covered by it; scene roots and instance inner ids are
/// skipped) and the frame they share (null when they are in different
/// frames).
({List<ir.Node> nodes, String? parentId}) copyableNodes(
  ir.StageDocument doc,
  Iterable<String> ids,
) {
  final index = ir.DocumentIndex.of(doc);
  final want = {
    for (final id in ids)
      if (!id.contains('/') && index.node(id) != null) id,
  };
  final top = <(String, ir.NodeLocation)>[];
  for (final id in want) {
    final loc = index.locate(id)!;
    if (loc.isRoot) continue;
    if (loc.ancestorIds.any(want.contains)) continue;
    top.add((id, loc));
  }
  int order((String, ir.NodeLocation) a, (String, ir.NodeLocation) b) {
    final s = (a.$2.sceneIndex ?? -1).compareTo(b.$2.sceneIndex ?? -1);
    if (s != 0) return s;
    final pa = a.$2.childPath, pb = b.$2.childPath;
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
    }
    return pa.length.compareTo(pb.length);
  }

  top.sort(order);
  final parents = {for (final t in top) t.$2.parentId};
  return (
    nodes: [for (final t in top) index.node(t.$1)!],
    parentId: parents.length == 1 ? parents.single : null,
  );
}
