import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// The story list's account control (m4.md T4.1): "Sign in" when signed
/// out, the author's email with a Sign out menu when signed in. Hidden in
/// a local-only build.
class AccountButton extends ConsumerWidget {
  const AccountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloud = ref.watch(cloudProvider);
    if (cloud == null) return const SizedBox.shrink();
    final user = ref.watch(authUserProvider).value;
    if (user == null) {
      return SsButton(
        key: const ValueKey<String>('account:sign-in'),
        label: 'Sign in',
        icon: SsIcons.user,
        onPressed: () => showSignInDialog(context, cloud.auth),
      );
    }
    return Builder(
      builder: (anchor) => SsButton(
        key: const ValueKey<String>('account:menu'),
        label: user.email ?? 'Account',
        icon: SsIcons.user,
        onPressed: () {
          final box = anchor.findRenderObject()! as RenderBox;
          showSsMenu(
            context,
            anchor: box.localToGlobal(Offset.zero) & box.size,
            placement: SsPlacement.belowEnd,
            entries: [
              SsMenuItem(
                label: 'Sign out',
                icon: SsIcons.logOut,
                onSelected: () => cloud.auth.signOut(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Email and password sign-in, or account creation. Resolves when the
/// dialog closes.
Future<void> showSignInDialog(BuildContext context, FirebaseAuth auth) =>
    showSsDialog<void>(context, builder: (ctx) => _SignInDialog(auth: auth));

class _SignInDialog extends StatefulWidget {
  const _SignInDialog({required this.auth});

  final FirebaseAuth auth;

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _create = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your email and a password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_create) {
        final created = await widget.auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        await created.user?.sendEmailVerification();
      } else {
        await widget.auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      setState(() {
        _busy = false;
        _error = authErrorText(e.code);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return SsDialog(
      title: _create ? 'Create an account' : 'Sign in',
      width: 380,
      content: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SsTextField(
              key: const ValueKey<String>('sign-in:email'),
              controller: _email,
              autofocus: true,
              placeholder: 'Email',
              semanticLabel: 'Email',
              autofillHints: const [AutofillHints.email],
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: SsSpace.s2),
            SsTextField(
              key: const ValueKey<String>('sign-in:password'),
              controller: _password,
              obscureText: true,
              placeholder: 'Password',
              semanticLabel: 'Password',
              autofillHints: [
                _create ? AutofillHints.newPassword : AutofillHints.password,
              ],
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: SsSpace.s2),
              Text(
                _error!,
                style: t.text.small.copyWith(color: t.colors.danger),
              ),
            ],
            const SizedBox(height: SsSpace.s2),
            Align(
              alignment: Alignment.centerLeft,
              child: SsButton(
                label: _create
                    ? 'I have an account'
                    : 'Create an account instead',
                variant: SsButtonVariant.ghost,
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _create = !_create;
                        _error = null;
                      }),
              ),
            ),
          ],
        ),
      ),
      actions: [
        SsButton(
          label: 'Cancel',
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        SsButton(
          key: const ValueKey<String>('sign-in:submit'),
          label: _busy ? 'Working…' : (_create ? 'Create account' : 'Sign in'),
          variant: SsButtonVariant.primary,
          onPressed: _busy ? null : _submit,
        ),
      ],
    );
  }
}

/// Makes sure the author may use the cloud (publish, agent): signs in if
/// needed, then explains an unverified email (with resend) or a missing
/// invite. True when invited.
Future<bool> ensureCloudAccess(BuildContext context, Cloud cloud) async {
  if (cloud.auth.currentUser == null) {
    await showSignInDialog(context, cloud.auth);
    if (cloud.auth.currentUser == null) return false;
  }
  while (context.mounted) {
    final CloudAccess access;
    try {
      access = await accessOf(cloud);
    } on Object {
      if (context.mounted) {
        SsToast.show(
          context,
          'Could not reach Soundstage. Check the network.',
          kind: SsToastKind.danger,
        );
      }
      return false;
    }
    if (!context.mounted) return false;
    switch (access) {
      case CloudAccess.invited:
        return true;
      case CloudAccess.signedOut:
        return false;
      case CloudAccess.notInvited:
        await _showNotInvited(context, cloud.auth.currentUser?.email ?? '');
        return false;
      case CloudAccess.unverified:
        final again = await _showVerify(context, cloud.auth);
        if (!again) return false;
    }
  }
  return false;
}

Future<void> _showNotInvited(BuildContext context, String email) =>
    showSsDialog<void>(
      context,
      builder: (ctx) => SsDialog(
        title: 'Soundstage is invite-only',
        width: 400,
        content: Text(
          '$email is not on the invite list yet. Your stories stay in this '
          'browser in the meantime; publishing and the agent open once you '
          'are invited.',
        ),
        actions: [
          SsButton(
            label: 'OK',
            variant: SsButtonVariant.primary,
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );

/// Asks the author to verify their email. True to check again.
Future<bool> _showVerify(BuildContext context, FirebaseAuth auth) async {
  final email = auth.currentUser?.email ?? 'your email';
  final again = await showSsDialog<bool>(
    context,
    builder: (ctx) => SsDialog(
      title: 'Verify your email',
      width: 400,
      content: Text(
        'We sent a link to $email. Open it, then come back and choose '
        '"I have verified".',
      ),
      actions: [
        SsButton(
          label: 'Send again',
          onPressed: () async {
            try {
              await auth.currentUser?.sendEmailVerification();
              if (ctx.mounted) SsToast.show(ctx, 'Sent.');
            } on FirebaseAuthException catch (e) {
              if (ctx.mounted) {
                SsToast.show(
                  ctx,
                  authErrorText(e.code),
                  kind: SsToastKind.danger,
                );
              }
            }
          },
        ),
        SsButton(
          key: const ValueKey<String>('verify:check'),
          label: 'I have verified',
          variant: SsButtonVariant.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return again ?? false;
}

/// Firebase Auth error codes in the author's words.
String authErrorText(String code) => switch (code) {
  'invalid-email' => 'That email address does not look right.',
  'user-disabled' => 'This account is disabled.',
  'user-not-found' ||
  'wrong-password' ||
  'invalid-credential' => 'The email or password is not right.',
  'email-already-in-use' => 'An account with this email exists. Sign in.',
  'weak-password' => 'Use a longer password (at least 6 characters).',
  'too-many-requests' => 'Too many attempts. Try again in a minute.',
  'network-request-failed' => 'No connection. Check the network.',
  _ => 'Sign-in failed ($code).',
};

/// Asks for the published link of a story: [suggested] is prefilled.
/// Returns the chosen slug, or null when cancelled.
Future<String?> showPublishDialog(
  BuildContext context, {
  required String title,
  required String suggested,
  required String origin,
  String path = 's',
}) => showSsDialog<String>(
  context,
  builder: (ctx) => _PublishDialog(
    title: title,
    suggested: suggested,
    origin: origin,
    path: path,
  ),
);

class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.title,
    required this.suggested,
    required this.origin,
    this.path = 's',
  });

  final String title;
  final String suggested;
  final String origin;

  /// The route the link lives under (`s` for stories, `series`).
  final String path;

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  late final _slug = TextEditingController(text: widget.suggested);

  @override
  void dispose() {
    _slug.dispose();
    super.dispose();
  }

  void _submit() {
    if (isValidSlug(_slug.text.trim())) {
      Navigator.of(context).pop(_slug.text.trim());
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final slug = _slug.text.trim();
    final valid = isValidSlug(slug);
    return SsDialog(
      title: 'Publish "${widget.title}"',
      width: 440,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Anyone with the link can read the published version. '
            'Publishing again updates it.',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: SsSpace.s3),
          SsTextField(
            key: const ValueKey<String>('publish:slug'),
            controller: _slug,
            autofocus: true,
            selectAllOnFocus: true,
            semanticLabel: 'Link',
            prefix: Text(
              '${widget.origin}/${widget.path}/',
              style: t.text.small,
            ),
            errorText: valid || slug.isEmpty
                ? null
                : 'Lowercase letters, digits and dashes',
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SsButton(
          key: const ValueKey<String>('publish:submit'),
          label: 'Publish',
          variant: SsButtonVariant.primary,
          onPressed: valid ? _submit : null,
        ),
      ],
    );
  }
}

/// Shows the published link with Copy and Open.
Future<void> showPublishedDialog(
  BuildContext context, {
  required String url,
  required int version,
  required List<String> warnings,
  required VoidCallback onOpen,
}) => showSsDialog<void>(
  context,
  builder: (ctx) {
    final t = ctx.ss;
    return SsDialog(
      title: version == 1 ? 'Published' : 'Published version $version',
      width: 440,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(url, style: t.text.body),
          for (final w in warnings) ...[
            const SizedBox(height: SsSpace.s2),
            Text(w, style: t.text.small.copyWith(color: t.colors.warning)),
          ],
        ],
      ),
      actions: [
        SsButton(
          label: 'Copy link',
          icon: SsIcons.copy,
          onPressed: () => Clipboard.setData(ClipboardData(text: url)),
        ),
        SsButton(
          label: 'Open',
          variant: SsButtonVariant.primary,
          onPressed: () {
            Navigator.of(ctx).pop();
            onOpen();
          },
        ),
      ],
    );
  },
);
