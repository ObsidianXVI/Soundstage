import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/asset_service.dart';
import '../insert/insert_nodes.dart';
import '../text/rich_text_model.dart';
import 'agent_transport.dart';

// The agent's typed actions (m6.md T6.3, product spec "Operations and
// history"): every write is one of the editor's own commands, validated
// and undoable like a person's edit; the agent never writes document JSON.
// Reads are compact (an outline, one node at a time) so a turn stays cheap.

/// A tool result: text for the model, and whether it is an error.
typedef ToolResult = ({String content, bool isError});

/// Lines of outline per scene at most.
const int kOutlineLimit = 400;

/// The tool definitions sent to Claude (`tools`).
const List<Map<String, Object?>> kAgentTools = [
  {
    'name': 'get_outline',
    'description':
        'The story outline: every scene (id, name, kind), and the layer tree '
        'of one scene (the active one unless scene_id is given), one line per '
        'layer: id, kind, name, role, box (x,y w×h in the parent), and the '
        'start of its text. Call it before editing and after the author edits.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'scene_id': {'type': 'string'},
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'get_node',
    'description':
        'One layer in detail: kind, name, role, box, visibility, opacity, '
        'fills (hex), text and its size/weight, child ids, and its note.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'node_id': {'type': 'string'},
      },
      'required': ['node_id'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'get_board',
    'description':
        'The draft\'s inspiration board: the author\'s rough notes, links '
        'and images (by name). Read it to know what the author is aiming for.',
    'input_schema': {
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
  },
  {
    'name': 'get_annotations',
    'description':
        'The author\'s annotations: rough marks drawn on artboards to show '
        'you what they want (frame, text area, arrow, path, comment), each '
        'with its scene, artboard (breakpoint and size), points in that '
        'artboard\'s pixels, the layer it is over, a note, and a status. '
        'Build the real design from open ones; their boxes are where things '
        'go. Mark them resolved when done.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'include_resolved': {'type': 'boolean'},
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'set_annotation_status',
    'description': 'Sets an annotation to open, in_progress or resolved.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'status': {
          'type': 'string',
          'enum': ['open', 'in_progress', 'resolved'],
        },
      },
      'required': ['id', 'status'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'ask_point',
    'description':
        'Asks the author to click a place on the canvas (e.g. "Where should '
        'the icon go?") and waits. Returns the scene, the artboard '
        '(breakpoint) and the point in its pixels, or that they cancelled.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'question': {'type': 'string'},
      },
      'required': ['question'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'set_text',
    'description':
        'Replaces the words of a text layer (paragraphs separated by \\n). '
        'Shared across breakpoints; styling of the first span carries over.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'node_id': {'type': 'string'},
        'text': {'type': 'string'},
      },
      'required': ['node_id', 'text'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'set_properties',
    'description':
        'Sets properties on one or more layers (only the ones given): box '
        'and rotation in pixels/degrees, opacity 0-1, visible, corner_radius '
        '(frames, shapes), fill (hex like #1a1a2e, or "none"; on text layers '
        'the text colour), and for text layers text_color, '
        'font_size, font_weight (100-900). name renames. Written for every '
        'breakpoint unless the author chose "This breakpoint".',
    'input_schema': {
      'type': 'object',
      'properties': {
        'node_ids': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'width': {'type': 'number'},
        'height': {'type': 'number'},
        'rotation': {'type': 'number'},
        'opacity': {'type': 'number'},
        'visible': {'type': 'boolean'},
        'corner_radius': {'type': 'number'},
        'fill': {'type': 'string'},
        'text_color': {'type': 'string'},
        'font_size': {'type': 'number'},
        'font_weight': {'type': 'number'},
        'name': {'type': 'string'},
      },
      'required': ['node_ids'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'add_layer',
    'description':
        'Adds a text, frame, rectangle or ellipse layer inside parent_id (a '
        'frame; default the active scene\'s stage), at x,y with width×height '
        'in the parent. Optional text (text layers), fill (hex) and name. '
        'Returns the new id.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': ['text', 'frame', 'rectangle', 'ellipse'],
        },
        'parent_id': {'type': 'string'},
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'width': {'type': 'number'},
        'height': {'type': 'number'},
        'text': {'type': 'string'},
        'fill': {'type': 'string'},
        'name': {'type': 'string'},
      },
      'required': ['kind', 'x', 'y', 'width', 'height'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'delete_layers',
    'description': 'Deletes layers (and their children).',
    'input_schema': {
      'type': 'object',
      'properties': {
        'node_ids': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['node_ids'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'select',
    'description': 'Selects layers on the canvas, to show the author.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'node_ids': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['node_ids'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'add_scene',
    'description':
        'Adds a pinned scene at the end of the story and makes it active. '
        'Returns its id and its stage id.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'set_note',
    'description':
        'Sets the author-facing note on a scene or layer (private, never '
        'published); empty text removes it. Use it to leave suggestions.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'text': {'type': 'string'},
      },
      'required': ['id', 'text'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'add_illustration',
    'description':
        'Draws a vector illustration (Quiver) from a prompt and places it as '
        'an image layer in parent_id (default the active stage) at x,y with '
        'width×height. alt is the alt text for readers. Slow (seconds); use '
        'only when the author wants artwork.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'prompt': {'type': 'string'},
        'alt': {'type': 'string'},
        'parent_id': {'type': 'string'},
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'width': {'type': 'number'},
        'height': {'type': 'number'},
      },
      'required': ['prompt', 'alt', 'x', 'y', 'width', 'height'],
      'additionalProperties': false,
    },
  },
];

/// The tools a review may use: reads only, and `suggest`.
const Set<String> kReviewReadTools = {
  'get_outline',
  'get_node',
  'get_board',
  'get_annotations',
};

/// The review's way to propose a change (DECISIONS 26/10/26 #12: unasked,
/// the agent only suggests).
const Map<String, Object?> kSuggestTool = {
  'name': 'suggest',
  'description':
      'Proposes one change to the author. Nothing is applied by this call: '
      'the author applies or dismisses it (some kinds may apply themselves '
      'under the author\'s policy). actions are the tool calls that make '
      'the change, in order, each {tool, input} with the editing tools\' '
      'names and inputs (set_text, set_properties, add_layer, '
      'delete_layers, add_scene, set_note, add_illustration).',
  'input_schema': {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'why': {'type': 'string'},
      'actions': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'tool': {'type': 'string'},
            'input': {'type': 'object'},
          },
          'required': ['tool', 'input'],
        },
      },
    },
    'required': ['title', 'why', 'actions'],
    'additionalProperties': false,
  },
};

