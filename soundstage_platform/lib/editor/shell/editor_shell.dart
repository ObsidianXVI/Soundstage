import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../shortcuts/editor_shortcuts.dart';
import '../shortcuts/intents.dart';
import '../shortcuts/shortcut_help.dart';
import 'content_mode_screen.dart';
import 'editor_layout.dart';
import 'resize_handle.dart';
import 'toolbar.dart';

/// The editor frame for one story: toolbar, resizable left panel, canvas,
/// inspector and the timeline strip.
///
/// The panels, canvas and inspector are placeholders; T1.3-T1.8 fill them.
/// Below [kEditorMinWidth] it shows [ContentModeScreen] instead.
class EditorShell extends ConsumerWidget {
  const EditorShell({
    required this.document,
    required this.onBack,
    required this.onPreview,
    super.key,
  });

  final ir.StageDocument document;
  final VoidCallback onBack;

  /// Opens the player for this story (`/play/:id`).
  final VoidCallback onPreview;

  String get _title =>
      document.meta.title.isEmpty ? 'Untitled story' : document.meta.title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < kEditorMinWidth) {
          return ContentModeScreen(
            title: _title,
            scenes: document.scenes,
            onPlay: onPreview,
            onBack: onBack,
          );
        }
        return _DockedEditor(
          document: document,
          title: _title,
          width: box.maxWidth,
          onBack: onBack,
          onPreview: onPreview,
        );
      },
    );
  }
}

class _DockedEditor extends ConsumerWidget {
  const _DockedEditor({
    required this.document,
    required this.title,
    required this.width,
    required this.onBack,
    required this.onPreview,
  });

  final ir.StageDocument document;
  final String title;
  final double width;
  final VoidCallback onBack;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ss.colors;
    final layout = ref.watch(editorLayoutProvider);
    final notifier = ref.read(editorLayoutProvider.notifier);

    // Keep the canvas usable if the window shrank after the panels grew.
    final maxSide = math.max(
      kLeftPanelMin,
      (width - kCanvasMinWidth) - (layout.rightOpen ? kRightPanelMin : 0),
    );
    final leftW = layout.leftWidth.clamp(
      kLeftPanelMin,
      math.min(kLeftPanelMax, maxSide),
    );
    final maxRight = math.max(
      kRightPanelMin,
      width - kCanvasMinWidth - (layout.leftOpen ? leftW : 0),
    );
    final rightW = layout.rightWidth.clamp(
      kRightPanelMin,
      math.min(kRightPanelMax, maxRight),
    );

    void help() => showShortcutHelp(context);

