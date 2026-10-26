import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/domains.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../agent/agent_platform.dart' as platform;
import '../agent/agent_settings.dart' show kAgentUrl;
import 'cloud_ui.dart' show ensureCloudAccess, ensureHandle;

/// The author's custom domains (DECISIONS 26/10/26 "Custom domains", m7.md
/// T7.5): premium and by request. A connected domain shows the author's
/// handle page and published work at clean paths.
Future<void> showDomainsDialog(BuildContext context, WidgetRef ref) async {
  final cloud = ref.read(cloudProvider);
  if (cloud == null || kAgentUrl.isEmpty) return;
  if (!await ensureCloudAccess(context, cloud) || !context.mounted) return;
  final handle = await ensureHandle(context, cloud);
  if (handle == null || !context.mounted) return;
  final client = DomainsClient(
    baseUrl: kAgentUrl,
    send: platform.sendJson,
    idToken: () async => cloud.auth.currentUser?.getIdToken(),
  );
  await showSsDialog<void>(
    context,
    builder: (_) => DomainsDialog(client: client, handle: handle),
  );
}

class DomainsDialog extends StatefulWidget {
  const DomainsDialog({required this.client, required this.handle, super.key});

  final DomainsClient client;
  final String handle;

  @override
  State<DomainsDialog> createState() => _DomainsDialogState();
}

class _DomainsDialogState extends State<DomainsDialog> {
  final _host = TextEditingController();
  bool? _premium;
  List<CustomDomain> _domains = const [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final (premium, domains) = await widget.client.list();
    if (mounted) {
      setState(() {
        _premium = premium;
        _domains = domains;
      });
    }
  });

  Future<void> _add() => _run(() async {
    final host = _host.text.trim().toLowerCase();
    if (host.isEmpty) return;
    final added = await widget.client.add(host);
    if (!mounted) return;
    _host.clear();
    setState(
      () => _domains = [..._domains.where((d) => d.host != added.host), added],
    );
  });

  Future<void> _remove(CustomDomain d) => _run(() async {
    await widget.client.remove(d.host);
    if (mounted) {
      setState(
        () => _domains = _domains.where((x) => x.host != d.host).toList(),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final premium = _premium;
    return SsDialog(
      title: 'Custom domains',
      width: 560,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'A domain you own shows your page (@${widget.handle}) and '
                'everything you publish, at clean links: your-domain/s/… '
                'for stories, your-domain/<publication>/… for issues.',
                style: t.text.small.copyWith(color: t.colors.textSecondary),
              ),
              const SizedBox(height: SsSpace.s3),
              if (premium == false)
                Text(
                  'Custom domains are available by request. Ask to have them '
                  'enabled for your account.',
                  style: t.text.body,
                ),
              for (final d in _domains)
                _DomainCard(domain: d, busy: _busy, onRemove: () => _remove(d)),
              if (premium == true) ...[
                const SizedBox(height: SsSpace.s2),
                Row(
                  children: [
                    Expanded(
                      child: SsTextField(
                        key: const ValueKey<String>('domains:host'),
                        controller: _host,
                        placeholder: 'yourdomain.com',
                        semanticLabel: 'Domain',
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: SsSpace.s2),
                    SsButton(
                      key: const ValueKey<String>('domains:add'),
                      label: 'Connect',
                      variant: SsButtonVariant.primary,
                      onPressed: _busy ? null : _add,
                    ),
                  ],
                ),
              ],
              if (_error case final e?) ...[
                const SizedBox(height: SsSpace.s2),
                Text(e, style: t.text.small.copyWith(color: t.colors.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        SsButton(
          label: _busy ? 'Checking…' : 'Check again',
          icon: SsIcons.rotateCw,
          onPressed: _busy ? null : _load,
        ),
        SsButton(
          label: 'Close',
          variant: SsButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _DomainCard extends StatelessWidget {
  const _DomainCard({
    required this.domain,
    required this.busy,
    required this.onRemove,
  });

  final CustomDomain domain;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final live = domain.state == 'live';
    return Container(
      margin: const EdgeInsets.only(bottom: SsSpace.s2),
      padding: const EdgeInsets.all(SsSpace.s3),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: SsRadius.brLg,
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(domain.host, style: t.text.bodyStrong)),
              Text(
                domain.stateLabel,
                style: t.text.small.copyWith(
                  color: live ? c.success : c.warning,
                ),
              ),
              const SizedBox(width: SsSpace.s2),
              SsButton(
                label: 'Remove',
                variant: SsButtonVariant.ghost,
                onPressed: busy ? null : onRemove,
              ),
            ],
          ),
          if (domain.records.isNotEmpty) ...[
            const SizedBox(height: SsSpace.s2),
            Text(
              'At your DNS provider:',
              style: t.text.small.copyWith(color: c.textSecondary),
            ),
            for (final r in domain.records)
              Padding(
                padding: const EdgeInsets.only(top: SsSpace.s1),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(
                        r.add ? 'Add' : 'Remove',
                        style: t.text.small.copyWith(
                          color: r.add ? c.success : c.danger,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(r.type, style: t.text.small),
                    ),
                    Expanded(
                      child: SelectableText(
                        '${r.name}  →  ${r.value}',
                        style: t.text.small,
                      ),
                    ),
                    SsButton(
                      label: 'Copy',
                      icon: SsIcons.copy,
                      variant: SsButtonVariant.ghost,
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: r.value)),
                    ),
                  ],
                ),
              ),
          ],
          for (final i in domain.issues)
            Padding(
              padding: const EdgeInsets.only(top: SsSpace.s1),
              child: Text(i, style: t.text.small.copyWith(color: c.warning)),
            ),
        ],
      ),
    );
  }
}
