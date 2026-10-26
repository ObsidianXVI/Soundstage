import 'dart:convert';

import 'package:soundstage_platform/ir/ir.dart' as ir;

// A project's shared library (DECISIONS 26/10/26 #11): the design system
// every issue of the project uses. Issues open with it and write their
// changes to it, so a token, style or component edited in one issue is the
// next issue's too.

/// The document parts a project shares across its issues.
class ProjectLibrary {
  const ProjectLibrary({
    this.tokens = const ir.TokenSystem(),
    this.components = const {},
    this.variantSets = const {},
    this.fonts = const {},
    this.defaultTextStyle = const ir.TextStyle(),
    this.assets = const {},
  });

  /// [doc]'s library: its tokens, components, variant sets, fonts and
  /// default text style, plus the assets those refer to (font files,
  /// images inside components).
  factory ProjectLibrary.of(ir.StageDocument doc) {
    final shared = jsonEncode({
      'components': {
        for (final e in doc.components.entries) e.key: e.value.toJson(),
      },
      'fonts': {for (final e in doc.fonts.entries) e.key: e.value.toJson()},
      'variantSets': {
        for (final e in doc.variantSets.entries) e.key: e.value.toJson(),
      },
    });
    return ProjectLibrary(
      tokens: doc.tokens,
      components: doc.components,
      variantSets: doc.variantSets,
      fonts: doc.fonts,
      defaultTextStyle: doc.defaultTextStyle,
      assets: {
        for (final e in doc.assets.entries)
          if (shared.contains('"${e.key}"')) e.key: e.value,
      },
    );
  }

  factory ProjectLibrary.fromJson(Map<String, Object?> json) {
    final doc = ir.StageDocument.fromJsonMigrating({
      'id': 'library',
      'breakpoints': const <Object?>[],
      'schemaVersion': ir.kStageSchemaVersion,
      ...json,
    });
    return ProjectLibrary(
      tokens: doc.tokens,
      components: doc.components,
      variantSets: doc.variantSets,
      fonts: doc.fonts,
      defaultTextStyle: doc.defaultTextStyle,
      assets: doc.assets,
    );
  }

  final ir.TokenSystem tokens;
  final Map<String, ir.ComponentDef> components;
  final Map<String, ir.VariantSet> variantSets;
  final Map<String, ir.FontFamily> fonts;
  final ir.TextStyle defaultTextStyle;
  final Map<String, ir.Asset> assets;

  /// The library as document JSON fields (what a document stores them as).
  Map<String, Object?> toJson() {
    final doc = ir.StageDocument(
      id: 'library',
      breakpoints: const [],
      tokens: tokens,
      components: components,
      variantSets: variantSets,
      fonts: fonts,
      defaultTextStyle: defaultTextStyle,
      assets: assets,
    );
    final json = jsonDecode(jsonEncode(doc.toJson())) as Map<String, Object?>;
    return {
      for (final k in const [
        'schemaVersion',
        'tokens',
        'components',
        'variantSets',
        'fonts',
        'defaultTextStyle',
        'assets',
      ])
        if (json.containsKey(k)) k: json[k],
    };
  }

  /// [doc] using this library: its tokens, components, variant sets, fonts
  /// and default text style replaced, and the library's assets added to its
  /// own (the document's own entries win on a clash).
  ir.StageDocument applyTo(ir.StageDocument doc) => doc.copyWith(
    tokens: tokens,
    components: components,
    variantSets: variantSets,
    fonts: fonts,
    defaultTextStyle: defaultTextStyle,
    assets: {...assets, ...doc.assets},
  );

  /// A blank issue of a project: the default breakpoints, one blank scene,
  /// and this library.
  ir.StageDocument blankIssue({required String title}) {
    final ids = ir.IdGenerator();
    final empty = ir.StageDocument.empty(
      ids: ids,
      meta: ir.StageMeta(title: title),
    );
    return applyTo(
      empty.copyWith(
        scenes: [
          ir.Scene.blankPinned(
            ids: ids,
            breakpoint: empty.breakpoints.first,
            name: 'Scene 1',
          ),
        ],
      ),
    );
  }
}
