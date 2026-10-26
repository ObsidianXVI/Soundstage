import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/asset_service.dart';
import 'agent_policy.dart';
import 'agent_session.dart';
import 'agent_transport.dart';

/// The agent's model access, supplied by the app (`EditorShell`); null in
/// a local-only build or when signed out.
final agentTransportProvider = Provider<AgentTransport?>(
  (ref) => null,
  dependencies: const [],
);

/// Stores a changed agent config (the policy panel); supplied by the app.
final agentConfigSinkProvider = Provider<ValueChanged<AgentConfig>?>(
  (ref) => null,
  dependencies: const [],
);

/// Opens the app's Agent settings (keys and models); null when there are
/// none.
final agentSettingsProvider = Provider<VoidCallback?>(
  (ref) => null,
  dependencies: const [],
);

/// The open editor's conversation with the agent (null without a
/// transport). Lives as long as the editor.
final agentSessionProvider = Provider<AgentSession?>(
  (ref) {
    final transport = ref.watch(agentTransportProvider);
    if (transport == null) return null;
    final session = AgentSession(
      editor: ref.read(editorControllerProvider.notifier),
      readState: () => ref.read(editorControllerProvider),
      transport: transport,
      assets: _assetsOf(ref),
    );
    final watcher = AgentWatcher(session);
    ref.listen(
      editorControllerProvider.select((s) => s.revision),
      (_, _) => watcher.changed(),
    );
    ref.onDispose(() {
      watcher.dispose();
      session
        ..stop()
        ..events.dispose()
        ..running.dispose()
        ..suggestions.dispose()
        ..reviewing.dispose()
        ..pointRequest.dispose();
    });
    return session;
  },
  dependencies: [
    agentTransportProvider,
    editorControllerProvider,
    editorAssetServiceProvider,
  ],
);

EditorAssetService? _assetsOf(Ref ref) {
  try {
    return ref.read(editorAssetServiceProvider);
  } on Object {
    // No asset store (tests, a bare editor); Riverpod wraps the provider's
    // StateError.
    return null;
  }
}

