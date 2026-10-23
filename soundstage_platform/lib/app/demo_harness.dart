import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// The bundled demo story the M0 harness renders.
const String kDemoDocumentAsset = 'assets/demo/static.stage.json';

/// The bundled demos the harness can switch between (`?demo=<key>`).
const Map<String, String> kDemoDocuments = {
  'static': kDemoDocumentAsset,
  'gallery': 'assets/demo/paint_gallery.stage.json',
};

/// The selected demo key: the `demo` query parameter, else `static`.
class DemoSelection extends Notifier<String> {
  @override
  String build() {
    return 'static';
  }

  void select(String key) {
    if (kDemoDocuments.containsKey(key)) state = key;
  }
}

final demoSelectionProvider = NotifierProvider<DemoSelection, String>(
  DemoSelection.new,
);

/// The demo document, loaded and migrated from the app bundle.
final demoDocumentProvider = FutureProvider<ir.StageDocument>((ref) async {
  final key = ref.watch(demoSelectionProvider);
  final text = await rootBundle.loadString(kDemoDocuments[key]!);
  final json = jsonDecode(text) as Map<String, Object?>;
  return ir.StageDocument.fromJsonMigrating(json);
});

/// The runtime environment for the demo document (fonts, media and the
/// decoded-image cache). Kept for the document's lifetime.
final demoEnvironmentProvider = Provider<StageEnvironment?>((ref) {
  final doc = ref.watch(demoDocumentProvider).value;
  if (doc == null) return null;
  final env = StageEnvironment.forDocument(doc);
  ref.onDispose(() => env.media?.cache.clear());
  return env;
});

/// The demo document resolved for a breakpoint id. Watched per breakpoint,
/// so resizing within a breakpoint never re-resolves.
final resolvedDemoProvider = Provider.family<ir.ResolvedDocument?, String>((
  ref,
  breakpointId,
) {
  final doc = ref.watch(demoDocumentProvider).value;
  if (doc == null) return null;
  return ir.resolveDocument(doc, ir.ResolveContext(breakpointId: breakpointId));
});

/// The M0 development harness: renders every scene of the demo document,
/// stacked in a plain scroll view, at the window's size. Scroll-driven
/// pinning and motion arrive with `StagePlayer` (T0.6).
class DemoHarness extends ConsumerStatefulWidget {
  /// [demoKey] selects the demo (`static` or `gallery`); null keeps the
  /// provider's current selection.
  const DemoHarness({super.key, this.demoKey});

  final String? demoKey;

  @override
  ConsumerState<DemoHarness> createState() => _DemoHarnessState();
}

class _DemoHarnessState extends ConsumerState<DemoHarness> {
  @override
  void initState() {
    super.initState();
    _apply();
  }

  @override
  void didUpdateWidget(DemoHarness old) {
    super.didUpdateWidget(old);
    if (old.demoKey != widget.demoKey) _apply();
  }

  void _apply() {
    final k = widget.demoKey;
    if (k == null) return;
    // Providers may not be modified during build; do it right after.
    Future<void>.microtask(() {
      if (mounted) ref.read(demoSelectionProvider.notifier).select(k);
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (ref.watch(demoDocumentProvider)) {
      AsyncData(:final value) => Stack(
        children: [
          _DemoStage(document: value),
          const Positioned(top: 8, right: 8, child: _DemoPicker()),
        ],
      ),
      AsyncError(:final error) => Center(
        child: Text('Could not load the demo document: $error'),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _DemoStage extends ConsumerWidget {
  const _DemoStage({required this.document});

  final ir.StageDocument document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final env = ref.watch(demoEnvironmentProvider);
    if (env == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final bp = ir.breakpointForWidth(document, viewport.width);
        final resolved = ref.watch(resolvedDemoProvider(bp?.id ?? ''));
        if (resolved == null) return const SizedBox.shrink();
        return StageScope(
          environment: env,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final scene in resolved.scenes)
                  StageSceneView(
                    key: ValueKey<String>(scene.id),
                    scene: scene,
                    viewportSize: viewport,
                    breakpoint: resolved.breakpoint,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A minimal switcher between the bundled demos.
class _DemoPicker extends ConsumerWidget {
  const _DemoPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: const Color(0xCC000000),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: DropdownButton<String>(
          value: ref.watch(demoSelectionProvider),
          dropdownColor: const Color(0xFF202028),
          underline: const SizedBox.shrink(),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: [
            for (final k in kDemoDocuments.keys)
              DropdownMenuItem(value: k, child: Text(k)),
          ],
          onChanged: (k) {
            if (k == null) return;
            final router = GoRouter.maybeOf(context);
            if (router != null) {
              router.go('/demo/$k');
            } else {
              ref.read(demoSelectionProvider.notifier).select(k);
            }
          },
        ),
      ),
    );
  }
}
