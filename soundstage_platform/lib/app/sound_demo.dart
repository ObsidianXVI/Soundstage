import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'debug_hooks_stub.dart'
    if (dart.library.js_interop) 'debug_hooks_web.dart';

/// The T0.7 sound demo (open the app with `?demo=sound`).
const String kSoundDemoAsset = 'assets/demo/sound.stage.json';

/// The T0.8 spike demo (`?demo=spike`, the harness default).
const String kSpikeDemoAsset = 'assets/demo/spike.stage.json';

/// The mouse-wheel smoothing for the demos: on by default, off with
/// `?wheel=native` (to compare against the browser's own wheel scrolling).
///
/// [native] is the routed `wheel=native` flag; null falls back to the
/// browser's current URL.
StageWheelSmoothing? demoWheelSmoothing([bool? native]) =>
    (native ?? Uri.base.queryParameters['wheel'] == 'native')
    ? null
    : const StageWheelSmoothing();

/// A bundled audio demo document, loaded and migrated from the app bundle.
final audioDemoDocumentProvider =
    FutureProvider.family<ir.StageDocument, String>((ref, asset) async {
      final text = await rootBundle.loadString(asset);
      final json = jsonDecode(text) as Map<String, Object?>;
      return ir.StageDocument.fromJsonMigrating(json);
    });

/// Plays the sound demo behind the enter gate, with its audio.
class SoundDemoHarness extends ConsumerWidget {
  const SoundDemoHarness({
    super.key,
    this.asset = kSoundDemoAsset,
    this.coverFocal = const Offset(0.68, 0.42),
    this.buildOnEnter = false,
    this.wheelNative,
    this.statsOn,
  });

  final String asset;
  final Offset coverFocal;
  final bool buildOnEnter;

  /// The `?wheel=native` flag (null: read the browser URL).
  final bool? wheelNative;

  /// The `?stats=1` flag (null: read the browser URL).
  final bool? statsOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(audioDemoDocumentProvider(asset))) {
      AsyncData(:final value) => GatedStagePlayer(
        document: value,
        coverFocal: coverFocal,
        buildOnEnter: buildOnEnter,
        wheelNative: wheelNative,
        statsOn: statsOn,
      ),
      AsyncError(:final error) => Center(
        child: Text('Could not load the sound demo: $error'),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

/// A story behind the enter gate, with its audio: the player the demos and
/// `/play/:id` use.
class GatedStagePlayer extends StatefulWidget {
  const GatedStagePlayer({
    super.key,
    required this.document,
    this.coverFocal = const Offset(0.5, 0.5),
    this.buildOnEnter = false,
    this.wheelNative,
    this.statsOn,
  });

  final ir.StageDocument document;
  final Offset coverFocal;
  final bool buildOnEnter;
  final bool? wheelNative;
  final bool? statsOn;

  @override
  State<GatedStagePlayer> createState() => _GatedStagePlayerState();
}

class _GatedStagePlayerState extends State<GatedStagePlayer> {
  late final StageEnvironment _env = StageEnvironment.forDocument(
    widget.document,
  );
  late final StageAudioService _audio = StageAudioService.forDocument(
    widget.document,
  );

  /// `?stats=1`: logs the decoded-image cache once a second (T0.8 memory
  /// measurement; read it from the browser console).
  Timer? _stats;
  final StagePlayerController _controller = StagePlayerController();
  late final bool _statsOn =
      widget.statsOn ?? Uri.base.queryParameters['stats'] == '1';

  /// Logs a load milestone as a wall-clock time (compare with
  /// `performance.timeOrigin` in the page).
  void _mark(String what) {
    if (_statsOn) {
      // ignore: avoid_print
      print('[stats] $what epoch=${DateTime.now().millisecondsSinceEpoch}');
    }
  }

  @override
  void initState() {
    super.initState();
    if (_statsOn) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _mark('gate-frame'));
      _publishAudioClock();
      // The scroll offset, for scripted measurements (`window.__ss_offset`).
      _stats = Timer.periodic(const Duration(milliseconds: 100), (t) {
        publishDebugValue(
          '__ss_offset',
          _controller.scrollController?.offset ?? -1,
        );
        if (t.tick % 10 != 0) return;
        final c = _env.media?.cache;
        if (c != null) {
          // ignore: avoid_print
          print('[stats] images=${c.length} decodedBytes=${c.currentBytes}');
        }
      });
    }
  }

  /// Drift measurement: an independent audio clock source, advanced every
  /// frame the way the animator advances its own, published as
  /// `window.__ss_audio_clock` (compare with the `<audio>` element's
  /// `currentTime`).
  void _publishAudioClock() {
    final track = _audio.tracks.firstOrNull;
    final source = track == null ? null : StageAudioClockSource(track);
    Duration? last;
    SchedulerBinding.instance.addPersistentFrameCallback((t) {
      final dt = last == null ? 0.0 : (t - last!).inMicroseconds / 1e6;
      last = t;
      // The scroll offset at the end of every frame (feel measurements).
      publishDebugValue(
        '__ss_offset_f',
        _controller.scrollController?.offset ?? -1,
      );
      if (source != null) {
        source.advance(dt);
        publishDebugValue('__ss_audio_clock', source.value);
      }
    });
  }

  @override
  void dispose() {
    _stats?.cancel();
    _audio.dispose();
    _env.media?.cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StageEnterGate(
      document: widget.document,
      environment: _env,
      audio: _audio,
      coverFocal: widget.coverFocal,
      onReady: () => _mark('gate-ready'),
      onEntered: _controller.requestFocus,
      onEnter: () {
        _mark('enter');
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _mark('hero-frame'),
        );
      },
      buildChildOnEnter: widget.buildOnEnter,
      child: StagePlayer(
        document: widget.document,
        environment: _env,
        audio: _audio,
        controller: _controller,
        wheelSmoothing: demoWheelSmoothing(widget.wheelNative),
      ),
    );
  }
}
