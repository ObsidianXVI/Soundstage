import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart' show stageColor;

import '../core/core.dart';
import '../insert/asset_service.dart';
import '../insert/canvas_drop.dart';
import '../insert/file_drop.dart';
import 'asset_actions.dart';
import 'fonts_panel.dart';

/// The Assets tab of the left panel (T1.9): the story's media and fonts.
///
/// **Media** is a grid of the document's assets: image thumbnails (the
/// dominant colour shows until the picture is read from storage), kind
/// icons for audio, video and other files, with name, size and
/// dimensions. Upload with the button, or drop files from the desktop on
/// the panel (fonts dropped here go to the font table).
///
/// - Clicking an **image** with nodes selected sets it as their image fill
///   (replacing the image paint, or adding one); with nothing selected it
///   only selects the asset.
/// - Dragging an image onto the canvas makes an image frame there, or
///   fills the frame or shape it is dropped on.
/// - The selected asset's details: rename, default alt text (copied to
///   frames made from it), credit, size, **Insert**, **Replace file…**
///   (same id, so every use updates), **Where used** and **Delete**. A
///   used asset cannot be deleted: the dialog lists where it is used and
///   offers *Replace everywhere* with another asset.
///
/// **Fonts** is [FontsPanel].
class AssetsPanel extends ConsumerStatefulWidget {
  const AssetsPanel({super.key});

  @override
  ConsumerState<AssetsPanel> createState() => _AssetsPanelState();
}

enum _Section { media, fonts }

class _AssetsPanelState extends ConsumerState<AssetsPanel> {
  _Section _section = _Section.media;
  String? _selected;

  AssetActions get _actions => ref.read(assetActionsProvider);

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final available = ref.watch(
      editorAssetServiceProvider.select((s) => s.available),
    );
    return FileDropTarget(
      caption: 'Drop to add to Assets',
      onDrop: (files, _) => _actions.addFiles(files),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SsSpace.s3,
              SsSpace.s3,
              SsSpace.s3,
              SsSpace.s2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SsSegmented<_Section>(
                    semanticLabel: 'Assets section',
                    expand: true,
                    selected: _section,
                    onChanged: (v) => setState(() => _section = v),
                    segments: const [
                      SsSegment(value: _Section.media, label: 'Media'),
                      SsSegment(value: _Section.fonts, label: 'Fonts'),
                    ],
                  ),
                ),
                const SizedBox(width: SsSpace.s2),
                SsIconButton(
                  key: const ValueKey<String>('assets-upload'),
                  icon: SsIcons.plus,
                  semanticLabel: _section == _Section.media
                      ? 'Upload files'
                      : 'Upload fonts',
                  tooltip: _section == _Section.media
                      ? 'Upload images, audio or video'
                      : 'Upload fonts (TTF, OTF, WOFF)',
                  onPressed: () => unawaited(
                    _section == _Section.media
                        ? _actions.uploadMedia()
                        : _actions.uploadFonts(),
                  ),
                ),
              ],
            ),
          ),
          if (!available)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SsSpace.s3,
                0,
                SsSpace.s3,
                SsSpace.s2,
              ),
              child: Text(
                'Browser storage is blocked, so files cannot be added.',
                style: t.text.small.copyWith(color: t.colors.warning),
              ),
            ),
          Expanded(
            child: _section == _Section.media
                ? _MediaSection(
                    selected: _selected,
                    onSelect: (id) => setState(() => _selected = id),
                  )
                : const FontsPanel(),
          ),
        ],
      ),
    );
  }
}

// ---- Media ----------------------------------------------------------------------

