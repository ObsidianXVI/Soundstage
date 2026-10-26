import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:rive/rive.dart' as rive;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_host.dart';

// A Rive embed (m3.md T3.6), loaded with a deferred import. Picks the
// artboard and state machine by name (or the file's defaults), sets the
// static `inputs`, and lets clocks drive the ones bound in `inputBindings`.
// An input name is a data-binding property of the default view model
// (number, or boolean: value > 0.5); files without data binding use their
// state machine's legacy inputs of that name.

Widget buildRiveSurface({
  required ir.EmbedNode node,
  required Uint8List bytes,
  required bool interactive,
}) => _RiveSurface(node: node, bytes: bytes, interactive: interactive);

class _RiveSurface extends StatefulWidget {
  const _RiveSurface({
    required this.node,
    required this.bytes,
    required this.interactive,
  });

  final ir.EmbedNode node;
  final Uint8List bytes;
  final bool interactive;

  @override
  State<_RiveSurface> createState() => _RiveSurfaceState();
}

class _RiveSurfaceState extends State<_RiveSurface> {
  rive.File? _file;
  rive.RiveWidgetController? _controller;
  rive.ViewModelInstance? _vm;
  RenderStageHost? _host;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _host = context.findAncestorRenderObjectOfType<RenderStageHost>()
        ?..onInput = _onInput;
    });
  }

  Future<void> _load() async {
    try {
      final file = await rive.File.decode(
        widget.bytes,
        riveFactory: rive.Factory.rive,
      );
      if (file == null || !mounted) return;
      final n = widget.node;
      final controller = rive.RiveWidgetController(
        file,
        artboardSelector: n.artboard == null
            ? rive.ArtboardSelector.byDefault()
            : rive.ArtboardSelector.byName(n.artboard!),
        stateMachineSelector: n.stateMachine == null
            ? rive.StateMachineSelector.byDefault()
            : rive.StateMachineSelector.byName(n.stateMachine!),
      );
      try {
        _vm = controller.dataBind(rive.DataBind.auto());
      } on Object {
        _vm = null; // no view model: legacy inputs only
      }
      n.inputs.forEach((name, v) {
        switch (v) {
          case ir.NumberValue(:final value):
            _set(controller, name, value);
          case ir.BoolValue(:final value):
            _set(controller, name, value ? 1 : 0);
          default:
            break;
        }
      });
      setState(() {
        _file = file;
        _controller = controller;
      });
      _host?.inputs.forEach(_onInput);
    } on Object catch (e) {
      debugPrint('soundstage rive: could not load: $e');
    }
  }

  void _set(rive.RiveWidgetController c, String name, double v) {
    final vm = _vm;
    if (vm != null) {
      final n = vm.number(name);
      if (n != null) {
        n.value = v;
        return;
      }
      final b = vm.boolean(name);
      if (b != null) {
        b.value = v > 0.5;
        return;
      }
    }
    // Files made before data binding.
    // ignore: deprecated_member_use
    final number = c.stateMachine.number(name);
    if (number != null) {
      number.value = v;
      return;
    }
    // ignore: deprecated_member_use
    c.stateMachine.boolean(name)?.value = v > 0.5;
  }

  void _onInput(String input, double value) {
    final c = _controller;
    if (c != null) _set(c, input, value);
  }

  @override
  void dispose() {
    if (_host?.onInput == _onInput) _host?.onInput = null;
    _controller?.dispose();
    _file?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const SizedBox.expand();
    return rive.RiveWidget(
      controller: c,
      fit: widget.node.scaleMode == ir.ImageScaleMode.fill
          ? rive.Fit.cover
          : rive.Fit.contain,
    );
  }
}
