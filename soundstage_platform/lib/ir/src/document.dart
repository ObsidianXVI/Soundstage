import 'package:freezed_annotation/freezed_annotation.dart';

import 'assets.dart';
import 'audio.dart';
import 'breakpoint.dart';
import 'components.dart';
import 'migrations/migrate.dart';
import 'nodes/node.dart';
import 'nodes/text.dart';
import 'scene.dart';
import 'tokens.dart';
import 'values/geometry.dart';
import 'values/ids.dart';

part 'document.freezed.dart';
part 'document.g.dart';

/// Story metadata.
@freezed
abstract class StageMeta with _$StageMeta {
  const factory StageMeta({
    @Default('') String title,
    @Default('') String slug,
    @Default('') String author,
    @Default('') String description,
    String? coverAssetId,
    @Default('en') String language,
  }) = _StageMeta;

  factory StageMeta.fromJson(Map<String, dynamic> json) =>
      _$StageMetaFromJson(json);
}

/// A Soundstage story (architecture §3).
///
/// `defaultTextStyle` is the base of every text style cascade (§7).
///
/// Maps keyed by id: `assets`, `fonts`, `components`, `variantSets`.
/// `scenes` are in reading order. `overlay` is persistent chrome drawn over
/// every scene.
@freezed
abstract class StageDocument with _$StageDocument {
  const factory StageDocument({
    required String id,
    required List<Breakpoint> breakpoints,
    @Default(kStageSchemaVersion) int schemaVersion,
    @Default(StageMeta()) StageMeta meta,
    @Default(TokenSystem()) TokenSystem tokens,
    @Default(TextStyle()) TextStyle defaultTextStyle,
    @Default(<String, Asset>{}) Map<String, Asset> assets,
    @Default(<String, FontFamily>{}) Map<String, FontFamily> fonts,
    @Default(<String, ComponentDef>{}) Map<String, ComponentDef> components,
    @Default(<String, VariantSet>{}) Map<String, VariantSet> variantSets,
    @Default(<Scene>[]) List<Scene> scenes,
    @Default(<AudioTrack>[]) List<AudioTrack> audioTracks,
    FrameNode? overlay,
  }) = _StageDocument;

  const StageDocument._();

  /// A valid empty document with the default shared-base breakpoints:
  /// desktop (primary, min 1024, 1440×900) and mobile (primary, min 0,
  /// 390×844) as peers over the shared base, and tablet (min 600, 834×1112)
  /// inheriting from desktop. No tokens and no scenes.
  factory StageDocument.empty({
    required IdGenerator ids,
    StageMeta meta = const StageMeta(),
  }) {
    final desktop = Breakpoint(
      id: ids.next(),
      name: 'Desktop',
      minWidth: 1024,
      designSize: const StageSize(width: 1440, height: 900),
      primary: true,
    );
    return StageDocument(
      id: ids.next(),
      meta: meta,
      breakpoints: [
        desktop,
        Breakpoint(
          id: ids.next(),
          name: 'Mobile',
          minWidth: 0,
          designSize: const StageSize(width: 390, height: 844),
          primary: true,
        ),
        Breakpoint(
          id: ids.next(),
          name: 'Tablet',
          minWidth: 600,
          designSize: const StageSize(width: 834, height: 1112),
          inheritsFrom: desktop.id,
        ),
      ],
    );
  }

  factory StageDocument.fromJson(Map<String, dynamic> json) =>
      _$StageDocumentFromJson(json);

  /// Migrates [json] to the current schema version, then parses it.
  factory StageDocument.fromJsonMigrating(Map<String, Object?> json) =>
      StageDocument.fromJson(migrateDocumentJson(json));

  /// The primary breakpoints (one editor artboard each, §15), in order.
  Iterable<Breakpoint> get primaryBreakpoints =>
      breakpoints.where((b) => b.primary);
}
