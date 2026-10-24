import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';
import 'property_commands.dart';

// Asset and font table commands (T1.9; architecture §12): adding, renaming,
// replacing and deleting assets, applying an image as a fill, and the
// document's font families. The bytes live in the asset store
// (`local://<id>`); these commands only change the document's tables.

// ---- Where things are used ---------------------------------------------------

/// What kind of thing holds a reference.
enum UsageKind { node, scene, font, audio, component, styles }

/// One place that refers to an asset or a font family.
class AssetUsage {
  const AssetUsage(this.kind, this.id, this.label);

  final UsageKind kind;

  /// The node, scene, family, track or component id.
  final String id;

  /// A human label ("Hero image", "Scene 2", "Font Inter").
  final String label;

  @override
  bool operator ==(Object other) =>
      other is AssetUsage && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'AssetUsage($kind $id "$label")';
}

/// Map keys whose string values are free text, never references.
const _freeTextKeys = {'name', 'alt', 'credit', 'text', 'altText', 'id'};

/// Where each of [ids] is referenced in [doc], by scanning the serialised
/// document for string values equal to an id. Used for assets (image
/// paints, video and embed nodes, font faces, audio, breakpoint patches,
/// styles) and for font families (`fontFamilyId` in styles and spans).
///
/// [skip] names the top-level tables that define the ids and so do not
/// count as uses (`assets` when looking for assets, `fonts` for families).
/// Free-text fields (names, alt text, text content) are ignored.
Map<String, List<AssetUsage>> findReferences(
  ir.StageDocument doc,
  Set<String> ids, {
  required String skip,
}) {
  final out = <String, Set<AssetUsage>>{};
  if (ids.isEmpty) return const {};
  final json = doc.toJson();

  void walk(Object? v, AssetUsage? owner, String? key) {
    switch (v) {
      case final String s:
        if (owner != null && ids.contains(s) && !_freeTextKeys.contains(key)) {
          (out[s] ??= {}).add(owner);
        }
      case final Map<String, dynamic> m:
        var o = owner;
        final common = m['common'];
        if (common is Map<String, dynamic> && common['id'] is String) {
          final id = common['id']! as String;
          final name = common['name'];
          o = AssetUsage(
            UsageKind.node,
            id,
            name is String && name.isNotEmpty ? name : '${m['type']} $id',
          );
        }
        for (final e in m.entries) {
          walk(e.value, o, e.key);
        }
      case final Iterable<dynamic> l:
        for (final e in l) {
          walk(e, owner, key);
        }
      default:
        break;
    }
  }

  for (final MapEntry(:key, :value) in json.entries) {
    if (key == skip) continue;
    switch (key) {
      case 'scenes':
        for (final s in value as List<dynamic>) {
          final m = s as Map<String, dynamic>;
          final name = m['name'] as String? ?? '';
          walk(
            m,
            AssetUsage(
              UsageKind.scene,
              m['id'] as String,
              name.isEmpty ? 'Scene' : name,
            ),
            null,
          );
        }
      case 'fonts':
        for (final e in (value as Map<String, dynamic>).entries) {
          final f = e.value as Map<String, dynamic>;
          walk(
            f,
            AssetUsage(UsageKind.font, e.key, 'Font ${f['name'] ?? e.key}'),
            null,
          );
        }
      case 'audioTracks':
        for (final t in value as List<dynamic>) {
          final m = t as Map<String, dynamic>;
          walk(
            m,
            AssetUsage(
              UsageKind.audio,
              m['id'] as String,
              'Audio ${m['name'] ?? m['id']}',
            ),
            null,
          );
        }
      case 'components':
        for (final e in (value as Map<String, dynamic>).entries) {
          final c = e.value as Map<String, dynamic>;
          walk(
            c,
            AssetUsage(
              UsageKind.component,
              e.key,
              'Component ${c['name'] ?? e.key}',
            ),
            null,
          );
        }
      case 'tokens':
        walk(
          value,
          const AssetUsage(UsageKind.styles, 'styles', 'Styles'),
          null,
        );
      case 'defaultTextStyle':
        walk(
          value,
          const AssetUsage(UsageKind.styles, 'default', 'Default text style'),
          null,
        );
      case 'overlay':
        walk(value, null, null);
      default:
        break;
    }
  }
  return {for (final e in out.entries) e.key: e.value.toList()};
}