class _MediaSection extends ConsumerWidget {
  const _MediaSection({required this.selected, required this.onSelect});

  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final assets = ref.watch(
      editorControllerProvider.select((s) => s.document.assets),
    );
    final media = [
      for (final a in assets.values)
        if (a.kind != ir.AssetKind.font) a,
    ];
    final picked = selected == null ? null : assets[selected];
    if (media.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SsSpace.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SsIcon(SsIcons.imagePlus, size: 24, color: t.colors.textDisabled),
              const SizedBox(height: SsSpace.s3),
              Text('No media yet', style: t.text.bodyStrong),
              const SizedBox(height: SsSpace.s1),
              Text(
                'Upload images, audio or video, or drop files here.',
                textAlign: TextAlign.center,
                style: t.text.small.copyWith(color: t.colors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(SsSpace.s3),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 112,
              mainAxisSpacing: SsSpace.s2,
              crossAxisSpacing: SsSpace.s2,
              mainAxisExtent: 112,
            ),
            itemCount: media.length,
            itemBuilder: (_, i) {
              final a = media[i];
              return _AssetTile(
                key: ValueKey<String>('asset-tile:${a.id}'),
                asset: a,
                selected: a.id == selected,
                onTap: () {
                  onSelect(a.id);
                  final selecting = ref
                      .read(editorControllerProvider)
                      .selection
                      .isNotEmpty;
                  if (selecting && a.kind == ir.AssetKind.image) {
                    ref.read(assetActionsProvider).applyAsFill(a.id);
                  }
                },
              );
            },
          ),
        ),
        if (picked != null && picked.kind != ir.AssetKind.font)
          _AssetDetails(
            key: ValueKey<String>('asset-details:${picked.id}'),
            asset: picked,
            onDeleted: () => onSelect(null),
          ),
      ],
    );
  }
}

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) {
    return '${(n / 1024).toStringAsFixed(n < 10240 ? 1 : 0)} KB';
  }
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// "1200 × 800 · 340 KB", "3:21 · 4.2 MB".
String assetFacts(ir.Asset a) {
  final parts = <String>[
    if (a.width != null && a.height != null) '${a.width} × ${a.height}',
    if (a.duration != null) _duration(a.duration!),
    if (a.byteSize > 0) formatBytes(a.byteSize),
  ];
  return parts.join(' · ');
}

String _duration(double s) {
  final m = s ~/ 60;
  final r = (s - m * 60).floor().toString().padLeft(2, '0');
  return '$m:$r';
}

IconData assetIcon(ir.AssetKind k) => switch (k) {
  ir.AssetKind.image => SsIcons.image,
  ir.AssetKind.audio => SsIcons.music,
  ir.AssetKind.video => SsIcons.film,
  _ => SsIcons.file,
};

class _AssetTile extends ConsumerWidget {
  const _AssetTile({
    required this.asset,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final ir.Asset asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final thumb = AssetThumb(asset: asset);
    Widget tile = SsInteractive(
      onTap: onTap,
      selected: selected,
      semanticLabel: asset.name.isEmpty ? asset.id : asset.name,
      semanticValue: '${asset.kind.name}, ${assetFacts(asset)}',
      excludeSemantics: true,
      builder: (context, s) => Container(
        decoration: BoxDecoration(
          borderRadius: SsRadius.brMd,
          border: Border.all(
            color: selected
                ? c.accent
                : s.contains(WidgetState.hovered)
                ? c.borderStrong
                : c.border,
            width: selected ? 2 : 1,
          ),
          color: c.surface2,
        ),
        padding: const EdgeInsets.all(SsSpace.s1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(borderRadius: SsRadius.brSm, child: thumb),
            ),
            const SizedBox(height: SsSpace.s1),
            Text(
              asset.name.isEmpty ? asset.id : asset.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.text.small,
            ),
            Text(
              assetFacts(asset),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.text.caption,
            ),
          ],
        ),
      ),
    );
    if (asset.kind == ir.AssetKind.image) {
      tile = Draggable<AssetDrag>(
        data: AssetDrag(asset.id),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: IgnorePointer(
          child: Opacity(
            opacity: 0.85,
            child: SizedBox(
              width: 72,
              height: 72,
              child: ClipRRect(
                borderRadius: SsRadius.brSm,
                child: AssetThumb(asset: asset),
              ),
            ),
          ),
        ),
        child: tile,
      );
    }
    return tile;
  }
}

