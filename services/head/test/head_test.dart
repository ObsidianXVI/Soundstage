import 'dart:convert';
import 'dart:math';

import 'package:soundstage_head/gate.dart';
import 'package:soundstage_head/head.dart';
import 'package:test/test.dart';

const _shell = '''<!DOCTYPE html>
<html>
<head>
  <base href="/">
  <meta charset="UTF-8">
  <meta name="description" content="Immersive stories.">
  <title>Soundstage</title>
</head>
<body></body>
</html>''';

void main() {
  test('routes come from /@<handle>/… paths only', () {
    expect(HeadRoute.parse('/@ada'), isA<SiteRoute>());
    expect(HeadRoute.parse('/@Ada/')!.handle, 'ada');
    final d = HeadRoute.parse('/@ada/s/night-walk')! as DraftRoute;
    expect(d.slug, 'night-walk');
    expect(d.docPath, 'sites/ada/drafts/night-walk');
    expect(d.path, '/@ada/s/night-walk');
    final p = HeadRoute.parse('/@ada/weekly')! as PublicationRoute;
    expect(p.docPath, 'sites/ada/publications/weekly');
    final i = HeadRoute.parse('/@ada/weekly/one/')! as IssueRoute;
    expect(i.docPath, 'sites/ada/publications/weekly/issues/one');
    expect(i.path, '/@ada/weekly/one');
    for (final bad in [
      '/@ada/s',
      '/@ad',
      '/ada',
      '/@ada/Night',
      '/@ada/a/b/c',
      '/edit/x',
      '/s/x',
      '/',
    ]) {
      expect(HeadRoute.parse(bad), isNull, reason: bad);
    }
  });

  test('Firestore REST fields', () {
    final h = StoryHead.fromFirestore({
      'fields': {
        'title': {'stringValue': ' The Hour Between '},
        'version': {'integerValue': '3'},
        'image': {'stringValue': 'https://cdn/x.png'},
      },
    }, 'https://site/s/hour');
    expect(h.title, 'The Hour Between');
    expect(h.description, isEmpty);
    expect(h.image, 'https://cdn/x.png');
  });

  test('the head carries the story, escaped', () {
    final out = injectHead(
      _shell,
      const StoryHead(
        title: 'Night <walk> & "rain"',
        description: 'A walk.',
        image: 'https://cdn/c.png?a=1&b=2',
        url: 'https://site/s/night',
      ),
    );
    expect(
      out,
      contains('<title>Night &lt;walk&gt; &amp; &quot;rain&quot;</title>'),
    );
    expect(out, contains('<meta name="description" content="A walk.">'));
    expect(out, isNot(contains('Immersive stories.')));
    expect(
      out,
      contains(
        '<meta property="og:image" content="https://cdn/c.png?a=1&amp;b=2">',
      ),
    );
    expect(out, contains('content="summary_large_image"'));
    expect(out, contains('<link rel="canonical" href="https://site/s/night">'));
    expect(out.indexOf('og:title'), lessThan(out.indexOf('</head>')));
    expect('<base href="/">'.allMatches(out), hasLength(1));
  });

  test('no title, image or description falls back', () {
    final out = injectHead(_shell, const StoryHead(title: '', url: 'u'));
    expect(out, contains('<title>Soundstage</title>'));
    expect(out, isNot(contains('og:image')));
    expect(out, isNot(contains('og:description')));
    expect(out, contains('content="summary"'));
  });

  test('sitemap from collection-group queries', () {
    const root = 'projects/p/databases/(default)/documents';
    final entries = sitemapEntries([
      {
        'document': {
          'name': '$root/sites/ada/drafts/night',
          'fields': {
            'updatedAt': {'timestampValue': '2026-10-26T04:00:00Z'},
          },
        },
      },
      {
        'document': {'name': '$root/sites/ada/publications/weekly'},
      },
      {
        'document': {'name': '$root/sites/bob/publications/weekly/issues/one'},
      },
      {
        'document': {'name': '$root/stories/x'},
      },
      {'readTime': '2026-10-26T04:00:00Z'}, // an empty reply has one of these
    ]);
    expect(entries.map((e) => e.path), [
      '/@ada/s/night',
      '/@ada/weekly',
      '/@bob/weekly/one',
    ]);
    final xml = sitemapXml('https://site', entries);
    expect(xml, contains('<loc>https://site/</loc>'));
    expect(xml, contains('<url><loc>https://site/@ada</loc></url>'));
    expect(xml, contains('<url><loc>https://site/@bob</loc></url>'));
    expect(
      xml,
      contains(
        '<url><loc>https://site/@ada/s/night</loc>'
        '<lastmod>2026-10-26T04:00:00Z</lastmod></url>',
      ),
    );
    expect(xml, contains('<url><loc>https://site/@bob/weekly/one</loc></url>'));
    expect(sitemapEntries({}), isEmpty);
  });

  test('previews of a publication and a handle', () {
    final h = headFor(const PublicationRoute('ada', 'weekly'), {
      'fields': {
        'title': {'stringValue': 'Weekly'},
        'issues': {
          'arrayValue': {
            'values': [
              {
                'mapValue': {
                  'fields': {
                    'image': {'stringValue': 'https://cdn/c.png'},
                  },
                },
              },
              {
                'mapValue': {'fields': <String, Object?>{}},
              },
            ],
          },
        },
      },
    }, 'https://site/@ada/weekly');
    expect(h.title, 'Weekly');
    expect(h.description, contains('2 issues'));
    expect(h.image, 'https://cdn/c.png');
    final site = headFor(const SiteRoute('ada'), {
      'fields': {
        'name': {'stringValue': 'Ada'},
      },
    }, 'https://site/@ada');
    expect(site.title, 'Ada (@ada)');
    expect(headFor(const SiteRoute('ada'), const {}, 'u').title, '@ada');
    final story = headFor(const DraftRoute('ada', 'x'), {
      'fields': {
        'title': {'stringValue': 'Night'},
      },
    }, 'u');
    expect(story.title, 'Night');
  });

  test('private pages preview as their handle only; unlisted not indexed', () {
    Map<String, Object?> doc(String audience) => {
      'fields': {
        'title': {'stringValue': 'Secret'},
        'image': {'stringValue': 'https://cdn/c.png'},
        'audience': {'stringValue': audience},
      },
    };
    final gated = headFor(const DraftRoute('ada', 'x'), doc('password'), 'u');
    expect(gated.title, '@ada on Soundstage');
    expect(gated.image, isEmpty);
    expect(injectHead(_shell, gated), contains('content="noindex"'));
    final unlisted = headFor(
      const DraftRoute('ada', 'x'),
      doc('unlisted'),
      'u',
    );
    expect(unlisted.title, 'Secret');
    expect(injectHead(_shell, unlisted), contains('content="noindex"'));
    final public = headFor(const DraftRoute('ada', 'x'), doc('public'), 'u');
    expect(injectHead(_shell, public), isNot(contains('noindex')));
    const root = 'projects/p/databases/(default)/documents';
    final entries = sitemapEntries([
      for (final (slug, a) in [
        ('a', 'public'),
        ('b', 'unlisted'),
        ('c', 'readers'),
      ])
        {
          'document': {
            'name': '$root/sites/ada/drafts/$slug',
            'fields': {
              'audience': {'stringValue': a},
            },
          },
        },
      {
        'document': {'name': '$root/sites/ada/drafts/old'},
      },
    ]);
    expect(entries.map((e) => e.path), ['/@ada/s/a', '/@ada/s/old']);
  });

  test('PBKDF2-HMAC-SHA256 matches RFC 7914', () {
    final out = pbkdf2('passwd', utf8.encode('salt'), 1);
    expect(
      out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc',
    );
    final secret = passwordSecret('open sesame', random: Random(1));
    expect(passwordMatches('open sesame', secret), isTrue);
    expect(passwordMatches('open sesame ', secret), isFalse);
    expect(passwordMatches('x', const {}), isFalse);
  });

  test('passes cover their folder until they expire', () {
    final key = utf8.encode('k' * 32);
    final now = DateTime.utc(2026, 10, 26, 12);
    const folder = 'gated/u1/ada/s/walk';
    final pass = signPass(key, folder, now.add(kPassLifetime));
    expect(passCovers(key, pass, '$folder/v1.manifest.json', now), isTrue);
    expect(passCovers(key, pass, '$folder/assets/a_{0001}.webp', now), isTrue);
    expect(passCovers(key, pass, 'gated/u1/ada/s/walker/x', now), isFalse);
    expect(passCovers(key, pass, '$folder/../other/x', now), isFalse);
    expect(
      passCovers(key, pass, '$folder/x', now.add(const Duration(hours: 7))),
      isFalse,
    );
    expect(passCovers(utf8.encode('other'), pass, '$folder/x', now), isFalse);
    final forged = '${pass.substring(0, pass.indexOf('.'))}.AAAA';
    expect(passCovers(key, forged, '$folder/x', now), isFalse);
    expect(passCovers(key, 'nonsense', '$folder/x', now), isFalse);
  });

  test('records, secrets and readers', () {
    expect(gateIdFor('sites/ada/drafts/x'), 'sites~ada~drafts~x');
    expect(routeOfDocPath('sites/ada/drafts/x'), isA<DraftRoute>());
    expect(
      routeOfDocPath('sites/ada/publications/w/issues/1'),
      isA<IssueRoute>(),
    );
    expect(routeOfDocPath('gates/x'), isNull);
    expect(routeOfDocPath('sites/ada/drafts/x/y'), isNull);
    expect(
      gatedFolderOf({'path': 'gated/u1/ada/s/walk/v2.stage.json'}),
      'gated/u1/ada/s/walk',
    );
    expect(
      gatedFolderOf({'path': 'published/u1/ada/s/walk/v2.stage.json'}),
      isNull,
    );
    expect(readersFrom([' A@x.org ', 'a@x.org', '', 'b@y.z']), [
      'a@x.org',
      'b@y.z',
    ]);
    expect(readersFrom(['nope']), isNull);
    expect(readersFrom('a@x.org'), isNull);
    final record = {
      'title': 'T',
      'version': 3,
      'versions': [
        {'version': 1, 'gated': true},
      ],
      'none': null,
    };
    final typed = {
      'fields': (typedValue(record)! as Map)['mapValue']['fields'],
    };
    expect(plainFields(typed), record);
  });
}
