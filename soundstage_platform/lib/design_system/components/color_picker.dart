import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/ss_icons.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'button.dart';
import 'checkerboard.dart';
import 'color_math.dart';
import 'eye_dropper.dart';
import 'number_field.dart';
import 'segmented.dart';
import 'text_field.dart';

/// The numeric input model of the picker.
enum SsColorMode { hex, rgb, hsl }

/// A colour swatch: the colour over a checkerboard, optionally tappable.
class SsColorSwatch extends StatelessWidget {
  const SsColorSwatch({
    required this.color,
    this.size = 20,
    this.onTap,
    this.selected = false,
    this.semanticLabel,
    this.mixed = false,
    super.key,
  });

  final Color color;
  final double size;
  final VoidCallback? onTap;
  final bool selected;
  final bool mixed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    final label =
        semanticLabel ??
        (mixed ? 'Mixed colour' : 'Colour ${formatHexColor(color)}');
    final swatch = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: SsRadius.brSm,
        border: Border.all(
          color: selected ? c.focusRing : c.border,
          width: selected ? 2 : 1,
        ),
      ),
      child: mixed
          ? Center(
              child: Container(
                width: size - 6,
                height: 2,
                color: c.textSecondary,
              ),
            )
          : SsCheckerboard(
              cell: math.max(3, size / 5),
              borderRadius: SsRadius.brSm,
              child: ColoredBox(color: color, child: const SizedBox.expand()),
            ),
    );
    if (onTap == null) {
      return Semantics(label: label, image: true, child: swatch);
    }
    return Semantics(
      label: label,
      button: true,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: swatch),
      ),
    );
  }
}