/// A thumbnail of [asset]: for images, the picture (decoded small) over
/// the asset's dominant colour, which shows until the file is read from
/// storage; for other kinds an icon.
class AssetThumb extends ConsumerStatefulWidget {
  const AssetThumb({required this.asset, super.key});

  final ir.Asset asset;

  @override
  ConsumerState<AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends ConsumerState<AssetThumb> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AssetThumb old) {
    super.didUpdateWidget(old);
    // A replaced file keeps the id but changes its facts.
    if (old.asset != widget.asset) _load();
  }

  void _load() {
    _bytes = widget.asset.kind == ir.AssetKind.image
        ? ref.read(editorAssetServiceProvider).bytes(widget.asset.id)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final a = widget.asset;
    final dominant = a.placeholder?.dominantColor;
    final base = dominant == null ? t.colors.surface3 : stageColor(dominant);
    if (a.kind != ir.AssetKind.image) {
      return ColoredBox(
        color: t.colors.surface3,
        child: Center(
          child: SsIcon(
            assetIcon(a.kind),
            size: 24,
            color: t.colors.textSecondary,
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        FutureBuilder<Uint8List?>(
          future: _bytes,
          builder: (_, snap) {
            final b = snap.data;
            if (b == null) return const SizedBox.shrink();
            return Image.memory(
              b,
              fit: BoxFit.cover,
              cacheWidth: 224,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            );
          },
        ),
      ],
    );
  }
}

// ---- Details ---------------------------------------------------------------------

class _AssetDetails extends ConsumerWidget {
  const _AssetDetails({
    required this.asset,
    required this.onDeleted,
    super.key,
  });

  final ir.Asset asset;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final actions = ref.read(assetActionsProvider);
    final isImage = asset.kind == ir.AssetKind.image;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.colors.borderSubtle)),
      ),
      padding: const EdgeInsets.all(SsSpace.s3),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _CommitField(
              fieldKey: const ValueKey<String>('asset-name'),
              label: 'Name',
              value: asset.name,
              onCommit: (v) => actions.rename(asset.id, v),
            ),
            if (isImage) ...[
              const SizedBox(height: SsSpace.s2),
              _CommitField(
                fieldKey: const ValueKey<String>('asset-alt'),
                label: 'Alt text',
                placeholder: 'Describe the image (copied to new frames)',
                value: asset.alt,
                onCommit: (v) => actions.setAlt(asset.id, v),
              ),
            ],
            const SizedBox(height: SsSpace.s2),
            Text(
              '${asset.kind.name} · ${assetFacts(asset)}',
              style: t.text.caption,
            ),
            const SizedBox(height: SsSpace.s2),
            Wrap(
              spacing: SsSpace.s2,
              runSpacing: SsSpace.s2,
              children: [
                if (isImage)
                  SsButton(
                    key: const ValueKey<String>('asset-insert'),
                    label: 'Insert',
                    icon: SsIcons.imagePlus,
                    onPressed: () => actions.insertOnCanvas(asset.id),
                  ),
                SsButton(
                  key: const ValueKey<String>('asset-replace'),
                  label: 'Replace file…',
                  onPressed: () => unawaited(actions.pickAndReplace(asset.id)),
                ),
                SsButton(
                  key: const ValueKey<String>('asset-used'),
                  label: 'Where used',
                  onPressed: () => _showUsage(context, ref),
                ),
                SsButton(
                  key: const ValueKey<String>('asset-delete'),
                  label: 'Delete',
                  variant: SsButtonVariant.danger,
                  icon: SsIcons.trash2,
                  onPressed: () => _delete(context, ref),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showUsage(BuildContext context, WidgetRef ref) {
    final uses =
        assetUsages(ref.read(editorControllerProvider).document)[asset.id] ??
        const <AssetUsage>[];
    unawaited(
      showSsDialog<void>(
        context,
        builder: (ctx) => SsDialog(
          title:
              'Where "${asset.name.isEmpty ? asset.id : asset.name}" is used',
          content: _UsageList(uses: uses),
          actions: [
            SsButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
          ],
        ),
      ),
    );
  }

  void _delete(BuildContext context, WidgetRef ref) {
    final actions = ref.read(assetActionsProvider);
    final uses = actions.delete(asset.id);
    if (uses.isEmpty) {
      onDeleted();
      return;
    }
    unawaited(
      showSsDialog<void>(
        context,
        builder: (ctx) => _InUseDialog(asset: asset, uses: uses),
      ),
    );
  }
}

class _UsageList extends StatelessWidget {
  const _UsageList({required this.uses});

  final List<AssetUsage> uses;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    if (uses.isEmpty) {
      return Text(
        'Nothing uses this asset yet.',
        style: t.text.body.copyWith(color: t.colors.textSecondary),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final u in uses)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(u.label, style: t.text.body),
              ),
          ],
        ),
      ),
    );
  }
}