/// Where each asset of [doc] is used. Assets with no uses have no entry.
Map<String, List<AssetUsage>> assetUsages(ir.StageDocument doc) =>
    findReferences(doc, doc.assets.keys.toSet(), skip: 'assets');

/// Where each font family of [doc] is used (text styles, spans, the
/// default text style).
Map<String, List<AssetUsage>> fontUsages(ir.StageDocument doc) =>
    findReferences(doc, doc.fonts.keys.toSet(), skip: 'fonts');

/// [json] with every string equal to a key of [map] replaced by its value,
/// except inside the top-level table [skip] and in free-text fields.
Object? _rewriteIds(
  Object? json,
  Map<String, String> map, {
  required String skip,
  String? key,
  bool top = false,
}) {
  switch (json) {
    case final String s:
      return !_freeTextKeys.contains(key) && map.containsKey(s) ? map[s] : s;
    case final Map<String, dynamic> m:
      return {
        for (final e in m.entries)
          e.key: top && e.key == skip
              ? e.value
              : _rewriteIds(e.value, map, skip: skip, key: e.key),
      };
    case final List<dynamic> l:
      return [for (final e in l) _rewriteIds(e, map, skip: skip, key: key)];
    default:
      return json;
  }
}

String _usageSummary(List<AssetUsage> uses) {
  final names = {for (final u in uses) u.label}.toList();
  final shown = names.take(3).join(', ');
  return names.length > 3 ? '$shown and ${names.length - 3} more' : shown;
}

// ---- Assets --------------------------------------------------------------------

/// Adds [assets] to the document's asset table (the bytes are already in
/// the store). Assets whose id is present are left as they are.
class AddAssets extends EditCommand {
  const AddAssets(this.assets);

  final List<ir.Asset> assets;

  @override
  String get label => assets.length == 1 ? 'Add asset' : 'Add assets';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final fresh = [
      for (final a in assets)
        if (!doc.assets.containsKey(a.id)) a,
    ];
    if (fresh.isEmpty) return CommandResult(document: doc, label: label);
    return CommandResult(
      document: doc.copyWith(
        assets: {...doc.assets, for (final a in fresh) a.id: a},
      ),
      label: label,
      changed: true,
    );
  }
}

/// Replaces the table entry with [asset]'s id: a rename, new alt text or
/// credit, or new metadata after the file's bytes were replaced (the id
/// and so every use stay).
class UpdateAsset extends EditCommand {
  const UpdateAsset(this.asset, {this.what = 'Edit asset'});

  final ir.Asset asset;
  final String what;

  @override
  String get label => what;

  /// A typing burst in a name field is one undo step.
  @override
  String get coalesceKey => 'asset:${asset.id}:$what';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    if (!doc.assets.containsKey(asset.id)) {
      return failedCommand(state, label, [
        commandError('There is no asset "${asset.id}".'),
      ]);
    }
    if (doc.assets[asset.id] == asset) {
      return CommandResult(document: doc, label: label);
    }
    return CommandResult(
      document: doc.copyWith(assets: {...doc.assets, asset.id: asset}),
      label: label,
      changed: true,
      coalesceKey: coalesceKey,
    );
  }
}

/// Deletes assets that nothing uses. An asset in use is not touched: the
/// result is an error that names where it is used (see
/// [ReplaceAssetEverywhere] for the alternative).
class DeleteAssets extends EditCommand {
  const DeleteAssets(this.assetIds);

  final List<String> assetIds;

  @override
  String get label => assetIds.length == 1 ? 'Delete asset' : 'Delete assets';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final uses = assetUsages(doc);
    final diags = <ir.IrDiagnostic>[];
    final remove = <String>{};
    for (final id in assetIds) {
      if (!doc.assets.containsKey(id)) continue;
      final u = uses[id];
      if (u != null && u.isNotEmpty) {
        diags.add(
          commandError(
            '"${doc.assets[id]!.name.isEmpty ? id : doc.assets[id]!.name}" '
            'is used by ${_usageSummary(u)}.',
          ),
        );
      } else {
        remove.add(id);
      }
    }
    if (diags.isNotEmpty) return failedCommand(state, label, diags);
    if (remove.isEmpty) return CommandResult(document: doc, label: label);
    return CommandResult(
      document: doc.copyWith(
        assets: {
          for (final e in doc.assets.entries)
            if (!remove.contains(e.key)) e.key: e.value,
        },
      ),
      label: label,
      changed: true,
    );
  }
}

