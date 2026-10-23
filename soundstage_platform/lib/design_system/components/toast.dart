import 'dart:async';

import 'package:flutter/material.dart';

import '../icons/ss_icons.dart';
import '../tokens/elevation.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'button.dart';
import 'icon.dart';

enum SsToastKind { info, success, warning, danger }

/// Transient notifications, stacked at the bottom centre. Announced to
/// assistive tech as a live region.
abstract final class SsToast {
  static final Expando<_Host> _hosts = Expando<_Host>('SsToast');

  /// Shows a toast; returns a function that dismisses it early.
  static VoidCallback show(
    BuildContext context,
    String message, {
    SsToastKind kind = SsToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = SsMotion.toastDuration,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final host = _hosts[overlay] ??= _Host(overlay, SsTheme.of(context));
    return host.add(_ToastData(message, kind, actionLabel, onAction, duration));
  }
}

class _ToastData {
  _ToastData(
    this.message,
    this.kind,
    this.actionLabel,
    this.onAction,
    this.duration,
  );

  final String message;
  final SsToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  Timer? timer;
}

class _Host {
  _Host(this.overlay, this.theme);

  final OverlayState overlay;
  final SsThemeData theme;
  final ValueNotifier<List<_ToastData>> items = ValueNotifier(const []);
  OverlayEntry? _entry;

  VoidCallback add(_ToastData d) {
    items.value = [...items.value, d];
    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (_) => SsScope(
          theme: theme,
          child: _ToastStack(items: items, onDismiss: remove),
        ),
      );
      overlay.insert(_entry!);
    }
    d.timer = Timer(d.duration, () => remove(d));
    return () => remove(d);
  }

  void remove(_ToastData d) {
    d.timer?.cancel();
    if (!items.value.contains(d)) return;
    items.value = items.value.where((e) => e != d).toList();
    if (items.value.isEmpty) {
      _entry?.remove();
      _entry?.dispose();
      _entry = null;
    }
  }
}

class _ToastStack extends StatelessWidget {
  const _ToastStack({required this.items, required this.onDismiss});

  final ValueNotifier<List<_ToastData>> items;
  final ValueChanged<_ToastData> onDismiss;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s4),
        child: ValueListenableBuilder<List<_ToastData>>(
          valueListenable: items,
          builder: (context, list, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final d in list)
                Padding(
                  padding: const EdgeInsets.only(top: SsSpace.s2),
                  child: _ToastCard(data: d, onDismiss: () => onDismiss(d)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.data, required this.onDismiss});

  final _ToastData data;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final (icon, tint) = switch (data.kind) {
      SsToastKind.info => (SsIcons.info, c.accentText),
      SsToastKind.success => (SsIcons.circleCheck, c.success),
      SsToastKind.warning => (SsIcons.triangleAlert, c.warning),
      SsToastKind.danger => (SsIcons.circleAlert, c.danger),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      label: data.message,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420, minHeight: 40),
        padding: const EdgeInsets.fromLTRB(
          SsSpace.s3,
          SsSpace.s1,
          SsSpace.s1,
          SsSpace.s1,
        ),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: SsRadius.brLg,
          border: Border.all(color: c.border),
          boxShadow: SsElevation.e2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsIcon(icon, size: 16, color: tint),
            const SizedBox(width: SsSpace.s2),
            Flexible(child: Text(data.message, style: t.text.body)),
            if (data.actionLabel != null) ...[
              const SizedBox(width: SsSpace.s2),
              SsButton(
                label: data.actionLabel!,
                variant: SsButtonVariant.ghost,
                onPressed: () {
                  data.onAction?.call();
                  onDismiss();
                },
              ),
            ],
            SsIconButton(
              icon: SsIcons.x,
              semanticLabel: 'Dismiss',
              size: 24,
              iconSize: 14,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
