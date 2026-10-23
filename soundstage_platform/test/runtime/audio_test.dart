import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// A player whose reported position only updates when [report] is called
/// (like a platform that sends coarse position events).
class FakeAudioBackend implements StageAudioBackend {
  double truePosition = 0;
  double reported = 0;
  bool isPlaying = false;
  bool loop = false;
  double volume = 1;
  final List<double> volumes = [];
  String? loadedUri;
  int plays = 0;
  @override
  double? duration = 30;

  void report() => reported = truePosition;

  /// Advances the true position by [dt] while playing.
  void run(double dt) {
    if (isPlaying) truePosition += dt;
  }

  @override
  Future<void> load(String uri) async => loadedUri = uri;
  @override
  void play() {
    isPlaying = true;
    plays++;
  }

  @override
  Future<void> pause() async => isPlaying = false;
  @override
  Future<void> seek(double seconds) async {
    truePosition = seconds;
    reported = seconds;
  }

  @override
  Future<void> setVolume(double v) async {
    volume = v;
    volumes.add(v);
  }

  @override
  Future<void> setLoop(bool l) async => loop = l;
  @override
  double get position => reported;
  @override
  bool get playing => isPlaying;
  @override
  double get speed => 1;
  @override
  Future<void> dispose() async {}
}

const ir.Asset _clip = ir.Asset(
  id: 'clip',
  kind: ir.AssetKind.audio,
  uri: 'asset://assets/demo/audio/lights_go_low.wav',
);

(StageAudioService, Map<String, FakeAudioBackend>) _service(
  List<ir.AudioTrack> tracks,
) {
  final backends = <FakeAudioBackend>[];
  final service = StageAudioService(
    tracks: tracks,
    assets: const {'clip': _clip},
    createBackend: () {
      final b = FakeAudioBackend();
      backends.add(b);
      return b;
    },
    autoTick: false,
  );
  return (service, {for (final (i, t) in tracks.indexed) t.id: backends[i]});
}

