import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../insert/asset_service.dart';
import '../../insert/file_drop.dart';

// Lyrics of an audio track in the Audio view (m2.md "Lyrics lane"): import
// LRC or enhanced LRC by picker or drop, through `parseLrc`, with the
// parser's `invalidLyrics` warnings shown inline, plus a short preview and
// Clear. The lane edits lines and words later, with the same commands.

/// File types the LRC picker offers.
const String kLrcAccept = '.lrc,.txt,text/plain';

/// "m:ss.s" for [seconds] (lyric times).
String formatLyricTime(double seconds) {
  final m = seconds ~/ 60;
  final s = seconds - m * 60;
  return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
}

/// How many diagnostics the import list shows before "and N more".
const int kShownLyricWarnings = 5;

/// How many lines the preview shows.
const int kShownLyricLines = 6;

class LyricsImport extends ConsumerStatefulWidget {
  const LyricsImport({required this.track, super.key});

  final ir.AudioTrack track;

  @override
  ConsumerState<LyricsImport> createState() => _LyricsImportState();
}

class _LyricsImportState extends ConsumerState<LyricsImport> {
  /// What the last import did, for the inline report.
  String? _message;
  bool _failed = false;
  List<ir.IrDiagnostic> _warnings = const [];

  @override
  void didUpdateWidget(LyricsImport old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) {
      _message = null;
      _failed = false;
      _warnings = const [];
    }
  }

  Future<void> _pick() async {
    final files = await ref.read(editorFilePickerProvider)(accept: kLrcAccept);
    if (files.isNotEmpty && mounted) importLyricFile(files.first);
  }

  /// Parses [file] as LRC and, when it holds lyrics, replaces the track's
  /// lyrics with them (one undo step). Anything the parser skipped is
  /// listed.
  void importLyricFile(EditorFile file) {
    if (mediaKindForMime(mimeOfFile(file) ?? '') != null) {
      setState(() {
        _failed = true;
        _warnings = const [];
        _message = '${file.name} is not a lyrics file. Use an .lrc file.';
      });
      return;
    }
    final result = ir.parseLrc(utf8.decode(file.bytes, allowMalformed: true));
    final lines = result.doc.lines.length;
    if (lines == 0) {
      setState(() {
        _failed = true;
        _warnings = result.diagnostics;
        _message = 'No lyrics found in ${file.name}.';
      });
      return;
    }
    final r = ref
        .read(editorControllerProvider.notifier)
        .execute(SetLyrics(widget.track.id, result.doc));
    setState(() {
      _failed = !r.ok;
      _warnings = result.diagnostics;
      _message = r.ok
          ? 'Imported $lines ${lines == 1 ? 'line' : 'lines'} from ${file.name}.'
          : r.diagnostics.map((d) => d.message).join(' ');
    });
  }

  void _drop(List<EditorFile> files, Offset _) {
    // The first file that is not media (a dropped audio file is not lyrics).
    for (final f in files) {
      if (mediaKindForMime(mimeOfFile(f) ?? '') == null) {
        importLyricFile(f);
        return;
      }
    }
    if (files.isNotEmpty) importLyricFile(files.first);
  }

  void _clear() {
    ref
        .read(editorControllerProvider.notifier)
        .execute(ClearLyrics(widget.track.id));
    setState(() {
      _message = null;
      _warnings = const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final lyrics = widget.track.lyrics;
    final lines = lyrics?.lines ?? const <ir.LyricLine>[];
    final words = lines.fold<int>(0, (n, l) => n + l.words.length);
    return FileDropTarget(
      onDrop: _drop,
      caption: 'Drop an LRC file to import lyrics',
      child: Column(
        key: const ValueKey('lyrics-import'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            lines.isEmpty
                ? 'No lyrics yet.'
                : '${lines.length} ${lines.length == 1 ? 'line' : 'lines'}'
                      '${words > 0 ? ', $words timed words' : ''}',
            style: t.text.small.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: SsSpace.s2),
          Wrap(
            spacing: SsSpace.s2,
            runSpacing: SsSpace.s1,
            children: [
              SsButton(
                label: lines.isEmpty ? 'Import LRC…' : 'Replace LRC…',
                onPressed: _pick,
              ),
              if (lines.isNotEmpty)
                SsButton(
                  label: 'Clear lyrics',
                  variant: SsButtonVariant.ghost,
                  onPressed: _clear,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: SsSpace.s1),
            child: Text(
              'or drop an .lrc file here. Enhanced LRC word times are kept.',
              style: t.text.caption.copyWith(color: c.textDisabled),
            ),
          ),
          if (_message != null)
            Padding(
              key: const ValueKey('lyrics-report'),
              padding: const EdgeInsets.only(top: SsSpace.s2),
              child: Text(
                _message!,
                style: t.text.small.copyWith(
                  color: _failed ? c.danger : c.success,
                ),
              ),
            ),
          for (final (i, d) in _warnings.take(kShownLyricWarnings).indexed)
            Padding(
              key: ValueKey('lyrics-warning-$i'),
              padding: const EdgeInsets.only(top: SsSpace.s1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      SsIcons.triangleAlert,
                      size: 12,
                      color: c.warning,
                    ),
                  ),
                  const SizedBox(width: SsSpace.s1),
                  Expanded(
                    child: Text(
                      d.message,
                      style: t.text.caption.copyWith(color: c.warning),
                    ),
                  ),
                ],
              ),
            ),
          if (_warnings.length > kShownLyricWarnings)
            Padding(
              padding: const EdgeInsets.only(top: SsSpace.s1),
              child: Text(
                'and ${_warnings.length - kShownLyricWarnings} more skipped.',
                style: t.text.caption.copyWith(color: c.warning),
              ),
            ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: SsSpace.s2),
            for (final l in lines.take(kShownLyricLines))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        formatLyricTime(l.start),
                        style: t.text.caption.copyWith(
                          color: c.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        l.text,
                        style: t.text.small,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            if (lines.length > kShownLyricLines)
              Text(
                'and ${lines.length - kShownLyricLines} more lines',
                style: t.text.caption.copyWith(color: c.textDisabled),
              ),
          ],
        ],
      ),
    );
  }
}
