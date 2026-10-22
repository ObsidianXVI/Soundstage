@Tags(['bench'])
@TestOn('vm')
library;

import 'dart:developer';
import 'dart:isolate' as iso;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Measures the animated-text-style path (T0.7) per value change: the
/// re-merge of the affected spans (`StageTextAnimation.apply`), the
/// layout's restyle of the affected paragraph and its relayout, for a
/// two-paragraph heading with a letter-spacing and a colour channel on
/// paragraph 0 (paragraph 1 is untouched).
///
///   flutter test --enable-vmservice --tags bench test/bench/text_style_bench.dart
///
/// Allocations are counted with the VM service's allocation profile
/// (differential over N vs 2N changes). Without the VM service only the
/// timing runs.
const int _changes = 2000;

ir.Track _t(String path, ir.IrValue a, ir.IrValue b) => ir.Track(
  id: path,
  target: 'h',
  property: path,
  clockId: 'c',
  keyframes: [
    ir.Keyframe(id: 'a', t: 0, value: a),
    ir.Keyframe(id: 'b', t: 1, value: b),
  ],
);

void main() {
  test('animated text style: cost per value change', () async {
    const node = ir.TextNode(
      common: ir.NodeCommon(id: 'h'),
      content: [
        ir.Paragraph(
          spans: [
            ir.Span(text: 'Lights go '),
            ir.Span(
              text: 'low',
              style: ir.TextStyleOverride(italic: true),
            ),
          ],
        ),
        ir.Paragraph(spans: [ir.Span(text: 'across the stage')]),
      ],
    );
    const base = ir.TextStyle(fontSize: 64);
    final paras = [
      for (final p in node.content)
        ir.ResolvedParagraph(
          spans: [for (final s in p.spans) ir.ResolvedSpan(text: s.text, style: base)],
          alignHorizontal: ir.TextAlignHorizontal.left,
          paragraphSpacing: 0,
          paragraphIndent: 0,
          listStyle: ir.ListStyle.none,
        ),
    ];
    final spacing = CompiledTrack.compile(
      _t(
        'content.0.spans.0.style.letterSpacing',
        const ir.IrValue.letterSpacing(ir.LetterSpacing.percent(0)),
        const ir.IrValue.letterSpacing(ir.LetterSpacing.percent(20)),
      ),
    );
    final colour = CompiledTrack.compile(
      _t(
        'content.0.spans.0.style.fills.text.color',
        const ir.IrValue.color(ir.StageColor.black),
        const ir.IrValue.color(ir.StageColor.white),
      ),
    );
    final anim = StageTextAnimation()
      ..add(TextStyleChannel.compile(spacing)!)
      ..add(TextStyleChannel.compile(colour)!);
    final layout = StageTextLayout(
      paragraphs: paras,
      fonts: StageFontTable.none,
      settings: const StageTextSettings(),
    )..layout();

    var f = 0;
    void run(int n) {
      for (var i = 0; i < n; i++, f++) {
        final v = (f % 400) / 400;
        spacing.evaluate(v);
        colour.evaluate(v);
        layout
          ..restyle(anim.apply(paras, node))
          ..relayout();
      }
    }

    run(_changes); // warm up
    final sw = Stopwatch()..start();
    run(_changes);
    sw.stop();
    final us = sw.elapsedMicroseconds / _changes;
    // ignore: avoid_print
    print('animated text style: ${us.toStringAsFixed(1)} µs per change (VM)');

    final info = await Service.getInfo();
    final ws = info.serverWebSocketUri;
    if (ws == null) {
      markTestSkipped('run with --enable-vmservice to count allocations');
      return;
    }
    final s = await vmServiceConnectUri(ws.toString());
    final isolate = Service.getIsolateId(iso.Isolate.current)!;
    Future<Map<String, int>> counts(int n) async {
      await s.getAllocationProfile(isolate, reset: true, gc: true);
      run(n);
      final p = await s.getAllocationProfile(isolate);
      return {
        for (final m in p.members ?? const <ClassHeapStats>[])
          if ((m.instancesAccumulated ?? 0) > 0)
            m.classRef?.name ?? '?': m.instancesAccumulated!,
      };
    }

    final a = await counts(_changes);
    final b = await counts(2 * _changes);
    final rates = <String, double>{
      for (final e in b.entries)
        if ((e.value - (a[e.key] ?? 0)) / _changes > 0.01)
          e.key: (e.value - (a[e.key] ?? 0)) / _changes,
    };
    final total = rates.values.fold(0.0, (x, y) => x + y);
    final top = (rates.entries.toList()
          ..sort((x, y) => y.value.compareTo(x.value)))
        .take(12)
        .map((e) => '${e.key} ${e.value.toStringAsFixed(2)}')
        .join(', ');
    // ignore: avoid_print
    print(
      'animated text style: ${total.toStringAsFixed(1)} Dart allocations '
      'per change: $top',
    );
    await s.dispose();
    layout.dispose();
  });
}
