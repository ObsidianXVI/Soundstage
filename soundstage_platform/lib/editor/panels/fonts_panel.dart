import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart'
    show registerFontWithFontLoader;

import '../core/core.dart';
import '../insert/asset_service.dart';
import 'asset_actions.dart';

/// The Fonts section of the Assets tab (T1.9): the story's font families.
///
/// Upload TTF, OTF or WOFF files (the Assets panel's **+**, or drop them on
/// the panel). Each file is read for its family name, weight and style
/// (`name`, `OS/2`, `head`), so the files of one family group together;
/// variable fonts keep their axes. WOFF2 and font collections are refused
/// with a reason.
///
/// - **Default font**: the document's `defaultTextStyle.fontFamilyId`, the
///   base of every text style.
/// - Each family shows its faces with a live preview in that face; a
///   variable face lists its axes as sliders that drive the preview.
/// - **Remove** works only while no text uses the family; otherwise the
///   dialog lists where it is used.
///
/// Families added here are in `StageDocument.fonts`, which the text
/// inspector's font menu reads.
class FontsPanel extends ConsumerWidget {
  const FontsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final fonts = ref.watch(
      editorControllerProvider.select((s) => s.document.fonts),
    );
    final assets = ref.watch(
      editorControllerProvider.select((s) => s.document.assets),
    );
    final defaultId = ref.watch(
      editorControllerProvider.select(
        (s) => s.document.defaultTextStyle.fontFamilyId,
      ),
    );
    final actions = ref.read(assetActionsProvider);
    return ListView(
      padding: const EdgeInsets.all(SsSpace.s3),
      children: [
        Text('DEFAULT FONT', style: t.text.overline),
        const SizedBox(height: SsSpace.s1),
        SsDropdown<String>(
          key: const ValueKey<String>('default-font'),
          semanticLabel: 'Default font',
          value: fonts.containsKey(defaultId) ? defaultId : '',
          onChanged: (v) => actions.setDefaultFont(v.isEmpty ? null : v),
          items: [
            const SsDropdownItem(value: '', label: 'System sans'),
            for (final f in fonts.values)
              SsDropdownItem(value: f.id, label: f.name),
          ],
        ),
        const SizedBox(height: SsSpace.s4),
        Text('FAMILIES', style: t.text.overline),
        const SizedBox(height: SsSpace.s2),
        if (fonts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: SsSpace.s4),
            child: Column(
              children: [
                SsIcon(SsIcons.type, size: 24, color: t.colors.textDisabled),
                const SizedBox(height: SsSpace.s2),
                Text('No fonts yet', style: t.text.bodyStrong),
                const SizedBox(height: SsSpace.s1),
                Text(
                  'Upload TTF, OTF or WOFF files with +, or drop them here.',
                  textAlign: TextAlign.center,
                  style: t.text.small.copyWith(color: t.colors.textSecondary),
                ),
              ],
            ),
          ),
        for (final f in fonts.values)
          Padding(
            padding: const EdgeInsets.only(bottom: SsSpace.s3),
            child: FontFamilyCard(
              key: ValueKey<String>('font-family:${f.id}'),
              family: f,
              assets: assets,
              isDefault: f.id == defaultId,
            ),
          ),
      ],
    );
  }
}

const _weightNames = {
  100: 'Thin',
  200: 'Extra Light',
  300: 'Light',
  400: 'Regular',
  500: 'Medium',
  600: 'Semi Bold',
  700: 'Bold',
  800: 'Extra Bold',
  900: 'Black',
};

/// "Bold Italic", "Regular", "Variable".
String faceLabel(ir.FontFace f) {
  if (f.variable) return f.italic ? 'Variable Italic' : 'Variable';
  final w = _weightNames[(f.weight / 100).round() * 100] ?? '${f.weight}';
  return f.italic ? (f.weight == 400 ? 'Italic' : '$w Italic') : w;
}

/// One family with its faces and their previews.
class FontFamilyCard extends ConsumerWidget {
  const FontFamilyCard({
    required this.family,
    required this.assets,
    required this.isDefault,
    super.key,
  });

  final ir.FontFamily family;
  final Map<String, ir.Asset> assets;
  final bool isDefault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final actions = ref.read(assetActionsProvider);
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: SsRadius.brMd,
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(SsSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  family.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.text.bodyStrong,
                ),
              ),
              if (isDefault)
                Padding(
                  padding: const EdgeInsets.only(right: SsSpace.s1),
                  child: Text(
                    'Default',
                    style: t.text.caption.copyWith(color: c.accentText),
                  ),
                ),
              Builder(
                builder: (anchor) => SsIconButton(
                  key: ValueKey<String>('font-menu:${family.id}'),
                  icon: SsIcons.ellipsis,
                  semanticLabel: 'Font actions',
                  size: 24,
                  iconSize: 14,
                  onPressed: () => showSsMenu(
                    anchor,
                    anchor: ssGlobalRect(anchor),
                    placement: SsPlacement.belowEnd,
                    entries: [
                      SsMenuItem(
                        label: 'Use as default font',
                        checked: isDefault,
                        onSelected: () => actions.setDefaultFont(
                          isDefault ? null : family.id,
                        ),
                      ),
                      const SsMenuDivider(),
                      SsMenuItem(
                        label: 'Remove family',
                        icon: SsIcons.trash2,
                        danger: true,
                        onSelected: () => _remove(context, ref),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SsSpace.s2),
          for (final face in family.faces)
            Padding(
              padding: const EdgeInsets.only(bottom: SsSpace.s2),
              child: _FaceRow(
                key: ValueKey<String>('face:${face.assetId}'),
                family: family,
                face: face,
                asset: assets[face.assetId],
              ),
            ),
        ],
      ),
    );
  }

  void _remove(BuildContext context, WidgetRef ref) {
    final doc = ref.read(editorControllerProvider).document;
    final uses = fontUsages(doc)[family.id] ?? const <AssetUsage>[];
    if (uses.isEmpty) {
      ref.read(assetActionsProvider).removeFont(family.id);
      return;
    }
    unawaited(
      showSsDialog<void>(
        context,
        builder: (ctx) => SsDialog(
          title: '${family.name} is in use',
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Change the text that uses it first:'),
              const SizedBox(height: SsSpace.s2),
              for (final u in uses.take(12)) Text(u.label),
              if (uses.length > 12) Text('and ${uses.length - 12} more'),
            ],
          ),
          actions: [
            SsButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
          ],
        ),
      ),
    );
  }
}

