import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/agent/agent_transport.dart';

import '../pages/cloud_ui.dart' show showSignInDialog;
import 'agent_client.dart';
import 'agent_platform.dart';

/// The agent service's URL, set at build time with the Firebase config
/// (`.env.firebase.json`, from Terraform's output); empty: no agent.
const String kAgentUrl = String.fromEnvironment('AGENT_URL');

const String _settingKey = 'soundstage.agent.config';

/// The author's model settings, kept in this browser.
class AgentConfigNotifier extends Notifier<AgentConfig> {
  @override
  AgentConfig build() {
    final raw = readSetting(_settingKey);
    if (raw == null) return const AgentConfig();
    try {
      return AgentConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      return const AgentConfig();
    }
  }

  void set(AgentConfig config) {
    state = config;
    writeSetting(_settingKey, jsonEncode(config.toJson()));
  }
}

final agentConfigProvider = NotifierProvider<AgentConfigNotifier, AgentConfig>(
  AgentConfigNotifier.new,
);

/// The agent client for the signed-in author, or null (local-only build,
/// no agent service, signed out).
final agentClientProvider = Provider<AgentServiceClient?>((ref) {
  final cloud = ref.watch(cloudProvider);
  final user = ref.watch(authUserProvider).value;
  if (cloud == null || user == null || kAgentUrl.isEmpty) return null;
  return AgentServiceClient(
    baseUrl: kAgentUrl,
    idToken: () async => cloud.auth.currentUser?.getIdToken(),
    send: sendJson,
    rasterize: rasterizeSvg,
    readConfig: () => ref.read(agentConfigProvider),
  );
});

/// The Claude models offered (current generation; the field also takes any
/// id).
const List<String> kClaudeModels = [
  'claude-opus-5-5',
  'claude-sonnet-5-5',
  'claude-haiku-5-5',
  'claude-fable-5-1',
];

/// Agent settings: the author's keys (sent once to the agent service,
/// never shown again) and the models.
Future<void> showAgentSettings(BuildContext context, WidgetRef ref) async {
  final cloud = ref.read(cloudProvider);
  if (cloud == null) return;
  if (cloud.auth.currentUser == null) {
    await showSignInDialog(context, cloud.auth);
    if (cloud.auth.currentUser == null || !context.mounted) return;
  }
  await showSsDialog<void>(context, builder: (_) => const _AgentSettings());
}

class _AgentSettings extends ConsumerStatefulWidget {
  const _AgentSettings();

  @override
  ConsumerState<_AgentSettings> createState() => _AgentSettingsState();
}

class _AgentSettingsState extends ConsumerState<_AgentSettings> {
  final Map<String, TextEditingController> _keys = {
    for (final p in AgentServiceClient.providers) p: TextEditingController(),
  };
  final Map<String, bool?> _set = {};
  String? _status;
  bool _busy = false;
  late final TextEditingController _claudeModel = TextEditingController(
    text: ref.read(agentConfigProvider).claudeModel,
  );
  late final TextEditingController _quiverModel = TextEditingController(
    text: ref.read(agentConfigProvider).quiverModel,
  );

  AgentServiceClient? get _client => ref.read(agentClientProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final c = _client;
    if (c == null) return;
    for (final p in AgentServiceClient.providers) {
      try {
        final has = await c.hasKey(p);
        if (mounted) setState(() => _set[p] = has);
      } on AgentException catch (e) {
        if (mounted) setState(() => _status = e.message);
      }
    }
  }