/// Runs the agent's tools on the open editor.
class AgentToolbox {
  AgentToolbox({
    required this.editor,
    required this.readState,
    this.assets,
    this.transport,
    this.askPoint,
  });

  /// Asks the author to point at the canvas (the session's), or null.
  final Future<({String sceneId, String breakpointId, double x, double y})?>
  Function(String question)?
  askPoint;

  final EditorController editor;

  /// The editor's current state (`ref.read(editorControllerProvider)`).
  final EditorState Function() readState;
  final EditorAssetService? assets;
  final AgentTransport? transport;

  ir.StageDocument get _doc => readState().document;
  ir.DocumentIndex get _index => ir.DocumentIndex.of(_doc);

  /// Writes made by the tools so far (for the run summary).
  int writes = 0;

  /// Whether [name] changes the document.
  static bool isWrite(String name) => !const {
    'get_outline',
    'get_node',
    'get_board',
    'get_annotations',
    'ask_point',
    'select',
  }.contains(name);

  Future<ToolResult> run(String name, Map<String, Object?> input) async {
    try {
      return switch (name) {
        'get_outline' => _ok(outline(input['scene_id'] as String?)),
        'get_node' => _node(_str(input, 'node_id')),
        'get_board' => _ok(board()),
        'get_annotations' => _ok(
          annotations(includeResolved: input['include_resolved'] == true),
        ),
        'set_annotation_status' => _setAnnotationStatus(
          _str(input, 'id'),
          _str(input, 'status'),
        ),
        'ask_point' => await _askPoint(_str(input, 'question')),
        'set_text' => _setText(_str(input, 'node_id'), _str(input, 'text')),
        'set_properties' => _setProperties(input),
        'add_layer' => _addLayer(input),
        'delete_layers' => _exec(DeleteNodes(_ids(input))),
        'select' => _select(_ids(input)),
        'add_scene' => _addScene(_str(input, 'name')),
        'set_note' => _exec(SetNote(_str(input, 'id'), _str(input, 'text'))),
        'add_illustration' => await _illustrate(input),
        _ => _error('There is no tool "$name".'),
      };
    } on FormatException catch (e) {
      return _error(e.message);
    }
  }

  // ---- Reads --------------------------------------------------------------

