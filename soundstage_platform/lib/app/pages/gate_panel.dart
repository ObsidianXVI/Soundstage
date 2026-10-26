import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/gate.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'cloud_ui.dart' show showSignInDialog;
import 'not_found_page.dart';

/// [error] without Riverpod's wrapper, when it has one.
Object unwrapProviderError(Object error) =>
    error is ProviderException ? unwrapProviderError(error.exception) : error;

/// Riverpod's retry for providers that may need the gate: a private page
/// is an answer, not a failure, so it is not retried (Riverpod keeps a
/// retrying provider loading); other errors retry three times.
Duration? retryUnlessGated(int count, Object error) =>
    unwrapProviderError(error) is GateRequired || count >= 3
    ? null
    : Duration(milliseconds: 200 << count);

/// The door of a password or readers-only page (m7.md T7.4): a signed-in
/// owner or listed reader goes straight through; others enter the
/// password or sign in. [onPass] receives the pass.
class GatePanel extends ConsumerStatefulWidget {
  const GatePanel({required this.docPath, required this.onPass, super.key});

  final String docPath;
  final ValueChanged<GatePass> onPass;

  @override
  ConsumerState<GatePanel> createState() => _GatePanelState();
}

class _GatePanelState extends ConsumerState<GatePanel> {
  final _password = TextEditingController();
  Audience? _audience;
  String? _message;
  bool _busy = true;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_try());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _try({String? password}) async {
    final gate = ref.read(gateClientProvider);
    if (gate == null) {
      setState(() {
        _busy = false;
        _message = 'This page is private.';
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final token = await ref
          .read(cloudProvider)
          ?.auth
          .currentUser
          ?.getIdToken();
      final result = await gate.open(
        widget.docPath,
        password: password,
        idToken: token,
      );
      if (!mounted) return;
      switch (result) {
        case GateOpened(:final pass):
          widget.onPass(pass);
        case GateMissing():
          setState(() => _missing = true);
        case GateClosed(:final audience, :final message):
          setState(() {
            _busy = false;
            _audience = audience;
            // The first, silent try needs no explanation.
            _message = password == null && token == null ? null : message;
          });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Could not reach Soundstage: $e';
        });
      }
    }
  }

  Future<void> _signIn() async {
    final cloud = ref.read(cloudProvider);
    if (cloud == null) return;
    await showSignInDialog(context, cloud.auth);
    if (mounted && cloud.auth.currentUser != null) await _try();
  }

  @override
  Widget build(BuildContext context) {
    if (_missing) return const NotFoundPage(message: 'Story not found');
    final t = context.ss;
    final audience = _audience;
    return Scaffold(
      backgroundColor: t.colors.surface0,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(SsSpace.s4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SsIcon(SsIcons.lock, size: 28),
                const SizedBox(height: SsSpace.s3),
                Text(
                  'This page is private',
                  textAlign: TextAlign.center,
                  style: t.text.heading,
                ),
                const SizedBox(height: SsSpace.s2),
                Text(
                  switch (audience) {
                    Audience.password => 'Enter the password to read it.',
                    Audience.readers =>
                      'Sign in with an email the author invited to read it.',
                    _ => _busy ? 'Opening…' : '',
                  },
                  textAlign: TextAlign.center,
                  style: t.text.body.copyWith(color: t.colors.textSecondary),
                ),
                const SizedBox(height: SsSpace.s4),
                if (audience == Audience.password) ...[
                  SsTextField(
                    key: const ValueKey<String>('gate:password'),
                    controller: _password,
                    obscureText: true,
                    autofocus: true,
                    placeholder: 'Password',
                    semanticLabel: 'Password',
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _try(password: _password.text),
                  ),
                  const SizedBox(height: SsSpace.s2),
                  SsButton(
                    key: const ValueKey<String>('gate:open'),
                    label: _busy ? 'Opening…' : 'Open',
                    variant: SsButtonVariant.primary,
                    onPressed: _busy
                        ? null
                        : () => _try(password: _password.text),
                  ),
                ],
                if (audience == Audience.readers)
                  SsButton(
                    key: const ValueKey<String>('gate:sign-in'),
                    label: ref.watch(authUserProvider).value == null
                        ? 'Sign in'
                        : 'Sign in with another email',
                    variant: SsButtonVariant.primary,
                    onPressed: _busy ? null : _signIn,
                  ),
                if (_message case final m?) ...[
                  const SizedBox(height: SsSpace.s2),
                  Text(
                    m,
                    textAlign: TextAlign.center,
                    style: t.text.small.copyWith(color: t.colors.danger),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
