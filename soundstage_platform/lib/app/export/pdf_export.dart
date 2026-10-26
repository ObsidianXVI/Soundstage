import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:soundstage_platform/export/export.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../persistence/story_package.dart' show AssetBytesSource;
import 'static_export.dart';

/// A story as a PDF (DECISIONS 26/10/26 #6 "Export (PDF, HTML, MD)", m4.md
/// T4.5c), built from the same linear text as the HTML and Markdown
/// exports: headings, paragraphs and lists with marks and links, quotes,
/// figures and posters as images with captions, transcripts, and a
/// backlink when the story is published.
///
/// Text sets in the PDF standard Times family (real bold and italic);
/// [fallbackFont] (TTF bytes, e.g. the bundled Inter) covers characters
/// Times does not have.
Future<Uint8List> exportStoryPdf(
  ir.StageDocument doc, {
  required AssetBytesSource bytesOf,
  required PosterSource poster,
  Uint8List? fallbackFont,
  Backlink? backlink,
  PdfPageFormat format = PdfPageFormat.a4,
}) async {
  final story = linearize(doc);
  final files = await collectExportFiles(
    story,
    doc,
    bytesOf: bytesOf,
    poster: poster,
  );
  final fallback = fallbackFont == null
      ? null
      : pw.Font.ttf(ByteData.sublistView(fallbackFont));
  final theme = pw.ThemeData.withFont(
    base: pw.Font.times(),
    bold: pw.Font.timesBold(),
    italic: pw.Font.timesItalic(),
    boldItalic: pw.Font.timesBoldItalic(),
    fontFallback: [?fallback],
  );
  final pdf = pw.Document(
    title: story.title,
    subject: story.description.isEmpty ? null : story.description,
    theme: theme,
  );

  pw.Widget? image(LinearBlock b) {
    final key = fileKeyOf(b);
    final f = key == null ? null : files[key];
    if (f == null || !f.mime.startsWith('image/') || f.mime.contains('svg')) {
      return null;
    }
    try {
      return pw.Image(pw.MemoryImage(f.bytes), fit: pw.BoxFit.contain);
    } on Object {
      return null; // a format the PDF library cannot embed
    }
  }

  final body = <pw.Widget>[
    pw.Header(
      level: 0,
      text: story.title,
      textStyle: const pw.TextStyle(fontSize: 26),
    ),
    if (story.description.trim().isNotEmpty)
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 12),
        child: pw.Text(
          story.description.trim(),
          style: const pw.TextStyle(fontSize: 14, color: PdfColors.grey700),
        ),
      ),
  ];
  for (final scene in story.scenes) {
    var ordinal = 0;
    for (final b in scene.blocks) {
      if (b is! ParagraphBlock || b.list != ListKind.ordered) ordinal = 0;
      switch (b) {
        case HeadingBlock(:final level, :final runs):
          body.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
              child: pw.RichText(
                text: _spans(runs, base: _headingStyle(level)),
              ),
            ),
          );
        case ParagraphBlock(:final runs, list: ListKind.none):
          body.add(_para(pw.RichText(text: _spans(runs))));
        case ParagraphBlock(:final runs, :final list):
          ordinal++;
          body.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 14, bottom: 4),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                    width: 18,
                    child: pw.Text(
                      list == ListKind.ordered ? '$ordinal.' : '•',
                    ),
                  ),
                  pw.Expanded(child: pw.RichText(text: _spans(runs))),
                ],
              ),
            ),
          );
        case QuoteBlock(:final paragraphs):
          body.add(
            _quote([
              for (final p in paragraphs)
                pw.RichText(
                  text: _spans(
                    p,
                    base: const pw.TextStyle(fontStyle: pw.FontStyle.italic),
                  ),
                ),
            ]),
          );
        case FigureBlock(:final caption):
          body.add(_figure(image(b), caption, null));
        case PosterBlock(:final sceneId):
          body.add(_figure(image(b), const [], backlink?.sceneUrl(sceneId)));
        case TranscriptBlock(:final lines):
          body.add(_quote([for (final l in lines) pw.Text(l)]));
        case AudioBlock(:final name):
          body.add(
            _para(
              pw.Text(
                'Audio: $name',
                style: const pw.TextStyle(color: PdfColors.grey700),
              ),
            ),
          );
      }
    }
  }
  if (backlink != null) {
    body
      ..add(pw.Divider())
      ..add(_link(Backlink.label, backlink.storyUrl));
  }

  pdf.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.symmetric(horizontal: 56, vertical: 48),
      build: (_) => body,
    ),
  );
  return pdf.save();
}

pw.Widget _figure(pw.Widget? img, List<InlineRun> caption, String? link) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 8),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (img != null)
            pw.ConstrainedBox(
              constraints: const pw.BoxConstraints(maxHeight: 360),
              child: img,
            ),
          if (caption.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.RichText(
                text: _spans(
                  caption,
                  base: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
              ),
            ),
          if (link != null) _link(Backlink.label, link, fontSize: 10),
        ],
      ),
    );

pw.TextStyle _headingStyle(int level) => pw.TextStyle(
  fontSize: switch (level) {
    1 => 20,
    2 => 17,
    3 => 15,
    _ => 13,
  },
  fontWeight: pw.FontWeight.bold,
);

pw.Widget _para(pw.Widget child) =>
    pw.Padding(padding: const pw.EdgeInsets.only(bottom: 8), child: child);

pw.Widget _quote(List<pw.Widget> children) => pw.Container(
  margin: const pw.EdgeInsets.only(bottom: 8),
  padding: const pw.EdgeInsets.only(left: 10),
  decoration: const pw.BoxDecoration(
    border: pw.Border(left: pw.BorderSide(color: PdfColors.grey400, width: 2)),
  ),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: children,
  ),
);

pw.Widget _link(String text, String url, {double fontSize = 12}) => pw.UrlLink(
  destination: url,
  child: pw.Text(
    text,
    style: pw.TextStyle(
      fontSize: fontSize,
      color: PdfColors.blue800,
      decoration: pw.TextDecoration.underline,
    ),
  ),
);

pw.TextSpan _spans(List<InlineRun> runs, {pw.TextStyle? base}) => pw.TextSpan(
  style: base,
  children: [
    for (final r in runs)
      pw.TextSpan(
        text: r.text,
        style: pw.TextStyle(
          fontWeight: r.bold ? pw.FontWeight.bold : null,
          fontStyle: r.italic ? pw.FontStyle.italic : null,
          decoration: r.strike
              ? pw.TextDecoration.lineThrough
              : r.href != null && !r.href!.startsWith('#')
              ? pw.TextDecoration.underline
              : null,
          color: r.href != null && !r.href!.startsWith('#')
              ? PdfColors.blue800
              : null,
        ),
        annotation: r.href != null && !r.href!.startsWith('#')
            ? pw.AnnotationUrl(r.href!)
            : null,
      ),
  ],
);
