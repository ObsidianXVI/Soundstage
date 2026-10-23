import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/app.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/demo_harness.dart';
import 'package:soundstage_platform/app/motion_demo.dart';
import 'package:soundstage_platform/app/pages/not_found_page.dart';
import 'package:soundstage_platform/app/router.dart';
import 'package:soundstage_platform/app/sound_demo.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/shell/content_mode_screen.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

final String _blank = jsonEncode(
  ir.StageDocument.empty(
    ids: ir.IdGenerator.seeded(7),
    meta: const ir.StageMeta(title: 'Blank'),
  ).toJson(),
);

class _App {
  _App(this.router, this.repo);
  final GoRouter router;
  final InMemoryStoryRepository repo;
  Uri get uri => router.routeInformationProvider.value.uri;
}

Future<_App> _pump(
  WidgetTester tester,
  String location, {
  Size size = const Size(1440, 900),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = InMemoryStoryRepository(loadAsset: (_) async => _blank);
  final router = buildRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storyRepositoryProvider.overrideWithValue(repo)],
      child: SoundstageApp(router: router),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return _App(router, repo);
}

void main() {
  group('redirectLegacyDemo', () {
    test('maps ?demo= to /demo/:name and keeps the other flags', () {
      expect(redirectLegacyDemo(Uri.parse('/?demo=motion')), '/demo/motion');
      expect(
        redirectLegacyDemo(Uri.parse('/?demo=sound&wheel=native&stats=1')),
        '/demo/sound?wheel=native&stats=1',
      );
      expect(redirectLegacyDemo(Uri.parse('/?demo=static')), '/demo/static');
    });

    test('leaves everything else alone', () {
      expect(redirectLegacyDemo(Uri.parse('/')), isNull);
      expect(redirectLegacyDemo(Uri.parse('/?wheel=native')), isNull);
      expect(redirectLegacyDemo(Uri.parse('/edit/abc?demo=x')), isNull);
    });
  });

  testWidgets('/ builds the story list with the demos', (tester) async {
    await _pump(tester, '/');
    expect(find.text('Stories'), findsOneWidget);
    expect(find.text('New story'), findsOneWidget);
    expect(find.text('The Hour Between (spike)'), findsOneWidget);
    expect(find.text('Static layout demo'), findsOneWidget);
  });

  testWidgets('New story creates a blank document and opens the editor', (
    tester,
  ) async {
    final app = await _pump(tester, '/');
    await tester.tap(find.text('New story'));
    await tester.pumpAndSettle();
    expect(app.uri.path, startsWith('/edit/'));
    expect(find.byType(EditorShell), findsOneWidget);
    expect(find.text('Untitled story'), findsWidgets);
    final id = app.uri.pathSegments.last;
    expect(await app.repo.load(id), isNotNull);
    expect((await app.repo.list()).first.id, id);
  });

  testWidgets(
    'back from the editor returns to the list, which shows the new story',
    (tester) async {
      final app = await _pump(tester, '/');
      await tester.tap(find.text('New story'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(String.fromCharCode(SsIcons.arrowLeft.codePoint)),
      );
      await tester.pumpAndSettle();
      expect(app.uri.path, '/');
      expect(find.text('Untitled story'), findsOneWidget);
    },
  );

  testWidgets('/edit/:id builds the docked editor at desktop width', (
    tester,
  ) async {
    await _pump(tester, '/edit/demo-static');
    expect(find.byType(EditorShell), findsOneWidget);
    expect(find.byType(ContentModeScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('/edit/:id below 1024 px shows content mode with a play link', (
    tester,
  ) async {
    for (final size in [const Size(390, 844), const Size(800, 600)]) {
      final app = await _pump(tester, '/edit/demo-static', size: size);
      expect(find.byType(ContentModeScreen), findsOneWidget);
      expect(find.textContaining('larger window'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Play story'));
      await tester.pump();
      await tester.pump();
      expect(app.uri.path, '/play/demo-static');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('/edit/:id for an unknown story says so', (tester) async {
    await _pump(tester, '/edit/does-not-exist');
    expect(find.byType(NotFoundPage), findsOneWidget);
    expect(find.text('Story not found'), findsOneWidget);
  });

  testWidgets('/play/:id builds the gated player', (tester) async {
    final s = InMemoryStoryRepository(loadAsset: (_) async => _blank);
    final created = await s.create(title: 'P');
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = buildRouter(initialLocation: '/play/${created.id}');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storyRepositoryProvider.overrideWithValue(s)],
        child: SoundstageApp(router: router),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(GatedStagePlayer), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('/demo/:name builds each demo harness', (tester) async {
    final expected = <String, Type>{
      'static': DemoHarness,
      'gallery': DemoHarness,
      'motion': MotionDemoHarness,
      'sound': SoundDemoHarness,
      'spike': SoundDemoHarness,
    };
    for (final e in expected.entries) {
      await _pump(tester, '/demo/${e.key}', settle: false);
      expect(find.byType(e.value), findsOneWidget, reason: '/demo/${e.key}');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('/demo/design-system builds the gallery', (tester) async {
    await _pump(tester, '/demo/design-system');
    expect(find.text('Design system'), findsOneWidget);
    expect(find.text('Colour roles'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('/demo/unknown shows a not-found message', (tester) async {
    await _pump(tester, '/demo/nope');
    expect(find.textContaining('Unknown demo'), findsOneWidget);
  });

  testWidgets(
    '?demo= URLs redirect to /demo/:name and keep ?wheel and ?stats',
    (tester) async {
      final app = await _pump(
        tester,
        '/?demo=motion&wheel=native&stats=1',
        settle: false,
      );
      expect(app.uri.path, '/demo/motion');
      expect(app.uri.queryParameters, {'wheel': 'native', 'stats': '1'});
      expect(find.byType(MotionDemoHarness), findsOneWidget);
      expect(
        tester
            .widget<MotionDemoHarness>(find.byType(MotionDemoHarness))
            .wheelNative,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());

      final b = await _pump(
        tester,
        '/?demo=sound&wheel=native&stats=1',
        settle: false,
      );
      expect(b.uri.path, '/demo/sound');
      final h = tester.widget<SoundDemoHarness>(find.byType(SoundDemoHarness));
      expect(h.wheelNative, isTrue);
      expect(h.statsOn, isTrue);
      await tester.pumpWidget(const SizedBox());

      final c = await _pump(tester, '/demo/spike', settle: false);
      final h2 = tester.widget<SoundDemoHarness>(find.byType(SoundDemoHarness));
      expect(h2.wheelNative, isNull); // no flag: falls back to the browser URL
      expect(c.uri.path, '/demo/spike');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an unknown route shows not found', (tester) async {
    await _pump(tester, '/nowhere/at/all');
    expect(find.byType(NotFoundPage), findsOneWidget);
  });
}
