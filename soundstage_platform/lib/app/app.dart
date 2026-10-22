import 'package:flutter/material.dart';

import 'demo_harness.dart';
import 'motion_demo.dart';
import 'sound_demo.dart';

/// Root of the Soundstage web app.
///
/// `?demo=spike` (the default) is the T0.8 spike story; `?wheel=native`
/// turns the mouse-wheel smoothing off.
///
/// During M0 this is a development harness for the runtime ([DemoHarness]);
/// the editor and player routes arrive in M1 (`docs/roadmap.md`).
class SoundstageApp extends StatelessWidget {
  const SoundstageApp({super.key});

  @override
  Widget build(BuildContext context) {
    final demo = Uri.base.queryParameters['demo'];
    return MaterialApp(
      title: 'Soundstage',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: switch (demo) {
          'motion' => const MotionDemoHarness(),
          'sound' => const SoundDemoHarness(),
          'static' || 'gallery' => const DemoHarness(),
          _ => const SoundDemoHarness(
            asset: kSpikeDemoAsset,
            coverFocal: Offset(0.62, 0.40),
            buildOnEnter: true,
          ),
        },
      ),
    );
  }
}
