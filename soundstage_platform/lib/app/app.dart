import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'router.dart';

/// Root of the Soundstage web app: the router plus the editor-chrome theme.
///
/// Routes are in [buildRouter]. The old `?demo=` URLs redirect to
/// `/demo/:name`.
class SoundstageApp extends StatefulWidget {
  const SoundstageApp({this.router, super.key});

  /// Overrides the router (tests start at a given location).
  final GoRouter? router;

  @override
  State<SoundstageApp> createState() => _SoundstageAppState();
}

class _SoundstageAppState extends State<SoundstageApp> {
  late final GoRouter _router = widget.router ?? buildRouter();

  @override
  void dispose() {
    if (widget.router == null) _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = SsThemeData.dark();
    return MaterialApp.router(
      title: 'Soundstage',
      debugShowCheckedModeBanner: false,
      theme: theme.toMaterial(),
      routerConfig: _router,
      builder: (context, child) =>
          SsScope(theme: theme, child: child ?? const SizedBox.shrink()),
    );
  }
}