/// The full colour picker: saturation/value area, hue and alpha sliders,
/// hex / RGB / HSL inputs and (where the browser has the EyeDropper API) an
/// eyedropper.
///
/// [onChanged] fires continuously while dragging; [onChangeStart] and
/// [onChangeEnd] bracket each drag for undo coalescing.
class SsColorPicker extends StatefulWidget {
  const SsColorPicker({
    required this.color,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.enableEyeDropper,
    this.pickScreen,
    this.initialMode = SsColorMode.hex,
    this.width,
    super.key,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  /// Defaults to the platform feature detection ([eyeDropperSupported]).
  final bool? enableEyeDropper;

  /// Overrides the screen-colour source (tests, the gallery).
  final Future<Color?> Function()? pickScreen;
  final SsColorMode initialMode;

  /// A fixed width, or null to fill the available width.
  final double? width;

  @override
  State<SsColorPicker> createState() => _SsColorPickerState();
}

class _SsColorPickerState extends State<SsColorPicker> {
  late SsHsv _hsv = SsHsv.fromColor(widget.color);
  late SsColorMode _mode = widget.initialMode;

  @override
  void didUpdateWidget(SsColorPicker old) {
    super.didUpdateWidget(old);
    // Keep hue/saturation when the colour is the one we emitted (the colour
    // alone cannot recover the hue of a grey).
    if (widget.color != _hsv.toColor()) {
      _hsv = SsHsv.fromColor(widget.color);
    }
  }

  void _set(SsHsv hsv) {
    setState(() => _hsv = hsv);
    widget.onChanged(hsv.toColor());
  }

  void _setColor(Color c) => _set(SsHsv.fromColor(c));

  bool get _eyeDropper => widget.enableEyeDropper ?? eyeDropperSupported;

  Future<void> _pick() async {
    final c = await (widget.pickScreen ?? pickScreenColor)();
    if (c != null && mounted) {
      widget.onChangeStart?.call();
      _setColor(c);
      widget.onChangeEnd?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final color = _hsv.toColor();
    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 150,
            child: _SvArea(
              hsv: _hsv,
              onChanged: _set,
              onStart: widget.onChangeStart,
              onEnd: widget.onChangeEnd,
            ),
          ),
          const SizedBox(height: SsSpace.s3),
          Row(
            children: [
              if (_eyeDropper) ...[
                SsIconButton(
                  icon: SsIcons.pipette,
                  semanticLabel: 'Pick colour from screen',
                  onPressed: _pick,
                ),
                const SizedBox(width: SsSpace.s2),
              ],
              Expanded(
                child: Column(
                  children: [
                    _GradientSlider(
                      label: 'Hue',
                      value: _hsv.h / 360,
                      valueOf: (v) => '${(v * 360).round()} degrees',
                      track: const _HueTrack(),
                      thumbColor: _hsv.pureHue,
                      onChanged: (v) => _set(_hsv.copyWith(h: v * 360)),
                      onStart: widget.onChangeStart,
                      onEnd: widget.onChangeEnd,
                    ),
                    const SizedBox(height: SsSpace.s2),
                    _GradientSlider(
                      label: 'Alpha',
                      value: _hsv.a,
                      valueOf: (v) => '${(v * 100).round()} percent',
                      track: _AlphaTrack(_hsv.copyWith(a: 1).toColor()),
                      thumbColor: color,
                      onChanged: (v) => _set(_hsv.copyWith(a: v)),
                      onStart: widget.onChangeStart,
                      onEnd: widget.onChangeEnd,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: SsSpace.s3),
          SsSegmented<SsColorMode>(
            semanticLabel: 'Colour model',
            expand: true,
            selected: _mode,
            onChanged: (m) => setState(() => _mode = m),
            segments: const [
              SsSegment(value: SsColorMode.hex, label: 'Hex'),
              SsSegment(value: SsColorMode.rgb, label: 'RGB'),
              SsSegment(value: SsColorMode.hsl, label: 'HSL'),
            ],
          ),
          const SizedBox(height: SsSpace.s2),
          _inputs(color, t),
        ],
      ),
    );
  }

  Widget _inputs(Color color, SsThemeData t) {
    final a = (color.alpha01 * 100);
    Widget alpha() => SsNumberField(
      semanticLabel: 'Alpha percent',
      value: a.roundToDouble(),
      unit: '%',
      min: 0,
      max: 100,
      fractionDigits: 0,
      onChanged: (v) => _set(_hsv.copyWith(a: v / 100)),
    );
    switch (_mode) {
      case SsColorMode.hex:
        return Row(
          children: [
            Expanded(
              child: _HexInput(color: color, onChanged: _setColor),
            ),
            const SizedBox(width: SsSpace.s2),
            SizedBox(width: 60, child: alpha()),
          ],
        );
      case SsColorMode.rgb:
        Widget ch(String name, int v, Color Function(int) apply) {
          return Expanded(
            child: SsNumberField(
              semanticLabel: name,
              value: v.toDouble(),
              min: 0,
              max: 255,
              fractionDigits: 0,
              onChanged: (n) => _setColor(apply(n.round())),
            ),
          );
        }
        final r = color.red8;
        final g = color.green8;
        final b = color.blue8;
        final al = color.alpha01;
        return Column(
          children: [
            Row(
              children: [
                ch('Red', r, (n) => rgbaColor(n, g, b, al)),
                const SizedBox(width: SsSpace.s1),
                ch('Green', g, (n) => rgbaColor(r, n, b, al)),
                const SizedBox(width: SsSpace.s1),
                ch('Blue', b, (n) => rgbaColor(r, g, n, al)),
              ],
            ),
            const SizedBox(height: SsSpace.s1),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(width: 72, child: alpha()),
            ),
          ],
        );
      case SsColorMode.hsl:
        final hsl = SsHsl.fromColor(color);
        final h = _hsv.s == 0 || _hsv.v == 0 ? _hsv.h : hsl.h;
        Widget ch(String name, double v, double max, ValueChanged<double> on) {
          return Expanded(
            child: SsNumberField(
              semanticLabel: name,
              value: v.roundToDouble(),
              min: 0,
              max: max,
              fractionDigits: 0,
              onChanged: on,
            ),
          );
        }
        return Column(
          children: [
            Row(
              children: [
                ch(
                  'Hue',
                  h,
                  360,
                  (n) => _setColor(SsHsl(n, hsl.s, hsl.l, hsl.a).toColor()),
                ),
                const SizedBox(width: SsSpace.s1),
                ch(
                  'Saturation',
                  hsl.s * 100,
                  100,
                  (n) => _setColor(SsHsl(h, n / 100, hsl.l, hsl.a).toColor()),
                ),
                const SizedBox(width: SsSpace.s1),
                ch(
                  'Lightness',
                  hsl.l * 100,
                  100,
                  (n) => _setColor(SsHsl(h, hsl.s, n / 100, hsl.a).toColor()),
                ),
              ],
            ),
            const SizedBox(height: SsSpace.s1),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(width: 72, child: alpha()),
            ),
          ],
        );
    }
  }
}

/// A hex entry that commits on Enter/blur and reverts on Escape; invalid
/// text shows the error state.
class _HexInput extends StatefulWidget {
  const _HexInput({required this.color, required this.onChanged});

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<_HexInput> createState() => _HexInputState();
}

class _HexInputState extends State<_HexInput> {
  late final TextEditingController _c = TextEditingController(text: _text());
  final FocusNode _focus = FocusNode();
  bool _invalid = false;

  String _text() => formatHexColor(widget.color, withAlpha: false).substring(1);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_HexInput old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.color != widget.color) _c.text = _text();
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = parseHexColor(_c.text);
    if (parsed == null) {
      setState(() => _invalid = _c.text.trim().isNotEmpty);
      if (_c.text.trim().isEmpty) _c.text = _text();
      return;
    }
    setState(() => _invalid = false);
    // Keep the current alpha unless the entry carried one.
    final hadAlpha =
        _c.text.trim().replaceFirst('#', '').length == 8 ||
        _c.text.trim().replaceFirst('#', '').length == 4;
    final next = hadAlpha
        ? parsed
        : parsed.withValues(alpha: widget.color.alpha01);
    _c.text = formatHexColor(next, withAlpha: false).substring(1);
    if (next != widget.color) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return SsTextField(
      controller: _c,
      focusNode: _focus,
      semanticLabel: 'Hex colour',
      revertOnEscape: true,
      selectAllOnFocus: true,
      textStyle: t.text.numeric,
      prefix: Text('#', style: t.text.caption),
      errorText: _invalid ? 'Invalid hex' : null,
      onSubmitted: (_) => _commit(),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
        LengthLimitingTextInputFormatter(9),
      ],
    );
  }
}

