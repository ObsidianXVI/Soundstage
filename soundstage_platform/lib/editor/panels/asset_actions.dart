import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart'
    show SsToastKind;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../insert/asset_service.dart';
import '../insert/editor_notices.dart';
import '../insert/insert_actions.dart';
import 'font_info.dart';

/// What the Assets and Fonts panels do (T1.9): upload, rename, replace,
/// delete and place assets, import fonts. UI-free, so it is testable
/// without widgets.
///
/// Files are stored first (the asset store, `local://<id>`) and the
/// document changes after, as one command, so each user action is one undo
/// step. A file that cannot be used is reported through
/// [editorNoticesProvider] and changes nothing.
class AssetActions {
  AssetActions(this._ref);

  final Ref _ref;

  EditorController get _ctl => _ref.read(editorControllerProvider.notifier);
  EditorState get _state => _ref.read(editorControllerProvider);
  EditorAssetService get _service => _ref.read(editorAssetServiceProvider);
  EditorNotices get _notices => _ref.read(editorNoticesProvider);
  InsertActions get _insert => _ref.read(insertActionsProvider);

  void _say(String m, [SsToastKind k = SsToastKind.warning]) =>
      _notices.say(m, kind: k);

  // ---- Upload --------------------------------------------------------------------

  /// Opens the picker for images, audio and video and stores the files.
  Future<List<ir.Asset>> uploadMedia() async {
    final files = await _ref.read(editorFilePickerProvider)(
      accept: 'image/*,audio/*,video/*,.json,.lottie,.riv',
      multiple: true,
    );
    return files.isEmpty ? const [] : _insert.addToLibrary(files);
  }

  /// Opens the picker for audio files, stores them (computing their
  /// waveform peaks) and adds them to the library. The audio assets among
  /// the files, or nothing when cancelled or refused.
  Future<List<ir.Asset>> uploadAudio() async {
    final files = await _ref.read(editorFilePickerProvider)(
      accept: 'audio/*',
      multiple: false,
    );
    if (files.isEmpty) return const [];
    final assets = await _insert.addToLibrary(files);
    final audio = [
      for (final a in assets)
        if (a.kind == ir.AssetKind.audio) a,
    ];
    if (audio.isEmpty && assets.isNotEmpty) {
      _say('${files.first.name}: not an audio file.');
    }
    return audio;
  }

  /// Opens the picker for one image, stores it and adds it to the library
  /// (the image fill chooser's *Upload…*). Null when cancelled or refused.
  Future<ir.Asset?> uploadImage() async {
    final files = await _ref.read(editorFilePickerProvider)(accept: 'image/*');
    if (files.isEmpty) return null;
    final assets = await _insert.addToLibrary(files.take(1));
    return assets.isEmpty ? null : assets.first;
  }

  /// Opens the picker for font files and imports them.
  Future<void> uploadFonts() async {
    final files = await _ref.read(editorFilePickerProvider)(
      accept: kFontAccept,
      multiple: true,
    );
    if (files.isNotEmpty) await importFonts(files);
  }

  /// Files dropped on the Assets panel (or the canvas): fonts go to the
  /// font table, the rest to the library.
  Future<void> addFiles(Iterable<EditorFile> files) async {
    final fonts = <EditorFile>[];
    final media = <EditorFile>[];
    for (final f in files) {
      (isFontFile(f) ? fonts : media).add(f);
    }
    if (media.isNotEmpty) await _insert.addToLibrary(media);
    if (fonts.isNotEmpty) await importFonts(fonts);
  }

  /// Whether [f] looks like a font by its name or MIME type (the contents
  /// are checked on import).
  static bool isFontFile(EditorFile f) {
    final n = f.name.toLowerCase();
    return n.endsWith('.ttf') ||
        n.endsWith('.otf') ||
        n.endsWith('.woff') ||
        n.endsWith('.woff2') ||
        n.endsWith('.ttc') ||
        n.endsWith('.otc') ||
        f.mime.startsWith('font/') ||
        f.mime.contains('font');
  }

