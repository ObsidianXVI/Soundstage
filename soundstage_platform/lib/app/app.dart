import 'package:flutter/material.dart';

/// Root of the Soundstage web app.
///
/// During M0 this is a development harness for the runtime; the editor and
/// player routes arrive in M1 (`docs/roadmap.md`).
class SoundstageApp extends StatelessWidget {
  const SoundstageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Soundstage',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(child: Text('Soundstage')),
      ),
    );
  }
}
