import 'dart:convert';

import 'package:soundstage_platform/ir/ir.dart';

/// The demo documents under `assets/demo/`.
const demoFiles = [
  'motion',
  'paint_gallery',
  'sound',
  'spike',
  'static',
];

/// Viewport widths the demos are compared at.
const digestWidths = [390.0, 834.0, 1440.0];

/// A canonical JSON dump of every resolved scene of [doc] (node trees,
/// merged span styles, modes and resolved tracks). The breakpoint itself is
/// left out, so documents whose breakpoint model differs but whose output
/// is the same dump the same.
String resolvedDump(ResolvedDocument doc) {
  Object? node(ResolvedNode n) => {
    'id': n.id,
    'node': n.node.toJson(),
    'modes': n.modes,
    'src': n.sourceComponentId,
    'inst': n.instanceId,
    'ph': n.isPlaceholder,
    if (n.paragraphs case final ps?)
      'paragraphs': [
        for (final p in ps)
          {
            'align': p.alignHorizontal.name,
            'spacing': p.paragraphSpacing,
            'indent': p.paragraphIndent,
            'list': p.listStyle.name,
            'spans': [
              for (final s in p.spans)
                {
                  'text': s.text,
                  'style': s.style.toJson(),
                  'link': s.link?.toJson(),
                },
            ],
          },
      ],
    'children': [for (final c in n.children) node(c)],
  };
  return jsonEncode({
    'scenes': [
      for (final s in doc.scenes)
        {
          'id': s.id,
          'root': node(s.root),
          'tracks': [for (final t in s.tracks) t.toJson()],
          'modes': s.modes,
        },
    ],
    if (doc.overlay case final o?) 'overlay': node(o),
  });
}

/// 32-bit FNV-1a over the UTF-8 bytes of [s], as 8 hex digits, plus the
/// length (works the same on the VM and the web).
String digest(String s) {
  var h = 0x811c9dc5;
  final bytes = utf8.encode(s);
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return '${h.toRadixString(16).padLeft(8, '0')}:${bytes.length}';
}