/// The Agent panel (m6.md T6.4): the conversation, what the agent did, and
/// a message box. Works in every mode; an agent run is one undo step.
class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  ConsumerState<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends ConsumerState<AgentPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(AgentSession session) {
    final text = _input.text.trim();
    if (text.isEmpty || session.running.value) return;
    _input.clear();
    session.send(text);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final session = ref.watch(agentSessionProvider);
    final settings = ref.watch(agentSettingsProvider);
    return Container(
      key: const ValueKey<String>('agent-panel'),
      decoration: BoxDecoration(
        color: t.colors.surface1,
        border: Border(left: BorderSide(color: t.colors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.colors.borderSubtle)),
            ),
            child: Row(
              children: [
                SsIcon(SsIcons.sparkles, size: 16, color: t.colors.accent),
                const SizedBox(width: SsSpace.s2),
                Expanded(child: Text('Agent', style: t.text.bodyStrong)),
                if (session != null) ...[
                  ValueListenableBuilder<bool>(
                    valueListenable: session.reviewing,
                    builder: (_, reviewing, _) => SsIconButton(
                      key: const ValueKey<String>('agent-review'),
                      icon: SsIcons.scan,
                      semanticLabel: reviewing
                          ? 'Reviewing…'
                          : 'Review the story and suggest',
                      size: 28,
                      selected: reviewing,
                      onPressed: reviewing ? null : session.review,
                    ),
                  ),
                  SsIconButton(
                    key: const ValueKey<String>('agent-policy'),
                    icon: SsIcons.slidersHorizontal,
                    semanticLabel: 'What the agent may do unasked',
                    size: 28,
                    selected: session.policy.watch,
                    onPressed: () => showAgentPolicy(context, ref),
                  ),
                  SsIconButton(
                    icon: SsIcons.rotateCcw,
                    semanticLabel: 'New conversation',
                    size: 28,
                    onPressed: session.clear,
                  ),
                ],
                if (settings != null)
                  SsIconButton(
                    icon: SsIcons.settings,
                    semanticLabel: 'Agent settings',
                    size: 28,
                    onPressed: settings,
                  ),
                SsIconButton(
                  icon: SsIcons.x,
                  semanticLabel: 'Close agent',
                  size: 28,
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          if (session != null) _Suggestions(session: session),
          Expanded(
            child: session == null
                ? Padding(
                    padding: const EdgeInsets.all(SsSpace.s4),
                    child: Text(
                      'The agent works in the hosted Soundstage when you are '
                      'signed in, with your own Claude key (and a Quiver key '
                      'for illustrations).',
                      style: t.text.small.copyWith(
                        color: t.colors.textSecondary,
                      ),
                    ),
                  )
                : ValueListenableBuilder<List<AgentEvent>>(
                    valueListenable: session.events,
                    builder: (context, events, _) {
                      _scrollToEnd();
                      if (events.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(SsSpace.s4),
                          child: Text(
                            'Ask for help with the open story: "tighten the '
                            'opening text", "make the title larger on every '
                            'scene", "add an illustration of a lighthouse".',
                            style: t.text.small.copyWith(
                              color: t.colors.textSecondary,
                            ),
                          ),
                        );
                      }
                      return ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.all(SsSpace.s3),
                        children: [
                          for (final e in events)
                            _EventView(event: e, onSettings: settings),
                        ],
                      );
                    },
                  ),
          ),
          if (session != null)
            _AskAndBuild(
              session: session,
              onSend: (text) {
                _input.text = text;
                _send(session);
              },
            ),
          if (session != null)
            ValueListenableBuilder<bool>(
              valueListenable: session.running,
              builder: (context, running, _) => Container(
                padding: const EdgeInsets.all(SsSpace.s2),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: t.colors.borderSubtle)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Shortcuts(
                        shortcuts: const {
                          SingleActivator(LogicalKeyboardKey.enter):
                              _SendIntent(),
                        },
                        child: Actions(
                          actions: {
                            _SendIntent: CallbackAction<_SendIntent>(
                              onInvoke: (_) => _send(session),
                            ),
                          },
                          child: TextField(
                            key: const ValueKey<String>('agent-input'),
                            controller: _input,
                            minLines: 1,
                            maxLines: 6,
                            style: t.text.body,
                            decoration: InputDecoration.collapsed(
                              hintText: running
                                  ? 'Working…'
                                  : 'Ask the agent (Shift+Enter for a new line)',
                              hintStyle: t.text.body.copyWith(
                                color: t.colors.textDisabled,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: SsSpace.s1),
                    SsIconButton(
                      key: const ValueKey<String>('agent-send'),
                      icon: running ? SsIcons.square : SsIcons.send,
                      semanticLabel: running ? 'Stop' : 'Send',
                      size: 28,
                      onPressed: running ? session.stop : () => _send(session),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _EventView extends StatelessWidget {
  const _EventView({required this.event, required this.onSettings});

  final AgentEvent event;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: switch (event) {
        AgentUserMessage(:final text) => Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SsSpace.s3,
              vertical: SsSpace.s2,
            ),
            decoration: BoxDecoration(
              color: t.colors.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(SsRadius.md),
            ),
            child: SelectableText(text, style: t.text.body),
          ),
        ),
        AgentReply(:final text) => SelectableText(text, style: t.text.body),
        AgentToolCall(:final name, :final result, :final isError) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SsIcon(
              isError ? SsIcons.circleAlert : SsIcons.circleCheck,
              size: 12,
              color: isError ? t.colors.warning : t.colors.textDisabled,
            ),
            const SizedBox(width: SsSpace.s1),
            Expanded(
              child: SsTooltip(
                message: result.length > 400
                    ? '${result.substring(0, 400)}…'
                    : result,
                child: Text(name.replaceAll('_', ' '), style: t.text.caption),
              ),
            ),
          ],
        ),
        AgentProblem(:final message, :final needsKey) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: t.text.small.copyWith(color: t.colors.danger)),
            if (needsKey && onSettings != null)
              SsButton(
                label: 'Add a key',
                icon: SsIcons.keyRound,
                variant: SsButtonVariant.ghost,
                onPressed: onSettings,
              ),
          ],
        ),
      },
    );
  }
}