/// Points every use of asset [fromId] at [toId], then deletes [fromId]
/// ("replace everywhere", then delete).
class ReplaceAssetEverywhere extends EditCommand {
  const ReplaceAssetEverywhere(this.fromId, this.toId);

  final String fromId;
  final String toId;

  @override
  String get label => 'Replace asset everywhere';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    if (!doc.assets.containsKey(fromId) || !doc.assets.containsKey(toId)) {
      return failedCommand(state, label, [
        commandError('Both assets must exist in the document.'),
      ]);
    }
    if (fromId == toId) return CommandResult(document: doc, label: label);
    final json = _rewriteIds(
      doc.toJson(),
      {fromId: toId},
      skip: 'assets',
      top: true,
    );
    final next = ir.StageDocument.fromJson(json! as Map<String, dynamic>);
    return CommandResult(
      document: next.copyWith(
        assets: {
          for (final e in next.assets.entries)
            if (e.key != fromId) e.key: e.value,
        },
      ),
      label: label,
      changed: true,
    );
  }
}

/// Sets [assetId] as the image fill of [nodeIds] (frames, shapes, videos):
/// the first image paint of each node takes the new asset (keeping its
/// scale mode, focal point and filters), or a new image paint is added on
/// top. Written like any fill edit, so it follows the edit scope.
class SetImageFill extends EditCommand {
  SetImageFill(this.nodeIds, this.assetId, {this.ids});

  final List<String> nodeIds;
  final String assetId;

  /// Ids for new paints (default: reserved against the document).
  final ir.IdGenerator? ids;

  @override
  String get label => 'Set image fill';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final index = ir.DocumentIndex.of(doc);
    final gen = ids ?? ir.IdGenerator.forDocument(doc);
    final reg = ir.PropertyRegistry.standard;
    final writes = <String, Map<String, ir.IrValue>>{};
    final skipped = <ir.IrDiagnostic>[];
    for (final id in nodeIds) {
      final node = index.node(id);
      final cur = node == null ? null : reg.get(node, 'fills');
      if (node == null || cur is! ir.PaintsValue) {
        skipped.add(
          commandWarning('"$id" cannot take an image fill.', nodeId: id),
        );
        continue;
      }
      var replaced = false;
      final paints = <ir.Paint>[];
      for (final p in cur.value) {
        if (!replaced && p is ir.ImagePaint) {
          paints.add(p.copyWith(assetId: assetId));
          replaced = true;
        } else {
          paints.add(p);
        }
      }
      if (!replaced) {
        paints.add(ir.Paint.image(id: gen.next(), assetId: assetId));
      }
      writes[id] = {'fills': ir.IrValue.paints(paints)};
    }
    if (writes.isEmpty) {
      return failedCommand(state, label, skipped);
    }
    final r = SetProperty.values(writes).apply(state);
    return r.copyWith(
      label: label,
      coalesceKey: null,
      diagnostics: [...r.diagnostics, ...skipped],
    );
  }
}

// ---- Fonts ---------------------------------------------------------------------

/// The family of [doc] called [name] (case-insensitive), or null.
ir.FontFamily? fontFamilyNamed(ir.StageDocument doc, String name) {
  for (final f in doc.fonts.values) {
    if (f.name.toLowerCase() == name.toLowerCase()) return f;
  }
  return null;
}

/// Why [face] cannot join the family called [familyName] in [doc]: the
/// family already has a face of that weight and style (a variable face
/// stands for every weight), or null when it can.
String? fontConflict(
  ir.StageDocument doc,
  String familyName,
  ir.FontFace face,
) {
  final family = fontFamilyNamed(doc, familyName);
  if (family == null) return null;
  final dup = family.faces.any(
    (f) =>
        f.italic == face.italic &&
        f.variable == face.variable &&
        (f.variable || f.weight == face.weight),
  );
  if (!dup) return null;
  return '${family.name} already has a '
      '${face.variable ? 'variable' : '${face.weight}'}'
      '${face.italic ? ' italic' : ''} face.';
}

