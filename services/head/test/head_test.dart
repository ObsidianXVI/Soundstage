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
  test('slugs come from /s/<slug> paths only', () {
    expect(slugFromPath('/s/night-walk'), 'night-walk');
    expect(slugFromPath('/s/night-walk/'), 'night-walk');
    expect(slugFromPath('/s/Night'), isNull);
    expect(slugFromPath('/s/a/b'), isNull);
    expect(slugFromPath('/edit/x'), isNull);
    expect(slugFromPath('/s/'), isNull);
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
}
