import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../audio/waveform_peaks.dart';
import '../core/commands/audio_commands.dart';
import '../core/editor_controller.dart';
import '../insert/asset_service.dart' show audioPeaksProvider;
import 'timeline_math.dart';

/// Height of the waveform lane.
const double kWaveformLaneHeight = 40;

/// Height of the lyrics lane.
const double kLyricsLaneHeight = 32;

/// Pixels from a lyric block's edge that grab the edge, not the block.
const double kLyricEdgeGrab = 5;

/// The waveform and lyrics lanes of audio track [trackId], shown under the
/// ruler while the timeline's active clock is that track's audio clock
/// (m2.md "Audio lane", "Lyrics lane"). [viewOf] maps clock seconds to
/// pixels in the lane area right of [labelWidth]; [repaint] fires when the
/// view or the playhead moves.
class TimelineMediaLanes extends ConsumerStatefulWidget {
  const TimelineMediaLanes({
    super.key,
    required this.trackId,
    required this.labelWidth,
    required this.viewOf,
    required this.repaint,
    required this.playhead,
  });

  final String trackId;
  final double labelWidth;
  final TimelineView Function(double width) viewOf;
  final Listenable repaint;
  final double Function() playhead;

  @override
  ConsumerState<TimelineMediaLanes> createState() => _TimelineMediaLanesState();
}

enum _Grab { body, start, end, word }

class _LyricPress {
  _LyricPress(this.line, this.grab, this.t0, this.start0, {this.word});

  final int line;
  final _Grab grab;
  final double t0;
  final double start0;
  final int? word;
  bool moved = false;
}

class _TimelineMediaLanesState extends ConsumerState<TimelineMediaLanes> {
  final FocusNode _focus = FocusNode(debugLabel: 'lyrics lane');
  final ValueNotifier<int?> _selected = ValueNotifier(null);
  _LyricPress? _press;
  double _width = 1;

  /// Tap-to-sync: the line the next tap times (null when off).
  int? _syncLine;

  /// The line being renamed in place.
  int? _editing;
  final TextEditingController _text = TextEditingController();

  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  ir.AudioTrack? get _track {
    for (final t in ref.read(editorControllerProvider).document.audioTracks) {
      if (t.id == widget.trackId) return t;
    }
    return null;
  }

  List<ir.LyricLine> get _lines => _track?.lyrics?.lines ?? const [];

  @override
  void dispose() {
    _focus.dispose();
    _selected.dispose();
    _text.dispose();
    super.dispose();
  }

  TimelineView get _view => widget.viewOf(_width);

  double _endOf(List<ir.LyricLine> lines, int i, double duration) {
    final l = lines[i];
    if (l.end != null) return l.end!;
    if (i + 1 < lines.length) return lines[i + 1].start;
    return math.max(l.start + 1, duration);
  }

