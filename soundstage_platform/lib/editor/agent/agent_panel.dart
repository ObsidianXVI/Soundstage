import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../core/core.dart';
import '../insert/asset_service.dart';
import 'agent_session.dart';
import 'agent_transport.dart';

/// The agent's model access, supplied by the app (`EditorShell`); null in
/// a local-only build or when signed out.
final agentTransportProvider = Provider<AgentTransport?>(
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
    ref.onDispose(() {
      session
        ..stop()
        ..events.dispose()
        ..running.dispose();
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
                if (session != null)
                  SsIconButton(
                    icon: SsIcons.rotateCcw,
                    semanticLabel: 'New conversation',
                    size: 28,
                    onPressed: session.clear,
                  ),
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