/// Adds a font file to the document: [asset] (kind font, already stored)
/// and a face of [face] in the family called [familyName], creating the
/// family when no family has that name (case-insensitive). A face whose
/// weight and style the family already has is refused.
class ImportFont extends EditCommand {
  ImportFont({
    required this.asset,
    required this.familyName,
    required this.face,
    this.ids,
  });

  final ir.Asset asset;
  final String familyName;
  final ir.FontFace face;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Add font';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final family = fontFamilyNamed(doc, familyName);
    final conflict = fontConflict(doc, familyName, face);
    if (conflict != null) {
      return failedCommand(state, label, [commandError(conflict)]);
    }
    final id = family?.id ?? (ids ?? ir.IdGenerator.forDocument(doc)).next();
    final next = (family ?? ir.FontFamily(id: id, name: familyName)).copyWith(
      faces: [...?family?.faces, face],
    );
    return CommandResult(
      document: doc.copyWith(
        assets: {...doc.assets, asset.id: asset},
        fonts: {...doc.fonts, id: next},
      ),
      label: label,
      changed: true,
    );
  }
}

/// Makes [familyId] the document's default font family
/// (`defaultTextStyle.fontFamilyId`), or the runtime sans when null.
class SetDefaultFontFamily extends EditCommand {
  const SetDefaultFontFamily(this.familyId);

  final String? familyId;

  @override
  String get label => 'Set default font';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    if (familyId != null && !doc.fonts.containsKey(familyId)) {
      return failedCommand(state, label, [
        commandError('There is no font family "$familyId".'),
      ]);
    }
    if (doc.defaultTextStyle.fontFamilyId == familyId) {
      return CommandResult(document: doc, label: label);
    }
    return CommandResult(
      document: doc.copyWith(
        defaultTextStyle: doc.defaultTextStyle.copyWith(fontFamilyId: familyId),
      ),
      label: label,
      changed: true,
    );
  }
}

/// Removes a font family and its font files from the document. A family
/// that text still uses is refused with where it is used.
class RemoveFontFamily extends EditCommand {
  const RemoveFontFamily(this.familyId);

  final String familyId;

  @override
  String get label => 'Remove font';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final family = doc.fonts[familyId];
    if (family == null) return CommandResult(document: doc, label: label);
    final uses = fontUsages(doc)[familyId] ?? const <AssetUsage>[];
    if (uses.isNotEmpty) {
      return failedCommand(state, label, [
        commandError('${family.name} is used by ${_usageSummary(uses)}.'),
      ]);
    }
    final files = {for (final f in family.faces) f.assetId};
    // A font file shared with another family stays.
    for (final o in doc.fonts.values) {
      if (o.id != familyId) {
        files.removeAll([for (final f in o.faces) f.assetId]);
      }
    }
    return CommandResult(
      document: doc.copyWith(
        fonts: {
          for (final e in doc.fonts.entries)
            if (e.key != familyId) e.key: e.value,
        },
        assets: {
          for (final e in doc.assets.entries)
            if (!files.contains(e.key)) e.key: e.value,
        },
      ),
      label: label,
      changed: true,
    );
  }
}

/// Removes one face (font file) of a family; the family goes with its last
/// face (see [RemoveFontFamily]).
class RemoveFontFace extends EditCommand {
  const RemoveFontFace(this.familyId, this.assetId);

  final String familyId;
  final String assetId;

  @override
  String get label => 'Remove font face';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final family = doc.fonts[familyId];
    if (family == null) return CommandResult(document: doc, label: label);
    final left = [
      for (final f in family.faces)
        if (f.assetId != assetId) f,
    ];
    if (left.length == family.faces.length) {
      return CommandResult(document: doc, label: label);
    }
    if (left.isEmpty) return RemoveFontFamily(familyId).apply(state);
    return CommandResult(
      document: doc.copyWith(
        fonts: {
          ...doc.fonts,
          familyId: family.copyWith(faces: left),
        },
        assets: {
          for (final e in doc.assets.entries)
            if (e.key != assetId) e.key: e.value,
        },
      ),
      label: label,
      changed: true,
    );
  }
}
