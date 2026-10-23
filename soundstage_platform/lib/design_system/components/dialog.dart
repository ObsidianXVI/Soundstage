import 'package:flutter/material.dart';

import '../tokens/elevation.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'button.dart';

/// A dialog card: title, content, and an action row.
class SsDialog extends StatelessWidget {
  const SsDialog({
    required this.title,
    required this.content,
    this.actions = const <Widget>[],
    this.width = 400,
    super.key,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: Container(
        width: width,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - SsSpace.s8,
        ),
        padding: const EdgeInsets.all(SsSpace.s5),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: SsRadius.brXl,
          border: Border.all(color: c.border),
          boxShadow: SsElevation.e3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: t.text.title),
            const SizedBox(height: SsSpace.s3),
            DefaultTextStyle(
              style: t.text.large.copyWith(color: c.textSecondary),
              child: content,
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: SsSpace.s5),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: SsSpace.s2,
                runSpacing: SsSpace.s2,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows [dialog] modally. Focus is trapped in the dialog's route, Escape
/// and (when [dismissible]) a press on the scrim close it, and focus returns
/// to the opener.
Future<T?> showSsDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  final theme = SsTheme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close dialog',
    barrierColor: theme.colors.scrim,
    transitionDuration: SsMotion.base,
    pageBuilder: (ctx, _, _) => SsScope(
      theme: theme,
      child: SafeArea(child: Center(child: builder(ctx))),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: SsMotion.easeOut);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// A confirm/cancel dialog. Resolves true on confirm.
Future<bool> showSsConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final r = await showSsDialog<bool>(
    context,
    builder: (ctx) => SsDialog(
      title: title,
      content: Text(message),
      actions: [
        SsButton(
          label: cancelLabel,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        SsButton(
          label: confirmLabel,
          variant: danger ? SsButtonVariant.danger : SsButtonVariant.primary,
          autofocus: true,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return r ?? false;
}