  /// The lyric element under lane x [x], or null.
  _LyricPress? _hit(double x, double duration) {
    final lines = _lines;
    final v = _view;
    final t = v.tOf(x);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final x0 = v.xOf(l.start);
      final x1 = v.xOf(_endOf(lines, i, duration));
      if (x < x0 - kLyricEdgeGrab || x > x1 + kLyricEdgeGrab) continue;
      for (var w = 0; w < l.words.length; w++) {
        if ((v.xOf(l.words[w].start) - x).abs() <= 3 && w > 0) {
          return _LyricPress(i, _Grab.word, t, l.words[w].start, word: w);
        }
      }
      if ((x - x0).abs() <= kLyricEdgeGrab) {
        return _LyricPress(i, _Grab.start, t, l.start);
      }
      if ((x - x1).abs() <= kLyricEdgeGrab) {
        return _LyricPress(i, _Grab.end, t, x1 / v.pxPerUnit + v.start);
      }
      if (x > x0 && x < x1) return _LyricPress(i, _Grab.body, t, l.start);
    }
    return null;
  }

  Duration? _lastDown;
  Offset? _lastDownAt;

  void _down(PointerDownEvent e, double duration) {
    if (e.buttons != kPrimaryButton) return;
    _focus.requestFocus();
    _commitEdit();
    final last = _lastDown, at = _lastDownAt;
    _lastDown = e.timeStamp;
    _lastDownAt = e.localPosition;
    if (last != null &&
        at != null &&
        e.timeStamp - last < kDoubleTapTimeout &&
        (e.localPosition - at).distance < kDoubleTapSlop) {
      _lastDown = null;
      _press = null;
      _doubleTap(e.localPosition, duration);
      return;
    }
    final p = _press = _hit(e.localPosition.dx, duration);
    _selected.value = p?.line;
  }

  void _move(PointerMoveEvent e) {
    final p = _press;
    final track = _track;
    if (p == null || track == null || track.lyrics == null) return;
    final dt = _view.tOf(e.localPosition.dx) - p.t0;
    if (!p.moved) {
      if (dt.abs() * _view.pxPerUnit < 2) return;
      p.moved = true;
      _editor.beginGesture();
    }
    final doc = track.lyrics!;
    switch (p.grab) {
      case _Grab.body:
        final b = ir.lyricStartBounds(doc, p.line);
        _editor.execute(
          MoveLyricLine(
            track.id,
            p.line,
            (p.start0 + dt).clamp(b.min, b.max).toDouble(),
          ),
        );
      case _Grab.start:
        final b = ir.lyricStartBounds(doc, p.line);
        final line = doc.lines[p.line];
        final hi = math.min(b.max, (line.end ?? double.infinity) - 0.05);
        final s = (p.start0 + dt).clamp(b.min, math.max(b.min, hi)).toDouble();
        _editor.execute(
          UpdateLyricLine(
            track.id,
            p.line,
            (l) => l.copyWith(start: s),
            label: 'Trim lyric line',
            coalesce: true,
          ),
        );
      case _Grab.end:
        final line = doc.lines[p.line];
        final next = p.line + 1 < doc.lines.length
            ? doc.lines[p.line + 1].start
            : double.infinity;
        final end = (p.start0 + dt).clamp(line.start + 0.05, next);
        _editor.execute(
          UpdateLyricLine(
            track.id,
            p.line,
            (l) => l.copyWith(end: end),
            label: 'Trim lyric line',
            coalesce: true,
          ),
        );
      case _Grab.word:
        final line = doc.lines[p.line];
        final b = ir.lyricWordStartBounds(line, p.word!);
        _editor.execute(
          UpdateLyricWord(
            track.id,
            p.line,
            p.word!,
            (w) => w.copyWith(
              start: (p.start0 + dt).clamp(b.min, b.max).toDouble(),
            ),
            label: 'Move lyric word',
            coalesce: true,
          ),
        );
    }
  }

  void _up() {
    final p = _press;
    _press = null;
    if (p != null && p.moved) _editor.endGesture();
  }

  /// Double-click: edit a line's text, or add a line where there is none.
  void _doubleTap(Offset local, double duration) {
    final track = _track;
    if (track == null) return;
    final hit = _hit(local.dx, duration);
    if (hit != null) {
      _beginEdit(hit.line);
      return;
    }
    final t = math.max(0.0, _view.tOf(local.dx));
    _editor.execute(
      InsertLyricLine(track.id, ir.LyricLine(start: t, text: 'Lyric')),
    );
    final i = _lines.indexWhere((l) => l.start == t);
    if (i >= 0) _beginEdit(i);
  }

  void _beginEdit(int i) {
    final lines = _lines;
    if (i >= lines.length) return;
    setState(() {
      _editing = i;
      _selected.value = i;
      _text.text = lines[i].text;
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    });
  }

  void _commitEdit() {
    final i = _editing;
    final track = _track;
    if (i == null) return;
    setState(() => _editing = null);
    if (track == null || i >= _lines.length) return;
    final text = _text.text.trim();
    if (text == _lines[i].text || text.isEmpty) return;
    _editor.execute(
      UpdateLyricLine(track.id, i, (l) => l.copyWith(text: text)),
    );
  }

  /// Times line [_syncLine] at the playhead: it and every later line shift
  /// by the same amount, so the order is kept.
  void _syncTap() {
    final i = _syncLine;
    final track = _track;
    final lines = _lines;
    if (i == null || track == null || i >= lines.length) return;
    final t = widget.playhead();
    final floor = i == 0 ? 0.0 : lines[i - 1].start + 0.01;
    final start = math.max(t, floor);
    final delta = start - lines[i].start;
    ir.LyricLine shift(ir.LyricLine l) => l.copyWith(
      start: l.start + delta,
      end: l.end == null ? null : l.end! + delta,
      words: [
        for (final w in l.words)
          w.copyWith(
            start: w.start + delta,
            end: w.end == null ? null : w.end! + delta,
          ),
      ],
    );
    _editor.execute(
      SetLyrics(
        track.id,
        ir.LyricsDoc(
          lines: [
            for (var k = 0; k < lines.length; k++)
              k < i ? lines[k] : shift(lines[k]),
          ],
        ),
      ),
    );
    setState(() => _syncLine = i + 1 < lines.length ? i + 1 : null);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || _editing != null) return KeyEventResult.ignored;
    final track = _track;
    if (track == null) return KeyEventResult.ignored;
    if (_syncLine != null && e.logicalKey == LogicalKeyboardKey.keyT) {
      _syncTap();
      return KeyEventResult.handled;
    }
    final sel = _selected.value;
    if (sel != null &&
        (e.logicalKey == LogicalKeyboardKey.delete ||
            e.logicalKey == LogicalKeyboardKey.backspace)) {
      _editor.execute(RemoveLyricLine(track.id, sel));
      _selected.value = null;
      return KeyEventResult.handled;
    }
    if (sel != null && e.logicalKey == LogicalKeyboardKey.enter) {
      _beginEdit(sel);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    final text = context.ss.text;
    final track = ref.watch(
      editorControllerProvider.select((s) {
        for (final t in s.document.audioTracks) {
          if (t.id == widget.trackId) return t;
        }
        return null;
      }),
    );
    if (track == null) return const SizedBox.shrink();
    final peaks = ref.watch(audioPeaksProvider(track.assetId)).asData?.value;
    final duration = peaks?.duration ?? 0;
    final lines = track.lyrics?.lines ?? const <ir.LyricLine>[];
    return Column(
      key: const ValueKey<String>('timeline-media-lanes'),
      children: [
        _lane(
          context,
          label: Text('Waveform', style: text.caption),
          height: kWaveformLaneHeight,
          child: CustomPaint(
            key: const ValueKey<String>('timeline-waveform'),
            painter: _WaveformPainter(
              peaks: peaks,
              viewOf: widget.viewOf,
              playhead: widget.playhead,
              colors: c,
              repaint: widget.repaint,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        _lane(
          context,
          label: Row(
            children: [
              Expanded(child: Text('Lyrics', style: text.caption)),
              if (lines.isNotEmpty)
                SsButton(
                  key: const ValueKey<String>('lyrics-sync'),
                  label: _syncLine == null ? 'Tap to sync' : 'Stop sync',
                  variant: SsButtonVariant.ghost,
                  onPressed: () {
                    setState(() => _syncLine = _syncLine == null ? 0 : null);
                    _focus.requestFocus();
                  },
                ),
            ],
          ),
          height: kLyricsLaneHeight,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _onKey,
            child: LayoutBuilder(
              builder: (context, box) {
                _width = box.maxWidth;
                return Stack(
                  children: [
                    Listener(
                      key: const ValueKey<String>('timeline-lyrics'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) => _down(e, duration),
                      onPointerMove: _move,
                      onPointerUp: (_) => _up(),
                      onPointerCancel: (_) => _up(),
                      child: CustomPaint(
                        painter: _LyricsPainter(
                          lines: lines,
                          duration: duration,
                          viewOf: widget.viewOf,
                          selected: _selected,
                          syncLine: _syncLine,
                          colors: c,
                          textStyle: text.caption,
                          repaint: widget.repaint,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    if (_editing != null && _editing! < lines.length)
                      _lineEditor(lines, duration, box.maxWidth),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _lineEditor(List<ir.LyricLine> lines, double duration, double width) {
    final i = _editing!;
    final v = _view;
    // At least 160 px wide, kept inside the lane.
    final w = math.min(
      width,
      math.max(
        160.0,
        v.xOf(_endOf(lines, i, duration)) - v.xOf(lines[i].start),
      ),
    );
    final x0 = v
        .xOf(lines[i].start)
        .clamp(0.0, math.max(0.0, width - w))
        .toDouble();
    final x1 = x0 + w;
    return Positioned(
      left: x0,
      width: x1 - x0,
      top: 2,
      bottom: 2,
      child: SsTextField(
        key: const ValueKey<String>('lyric-edit'),
        controller: _text,
        autofocus: true,
        onSubmitted: (_) => _commitEdit(),
      ),
    );
  }

  Widget _lane(
    BuildContext context, {
    required Widget label,
    required double height,
    required Widget child,
  }) {
    final c = context.ss.colors;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Container(
            width: widget.labelWidth,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(color: c.borderSubtle),
                bottom: BorderSide(color: c.borderSubtle),
              ),
            ),
            child: label,
          ),
          Expanded(child: ClipRect(child: child)),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.viewOf,
    required this.playhead,
    required this.colors,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final WaveformPeaks? peaks;
  final TimelineView Function(double width) viewOf;
  final double Function() playhead;
  final SsColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surface0);
    final p = peaks;
    final v = viewOf(size.width);
    if (p != null && p.length > 0) {
      final mid = size.height / 2;
      final paint = Paint()
        ..color = colors.accent.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      final x0 = math.max(0, v.xOf(0)).floorToDouble();
      final x1 = math.min(size.width, v.xOf(p.duration)).ceilToDouble();
      for (var x = x0; x < x1; x++) {
        final a = p.peakIn(v.tOf(x), v.tOf(x + 1));
        final h = math.max(0.5, a * (mid - 2));
        canvas.drawLine(
          Offset(x + 0.5, mid - h),
          Offset(x + 0.5, mid + h),
          paint,
        );
      }
    }
    final px = v.xOf(playhead());
    if (px >= 0 && px <= size.width) {
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()..color = colors.danger,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      !identical(old.peaks, peaks) || old.colors != colors;
}

class _LyricsPainter extends CustomPainter {
  _LyricsPainter({
    required this.lines,
    required this.duration,
    required this.viewOf,
    required this.selected,
    required this.syncLine,
    required this.colors,
    required this.textStyle,
    required Listenable repaint,
  }) : super(repaint: Listenable.merge([repaint, selected]));

  final List<ir.LyricLine> lines;
  final double duration;
  final TimelineView Function(double width) viewOf;
  final ValueListenable<int?> selected;
  final int? syncLine;
  final SsColors colors;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surface0);
    final v = viewOf(size.width);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final end =
          l.end ??
          (i + 1 < lines.length
              ? lines[i + 1].start
              : math.max(l.start + 1, duration));
      final x0 = v.xOf(l.start);
      final x1 = v.xOf(end);
      if (x1 < 0 || x0 > size.width) continue;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, 3, math.max(x0 + 2, x1 - 1), size.height - 3),
        const Radius.circular(3),
      );
      final isSel = selected.value == i;
      canvas.drawRRect(
        r,
        Paint()
          ..color = i == syncLine
              ? colors.warning.withValues(alpha: 0.5)
              : isSel
              ? colors.selection
              : colors.surface3,
      );
      if (isSel) {
        canvas.drawRRect(
          r,
          Paint()
            ..color = colors.accent
            ..style = PaintingStyle.stroke,
        );
      }
      for (final w in l.words.skip(1)) {
        final wx = v.xOf(w.start);
        canvas.drawLine(
          Offset(wx, 6),
          Offset(wx, size.height - 6),
          Paint()..color = colors.textDisabled,
        );
      }
      final room = r.width - 8;
      if (room > 12) {
        final tp = TextPainter(
          text: TextSpan(text: l.text, style: textStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: room);
        tp.paint(canvas, Offset(x0 + 4, (size.height - tp.height) / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_LyricsPainter old) =>
      !identical(old.lines, lines) ||
      old.duration != duration ||
      old.syncLine != syncLine ||
      old.colors != colors;
}