  /// The story outline (see the get_outline tool).
  String outline([String? sceneId]) {
    final doc = _doc;
    final active = sceneId ?? readState().activeSceneId;
    final out = StringBuffer('Story "${doc.meta.title}"\nScenes:\n');
    for (final (i, s) in doc.scenes.indexed) {
      out.writeln(
        '${i + 1}. ${s.id} "${s.name}" ${s.kind.name}'
        '${s.id == active ? ' (active)' : ''}'
        '${doc.notes[s.id] != null ? ' [note]' : ''}',
      );
    }
    final scene = doc.scenes.where((s) => s.id == active).firstOrNull;
    if (scene == null) return out.toString();
    out.writeln('\nLayers of ${scene.id}:');
    var lines = 0;
    void visit(ir.Node n, int depth) {
      if (lines++ >= kOutlineLimit) return;
      final c = n.common;
      final kind = switch (n) {
        ir.FrameNode() => 'frame',
        ir.TextNode() => 'text',
        ir.ShapeNode() => 'shape',
        ir.VideoNode() => 'video',
        ir.EmbedNode() => 'embed',
        ir.InstanceNode() => 'instance',
      };
      final text = n is ir.TextNode ? _excerpt(plainTextOf(n.content)) : '';
      out.writeln(
        '${'  ' * depth}- ${c.id} $kind "${c.name}"'
        '${c.role == ir.NodeRole.none ? '' : ' ${c.role.name}'}'
        ' (${_n(c.x)},${_n(c.y)} ${_n(c.width)}×${_n(c.height)})'
        '${c.visible ? '' : ' hidden'}'
        '${text.isEmpty ? '' : ' "$text"'}',
      );
      if (n is ir.FrameNode) {
        for (final k in n.children) {
          visit(k, depth + 1);
        }
      }
    }

    visit(scene.root, 0);
    if (lines > kOutlineLimit) {
      out.writeln('… ${lines - kOutlineLimit} more layers (use get_node).');
    }
    return out.toString();
  }

  /// The board as lines (see the get_board tool).
  String board() {
    final items = _doc.board.items;
    if (items.isEmpty) return 'The board is empty.';
    return [
      for (final i in items)
        switch (i.kind) {
          ir.BoardItemKind.note => '- note: ${i.text.replaceAll('\n', ' ')}',
          ir.BoardItemKind.link => '- link: ${i.uri}',
          ir.BoardItemKind.image => '- image: ${i.text}',
        },
    ].join('\n');
  }

  /// The annotations as JSON lines (see the get_annotations tool).
  String annotations({bool includeResolved = false}) {
    final doc = _doc;
    final list = [
      for (final (i, a) in doc.annotations.indexed)
        if (includeResolved || a.status != ir.AnnotationStatus.resolved)
          (i + 1, a),
    ];
    if (list.isEmpty) return 'There are no open annotations.';
    final bps = {for (final b in doc.breakpoints) b.id: b};
    return [
      for (final (n, a) in list)
        jsonEncode({
          'number': n,
          'id': a.id,
          'kind': a.kind.name,
          'scene_id': a.sceneId,
          'artboard': switch (bps[a.breakpointId]) {
            final b? =>
              '${b.name} ${b.designSize.width.round()}×${b.designSize.height.round()}',
            null => a.breakpointId,
          },
          'points': [
            for (final p in a.points) [p.x.round(), p.y.round()],
          ],
          if (a.targetIds.isNotEmpty) 'over': a.targetIds,
          'note': a.note,
          'status': a.status == ir.AnnotationStatus.inProgress
              ? 'in_progress'
              : a.status.name,
        }),
    ].join('\n');
  }

  ToolResult _setAnnotationStatus(String id, String status) {
    final a = _doc.annotations.where((x) => x.id == id).firstOrNull;
    if (a == null) return _error('There is no annotation "$id".');
    final s = switch (status) {
      'open' => ir.AnnotationStatus.open,
      'in_progress' => ir.AnnotationStatus.inProgress,
      'resolved' => ir.AnnotationStatus.resolved,
      _ => throw FormatException('Unknown status "$status".'),
    };
    return _exec(UpdateAnnotation(a.copyWith(status: s)));
  }

  Future<ToolResult> _askPoint(String question) async {
    final ask = askPoint;
    if (ask == null) return _error('The author cannot be asked here.');
    final p = await ask(question);
    if (p == null) return _ok('The author cancelled.');
    return _ok(
      jsonEncode({
        'scene_id': p.sceneId,
        'breakpoint': p.breakpointId,
        'x': p.x,
        'y': p.y,
      }),
    );
  }

