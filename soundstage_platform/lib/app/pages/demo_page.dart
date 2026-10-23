import 'package:flutter/material.dart';
import 'package:soundstage_platform/app/demo_harness.dart';
import 'package:soundstage_platform/app/motion_demo.dart';
import 'package:soundstage_platform/app/sound_demo.dart';

import 'not_found_page.dart';

/// The demo names `/demo/:name` accepts.
const List<String> kDemoNames = <String>[
  'static',
  'gallery',
  'motion',
  'sound',
  'spike',
];

/// `/demo/:name`: the M0 harnesses. `?wheel=native` turns wheel smoothing
/// off and `?stats=1` logs measurements, as before.
class DemoPage extends StatelessWidget {
  const DemoPage({
    required this.name,
    this.wheelNative,
    this.statsOn,
    super.key,
  });

  final String name;
  final bool? wheelNative;
  final bool? statsOn;

  @override
  Widget build(BuildContext context) {
    final Widget? body = switch (name) {
      'static' || 'gallery' => DemoHarness(demoKey: name),
      'motion' => MotionDemoHarness(wheelNative: wheelNative),
      'sound' => SoundDemoHarness(wheelNative: wheelNative, statsOn: statsOn),
      'spike' => SoundDemoHarness(
        asset: kSpikeDemoAsset,
        coverFocal: const Offset(0.62, 0.40),
        buildOnEnter: true,
        wheelNative: wheelNative,
        statsOn: statsOn,
      ),
      _ => null,
    };
    if (body == null) {
      return NotFoundPage(
        message: 'Unknown demo "$name". Try: ${kDemoNames.join(', ')}.',
      );
    }
    return Scaffold(body: body);
  }
}