const _sample = 'The quick brown fox jumps over the lazy dog';

class _FaceRow extends ConsumerStatefulWidget {
  const _FaceRow({
    required this.family,
    required this.face,
    required this.asset,
    super.key,
  });

  final ir.FontFamily family;
  final ir.FontFace face;
  final ir.Asset? asset;

  @override
  ConsumerState<_FaceRow> createState() => _FaceRowState();
}

class _FaceRowState extends ConsumerState<_FaceRow> {
  late final Map<String, double> _axes = {
    for (final a in widget.face.axes) a.tag: a.defaultValue,
  };
  late final Future<String?> _loaded = FontPreviewLoader.load(
    ref.read(editorAssetServiceProvider),
    widget.face.assetId,
  );

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final face = widget.face;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${faceLabel(face)}'
                '${face.variable ? '' : ' · ${face.weight}'}',
                style: t.text.caption,
              ),
            ),
            SsIconButton(
              key: ValueKey<String>('face-remove:${face.assetId}'),
              icon: SsIcons.x,
              semanticLabel: 'Remove ${faceLabel(face)} face',
              size: 20,
              iconSize: 12,
              onPressed: () => ref
                  .read(assetActionsProvider)
                  .removeFontFace(widget.family.id, face.assetId),
            ),
          ],
        ),
        FutureBuilder<String?>(
          future: _loaded,
          builder: (_, snap) {
            final name = snap.data;
            if (snap.connectionState == ConnectionState.done && name == null) {
              return Text(
                'This font could not be loaded.',
                style: t.text.small.copyWith(color: c.warning),
              );
            }
            return Text(
              _sample,
              key: ValueKey<String>('preview:${face.assetId}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: previewStyle(face, name, _axes, c.textPrimary),
            );
          },
        ),
        for (final a in face.axes)
          _AxisSlider(
            axis: a,
            value: _axes[a.tag] ?? a.defaultValue,
            onChanged: (v) => setState(() => _axes[a.tag] = v),
          ),
      ],
    );
  }
}

/// The preview line's style: [engineFamily] (null until loaded: the
/// default font), at the face's weight and slant with [axes] applied.
@visibleForTesting
TextStyle previewStyle(
  ir.FontFace face,
  String? engineFamily,
  Map<String, double> axes,
  Color color,
) => TextStyle(
  fontFamily: engineFamily,
  fontSize: 18,
  height: 1.3,
  color: color,
  fontStyle: face.italic ? FontStyle.italic : FontStyle.normal,
  fontWeight: FontWeight.values[((face.weight / 100).round() - 1).clamp(0, 8)],
  fontVariations: [for (final e in axes.entries) FontVariation(e.key, e.value)],
  decoration: TextDecoration.none,
);

class _AxisSlider extends StatelessWidget {
  const _AxisSlider({
    required this.axis,
    required this.value,
    required this.onChanged,
  });

  final ir.FontAxis axis;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final min = axis.min, max = axis.max > axis.min ? axis.max : axis.min + 1;
    return Row(
      children: [
        SizedBox(width: 40, child: Text(axis.tag, style: t.text.numeric)),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              activeTrackColor: c.accent,
              inactiveTrackColor: c.border,
              thumbColor: c.accent,
              overlayColor: c.accent.withValues(alpha: 0.16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              key: ValueKey<String>('axis:${axis.tag}'),
              min: min,
              max: max,
              value: value.clamp(min, max),
              semanticFormatterCallback: (v) => '${axis.tag} ${v.round()}',
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
            style: t.text.numeric,
          ),
        ),
      ],
    );
  }
}

/// Registers font files with the engine under preview-only names (the
/// document's own families load through the runtime's font table).
class FontPreviewLoader {
  FontPreviewLoader._();

  static final Map<String, Future<String?>> _loaded = {};

  /// The engine family name [assetId]'s file is registered under, or null
  /// if it cannot be read or is not a usable font. Loads once per process.
  static Future<String?> load(EditorAssetService service, String assetId) =>
      _loaded[assetId] ??= _register(service, assetId);

  static Future<String?> _register(
    EditorAssetService service,
    String assetId,
  ) async {
    try {
      final bytes = await service.bytes(assetId);
      if (bytes == null) return null;
      final name = 'ssp-$assetId';
      await registerFontWithFontLoader(name, bytes);
      return name;
    } on Object {
      return null;
    }
  }
}
