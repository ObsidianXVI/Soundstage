import 'package:flutter/foundation.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/asset_service.dart';
import 'agent_tools.dart';
import 'agent_transport.dart';

// The agent loop (m6.md T6.3): context → Claude → typed tools → results →
// until the model ends its turn. One run is one undo step. A write against
// a document the author changed since the agent last looked is refused, so
// a stale plan never overwrites newer work.

/// The agent's standing instructions (cached with the tool list).
const String kAgentSystemPrompt = '''
You are the design and writing assistant inside Soundstage, an editor for
scroll-driven, interactive stories. A story is a list of scenes; each scene
has a stage frame holding layers (frames, text, shapes, images). Layouts
exist per breakpoint (desktop, mobile…) over a shared base; text is shared.

Work only through the tools. Read before you write: call get_outline (and
get_node for details) to learn ids and boxes, then make focused edits. Keep
the author's words unless asked to change them. Prefer small, reversible
steps; your whole run is undone with one undo. If a write is refused because
the document changed, read again. When you are unsure what the author wants,
ask one short question instead of guessing. Finish with one or two sentences
saying what you changed.''';

/// Steps (model calls) per run at most.
const int kAgentMaxSteps = 24;

/// What the agent panel shows.
sealed class AgentEvent {
  const AgentEvent();
}

class AgentUserMessage extends AgentEvent {
  const AgentUserMessage(this.text);
  final String text;
}

class AgentReply extends AgentEvent {
  const AgentReply(this.text);
  final String text;
}

class AgentToolCall extends AgentEvent {
  const AgentToolCall(this.name, this.result, {required this.isError});
  final String name;
  final String result;
  final bool isError;
}

class AgentProblem extends AgentEvent {
  const AgentProblem(this.message, {this.needsKey = false});
  final String message;
  final bool needsKey;
}

/// A conversation with the agent over one open story.
class AgentSession {
  AgentSession({
    required this.editor,
    required this.readState,
    required this.transport,
    EditorAssetService? assets,
  }) : toolbox = AgentToolbox(
         editor: editor,
         readState: readState,
         assets: assets,
         transport: transport,
       );

  final EditorController editor;
  final EditorState Function() readState;
  final AgentTransport transport;
  final AgentToolbox toolbox;

  /// The conversation in Messages API form (assistant turns kept whole,
  /// thinking blocks included, as the API requires).
  final List<Map<String, Object?>> messages = [];

  /// What the panel shows, oldest first.
  final ValueNotifier<List<AgentEvent>> events = ValueNotifier(const []);
  final ValueNotifier<bool> running = ValueNotifier(false);
  bool _stop = false;

  /// The document revision the agent last saw.
  int _seen = 0;

  void _emit(AgentEvent e) => events.value = [...events.value, e];

  /// Asks the agent to stop after the current step.
  void stop() => _stop = true;

  /// Runs one request from the author to the end of the agent's turn.
  Future<void> send(String prompt) async {
    if (running.value || prompt.trim().isEmpty) return;
    running.value = true;
    _stop = false;
    _emit(AgentUserMessage(prompt));
    final depth = editor.history.undoDepth;
    final writesBefore = toolbox.writes;
    _seen = readState().revision;
    messages.add({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': prompt},
        {'type': 'text', 'text': editorContext(readState())},
      ],
    });
    try {
      for (var step = 0; step < kAgentMaxSteps && !_stop; step++) {
        final reply = await transport.claude({
          'max_tokens': 16000,
          'system': [
            {
              'type': 'text',
              'text': kAgentSystemPrompt,
              'cache_control': {'type': 'ephemeral'},
            },
          ],
          'tools': kAgentTools,
          'messages': messages,
          'output_config': {'effort': transport.config.effort},
        });
        final content = (reply['content'] as List?) ?? const [];
        final stop = reply['stop_reason'];
        if (stop == 'refusal') {
          _emit(const AgentProblem('The model declined this request.'));
          messages.removeLast();
          break;
        }
        messages.add({'role': 'assistant', 'content': content});
        final results = <Map<String, Object?>>[];
        for (final block in content.whereType<Map<String, Object?>>()) {
          switch (block['type']) {
            case 'text':
              final text = (block['text'] as String?)?.trim() ?? '';
              if (text.isNotEmpty) _emit(AgentReply(text));
            case 'tool_use':
              results.add(await _runTool(block));
          }
        }
        if (results.isEmpty) {
          if (stop == 'max_tokens') {
            _emit(const AgentProblem('The reply was cut off (too long).'));
          }
          break;
        }
        messages.add({'role': 'user', 'content': results});
      }
      if (_stop) _emit(const AgentProblem('Stopped.'));
    } on AgentException catch (e) {
      _emit(AgentProblem(e.message, needsKey: e.needsKey));
      _dropDanglingToolUse();
    } on Object catch (e) {
      _emit(AgentProblem('The agent failed: $e'));
      _dropDanglingToolUse();
    } finally {
      if (toolbox.writes > writesBefore) {
        editor.squashHistorySince(depth, 'Agent: ${_short(prompt)}');
      }
      running.value = false;
    }
  }

  Future<Map<String, Object?>> _runTool(Map<String, Object?> block) async {
    final name = block['name'] as String? ?? '';
    final input = (block['input'] as Map?)?.cast<String, Object?>() ?? {};
    ToolResult r;
    if (AgentToolbox.isWrite(name) && readState().revision != _seen) {
      r = (
        content:
            'The author changed the document since you last read it. Call '
            'get_outline (or get_node) again before editing.',
        isError: true,
      );
    } else {
      r = await toolbox.run(name, input);
    }
    _seen = readState().revision;
    _emit(AgentToolCall(name, r.content, isError: r.isError));
    return {
      'type': 'tool_result',
      'tool_use_id': block['id'],
      'content': r.content,
      if (r.isError) 'is_error': true,
    };
  }

  /// After a failed call the last assistant turn may hold tool uses with no
  /// results; the next request would be refused, so it is dropped.
  void _dropDanglingToolUse() {
    if (messages.isNotEmpty && messages.last['role'] == 'assistant') {
      messages.removeLast();
    }
  }

  /// Starts over (the document keeps every change).
  void clear() {
    messages.clear();
    events.value = const [];
  }

  static String _short(String s) {
    final one = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return one.length <= 40 ? one : '${one.substring(0, 37)}…';
  }
}

/// What the agent is told about the editor with each request: the active
/// scene, the selection, the breakpoint and edit scope. Small on purpose;
/// the outline is a tool call away.
String editorContext(EditorState s) {
  final doc = s.document;
  final index = ir.DocumentIndex.of(doc);
  final selection = [
    for (final id in s.selection)
      if (index.node(id) case final n?) '$id "${n.common.name}"',
  ];
  final bp = doc.breakpoints.where((b) => b.id == s.breakpointId).firstOrNull;
  return '<editor_state>\n'
      'active scene: ${s.activeSceneId ?? 'none'}\n'
      'selection: ${selection.isEmpty ? 'nothing' : selection.join(', ')}\n'
      'breakpoint: ${bp == null ? 'none' : '${bp.name} ${bp.designSize.width.round()}×${bp.designSize.height.round()}'}\n'
      'edit scope: ${s.effectiveScope.name}\n'
      '</editor_state>';
}
