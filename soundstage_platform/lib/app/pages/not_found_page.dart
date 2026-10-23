import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// Shown for unknown routes, stories and demos.
class NotFoundPage extends StatelessWidget {
  const NotFoundPage({this.message = 'Page not found', super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Scaffold(
      backgroundColor: t.colors.surface0,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(SsSpace.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, style: t.text.title, textAlign: TextAlign.center),
              const SizedBox(height: SsSpace.s4),
              SsButton(
                label: 'Back to stories',
                variant: SsButtonVariant.primary,
                onPressed: () => context.go('/'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