  ToolResult _node(String id) {
    final n = _index.node(id);
    if (n == null) return _error('There is no layer "$id".');
    final c = n.common;
    final fills = switch (n) {
      ir.FrameNode(:final appearance) || ir.ShapeNode(:final appearance) => [
        for (final p in appearance.fills)
          if (p is ir.SolidPaint) p.color.toHex() else p.runtimeType.toString(),
      ],
      _ => const <String>[],
    };
    return _ok(
      jsonEncode({
        'id': c.id,
        'kind': n.runtimeType.toString().replaceAll('Node', '').toLowerCase(),
        'name': c.name,
        'role': c.role.name,
        'x': c.x,
        'y': c.y,
        'width': c.width,
        'height': c.height,
        'rotation': c.rotation,
        'opacity': c.opacity,
        'visible': c.visible,
        if (fills.isNotEmpty) 'fills': fills,
        'alt': ?c.altText,
        if (n is ir.TextNode) ...{
          'text': plainTextOf(n.content),
          'font_size': n.style.fontSize,
          'font_weight': n.style.fontWeight,
        },
        if (n is ir.FrameNode)
          'children': [for (final k in n.children) k.common.id],
        'note': ?_doc.notes[c.id],
      }),
    );
  }

  // ---- Writes -------------------------------------------------------------

  ToolResult _setText(String id, String text) {
    final n = _index.node(id);
    if (n is! ir.TextNode) return _error('"$id" is not a text layer.');
    final len = plainTextOf(n.content).length;
    return _exec(ReplaceText(id, 0, len, text, customLabel: 'Set text'));
  }

  ToolResult _setProperties(Map<String, Object?> input) {
    final ids = _ids(input);
    for (final id in ids) {
      if (_index.node(id) == null) return _error('There is no layer "$id".');
    }
    final values = <String, ir.IrValue>{
      for (final (key, path) in const [
        ('x', 'x'),
        ('y', 'y'),
        ('width', 'width'),
        ('height', 'height'),
        ('rotation', 'rotation'),
        ('opacity', 'opacity'),
      ])
        if (input[key] case final num v) path: ir.IrValue.number(v.toDouble()),
      if (input['visible'] case final bool v) 'visible': ir.IrValue.boolean(v),
    };
    // Frames and shapes have a fill stack and corners; text has a colour
    // (a text layer's "fill" is its colour).
    final boxValues = <String, ir.IrValue>{
      if (input['corner_radius'] case final num v)
        'cornerRadius': ir.IrValue.cornerRadius(
          ir.CornerRadius.uniform(v.toDouble()),
        ),
      if (input['fill'] case final String hex) 'fills': _paints(hex),
    };
    final textValues = <String, ir.IrValue>{
      if ((input['text_color'] ?? input['fill']) case final String hex)
        'style.fills': _paints(hex),
      if (input['font_size'] case final num v)
        'style.fontSize': ir.IrValue.number(v.toDouble()),
      if (input['font_weight'] case final num v)
        'style.fontWeight': ir.IrValue.number(v.roundToDouble()),
    };
    final writes = <String, Map<String, ir.IrValue>>{
      for (final id in ids)
        id: {
          ...values,
          ...switch (_index.node(id)) {
            ir.TextNode() => textValues,
            ir.FrameNode() || ir.ShapeNode() => boxValues,
            _ => const <String, ir.IrValue>{},
          },
        },
    }..removeWhere((_, w) => w.isEmpty);
    final results = <String>[];
    if (writes.isNotEmpty) {
      final r = _exec(SetProperty.values(writes));
      if (r.isError) return r;
      results.add(r.content);
    }
    if (input['name'] case final String name) {
      for (final id in ids) {
        final r = _exec(RenameNode(id, name));
        if (r.isError) return r;
      }
      results.add('renamed');
    }
    if (results.isEmpty) return _error('No properties were given.');
    return _ok('Done.');
  }

  ToolResult _addLayer(Map<String, Object?> input) {
    final kind = _str(input, 'kind');
    final tool = switch (kind) {
      'text' => EditorTool.text,
      'frame' => EditorTool.frame,
      'rectangle' => EditorTool.rectangle,
      'ellipse' => EditorTool.ellipse,
      _ => throw FormatException('Unknown layer kind "$kind".'),
    };
    final parentId = (input['parent_id'] as String?) ?? _activeStageId();
    if (parentId == null) return _error('There is no scene to add to.');
    if (_index.node(parentId) is! ir.FrameNode) {
      return _error('"$parentId" is not a frame.');
    }
    final id = ir.IdGenerator.forDocument(_doc).next();
    final box = Rect.fromLTWH(
      _num(input, 'x'),
      _num(input, 'y'),
      _num(input, 'width'),
      _num(input, 'height'),
    );
    var node = buildInsertNode(tool, id, box, drawn: true)!;
    if (input['name'] case final String name) {
      node = node.copyWith(common: node.common.copyWith(name: name));
    }
    if (node is ir.TextNode && input['text'] is String) {
      node = node.copyWith(
        content: [
          for (final p in (input['text']! as String).split('\n'))
            ir.Paragraph(spans: [ir.Span(text: p)]),
        ],
      );
    }
    if (input['fill'] case final String hex) {
      final paints = _paintList(hex);
      node = switch (node) {
        final ir.FrameNode f => f.copyWith(
          appearance: f.appearance.copyWith(fills: paints),
        ),
        final ir.ShapeNode s => s.copyWith(
          appearance: s.appearance.copyWith(fills: paints),
        ),
        final ir.TextNode t => t.copyWith(
          style: t.style.copyWith(fills: paints),
        ),
        _ => node,
      };
    }
    final r = _exec(InsertNodes(parentId, [node]));
    return r.isError ? r : _ok(jsonEncode({'id': id}));
  }