class _InUseDialog extends ConsumerStatefulWidget {
  const _InUseDialog({required this.asset, required this.uses});

  final ir.Asset asset;
  final List<AssetUsage> uses;

  @override
  ConsumerState<_InUseDialog> createState() => _InUseDialogState();
}

class _InUseDialogState extends ConsumerState<_InUseDialog> {
  String? _with;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final assets = ref.watch(
      editorControllerProvider.select((s) => s.document.assets),
    );
    final others = [
      for (final a in assets.values)
        if (a.kind == widget.asset.kind && a.id != widget.asset.id) a,
    ];
    final name = widget.asset.name.isEmpty
        ? widget.asset.id
        : widget.asset.name;
    return SsDialog(
      title: 'Asset in use',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '"$name" cannot be deleted while it is used. It is used by:',
            style: t.text.body,
          ),
          const SizedBox(height: SsSpace.s2),
          _UsageList(uses: widget.uses),
          const SizedBox(height: SsSpace.s4),
          Text('Replace everywhere with', style: t.text.caption),
          const SizedBox(height: SsSpace.s1),
          SsDropdown<String>(
            semanticLabel: 'Replacement asset',
            hint: others.isEmpty
                ? 'No other ${widget.asset.kind.name}'
                : 'Choose…',
            value: _with,
            enabled: others.isNotEmpty,
            onChanged: (v) => setState(() => _with = v),
            items: [
              for (final a in others)
                SsDropdownItem(
                  value: a.id,
                  label: a.name.isEmpty ? a.id : a.name,
                  icon: assetIcon(a.kind),
                ),
            ],
          ),
        ],
      ),
      actions: [
        SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SsButton(
          key: const ValueKey<String>('asset-replace-everywhere'),
          label: 'Replace everywhere',
          variant: SsButtonVariant.primary,
          onPressed: _with == null
              ? null
              : () {
                  ref
                      .read(assetActionsProvider)
                      .replaceEverywhere(widget.asset.id, _with!);
                  Navigator.of(context).pop();
                },
        ),
      ],
    );
  }
}

/// A labelled text field that commits when the author presses Enter or
/// leaves it (one undo step per edit, not per keystroke).
class _CommitField extends StatefulWidget {
  const _CommitField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onCommit,
    this.placeholder,
  });

  final Key fieldKey;
  final String label;
  final String value;
  final String? placeholder;
  final ValueChanged<String> onCommit;

  @override
  State<_CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<_CommitField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_CommitField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && !_focus.hasFocus) {
      _controller.text = widget.value;
    }
  }

  void _commit() {
    if (_controller.text != widget.value) widget.onCommit(_controller.text);
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.label, style: t.text.caption),
        const SizedBox(height: 2),
        SsTextField(
          key: widget.fieldKey,
          controller: _controller,
          focusNode: _focus,
          placeholder: widget.placeholder,
          semanticLabel: widget.label,
          revertOnEscape: true,
          releaseFocusOnSubmit: true,
          onSubmitted: (_) => _commit(),
        ),
      ],
    );
  }
}
