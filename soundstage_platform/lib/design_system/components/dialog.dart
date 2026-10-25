import 'package:flutter/material.dart';

import '../tokens/elevation.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'button.dart';
import 'text_field.dart';

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

/// A one-field text dialog ("Rename collection"). Resolves to the trimmed
/// text on confirm (Enter or the confirm button), or null on cancel or
/// when the text is empty.
Future<String?> showSsPrompt(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String confirmLabel = 'Save',
  String? placeholder,
}) => showSsDialog<String>(
  context,
  builder: (_) => _SsPrompt(
    title: title,
    initialValue: initialValue,
    confirmLabel: confirmLabel,
    placeholder: placeholder,
  ),
);

class _SsPrompt extends StatefulWidget {
  const _SsPrompt({
    required this.title,
    required this.initialValue,
    required this.confirmLabel,
    this.placeholder,
  });

  final String title;
  final String initialValue;
  final String confirmLabel;
  final String? placeholder;

  @override
  State<_SsPrompt> createState() => _SsPromptState();
}

class _SsPromptState extends State<_SsPrompt> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _text.text.trim();
    Navigator.of(context).pop(v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) => SsDialog(
    title: widget.title,
    width: 320,
    content: SsTextField(
      controller: _text,
      autofocus: true,
      selectAllOnFocus: true,
      placeholder: widget.placeholder,
      semanticLabel: widget.title,
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
      SsButton(
        label: widget.confirmLabel,
        variant: SsButtonVariant.primary,
        onPressed: _submit,
      ),
    ],
  );
}