  ToolResult _select(List<String> ids) {
    final known = [
      for (final id in ids)
        if (_index.node(id) != null) id,
    ];
    editor.select(known.toSet());
    return _ok('Selected ${known.length}.');
  }

  ToolResult _addScene(String name) {
    final r = _exec(AddScene(name: name));
    if (r.isError) return r;
    final scene = _doc.scenes.last;
    return _ok(jsonEncode({'scene_id': scene.id, 'stage_id': scene.root.id}));
  }

  Future<ToolResult> _illustrate(Map<String, Object?> input) async {
    final t = transport;
    final store = assets;
    if (t == null) return _error('Illustrations need the hosted build.');
    if (store == null || !store.available) {
      return _error('This browser cannot store images right now.');
    }
    final parentId = (input['parent_id'] as String?) ?? _activeStageId();
    if (parentId == null || _index.node(parentId) is! ir.FrameNode) {
      return _error('There is no frame to place the illustration in.');
    }
    final box = Rect.fromLTWH(
      _num(input, 'x'),
      _num(input, 'y'),
      _num(input, 'width'),
      _num(input, 'height'),
    );
    final png = await t.illustrate(
      _str(input, 'prompt'),
      width: box.width,
      height: box.height,
    );
    final alt = _str(input, 'alt');
    final added = await store.add(png, 'image/png', name: 'Illustration.png');
    final asset = added.copyWith(alt: alt);
    final gen = ir.IdGenerator.forDocument(_doc);
    final id = gen.next();
    final frame = buildImageFrame(asset, id, gen.next(), box);
    final r = _exec(
      CommandBatch([
        AddAssets([asset]),
        InsertNodes(parentId, [frame]),
      ], label: 'Add illustration'),
    );
    return r.isError ? r : _ok(jsonEncode({'id': id}));
  }

  // ---- Helpers ------------------------------------------------------------

  ToolResult _exec(EditCommand command) {
    final r = editor.execute(command);
    if (!r.ok) {
      return _error(
        r.diagnostics.map((d) => d.message).join(' ').trim().isEmpty
            ? '${command.label} failed.'
            : r.diagnostics.map((d) => d.message).join(' '),
      );
    }
    if (r.changed) writes++;
    return _ok(r.changed ? 'Done.' : 'Nothing changed.');
  }

  String? _activeStageId() {
    final id = readState().activeSceneId;
    final scene =
        _doc.scenes.where((s) => s.id == id).firstOrNull ??
        _doc.scenes.firstOrNull;
    return scene?.root.id;
  }

  ir.IrValue _paints(String hex) => ir.IrValue.paints(_paintList(hex));

  List<ir.Paint> _paintList(String hex) {
    if (hex.trim().toLowerCase() == 'none') return const [];
    return [
      ir.Paint.solid(
        id: ir.IdGenerator.forDocument(_doc).next(),
        color: ir.StageColor.fromHex(hex),
      ),
    ];
  }

  static String _str(Map<String, Object?> input, String key) {
    final v = input[key];
    if (v is! String) throw FormatException('"$key" must be text.');
    return v;
  }

  static double _num(Map<String, Object?> input, String key) {
    final v = input[key];
    if (v is! num) throw FormatException('"$key" must be a number.');
    return v.toDouble();
  }

  static List<String> _ids(Map<String, Object?> input) {
    final v = input['node_ids'];
    if (v is! List || v.any((e) => e is! String)) {
      throw const FormatException('"node_ids" must be a list of ids.');
    }
    return v.cast<String>();
  }

  static String _excerpt(String s) {
    final one = s.replaceAll('\n', ' ⏎ ').trim();
    return one.length <= 60 ? one : '${one.substring(0, 57)}…';
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  static ToolResult _ok(String content) => (content: content, isError: false);
  static ToolResult _error(String content) => (content: content, isError: true);
}