/// The saturation (x) / value (y) area.
class _SvArea extends StatelessWidget {
  const _SvArea({
    required this.hsv,
    required this.onChanged,
    this.onStart,
    this.onEnd,
  });

  final SsHsv hsv;
  final ValueChanged<SsHsv> onChanged;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        void at(Offset p) {
          final s = (p.dx / size.width).clamp(0.0, 1.0);
          final v = 1 - (p.dy / size.height).clamp(0.0, 1.0);
          onChanged(hsv.copyWith(s: s, v: v));
        }

        return Focus(
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            final big = HardwareKeyboard.instance.isShiftPressed ? 0.1 : 0.01;
            final k = event.logicalKey;
            if (k == LogicalKeyboardKey.arrowLeft) {
              onChanged(hsv.copyWith(s: (hsv.s - big).clamp(0.0, 1.0)));
            } else if (k == LogicalKeyboardKey.arrowRight) {
              onChanged(hsv.copyWith(s: (hsv.s + big).clamp(0.0, 1.0)));
            } else if (k == LogicalKeyboardKey.arrowUp) {
              onChanged(hsv.copyWith(v: (hsv.v + big).clamp(0.0, 1.0)));
            } else if (k == LogicalKeyboardKey.arrowDown) {
              onChanged(hsv.copyWith(v: (hsv.v - big).clamp(0.0, 1.0)));
            } else {
              return KeyEventResult.ignored;
            }
            return KeyEventResult.handled;
          },
          child: Builder(
            builder: (context) {
              final focused =
                  Focus.of(context).hasFocus &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional;
              return Semantics(
                label: 'Saturation and brightness',
                value:
                    'Saturation ${(hsv.s * 100).round()} percent, brightness ${(hsv.v * 100).round()} percent',
                focusable: true,
                child: MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanDown: (d) {
                      Focus.of(context).requestFocus();
                      onStart?.call();
                      at(d.localPosition);
                    },
                    onPanUpdate: (d) => at(d.localPosition),
                    onPanEnd: (_) => onEnd?.call(),
                    onPanCancel: () => onEnd?.call(),
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: SsRadius.brMd,
                        border: Border.all(
                          color: focused ? c.focusRing : c.border,
                          width: focused ? 2 : 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: SsRadius.brMd,
                        child: CustomPaint(
                          painter: _SvPainter(hsv),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _SvPainter extends CustomPainter {
  const _SvPainter(this.hsv);

  final SsHsv hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = hsv.pureHue);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );
    final p = Offset(hsv.s * size.width, (1 - hsv.v) * size.height);
    canvas.drawCircle(
      p,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFF000000).withValues(alpha: 0.35),
    );
    canvas.drawCircle(
      p,
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_SvPainter old) => old.hsv != hsv;
}

abstract class _Track extends StatelessWidget {
  const _Track();
}

class _HueTrack extends _Track {
  const _HueTrack();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: SsRadius.brLg,
        gradient: LinearGradient(
          colors: [
            for (var i = 0; i <= 6; i++) SsHsv(i * 60.0, 1, 1).toColor(),
          ],
        ),
      ),
    );
  }
}

class _AlphaTrack extends _Track {
  const _AlphaTrack(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SsCheckerboard(
      cell: 4,
      borderRadius: SsRadius.brLg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [color.withValues(alpha: 0), color]),
        ),
      ),
    );
  }
}