  // ---- Fonts --------------------------------------------------------------------

  /// Imports font files: each is checked (format, name, weight, axes),
  /// stored as plain sfnt, and added as a face of the family its name says.
  /// Unsupported files are refused with the reason.
  Future<void> importFonts(Iterable<EditorFile> files) async {
    final added = <String>[];
    final problems = <String>[];
    for (final f in files) {
      final r = parseFontInfo(f.bytes);
      final info = r.info;
      if (info == null) {
        problems.add('${f.name}: ${r.problem}');
        continue;
      }
      final probe = info.face('');
      final conflict = fontConflict(_state.document, info.familyName, probe);
      if (conflict != null) {
        problems.add('${f.name}: $conflict');
        continue;
      }
      try {
        final stored = await _service.add(info.sfnt, info.mime, name: f.name);
        final res = _ctl.execute(
          ImportFont(
            asset: stored,
            familyName: info.familyName,
            face: info.face(stored.id),
          ),
        );
        if (res.ok) {
          added.add(info.familyName);
        } else {
          problems.addAll([
            for (final d in res.diagnostics) '${f.name}: ${d.message}',
          ]);
        }
      } on AssetServiceException catch (e) {
        problems.add('${f.name}: ${e.message}');
      }
    }
    if (added.isNotEmpty) {
      final names = added.toSet().join(', ');
      _say(
        added.length == 1
            ? 'Added font $names.'
            : 'Added ${added.length} font files ($names).',
        SsToastKind.success,
      );
    }
    if (problems.isNotEmpty) _say(problems.join('\n'));
  }

  /// Makes [familyId] the document's default font (null: system sans).
  void setDefaultFont(String? familyId) =>
      _ctl.execute(SetDefaultFontFamily(familyId));

  /// Removes a font family; refuses (and says where it is used) when text
  /// still uses it.
  bool removeFont(String familyId) {
    final r = _ctl.execute(RemoveFontFamily(familyId));
    if (!r.ok) _say(r.diagnostics.map((d) => d.message).join('\n'));
    return r.ok;
  }

  bool removeFontFace(String familyId, String assetId) {
    final r = _ctl.execute(RemoveFontFace(familyId, assetId));
    if (!r.ok) _say(r.diagnostics.map((d) => d.message).join('\n'));
    return r.ok;
  }

  // ---- Asset edits ------------------------------------------------------------------

  ir.Asset? _asset(String id) => _state.document.assets[id];

  void rename(String assetId, String name) {
    final a = _asset(assetId);
    if (a != null) {
      _ctl.execute(UpdateAsset(a.copyWith(name: name), what: 'Rename asset'));
    }
  }

  /// Sets the default alt text of an image asset (copied to image frames
  /// made from it afterwards).
  void setAlt(String assetId, String alt) {
    final a = _asset(assetId);
    if (a != null) {
      _ctl.execute(UpdateAsset(a.copyWith(alt: alt), what: 'Edit alt text'));
    }
  }

  void setCredit(String assetId, String credit) {
    final a = _asset(assetId);
    if (a != null) {
      _ctl.execute(
        UpdateAsset(a.copyWith(credit: credit), what: 'Edit credit'),
      );
    }
  }

  /// Swaps the file behind [assetId] for [file]; the id stays, so every
  /// use shows the new file. The new file must be the same kind of media.
  Future<bool> replaceFile(String assetId, EditorFile file) async {
    final old = _asset(assetId);
    if (old == null) return false;
    final mime = mimeOfFile(file);
    final kind = mime == null ? null : mediaKindForMime(mime);
    if (mime == null || kind != old.kind) {
      _say(
        '${file.name}: replace "${old.name}" with another '
        '${old.kind.name} file.',
      );
      return false;
    }
    try {
      final fresh = await _service.replace(assetId, file.bytes, mime);
      if (kind == ir.AssetKind.audio) {
        _ref.invalidate(audioPeaksProvider(assetId));
      }
      _ctl.execute(
        UpdateAsset(
          fresh.copyWith(
            name: old.name,
            alt: old.alt,
            credit: old.credit,
            variants: old.variants,
          ),
          what: 'Replace asset',
        ),
      );
      return true;
    } on AssetServiceException catch (e) {
      _say('${file.name}: ${e.message}');
      return false;
    }
  }