    return EditorShortcuts(
      child: Actions(
        actions: <Type, Action<Intent>>{
          ShowShortcutHelpIntent: EditorAction<ShowShortcutHelpIntent>(
            (_) => help(),
          ),
          ToggleLeftPanelIntent: EditorAction<ToggleLeftPanelIntent>(
            (_) => notifier.toggleLeft(),
          ),
          ToggleRightPanelIntent: EditorAction<ToggleRightPanelIntent>(
            (_) => notifier.toggleRight(),
          ),
          ToggleTimelineIntent: EditorAction<ToggleTimelineIntent>(
            (_) => notifier.toggleTimeline(),
          ),
          PreviewIntent: EditorAction<PreviewIntent>((_) => onPreview()),
        },
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: c.surface0,
            child: Column(
              children: [
                EditorToolbar(
                  title: title,
                  onBack: onBack,
                  onPreview: onPreview,
                  onHelp: help,
                ),
                Expanded(
                  child: Row(
                    children: [
                      if (layout.leftOpen) ...[
                        SizedBox(
                          width: leftW.toDouble(),
                          child: _LeftPanel(document: document),
                        ),
                        ResizeHandle(
                          semanticLabel: 'Resize left panel',
                          onDelta: (d) => notifier.setLeftWidth(
                            leftW + d,
                            available: width,
                          ),
                          onReset: () => notifier.setLeftWidth(264),
                        ),
                      ],
                      Expanded(child: _CanvasPlaceholder(document: document)),
                      if (layout.rightOpen) ...[
                        ResizeHandle(
                          semanticLabel: 'Resize inspector',
                          onDelta: (d) => notifier.setRightWidth(
                            rightW - d,
                            available: width,
                          ),
                          onReset: () => notifier.setRightWidth(288),
                        ),
                        SizedBox(
                          width: rightW.toDouble(),
                          child: const _InspectorPlaceholder(),
                        ),
                      ],
                    ],
                  ),
                ),
                _TimelineStrip(open: layout.timelineOpen),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsIcon(icon, size: 24, color: t.colors.textDisabled),
            const SizedBox(height: SsSpace.s3),
            Text(title, style: t.text.bodyStrong, textAlign: TextAlign.center),
            const SizedBox(height: SsSpace.s1),
            Text(
              body,
              textAlign: TextAlign.center,
              style: t.text.small.copyWith(color: t.colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeftPanel extends ConsumerWidget {
  const _LeftPanel({required this.document});

  final ir.StageDocument document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ss.colors;
    final tab = ref.watch(editorLayoutProvider.select((s) => s.leftTab));
    final notifier = ref.read(editorLayoutProvider.notifier);
    return Container(
      color: c.surface1,
      child: Column(
        children: [
          SsTabs(
            selectedId: tab.name,
            onChanged: (id) => notifier.setLeftTab(
              LeftPanelTab.values.firstWhere((t) => t.name == id),
            ),
            tabs: const [
              SsTab(id: 'scenes', label: 'Scenes'),
              SsTab(id: 'layers', label: 'Layers'),
              SsTab(id: 'assets', label: 'Assets'),
            ],
          ),
          Expanded(
            child: SsTabPanel(
              label: '${tab.name} panel',
              child: switch (tab) {
                LeftPanelTab.scenes =>
                  document.scenes.isEmpty
                      ? const _EmptyState(
                          icon: SsIcons.clapperboard,
                          title: 'No scenes yet',
                          body: 'Scenes you add will be listed here.',
                        )
                      : ListView(
                          padding: const EdgeInsets.all(SsSpace.s2),
                          children: [
                            for (var i = 0; i < document.scenes.length; i++)
                              SsTreeRow(
                                icon: SsIcons.clapperboard,
                                label: document.scenes[i].name.isEmpty
                                    ? 'Scene ${i + 1}'
                                    : document.scenes[i].name,
                                renameEnabled: false,
                              ),
                          ],
                        ),
                LeftPanelTab.layers => const _EmptyState(
                  icon: SsIcons.layers,
                  title: 'Layers',
                  body: 'The layer tree of the selected scene appears here.',
                ),
                LeftPanelTab.assets => const _EmptyState(
                  icon: SsIcons.image,
                  title: 'Assets',
                  body:
                      'Images, video, audio and fonts you upload appear here.',
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _InspectorPlaceholder extends StatelessWidget {
  const _InspectorPlaceholder();

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return Container(
      color: c.surface1,
      child: const Column(
        children: [
          SizedBox(
            height: 36,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: SsSpace.s3),
                child: _InspectorTitle(),
              ),
            ),
          ),
          Expanded(
            child: _EmptyState(
              icon: SsIcons.slidersHorizontal,
              title: 'Nothing selected',
              body: 'Select a layer to edit its properties.',
            ),
          ),
        ],
      ),
    );
  }
}

class _InspectorTitle extends StatelessWidget {
  const _InspectorTitle();

  @override
  Widget build(BuildContext context) =>
      Text('Inspector', style: context.ss.text.bodyStrong);
}

/// Two artboards (the widest and narrowest breakpoints) side by side, as
/// the real canvas will lay them out (T1.3).
class _CanvasPlaceholder extends StatelessWidget {
  const _CanvasPlaceholder({required this.document});

  final ir.StageDocument document;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final bps = [...document.breakpoints]
      ..sort((a, b) => b.minWidth.compareTo(a.minWidth));
    final boards = <ir.Breakpoint>[
      if (bps.isNotEmpty) bps.first,
      if (bps.length > 1) bps.last,
    ];
    return ClipRect(
      child: Semantics(
        label: 'Canvas',
        container: true,
        child: CustomPaint(
          painter: _DotGridPainter(c.borderSubtle),
          child: LayoutBuilder(
            builder: (context, box) {
              const pad = SsSpace.s8;
              const gap = SsSpace.s8;
              final availW = math.max(
                1.0,
                box.maxWidth - pad * 2 - gap * (boards.length - 1),
              );
              final availH = math.max(1.0, box.maxHeight - pad * 2 - 24);
              final totalW = boards.fold<double>(
                0,
                (s, b) => s + b.designSize.width,
              );
              final maxH = boards.fold<double>(
                0,
                (s, b) => math.max(s, b.designSize.height),
              );
              // A board's caption needs at least [labelW]; narrow boards
              // (mobile) get padded, so solve the scale in two passes.
              const labelW = 120.0;
              var scale = math.min(availW / totalW, availH / maxH);
              for (var pass = 0; pass < 2; pass++) {
                var extra = 0.0;
                var fixedW = 0.0;
                for (final b in boards) {
                  if (b.designSize.width * scale < labelW) {
                    fixedW += labelW;
                  } else {
                    fixedW += 0;
                    extra += b.designSize.width;
                  }
                }
                scale = math.min(
                  extra == 0 ? double.infinity : (availW - fixedW) / extra,
                  availH / maxH,
                );
              }
              scale = math.max(scale, 0.01);
              return Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < boards.length; i++) ...[
                      if (i > 0) const SizedBox(width: gap),
                      SizedBox(
                        width: math.max(
                          boards[i].designSize.width * scale,
                          labelW,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${boards[i].name}  ${boards[i].designSize.width.round()}×${boards[i].designSize.height.round()}',
                              style: t.text.caption,
                            ),
                            const SizedBox(height: SsSpace.s1),
                            Container(
                              width: boards[i].designSize.width * scale,
                              height: boards[i].designSize.height * scale,
                              decoration: const BoxDecoration(
                                color: Color(0xFFFFFFFF),
                                boxShadow: SsElevation.e2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  const _DotGridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var y = 12.0; y < size.height; y += 24) {
      for (var x = 12.0; x < size.width; x += 24) {
        canvas.drawCircle(Offset(x, y), 1, p);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}

class _TimelineStrip extends ConsumerWidget {
  const _TimelineStrip({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final notifier = ref.read(editorLayoutProvider.notifier);
    return AnimatedSize(
      duration: SsMotion.base,
      curve: SsMotion.easeOut,
      alignment: Alignment.topCenter,
      child: Container(
        height: open ? 200 : 32,
        decoration: BoxDecoration(
          color: c.surface1,
          border: Border(top: BorderSide(color: c.borderSubtle)),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 31,
              child: Row(
                children: [
                  const SizedBox(width: SsSpace.s3),
                  Text('Timeline', style: t.text.bodyStrong),
                  const SizedBox(width: SsSpace.s2),
                  Text('Motion editing arrives in M2', style: t.text.caption),
                  const Spacer(),
                  SsIconButton(
                    icon: open ? SsIcons.chevronDown : SsIcons.chevronUp,
                    semanticLabel: open
                        ? 'Collapse timeline'
                        : 'Expand timeline',
                    size: 24,
                    iconSize: 14,
                    onPressed: notifier.toggleTimeline,
                  ),
                  const SizedBox(width: SsSpace.s1),
                ],
              ),
            ),
            if (open)
              const Expanded(
                child: _EmptyState(
                  icon: SsIcons.audioLines,
                  title: 'Timeline',
                  body: 'Keyframes and clips will be edited here.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
