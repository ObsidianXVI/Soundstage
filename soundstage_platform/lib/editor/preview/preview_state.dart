import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/runtime/runtime.dart' show StageTier;

/// Narrowest and widest free preview width.
const double kPreviewMinFreeWidth = 200;
const double kPreviewMaxFreeWidth = 3840;

/// [PreviewState.breakpointId] value for the free width.
const String kPreviewFreeWidth = '@free';

/// The preview split's state (T2.6). Lives in the editor's own provider
/// scope, so it belongs to one open editor: it survives panel toggles and
/// edits, and is gone with the editor.
@immutable
class PreviewState {
  const PreviewState({
    this.open = false,
    this.fraction = 0.42,
    this.breakpointId,
    this.freeWidth = 800,
    this.muted = false,
    this.follow = false,
    this.tier = StageTier.full,
  });

  /// Whether the canvas area is split.
  final bool open;

  /// The preview pane's share of the canvas area's width.
  final double fraction;

  /// The primary breakpoint whose design size the preview renders at,
  /// [kPreviewFreeWidth] for the free width, or null (not chosen yet: the
  /// first primary breakpoint).
  final String? breakpointId;

  /// The width used when [free].
  final double freeWidth;
  final bool muted;

  /// Scroll the preview to the active scene whenever it changes.
  final bool follow;

  /// The player tier previewed (m4.md T4.6).
  final StageTier tier;

  bool get free => breakpointId == kPreviewFreeWidth;

  PreviewState copyWith({
    bool? open,
    double? fraction,
    String? breakpointId,
    double? freeWidth,
    bool? muted,
    bool? follow,
    StageTier? tier,
  }) => PreviewState(
    open: open ?? this.open,
    fraction: fraction ?? this.fraction,
    breakpointId: breakpointId ?? this.breakpointId,
    freeWidth: freeWidth ?? this.freeWidth,
    muted: muted ?? this.muted,
    follow: follow ?? this.follow,
    tier: tier ?? this.tier,
  );
}

class PreviewNotifier extends Notifier<PreviewState> {
  @override
  PreviewState build() => const PreviewState();

  void toggle() => state = state.copyWith(open: !state.open);
  void setOpen(bool open) => state = state.copyWith(open: open);

  void setFraction(double fraction) =>
      state = state.copyWith(fraction: fraction.clamp(0.15, 0.85));

  void chooseBreakpoint(String id) => state = state.copyWith(breakpointId: id);

  void chooseFree([double? width]) => state = state.copyWith(
    breakpointId: kPreviewFreeWidth,
    freeWidth: (width ?? state.freeWidth).clamp(
      kPreviewMinFreeWidth,
      kPreviewMaxFreeWidth,
    ),
  );

  void setFreeWidth(double width) => chooseFree(width);
  void toggleMuted() => state = state.copyWith(muted: !state.muted);
  void toggleFollow() => state = state.copyWith(follow: !state.follow);
  void setTier(StageTier tier) => state = state.copyWith(tier: tier);
}

final previewProvider = NotifierProvider<PreviewNotifier, PreviewState>(
  PreviewNotifier.new,
);