  /// Picks a file and replaces [assetId] with it.
  Future<bool> pickAndReplace(String assetId) async {
    final old = _asset(assetId);
    if (old == null) return false;
    final accept = switch (old.kind) {
      ir.AssetKind.image => 'image/*',
      ir.AssetKind.audio => 'audio/*',
      ir.AssetKind.video => 'video/*',
      _ => '',
    };
    final files = await _ref.read(editorFilePickerProvider)(accept: accept);
    return files.isEmpty ? false : replaceFile(assetId, files.first);
  }

  /// Picks an audio file and makes it the sound of track [trackId] only
  /// (content mode's *Replace*): the file becomes a new asset and the track
  /// points at it, so other tracks that share the old asset keep it. The
  /// old asset stays until the unused-asset clean-up. One undo step.
  ///
  /// Unlike [pickAndReplace] (the Assets panel's *Replace file…*, which
  /// swaps the file behind an asset everywhere it is used).
  Future<bool> pickAndReplaceTrack(String trackId) async {
    final track = _state.document.audioTracks
        .where((t) => t.id == trackId)
        .firstOrNull;
    if (track == null) return false;
    final files = await _ref.read(editorFilePickerProvider)(accept: 'audio/*');
    if (files.isEmpty) return false;
    final file = files.first;
    final mime = mimeOfFile(file);
    if (mime == null || mediaKindForMime(mime) != ir.AssetKind.audio) {
      _say('${file.name}: choose an audio file.');
      return false;
    }
    final anchor = _ctl.history.lastEntry;
    final assets = await _insert.addToLibrary([file]);
    if (assets.isEmpty) return false;
    final r = _ctl.execute(SetAudioTrackAsset(trackId, assets.first.id));
    if (!r.ok) {
      _say(r.diagnostics.map((d) => d.message).join('\n'));
      return false;
    }
    _ctl.squashHistoryAfter(anchor, 'Replace sound');
    return true;
  }

  /// Deletes [assetId] if nothing uses it. Returns the places that use it
  /// instead when something does (the asset stays).
  List<AssetUsage> delete(String assetId) {
    final uses = assetUsages(_state.document)[assetId] ?? const [];
    if (uses.isNotEmpty) return uses;
    _ctl.execute(DeleteAssets([assetId]));
    return const [];
  }

  /// Points every use of [fromId] at [toId] and deletes [fromId].
  bool replaceEverywhere(String fromId, String toId) {
    final r = _ctl.execute(ReplaceAssetEverywhere(fromId, toId));
    if (!r.ok) _say(r.diagnostics.map((d) => d.message).join('\n'));
    return r.ok;
  }

  // ---- Placing -----------------------------------------------------------------------

  /// Uses image [assetId] as the fill of the selected nodes; with nothing
  /// selected, does nothing and returns false.
  bool applyAsFill(String assetId) => _insert.applyAsFillToSelection(assetId);

  /// Places image [assetId] as a new frame (see `InsertActions.insertImages`).
  void insertOnCanvas(String assetId) {
    final a = _asset(assetId);
    if (a != null && a.kind == ir.AssetKind.image) _insert.insertImages([a]);
  }

  /// The bytes of [assetId] for a thumbnail.
  Future<Uint8List?> bytes(String assetId) => _service.bytes(assetId);
}

final assetActionsProvider = Provider<AssetActions>(
  AssetActions.new,
  dependencies: [
    editorControllerProvider,
    insertActionsProvider,
    editorAssetServiceProvider,
    editorFilePickerProvider,
  ],
);
