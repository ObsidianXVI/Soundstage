import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/gate.dart';
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

/// The signed-in author's handle; asks them to choose one the first time
/// (DECISIONS 26/10/26 "Handles and URLs"). Null when cancelled or it
/// could not be read.
Future<String?> ensureHandle(BuildContext context, Cloud cloud) async {
  try {
    final h = await cloud.backend.handle();
    if (h != null || !context.mounted) return h;
  } on Object {
    if (context.mounted) {
      SsToast.show(
        context,
        'Could not reach Soundstage. Check the network.',
        kind: SsToastKind.danger,
      );
    }
    return null;
  }
  return showSsDialog<String>(
    context,
    builder: (ctx) => _HandleDialog(
      backend: cloud.backend,
      suggested: handleFor(cloud.auth.currentUser?.email ?? ''),
    ),
  );
}

class _HandleDialog extends StatefulWidget {
  const _HandleDialog({required this.backend, required this.suggested});

  final CloudBackend backend;
  final String suggested;

  @override
  State<_HandleDialog> createState() => _HandleDialogState();
}

class _HandleDialogState extends State<_HandleDialog> {
  late final _handle = TextEditingController(text: widget.suggested);
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _handle.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final h = _handle.text.trim();
    if (!isValidHandle(h)) return setState(() {});
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.backend.claimHandle(h, name: _name.text.trim());
      if (mounted) Navigator.of(context).pop(h);
    } on PublishException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not save the handle: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final h = _handle.text.trim();
    final valid = isValidHandle(h);
    return SsDialog(
      title: 'Choose your handle',
      width: 440,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Everything you publish lives under your handle. It cannot be '
            'changed later.',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: SsSpace.s3),
          SsTextField(
            key: const ValueKey<String>('handle:handle'),
            controller: _handle,
            autofocus: true,
            selectAllOnFocus: true,
            semanticLabel: 'Handle',
            prefix: Text('${Uri.base.origin}/@', style: t.text.small),
            errorText: valid || h.isEmpty
                ? _error
                : '3–30 lowercase letters, digits and dashes',
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: SsSpace.s2),
          SsTextField(
            key: const ValueKey<String>('handle:name'),
            controller: _name,
            placeholder: 'Display name (optional)',
            semanticLabel: 'Display name',
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        SsButton(
          label: 'Cancel',
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        SsButton(
          key: const ValueKey<String>('handle:submit'),
          label: _busy ? 'Saving…' : 'Use this handle',
          variant: SsButtonVariant.primary,
          onPressed: valid && !_busy ? _submit : null,
        ),
      ],
    );
  }
}

/// What the author chose in the publish dialog.
class PublishChoice {
  const PublishChoice({
    required this.slug,
    this.audience = Audience.public,
    this.password,
    this.readers,
  });

  final String slug;
  final Audience audience;

  /// A new password (password audience), or null to keep the current one.
  final String? password;

  /// A new readers list (readers audience), or null to keep the current
  /// one.
  final List<String>? readers;
}

final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+$');

/// The emails in [text] (separated by commas, spaces or lines), lowercase.
List<String> parseReaders(String text) => {
  for (final e in text.split(RegExp(r'[\s,;]+')))
    if (e.trim().isNotEmpty) e.trim().toLowerCase(),
}.toList();

/// Stores [choice]'s password or readers for record [docPath] with the
/// gate; a warning when it fails (null when done or nothing changed).
Future<String?> setGateFor(
  GateClient gate,
  Cloud cloud,
  String docPath,
  PublishChoice choice,
) async {
  if (choice.password == null && choice.readers == null) return null;
  try {
    final token = await cloud.auth.currentUser?.getIdToken();
    if (token == null) return 'Sign in again to set who can read it.';
    await gate.setSecret(
      docPath,
      idToken: token,
      password: choice.password,
      readers: choice.readers,
    );
    return null;
  } on Object catch (e) {
    return 'Readers cannot open it yet: $e. Publish again to retry.';
  }
}

/// Asks for the published link of a story or publication and who can read
/// it (m7.md T7.4): [suggested] is prefilled after [prefix] (the link up
/// to the slug); [audience] is the current audience. [valid] checks the
/// slug (default [isValidSlug]). Null when cancelled.
Future<PublishChoice?> showPublishDialog(
  BuildContext context, {
  required String title,
  required String suggested,
  required String prefix,
  String? note,
  String action = 'Publish',
  Audience audience = Audience.public,
  bool published = false,
  bool Function(String slug) valid = isValidSlug,
}) => showSsDialog<PublishChoice>(
  context,
  builder: (ctx) => _PublishDialog(
    title: title,
    suggested: suggested,
    prefix: prefix,
    note: note,
    action: action,
    current: audience,
    published: published,
    valid: valid,
  ),
);