void main() {
  group('audio clock', () {
    test('interpolates smoothly between coarse position updates', () async {
      final (service, b) = _service([
        const ir.AudioTrack(id: 'song', assetId: 'clip', autoplay: true),
      ]);
      await service.unlock();
      final backend = b['song']!;
      expect(backend.isPlaying, isTrue);
      expect(backend.loadedUri, _clip.uri);
      final clock = service.clockSource(
        const ir.Clock.audio(id: 'c', audioTrackId: 'song'),
        sceneId: 's',
      )!;
      expect(clock.isActive, isTrue);

      const dt = 1 / 60;
      var last = clock.value;
      var maxErr = 0.0;
      var stalls = 0;
      for (var f = 0; f < 240; f++) {
        backend.run(dt);
        if (f % 15 == 0) backend.report(); // 4 updates per second
        clock.advance(dt);
        final v = clock.value;
        expect(v, greaterThanOrEqualTo(last), reason: 'never backwards');
        if (v == last) stalls++;
        last = v;
        if (f > 30) {
          maxErr = (v - backend.truePosition).abs() > maxErr
              ? (v - backend.truePosition).abs()
              : maxErr;
        }
      }
      expect(stalls, 0, reason: 'moves every frame');
      expect(maxErr, lessThan(0.03));
      // The raw reported position lags by up to 0.25 s.
      expect(backend.truePosition - backend.reported, greaterThan(0));
    });

    test('seeks resynchronise at once and notify listeners', () async {
      final (service, b) = _service([
        const ir.AudioTrack(id: 'song', assetId: 'clip', autoplay: true),
      ]);
      await service.unlock();
      final clock = service.clockSource(
        const ir.Clock.audio(id: 'c', audioTrackId: 'song'),
        sceneId: 's',
      )!;
      var notified = 0;
      service.addClockListener(() => notified++);
      clock.advance(1 / 60);
      await service.seek('song', 12.5);
      expect(notified, 1);
      clock.advance(0);
      expect(clock.value, 12.5);
      // Backwards seeks too.
      await service.seek('song', 2);
      clock.advance(1 / 60);
      expect(clock.value, 2);
      // Paused: the reported position.
      service.pause('song');
      b['song']!.reported = 3;
      clock.advance(1 / 60);
      expect(clock.value, 3);
      expect(clock.isActive, isFalse);
    });

    test('an unknown track has no source', () {
      final (service, _) = _service(const []);
      expect(
        service.clockSource(
          const ir.Clock.audio(id: 'c', audioTrackId: 'nope'),
          sceneId: 's',
        ),
        isNull,
      );
    });
  });

  group('service', () {
    test('nothing plays before unlock', () async {
      final (service, b) = _service([
        const ir.AudioTrack(id: 'a', assetId: 'clip', autoplay: true),
      ]);
      await service.preload();
      service.play('a');
      expect(b['a']!.isPlaying, isFalse);
      expect(service.unlocked, isFalse);
    });

    test('scene tracks fade in on enter and fade out on leave', () async {
      final (service, b) = _service([
        const ir.AudioTrack(
          id: 'a',
          assetId: 'clip',
          scope: ir.AudioScope.scene('lyric'),
          autoplay: true,
          loop: true,
          volume: 0.8,
          fadeIn: 1,
          fadeOut: 0.5,
        ),
      ]);
      final backend = b['a']!;
      await service.unlock();
      expect(backend.isPlaying, isFalse, reason: 'scene not on screen');
      expect(backend.loop, isTrue);

      service.sceneVisibilityChanged('lyric', visible: true);
      expect(backend.isPlaying, isTrue);
      expect(backend.volume, 0);
      service.advance(0.5);
      expect(backend.volume, closeTo(0.4, 1e-9));
      service.advance(0.6);
      expect(backend.volume, closeTo(0.8, 1e-9));

      service.sceneVisibilityChanged('lyric', visible: false);
      expect(backend.isPlaying, isTrue, reason: 'fading out');
      service.advance(0.25);
      expect(backend.volume, closeTo(0.4, 1e-9));
      service.advance(0.3);
      expect(backend.isPlaying, isFalse);

      // Re-entering resumes (no restart).
      backend.truePosition = backend.reported = 7;
      service.sceneVisibilityChanged('lyric', visible: true);
      expect(backend.isPlaying, isTrue);
      expect(backend.truePosition, 7);
    });

    test('tracks that do not loop fade out before their end', () async {
      final (service, b) = _service([
        const ir.AudioTrack(
          id: 'a',
          assetId: 'clip',
          autoplay: true,
          fadeOut: 2,
        ),
      ]);
      await service.unlock();
      final backend = b['a']!
        ..duration = 10
        ..reported = 8.5;
      service.advance(0);
      service.advance(0.75);
      expect(backend.volume, closeTo(0.5, 1e-9));
    });

    test('a missing asset stays silent', () async {
      final (service, b) = _service([
        const ir.AudioTrack(id: 'a', assetId: 'missing', autoplay: true),
      ]);
      await service.unlock();
      expect(b['a']!.isPlaying, isFalse);
      expect(service.track('a')!.loadError, isNotNull);
    });
  });

  group('enter gate', () {
    const doc = ir.StageDocument(
      id: 'd',
      breakpoints: [],
      meta: ir.StageMeta(title: 'Night Songs', description: 'A test'),
      audioTracks: [ir.AudioTrack(id: 'a', assetId: 'clip', autoplay: true)],
      assets: {'clip': _clip},
    );

    Future<(StageAudioService, FakeAudioBackend, List<int>)> pump(
      WidgetTester tester,
    ) async {
      final (service, b) = _service(doc.audioTracks);
      final entered = <int>[];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(800, 600)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: StageEnterGate(
              document: doc,
              environment: const StageEnvironment(),
              audio: service,
              onEntered: () => entered.add(1),
              child: const Text('the stage'),
            ),
          ),
        ),
      );
      return (service, b['a']!, entered);
    }

    testWidgets('keyboard Enter unlocks audio, waits, then fades away', (
      tester,
    ) async {
      final (service, backend, entered) = await pump(tester);
      expect(find.text('Night Songs'), findsOneWidget);
      expect(find.text(kStageEnterLabel), findsOneWidget);
      expect(backend.isPlaying, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(service.unlocked, isTrue);
      expect(backend.isPlaying, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Night Songs'), findsNothing);
      expect(find.text('the stage'), findsOneWidget);
      expect(entered, [1]);
    });

    testWidgets('Space and tap also enter; only once', (tester) async {
      final (_, backend, entered) = await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.tap(find.text('Night Songs'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(backend.plays, 1);
      expect(entered, [1]);
    });

    testWidgets('screen readers see a labelled button', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('Enter the stage'))),
        matchesSemantics(
          label: 'Enter the stage: Night Songs',
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      handle.dispose();
    });
  });
}