/// A horizontal slider over a gradient [track], 0..1.
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.label,
    required this.value,
    required this.valueOf,
    required this.track,
    required this.thumbColor,
    required this.onChanged,
    this.onStart,
    this.onEnd,
  });

  final String label;
  final double value;
  final String Function(double) valueOf;
  final Widget track;
  final Color thumbColor;
  final ValueChanged<double> onChanged;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        void at(double dx) => onChanged((dx / w).clamp(0.0, 1.0));
        return Focus(
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            final big = HardwareKeyboard.instance.isShiftPressed ? 0.1 : 0.01;
            final k = event.logicalKey;
            if (k == LogicalKeyboardKey.arrowLeft ||
                k == LogicalKeyboardKey.arrowDown) {
              onChanged((value - big).clamp(0.0, 1.0));
            } else if (k == LogicalKeyboardKey.arrowRight ||
                k == LogicalKeyboardKey.arrowUp) {
              onChanged((value + big).clamp(0.0, 1.0));
            } else if (k == LogicalKeyboardKey.home) {
              onChanged(0);
            } else if (k == LogicalKeyboardKey.end) {
              onChanged(1);
            } else {
              return KeyEventResult.ignored;
            }
            return KeyEventResult.handled;
          },
          child: Builder(
            builder: (context) {
              final focused =
                  Focus.of(context).hasFocus &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional;
              return Semantics(
                label: label,
                value: valueOf(value),
                increasedValue: valueOf((value + 0.01).clamp(0.0, 1.0)),
                decreasedValue: valueOf((value - 0.01).clamp(0.0, 1.0)),
                slider: true,
                focusable: true,
                onIncrease: () => onChanged((value + 0.01).clamp(0.0, 1.0)),
                onDecrease: () => onChanged((value - 0.01).clamp(0.0, 1.0)),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) => onStart?.call(),
                    onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
                    onHorizontalDragEnd: (_) => onEnd?.call(),
                    onTapDown: (d) {
                      Focus.of(context).requestFocus();
                      onStart?.call();
                      at(d.localPosition.dx);
                      onEnd?.call();
                    },
                    child: SizedBox(
                      height: 14,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(top: 2, bottom: 2, child: track),
                          Positioned(
                            left: (value * w) - 7,
                            top: 0,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: thumbColor,
                                border: Border.all(
                                  color: focused
                                      ? c.focusRing
                                      : const Color(0xFFFFFFFF),
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x66000000),
                                    blurRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// A colour input for the inspector: a swatch that opens the picker, and
/// the hex value. [mixed] shows "Mixed" until a colour is chosen.
class SsColorField extends StatefulWidget {
  const SsColorField({
    required this.color,
    required this.onChanged,
    this.mixed = false,
    this.placeholder = 'Mixed',
    this.semanticLabel = 'Colour',
    this.onChangeStart,
    this.onChangeEnd,
    super.key,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final bool mixed;

  /// The hint shown while [mixed] ("None" for an absent colour).
  final String placeholder;
  final String semanticLabel;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  @override
  State<SsColorField> createState() => _SsColorFieldState();
}

class _SsColorFieldState extends State<SsColorField> {
  bool _open = false;
  late final TextEditingController _text = TextEditingController(text: _hex());
  final FocusNode _focus = FocusNode();
  late Color _live = widget.color;

  String _hex() => widget.mixed
      ? ''
      : formatHexColor(widget.color, withAlpha: false).substring(1);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(SsColorField old) {
    super.didUpdateWidget(old);
    _live = widget.color;
    if (!_focus.hasFocus) _text.text = _hex();
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = parseHexColor(_text.text);
    if (parsed == null) {
      _text.text = _hex();
      return;
    }
    final next = parsed.withValues(alpha: widget.color.alpha01);
    _text.text = formatHexColor(next, withAlpha: false).substring(1);
    if (widget.mixed || next != widget.color) widget.onChanged(next);
  }

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final field = Container(
      height: SsSpace.controlHeight,
      padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: SsRadius.brMd,
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          SsColorSwatch(
            color: widget.color,
            size: 16,
            mixed: widget.mixed,
            onTap: _toggle,
            semanticLabel: '${widget.semanticLabel}, open colour picker',
          ),
          const SizedBox(width: SsSpace.s2),
          if (!widget.mixed) Text('#', style: t.text.caption),
          Expanded(
            child: SsTextField(
              bare: true,
              controller: _text,
              focusNode: _focus,
              placeholder: widget.mixed ? widget.placeholder : null,
              semanticLabel: '${widget.semanticLabel} hex',
              revertOnEscape: true,
              selectAllOnFocus: true,
              textStyle: t.text.numeric,
              onSubmitted: (_) => _commit(),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
                LengthLimitingTextInputFormatter(9),
              ],
            ),
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        AnimatedSize(
          duration: SsMotion.base,
          curve: SsMotion.easeOut,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: SsSpace.s2),
                  child: SsColorPicker(
                    color: _live,
                    onChangeStart: widget.onChangeStart,
                    onChangeEnd: widget.onChangeEnd,
                    onChanged: (c) {
                      setState(() => _live = c);
                      widget.onChanged(c);
                    },
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