class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.title,
    required this.suggested,
    required this.prefix,
    required this.action,
    required this.current,
    required this.published,
    required this.valid,
    this.note,
  });

  final String title;
  final String suggested;
  final String prefix;
  final String? note;
  final String action;
  final Audience current;

  /// Whether earlier versions exist (crossing public ↔ private removes
  /// them).
  final bool published;
  final bool Function(String slug) valid;

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  late final _slug = TextEditingController(text: widget.suggested);
  final _password = TextEditingController();
  final _readers = TextEditingController();
  late Audience _audience = widget.current;

  @override
  void dispose() {
    _slug.dispose();
    _password.dispose();
    _readers.dispose();
    super.dispose();
  }

  /// Why the audience settings cannot be used yet, or null.
  String? get _audienceProblem {
    switch (_audience) {
      case Audience.password:
        final p = _password.text;
        if (p.isEmpty && widget.current == Audience.password) return null;
        return p.length < 4 ? 'Use at least 4 characters' : null;
      case Audience.readers:
        final list = parseReaders(_readers.text);
        if (list.isEmpty && widget.current == Audience.readers) return null;
        if (list.isEmpty) return 'Add at least one email';
        final bad = list.where((e) => !_emailPattern.hasMatch(e)).firstOrNull;
        return bad == null ? null : '"$bad" is not an email';
      case Audience.public || Audience.unlisted:
        return null;
    }
  }

  void _submit() {
    final slug = _slug.text.trim();
    if (!widget.valid(slug) || _audienceProblem != null) {
      setState(() {});
      return;
    }
    final readers = parseReaders(_readers.text);
    Navigator.of(context).pop(
      PublishChoice(
        slug: slug,
        audience: _audience,
        password: _audience == Audience.password && _password.text.isNotEmpty
            ? _password.text
            : null,
        readers: _audience == Audience.readers && readers.isNotEmpty
            ? readers
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final slug = _slug.text.trim();
    final valid = widget.valid(slug);
    final problem = _audienceProblem;
    final crossing =
        widget.published && widget.current.gated != _audience.gated;
    return SsDialog(
      title: '${widget.action} "${widget.title}"',
      width: 460,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.note ?? 'Publishing again adds a version and makes it live.',
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: SsSpace.s3),
          SsTextField(
            key: const ValueKey<String>('publish:slug'),
            controller: _slug,
            autofocus: true,
            selectAllOnFocus: true,
            semanticLabel: 'Link',
            prefix: Text(widget.prefix, style: t.text.small),
            errorText: valid || slug.isEmpty
                ? null
                : 'Lowercase letters, digits and dashes',
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: SsSpace.s4),
          Text('WHO CAN READ IT', style: t.text.overline),
          const SizedBox(height: SsSpace.s2),
          SsSegmented<Audience>(
            key: const ValueKey<String>('publish:audience'),
            semanticLabel: 'Who can read it',
            expand: true,
            segments: [
              for (final a in Audience.values)
                SsSegment(value: a, label: a.label),
            ],
            selected: _audience,
            onChanged: (a) => setState(() => _audience = a),
          ),
          const SizedBox(height: SsSpace.s2),
          Text(
            _audience.description,
            style: t.text.small.copyWith(color: t.colors.textSecondary),
          ),
          if (_audience == Audience.password) ...[
            const SizedBox(height: SsSpace.s2),
            SsTextField(
              key: const ValueKey<String>('publish:password'),
              controller: _password,
              obscureText: true,
              semanticLabel: 'Password',
              placeholder: widget.current == Audience.password
                  ? 'New password (empty keeps the current one)'
                  : 'Password',
              autofillHints: const [AutofillHints.newPassword],
              errorText: _password.text.isEmpty ? null : problem,
              onChanged: (_) => setState(() {}),
            ),
          ],
          if (_audience == Audience.readers) ...[
            const SizedBox(height: SsSpace.s2),
            SsTextField(
              key: const ValueKey<String>('publish:readers'),
              controller: _readers,
              maxLines: 4,
              semanticLabel: 'Readers',
              placeholder: widget.current == Audience.readers
                  ? 'Emails, one per line (empty keeps the current list)'
                  : 'Emails, one per line',
              errorText: _readers.text.isEmpty ? null : problem,
              onChanged: (_) => setState(() {}),
            ),
          ],
          if (crossing) ...[
            const SizedBox(height: SsSpace.s2),
            Text(
              _audience.gated
                  ? 'Earlier public versions are removed, so only your '
                        'readers can open it.'
                  : 'Earlier private versions are removed.',
              style: t.text.small.copyWith(color: t.colors.warning),
            ),
          ],
        ],
      ),
      actions: [
        SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SsButton(
          key: const ValueKey<String>('publish:submit'),
          label: widget.action,
          variant: SsButtonVariant.primary,
          onPressed: valid && problem == null ? _submit : null,
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
