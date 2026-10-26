/// Static exports of a story (architecture §16.1, m4.md T4.5): linear text
/// and its Markdown and HTML renderings. Pure Dart over `lib/ir`; the
/// editor adds poster frames and bundles the files.
library;

export 'src/html.dart';
export 'src/linear_story.dart';
export 'src/linearize.dart' show linearize, orderedChildren, runsOf;
export 'src/markdown.dart';
