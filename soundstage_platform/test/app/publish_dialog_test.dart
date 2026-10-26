import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/app/pages/cloud_ui.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../design_system/harness.dart';

/// Opens the publish dialog from a button and returns the choice holder.
Future<List<PublishChoice?>> _open(
  WidgetTester tester, {
  Audience audience = Audience.public,
  bool published = false,
}) async {
  final out = <PublishChoice?>[];
  await pumpChrome(
    tester,
    Builder(
      builder: (context) => SsButton(
        label: 'Go',
        onPressed: () async => out.add(
          await showPublishDialog(
            context,
            title: 'Night',
            suggested: 'night',
            prefix: 'https://site/@ada/s/',
            audience: audience,
            published: published,
          ),
        ),
      ),
    ),
    size: const Size(900, 800),
  );
  await tester.tap(find.text('Go'));
  await tester.pumpAndSettle();
  return out;
}

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey<String>(key)),
  matching: find.byType(EditableText),
);

bool _submitEnabled(WidgetTester tester) =>
    tester
        .widget<SsButton>(find.byKey(const ValueKey('publish:submit')))
        .onPressed !=
    null;

void main() {
  testWidgets('a password needs 4 characters; the choice carries it', (
    tester,
  ) async {
    final out = await _open(tester);
    expect(find.text(Audience.public.description), findsOneWidget);
    await tester.tap(find.text('Password'));
    await tester.pumpAndSettle();
    expect(_submitEnabled(tester), isFalse);
    await tester.enterText(_field('publish:password'), 'abc');
    await tester.pump();
    expect(find.text('Use at least 4 characters'), findsOneWidget);
    expect(_submitEnabled(tester), isFalse);
    await tester.enterText(_field('publish:password'), 'abcd');
    await tester.pump();
    expect(_submitEnabled(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('publish:submit')));
    await tester.pumpAndSettle();
    final c = out.single!;
    expect(c.slug, 'night');
    expect(c.audience, Audience.password);
    expect(c.password, 'abcd');
    expect(c.readers, isNull);
  });

  testWidgets('readers: emails parsed; the current list may be kept', (
    tester,
  ) async {
    final out = await _open(tester, audience: Audience.readers);
    // Already readers-only: empty keeps the list.
    expect(_submitEnabled(tester), isTrue);
    await tester.enterText(_field('publish:readers'), 'A@x.org, nope');
    await tester.pump();
    expect(find.text('"nope" is not an email'), findsOneWidget);
    await tester.enterText(
      _field('publish:readers'),
      'A@x.org\nb@y.z  a@x.org',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('publish:submit')));
    await tester.pumpAndSettle();
    expect(out.single!.readers, ['a@x.org', 'b@y.z']);
  });

  testWidgets('going private over a public story warns its files go', (
    tester,
  ) async {
    await _open(tester, published: true);
    expect(find.textContaining('are removed'), findsNothing);
    await tester.tap(find.text('Unlisted'));
    await tester.pumpAndSettle();
    expect(find.textContaining('are removed'), findsNothing);
    await tester.tap(find.text('Readers'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Earlier public versions are removed'),
      findsOneWidget,
    );
  });

  test('readers text', () {
    expect(parseReaders(' A@x.org;b@y.z\n\n a@x.org '), ['a@x.org', 'b@y.z']);
  });
}
