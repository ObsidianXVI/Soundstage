import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'sound_demo.dart' show demoWheelSmoothing;

/// The T0.6 motion demo (open the app with `?demo=motion`).
const String kMotionDemoAsset = 'assets/demo/motion.stage.json';

/// The motion demo document, loaded and migrated from the app bundle.
final motionDemoDocumentProvider = FutureProvider<ir.StageDocument>((
  ref,
) async {
  final text = await rootBundle.loadString(kMotionDemoAsset);
  final json = jsonDecode(text) as Map<String, Object?>;
  return ir.StageDocument.fromJsonMigrating(json);
});

/// Plays the motion demo in a [StagePlayer].
class MotionDemoHarness extends ConsumerWidget {
  const MotionDemoHarness({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(motionDemoDocumentProvider)) {
      AsyncData(:final value) => StagePlayer(
        document: value,
        wheelSmoothing: demoWheelSmoothing(),
      ),
      AsyncError(:final error) => Center(
        child: Text('Could not load the motion demo: $error'),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}
