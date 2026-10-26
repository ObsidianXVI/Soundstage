import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/asset_service.dart';
import 'agent_policy.dart';
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

/// The review's instructions (DECISIONS 26/10/26 #12: unasked, the agent
/// only suggests).
const String kReviewPrompt = '''
Review the open story as an attentive editor and designer, without being
asked. Read what you need (get_outline, get_node, get_board: the board holds
the author's own notes on what they want). Then propose up to three changes
with suggest, most useful first: anything that would make the story better
or fix a problem (wording, hierarchy, contrast, alignment, missing alt text,
overflowing or empty text, consistency with the board's ideas). Each
suggestion's actions must be complete and use exact ids you read. You cannot
change anything yourself here. If nothing is worth suggesting, say so in one
line.''';

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

/// A change the agent proposed unasked.
class AgentSuggestion {
  AgentSuggestion({
    required this.id,
    required this.title,
    required this.why,
    required this.actions,
    this.status = SuggestionStatus.open,
    this.message = '',
  });

  final String id;
  final String title;
  final String why;
  final List<AgentAction> actions;
  SuggestionStatus status;

  /// Why applying failed.
  String message;

  /// The undo label of the change, once applied.
  String get undoLabel => 'Agent: $title';
}

enum SuggestionStatus { open, applied, autoApplied, dismissed, failed }

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

  /// The agent's unasked suggestions, newest last.
  final ValueNotifier<List<AgentSuggestion>> suggestions = ValueNotifier(
    const [],
  );
  final ValueNotifier<bool> reviewing = ValueNotifier(false);
  int _suggestionSerial = 0;
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

  // ---- Unasked help (DECISIONS 26/10/26 #12) ------------------------------

  AgentPolicy get policy => transport.config.policy;

  /// Reviews the story and proposes changes; suggestions the policy allows
  /// apply themselves. Uses its own short conversation (not the chat).
  Future<void> review() async {
    if (reviewing.value || running.value) return;
    reviewing.value = true;
    final convo = <Map<String, Object?>>[
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': kReviewPrompt},
          {'type': 'text', 'text': editorContext(readState())},
        ],
      },
    ];
    final tools = [
      for (final t in kAgentTools)
        if (kReviewReadTools.contains(t['name'])) t,
      kSuggestTool,
    ];
    try {
      for (var step = 0; step < 8; step++) {
        final reply = await transport.claude({
          'max_tokens': 16000,
          'system': [
            {
              'type': 'text',
              'text': kAgentSystemPrompt,
              'cache_control': {'type': 'ephemeral'},
            },
          ],
          'tools': tools,
          'messages': convo,
          'output_config': {'effort': transport.config.effort},
        });
        if (reply['stop_reason'] == 'refusal') break;
        final content = (reply['content'] as List?) ?? const [];
        convo.add({'role': 'assistant', 'content': content});
        final results = <Map<String, Object?>>[];
        for (final block in content.whereType<Map<String, Object?>>()) {
          if (block['type'] != 'tool_use') continue;
          final name = block['name'] as String? ?? '';
          final input = (block['input'] as Map?)?.cast<String, Object?>() ?? {};
          final String result;
          if (name == 'suggest') {
            result = _propose(input);
          } else if (kReviewReadTools.contains(name)) {
            result = (await toolbox.run(name, input)).content;
          } else {
            result = 'Only reads and suggest are available in a review.';
          }
          results.add({
            'type': 'tool_result',
            'tool_use_id': block['id'],
            'content': result,
          });
        }
        if (results.isEmpty) break;
        convo.add({'role': 'user', 'content': results});
      }
    } on AgentException catch (e) {
      _emit(AgentProblem(e.message, needsKey: e.needsKey));
    } on Object catch (e) {
      _emit(AgentProblem('The review failed: $e'));
    } finally {
      reviewing.value = false;
    }
  }

  String _propose(Map<String, Object?> input) {
    final actions = [
      for (final a in (input['actions'] as List?) ?? const [])
        if (a is Map && a['tool'] is String)
          AgentAction(
            a['tool'] as String,
            (a['input'] as Map?)?.cast<String, Object?>() ?? const {},
          ),
    ];
    final title = (input['title'] as String?)?.trim() ?? '';
    if (title.isEmpty || actions.isEmpty) {
      return 'A suggestion needs a title and at least one action.';
    }
    final suggestion = AgentSuggestion(
      id: 'sg${_suggestionSerial++}',
      title: title,
      why: (input['why'] as String?)?.trim() ?? '',
      actions: actions,
    );
    suggestions.value = [...suggestions.value, suggestion];
    final state = readState();
    if (policy.allowsAuto(
      actions,
      document: state.document,
      selection: state.selection,
      activeSceneId: state.activeSceneId,
    )) {
      unawaited(apply(suggestion, auto: true));
      return 'Recorded; it applied itself under the author\'s policy.';
    }
    return 'Recorded for the author.';
  }

  /// Applies [s] as one undo step.
  Future<void> apply(AgentSuggestion s, {bool auto = false}) async {
    if (s.status != SuggestionStatus.open) return;
    final depth = editor.history.undoDepth;
    final writesBefore = toolbox.writes;
    for (final a in s.actions) {
      final r = await toolbox.run(a.tool, a.input);
      if (r.isError) {
        s
          ..status = SuggestionStatus.failed
          ..message = r.content;
        break;
      }
    }
    if (toolbox.writes > writesBefore) {
      editor.squashHistorySince(depth, s.undoLabel);
    }
    if (s.status != SuggestionStatus.failed) {
      s.status = auto ? SuggestionStatus.autoApplied : SuggestionStatus.applied;
    }
    suggestions.value = [...suggestions.value];
  }

  void dismiss(AgentSuggestion s) {
    s.status = SuggestionStatus.dismissed;
    suggestions.value = [
      for (final x in suggestions.value)
        if (x != s) x,
    ];
  }

  /// Undoes an applied suggestion when it is still the last change.
  bool undo(AgentSuggestion s) {
    if (editor.history.undoLabel != s.undoLabel) return false;
    editor.undo();
    s.status = SuggestionStatus.open;
    suggestions.value = [...suggestions.value];
    return true;
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

/// Starts reviews while the author works (DECISIONS 26/10/26 #12,
/// product spec "Proactive"): after [idle] without an edit, never in the
/// middle of a gesture or typing burst, at most once per [minGap], and only
/// when the author's policy says to watch.
class AgentWatcher {
  AgentWatcher(
    this.session, {
    this.idle = const Duration(seconds: 30),
    this.minGap = const Duration(minutes: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AgentSession session;
  final Duration idle;
  final Duration minGap;
  final DateTime Function() _now;
  Timer? _timer;
  DateTime? _last;

  /// The document changed.
  void changed() {
    if (!session.policy.watch) return;
    _timer?.cancel();
    _timer = Timer(idle, _fire);
  }

  void _fire() {
    if (!session.policy.watch) return;
    if (session.editor.history.inGesture ||
        session.running.value ||
        session.reviewing.value) {
      _timer = Timer(idle, _fire);
      return;
    }
    final last = _last;
    final now = _now();
    if (last != null && now.difference(last) < minGap) {
      _timer = Timer(minGap - now.difference(last), _fire);
      return;
    }
    _last = now;
    unawaited(session.review());
  }

  void dispose() => _timer?.cancel();
}
