@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'demo_resolve_digest.dart';

/// Digests of every demo's resolved tree, recorded with the desktop-first
/// cascade (base = desktop, mobile inheriting tablet) before the move to the
/// shared-base breakpoint model. The converted demos (desktop and mobile
/// primary peers, tablet inheriting desktop, tablet-only patch keys folded
/// into mobile's patch) must resolve to the same trees.
final _before = {
  ('motion', 390.0): '15746451:279842',
  ('motion', 834.0): '136d9311:279863',
  ('motion', 1440.0): '136d9311:279863',
  ('paint_gallery', 390.0): 'b4c2b003:462822',
  ('paint_gallery', 834.0): 'bda2c6ed:462822',
  ('paint_gallery', 1440.0): 'b722f663:462822',
  ('sound', 390.0): '8b162388:23663',
  ('sound', 834.0): '21df1c61:23675',
  ('sound', 1440.0): '21df1c61:23675',
  ('spike', 390.0): '63cb3475:137160',
  ('spike', 834.0): '6b494ff3:137115',
  ('spike', 1440.0): '15d0cca9:137156',
  ('static', 390.0): 'd994b9a8:130621',
  ('static', 834.0): '310420c5:130627',
  ('static', 1440.0): '493929ae:130633',
};

void main() {
  for (final f in demoFiles) {
    group('$f demo', () {
      final doc = StageDocument.fromJsonMigrating(
        jsonDecode(File('assets/demo/$f.stage.json').readAsStringSync())
            as Map<String, Object?>,
      );

      test('uses the shared-base model and validates clean', () {
        expect(doc.primaryBreakpoints.map((b) => b.id), ['desktop', 'mobile']);
        expect(validateDocument(doc), isEmpty);
      });

      for (final w in digestWidths) {
        test('resolves at $w px exactly as before the shared base', () {
          final r = resolveDocument(doc, ResolveContext(viewportWidth: w));
          expect(r.diagnostics, isEmpty);
          expect(digest(resolvedDump(r)), _before[(f, w)]);
        });
      }
    });
  }
}