/// The agent's unasked suggestions (DECISIONS 26/10/26 #12).
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.session});

  final AgentSession session;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return ValueListenableBuilder<List<AgentSuggestion>>(
      valueListenable: session.suggestions,
      builder: (context, list, _) {
        final shown = [
          for (final s in list.reversed)
            if (s.status != SuggestionStatus.dismissed) s,
        ].take(6).toList();
        if (shown.isEmpty) return const SizedBox.shrink();
        return Container(
          constraints: const BoxConstraints(maxHeight: 320),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.colors.borderSubtle)),
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(SsSpace.s2),
            children: [
              Text('SUGGESTIONS', style: t.text.overline),
              const SizedBox(height: SsSpace.s1),
              for (final s in shown) _SuggestionCard(session: session, s: s),
            ],
          ),
        );
      },
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.session, required this.s});

  final AgentSession session;
  final AgentSuggestion s;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final status = switch (s.status) {
      SuggestionStatus.applied => 'Applied',
      SuggestionStatus.autoApplied => 'Applied automatically (your policy)',
      SuggestionStatus.failed => 'Could not apply: ${s.message}',
      _ => '',
    };
    return Container(
      key: ValueKey<String>('suggestion:${s.id}'),
      margin: const EdgeInsets.only(bottom: SsSpace.s2),
      padding: const EdgeInsets.all(SsSpace.s2),
      decoration: BoxDecoration(
        color: t.colors.surface2,
        borderRadius: BorderRadius.circular(SsRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.title, style: t.text.bodyStrong),
          if (s.why.isNotEmpty)
            Text(
              s.why,
              style: t.text.small.copyWith(color: t.colors.textSecondary),
            ),
          Text(
            '${s.actions.length} '
            '${s.actions.length == 1 ? 'change' : 'changes'}: '
            '${{for (final a in s.actions) a.tool.replaceAll('_', ' ')}.join(', ')}',
            style: t.text.caption,
          ),
          if (status.isNotEmpty)
            Text(
              status,
              style: t.text.caption.copyWith(
                color: s.status == SuggestionStatus.failed
                    ? t.colors.danger
                    : t.colors.success,
              ),
            ),
          Wrap(
            spacing: SsSpace.s1,
            children: [
              if (s.status == SuggestionStatus.open ||
                  s.status == SuggestionStatus.failed)
                SsButton(
                  key: ValueKey<String>('suggestion-apply:${s.id}'),
                  label: 'Apply',
                  variant: SsButtonVariant.primary,
                  onPressed: s.status == SuggestionStatus.open
                      ? () => session.apply(s)
                      : null,
                ),
              if (s.status == SuggestionStatus.applied ||
                  s.status == SuggestionStatus.autoApplied)
                SsButton(
                  label: 'Undo',
                  variant: SsButtonVariant.ghost,
                  onPressed: () => session.undo(s),
                ),
              SsButton(
                label: 'Dismiss',
                variant: SsButtonVariant.ghost,
                onPressed: () => session.dismiss(s),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The author's rules for the agent's unasked help (DECISIONS 26/10/26
/// #12): watch and suggest, and which kinds of change may apply themselves
/// within which boundaries.
///
/// The dialog opens above the editor's provider scope, so the config and
/// where to store it are read here and passed in.
Future<void> showAgentPolicy(BuildContext context, WidgetRef ref) {
  final config =
      ref.read(agentTransportProvider)?.config ?? const AgentConfig();
  final sink = ref.read(agentConfigSinkProvider);
  return showSsDialog<void>(
    context,
    builder: (_) => _PolicyDialog(initial: config, onChanged: sink),
  );
}

class _PolicyDialog extends StatefulWidget {
  const _PolicyDialog({required this.initial, required this.onChanged});

  final AgentConfig initial;
  final ValueChanged<AgentConfig>? onChanged;

  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  late AgentConfig _config = widget.initial;

  void _set(AgentPolicy p) {
    setState(() => _config = _config.copyWith(policy: p));
    widget.onChanged?.call(_config);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final p = _config.policy;
    return SsDialog(
      title: 'What the agent may do unasked',
      width: 460,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Unasked, the agent only suggests; you apply or dismiss. Asked '
            'in the chat, it acts. Reviews use your Claude key.',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: SsSpace.s3),
          SsToggle(
            key: const ValueKey<String>('policy-watch'),
            value: p.watch,
            label: 'Watch while I work and suggest (after a pause in editing)',
            onChanged: (v) => _set(p.copyWith(watch: v)),
          ),
          const SizedBox(height: SsSpace.s4),
          Text('AUTO-ACT', style: t.text.overline),
          const SizedBox(height: SsSpace.s1),
          Text(
            'Suggestions made only of these kinds of change apply '
            'themselves (each is one undo step):',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: SsSpace.s1),
          for (final k in AgentActionKind.values)
            SsCheckbox(
              key: ValueKey<String>('policy-auto:${k.name}'),
              value: p.autoAct.contains(k),
              label: k.label,
              onChanged: (v) => _set(
                p.copyWith(
                  autoAct: v ? {...p.autoAct, k} : ({...p.autoAct}..remove(k)),
                ),
              ),
            ),
          const SizedBox(height: SsSpace.s3),
          Row(
            children: [
              Text('Only within', style: t.text.small),
              const SizedBox(width: SsSpace.s2),
              SsDropdown<AgentScope>(
                key: const ValueKey<String>('policy-scope'),
                semanticLabel: 'Auto-act boundary',
                width: 200,
                value: p.scope,
                items: [
                  for (final s in AgentScope.values)
                    SsDropdownItem(value: s, label: s.label),
                ],
                onChanged: (s) => _set(p.copyWith(scope: s)),
              ),
            ],
          ),
          const SizedBox(height: SsSpace.s2),
          Row(
            children: [
              Text('At most', style: t.text.small),
              const SizedBox(width: SsSpace.s2),
              SsNumberField(
                semanticLabel: 'Most changes per suggestion',
                width: 72,
                value: p.maxChanges.toDouble(),
                min: 1,
                max: 50,
                fractionDigits: 0,
                onChanged: (v) => _set(p.copyWith(maxChanges: v.round())),
              ),
              const SizedBox(width: SsSpace.s2),
              Flexible(
                child: Text('changes per suggestion', style: t.text.small),
              ),
            ],
          ),
        ],
      ),
      actions: [
        SsButton(
          label: 'Done',
          variant: SsButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// The agent's open question to point at the canvas, and the quick action
/// to build from the author's open annotations.
class _AskAndBuild extends ConsumerWidget {
  const _AskAndBuild({required this.session, required this.onSend});

  final AgentSession session;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final open = ref.watch(
      editorControllerProvider.select(
        (s) => s.document.annotations
            .where((a) => a.status != ir.AnnotationStatus.resolved)
            .length,
      ),
    );
    return ValueListenableBuilder<PointRequest?>(
      valueListenable: session.pointRequest,
      builder: (context, request, _) {
        if (request != null) {
          return Container(
            key: const ValueKey<String>('agent-point-request'),
            padding: const EdgeInsets.all(SsSpace.s2),
            color: t.colors.accent.withValues(alpha: 0.12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${request.question}\nClick the place on the canvas '
                    '(in Design or Animate).',
                    style: t.text.small,
                  ),
                ),
                SsButton(
                  label: 'Cancel',
                  variant: SsButtonVariant.ghost,
                  onPressed: () => session.answerPoint(null),
                ),
              ],
            ),
          );
        }
        if (open == 0) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: session.running,
          builder: (context, running, _) => Padding(
            padding: const EdgeInsets.fromLTRB(
              SsSpace.s2,
              SsSpace.s1,
              SsSpace.s2,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SsButton(
                key: const ValueKey<String>('agent-build-annotations'),
                label:
                    'Build from $open '
                    '${open == 1 ? 'annotation' : 'annotations'}',
                icon: SsIcons.penTool,
                variant: SsButtonVariant.ghost,
                onPressed: running
                    ? null
                    : () => onSend(
                        'Build the real design from my open annotations '
                        '(read them with get_annotations), then mark each '
                        'one resolved.',
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