  Future<void> _save(String provider) async {
    final c = _client;
    final key = _keys[provider]!.text.trim();
    if (c == null || key.isEmpty) return;
    setState(() => _busy = true);
    try {
      await c.setKey(provider, key);
      _keys[provider]!.clear();
      setState(() {
        _set[provider] = true;
        _status = 'Saved the ${_label(provider)} key.';
      });
    } on AgentException catch (e) {
      setState(() => _status = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String provider) async {
    final c = _client;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      await c.removeKey(provider);
      setState(() {
        _set[provider] = false;
        _status = 'Removed the ${_label(provider)} key.';
      });
    } on AgentException catch (e) {
      setState(() => _status = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _label(String provider) =>
      provider == 'anthropic' ? 'Claude' : 'Quiver';

  @override
  void dispose() {
    for (final c in _keys.values) {
      c.dispose();
    }
    _claudeModel.dispose();
    _quiverModel.dispose();
    super.dispose();
  }

  void _saveModels() {
    final n = ref.read(agentConfigProvider.notifier);
    final c = ref.read(agentConfigProvider);
    n.set(
      c.copyWith(
        claudeModel: _claudeModel.text.trim().isEmpty
            ? null
            : _claudeModel.text.trim(),
        quiverModel: _quiverModel.text.trim().isEmpty
            ? null
            : _quiverModel.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final config = ref.watch(agentConfigProvider);
    Widget keyRow(String provider, String hint) {
      final set = _set[provider];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_label(provider)} key · '
            '${set == null ? 'checking…' : (set ? 'saved' : 'not set')}',
            style: t.text.caption,
          ),
          const SizedBox(height: SsSpace.s1),
          Row(
            children: [
              Expanded(
                child: SsTextField(
                  key: ValueKey<String>('agent-key:$provider'),
                  controller: _keys[provider],
                  obscureText: true,
                  placeholder: set == true ? 'Replace the key' : hint,
                  semanticLabel: '${_label(provider)} API key',
                ),
              ),
              const SizedBox(width: SsSpace.s1),
              SsButton(
                label: 'Save',
                onPressed: _busy ? null : () => _save(provider),
              ),
              if (set == true)
                SsButton(
                  label: 'Remove',
                  variant: SsButtonVariant.ghost,
                  onPressed: _busy ? null : () => _remove(provider),
                ),
            ],
          ),
        ],
      );
    }

    return SsDialog(
      title: 'Agent settings',
      width: 480,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your keys go to the Soundstage agent service and are stored in '
            'Google Secret Manager for your account only. They are used for '
            'your agent requests and are never shown again; usage is billed '
            'to your provider accounts.',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: SsSpace.s3),
          keyRow('anthropic', 'sk-ant-…'),
          const SizedBox(height: SsSpace.s3),
          keyRow('quiver', 'Quiver API key (for illustrations)'),
          const SizedBox(height: SsSpace.s4),
          Text('MODELS', style: t.text.overline),
          const SizedBox(height: SsSpace.s1),
          SsTextField(
            key: const ValueKey<String>('agent-claude-model'),
            controller: _claudeModel,
            semanticLabel: 'Claude model',
            prefix: Text('Claude ', style: t.text.small),
            onSubmitted: (_) => _saveModels(),
            onChanged: (_) => _saveModels(),
          ),
          const SizedBox(height: SsSpace.s1),
          Wrap(
            spacing: SsSpace.s1,
            children: [
              for (final m in kClaudeModels)
                SsButton(
                  label: m,
                  variant: m == config.claudeModel
                      ? SsButtonVariant.secondary
                      : SsButtonVariant.ghost,
                  onPressed: () {
                    _claudeModel.text = m;
                    _saveModels();
                  },
                ),
            ],
          ),
          const SizedBox(height: SsSpace.s2),
          Row(
            children: [
              Text('Effort', style: t.text.small),
              const SizedBox(width: SsSpace.s2),
              SsDropdown<String>(
                semanticLabel: 'Effort',
                width: 120,
                value: config.effort,
                items: [
                  for (final e in AgentConfig.efforts)
                    SsDropdownItem(value: e, label: e),
                ],
                onChanged: (e) => ref
                    .read(agentConfigProvider.notifier)
                    .set(config.copyWith(effort: e)),
              ),
            ],
          ),
          const SizedBox(height: SsSpace.s2),
          SsTextField(
            key: const ValueKey<String>('agent-quiver-model'),
            controller: _quiverModel,
            semanticLabel: 'Quiver model',
            prefix: Text('Quiver ', style: t.text.small),
            onChanged: (_) => _saveModels(),
          ),
          if (_status case final s?) ...[
            const SizedBox(height: SsSpace.s3),
            Text(s, style: t.text.small),
          ],
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
