import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/cloud/domains.dart';
import 'package:soundstage_platform/app/pages/domains_dialog.dart';
import 'package:soundstage_platform/app/router.dart';

import '../design_system/harness.dart';

void main() {
  test('app hosts and local links', () {
    expect(isAppHost('project-soundstage.web.app'), isTrue);
    expect(isAppHost('project-soundstage-pages.firebaseapp.com'), isTrue);
    expect(isAppHost('localhost'), isTrue);
    expect(isAppHost('news.example.com'), isFalse);
    expect(localRoute(null, '/@ada/s/walk'), '/@ada/s/walk');
    expect(localRoute('ada', '/@ada'), '/');
    expect(localRoute('ada', '/@ada/weekly/one'), '/weekly/one');
    expect(localRoute('ada', '/@bob/s/x'), '/@bob/s/x');
  });

  test('a custom domain routes its handle at clean paths only', () {
    String? match(String location) {
      final router = buildDomainRouter('ada', initialLocation: location);
      addTearDown(router.dispose);
      final m = router.configuration.findMatch(Uri.parse(location));
      return m.isEmpty ? null : m.fullPath;
    }

    expect(match('/'), '/');
    expect(match('/s/walk'), '/s/:slug');
    expect(match('/weekly'), '/:pub');
    expect(match('/weekly/one'), '/:pub/:issue');
    expect(match('/edit/x/y'), isNull);
  });

  testWidgets('domains: request-only, then connect with DNS records', (
    tester,
  ) async {
    var premium = false;
    final calls = <String>[];
    Future<(int, String)> send(
      String method,
      String url, {
      Map<String, String> headers = const {},
      String? body,
    }) async {
      calls.add('$method ${Uri.parse(url).path}');
      expect(headers['authorization'], 'Bearer tok');
      if (method == 'GET') {
        return (200, jsonEncode({'premium': premium, 'domains': <Object?>[]}));
      }
      if (method == 'POST') {
        expect(jsonDecode(body!), {'host': 'news.example.com'});
        return (
          200,
          jsonEncode({
            'host': 'news.example.com',
            'state': 'dns',
            'records': [
              {
                'action': 'ADD',
                'name': 'news.example.com',
                'type': 'TXT',
                'value': 'hosting-site=x',
              },
            ],
            'issues': <Object?>[],
          }),
        );
      }
      return (200, '{}');
    }

    DomainsClient client() => DomainsClient(
      baseUrl: 'https://agent.test',
      send: send,
      idToken: () async => 'tok',
    );
    await pumpChrome(
      tester,
      DomainsDialog(client: client(), handle: 'ada'),
      size: const Size(800, 900),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('by request'), findsOneWidget);
    expect(find.byKey(const ValueKey('domains:add')), findsNothing);

    premium = true;
    await pumpChrome(
      tester,
      DomainsDialog(key: UniqueKey(), client: client(), handle: 'ada'),
      size: const Size(800, 900),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('domains:host')),
        matching: find.byType(EditableText),
      ),
      'News.Example.com ',
    );
    await tester.tap(find.byKey(const ValueKey('domains:add')));
    await tester.pumpAndSettle();
    expect(find.text('news.example.com'), findsOneWidget);
    expect(find.text('Waiting for DNS'), findsOneWidget);
    expect(find.textContaining('hosting-site=x'), findsOneWidget);
    await tester.tap(find.text('Remove').first);
    await tester.pumpAndSettle();
    expect(find.text('news.example.com'), findsNothing);
    expect(calls, contains('DELETE /domains/news.example.com'));
  });
}
