import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'asset_resolver.dart';
import 'font_metrics.dart';

/// Loads the bytes of a font asset.
typedef StageFontBytesLoader = Future<Uint8List> Function(ir.Asset asset);

/// Registers font [bytes] with the engine under [family].
typedef StageFontRegistrar =
    Future<void> Function(String family, Uint8List bytes);

/// Called when a document font family finished loading (or failed to).
typedef StageFontListener = void Function(String familyId);

/// Registers [bytes] with Flutter's [FontLoader].
Future<void> registerFontWithFontLoader(String family, Uint8List bytes) =>
    (FontLoader(
      family,
    )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();

/// A loaded face of a document font family.
class StageFontFace {
  StageFontFace({required this.name, required this.face, this.metrics});

  /// The engine family name the face is registered under (unique per face).
  final String name;
  final ir.FontFace face;

  /// Vertical metrics from the font's OS/2 table, or null when unreadable.
  final StageFontMetrics? metrics;

  int get weight => face.weight;
  bool get italic => face.italic;

  /// The variation axis [tag], or null.
  ir.FontAxis? axis(String tag) {
    if (!face.variable) return null;
    for (final a in face.axes) {
      if (a.tag == tag) return a;
    }
    return null;
  }

  /// The weight range this face covers: a variable `wght` axis, else its
  /// static weight.
  (double, double) get weightRange {
    final a = axis('wght');
    return a == null
        ? (face.weight.toDouble(), face.weight.toDouble())
        : (a.min, a.max);
  }
}

/// A problem found while loading fonts (reported once, never thrown).
typedef StageFontDiagnostic = ({String familyId, String message});

enum _Load { loading, loaded, failed }

/// Document fonts (architecture §7, §12): maps a text style's
/// `fontFamilyId` to the engine family it renders with, and loads the
/// families' font files.
///
/// - **Names.** Each face registers under its own engine family name,
///   `ss-<familyId>-<hash>-<face>`, where the hash covers the family id and
///   its faces' asset URIs, weights and styles. Names are stable across
///   loads and two documents can only share a name when they would load the
///   same files. A face that is already registered (process-wide) is not
///   registered again.
/// - **Faces.** [faceFor] picks a face by CSS font matching (italic first,
///   then the nearest weight by the CSS rules; a variable face covers its
///   `wght` range).
/// - **Fallback.** Until a family is loaded (or when it fails), text uses
///   the family's generic fallback ([fallbackFamily]). Looking a family up
///   starts loading it; listeners hear when it finishes, so text render
///   objects that use it relayout.
class StageFontTable {
  StageFontTable([
    this.families = const {},
    this.assets = const {},
    StageFontBytesLoader? loadBytes,
    StageFontRegistrar? register,
    this.loadOnDemand = true,
  ]) : _loadBytes = loadBytes,
       _register = register ?? registerFontWithFontLoader;

  /// The document's font table, loading font files through [resolver].
  factory StageFontTable.fromDocument(
    ir.StageDocument doc, {
    StageAssetResolver? resolver,
    StageFontRegistrar? register,
  }) {
    final r = resolver ?? StageAssetResolver(assets: doc.assets);
    return StageFontTable(
      doc.fonts,
      doc.assets,
      (asset) => r.load(asset.uri),
      register,
    );
  }

  /// A table without document fonts.
  static final StageFontTable none = StageFontTable();

  final Map<String, ir.FontFamily> families;
  final Map<String, ir.Asset> assets;

  /// Whether looking up an unloaded family starts loading it ([faceFor]).
  /// When false, only [request] / [ensureLoaded] load.
  final bool loadOnDemand;
  final StageFontBytesLoader? _loadBytes;
  final StageFontRegistrar _register;

  final Map<String, _Load> _state = {};
  final Map<String, Future<void>> _futures = {};
  final Map<String, List<StageFontFace>> _faces = {};
  final List<StageFontListener> _listeners = [];
  final List<StageFontDiagnostic> _diagnostics = [];
  final Set<String> _reported = {};

  /// Engine family names registered in this process (shared by tables).
  static final Map<String, Future<void>> _registered = {};

  /// Problems found so far (missing assets, unreadable metrics, …).
  List<StageFontDiagnostic> get diagnostics => List.unmodifiable(_diagnostics);

  /// Records a diagnostic once per [familyId] and [message].
  void report(String familyId, String message) {
    if (!_reported.add('$familyId\u0000$message')) return;
    _diagnostics.add((familyId: familyId, message: message));
    debugPrint('soundstage fonts: $familyId: $message');
  }

  void addListener(StageFontListener l) => _listeners.add(l);
  void removeListener(StageFontListener l) => _listeners.remove(l);

  /// Whether [familyId]'s faces are registered.
  bool isLoaded(String familyId) => _state[familyId] == _Load.loaded;

  /// The generic fallback of [fontFamilyId] (sans when unknown).
  ir.FontFallback fallback(String? fontFamilyId) =>
      (fontFamilyId == null ? null : families[fontFamilyId]?.fallback) ??
      ir.FontFallback.sans;

  /// The engine family for the generic fallback: null (the platform
  /// default) for sans, `serif` and `monospace` otherwise.
  String? fallbackFamily(String? fontFamilyId) =>
      switch (fallback(fontFamilyId)) {
        ir.FontFallback.sans => null,
        ir.FontFallback.serif => 'serif',
        ir.FontFallback.mono => 'monospace',
      };

  /// The engine family of [fontFamilyId]'s regular face, or its fallback
  /// while it is not loaded.
  String? familyName(String? fontFamilyId) =>
      faceFor(fontFamilyId, 400, false)?.name ?? fallbackFamily(fontFamilyId);

  /// The face [fontFamilyId] renders [weight]/[italic] with, or null while
  /// the family is not loaded (it starts loading) or has no usable face.
  StageFontFace? faceFor(String? fontFamilyId, int weight, bool italic) {
    if (fontFamilyId == null || !families.containsKey(fontFamilyId)) {
      return null;
    }
    final faces = _faces[fontFamilyId];
    if (faces == null) {
      if (loadOnDemand) request(fontFamilyId);
      return null;
    }
    return pickFace(faces, weight, italic);
  }

  /// Starts loading [familyId] unless it is loading or loaded.
  void request(String familyId) {
    if (_state.containsKey(familyId)) return;
    _futures[familyId] = _load(familyId);
  }

  /// Loads every family in [familyIds] (unknown ids are ignored) and
  /// completes when all are loaded or failed. Never throws.
  Future<void> ensureLoaded(Iterable<String> familyIds) async {
    final waits = <Future<void>>[];
    for (final id in familyIds) {
      if (!families.containsKey(id)) continue;
      request(id);
      final f = _futures[id];
      if (f != null) waits.add(f);
    }
    await Future.wait(waits);
  }

  /// Loads every family of the table.
  Future<void> loadAll() => ensureLoaded(families.keys);

  Future<void> _load(String familyId) async {
    _state[familyId] = _Load.loading;
    // Never notify synchronously: lookups happen during layout.
    await Future<void>.value();
    final family = families[familyId]!;
    final base = 'ss-${_sanitize(familyId)}-${_hash(family)}';
    final out = <StageFontFace>[];
    for (final (i, face) in family.faces.indexed) {
      final asset = assets[face.assetId];
      if (asset == null) {
        report(familyId, 'font asset "${face.assetId}" does not exist');
        continue;
      }
      final loader = _loadBytes;
      if (loader == null) {
        report(familyId, 'no font loader');
        continue;
      }
      try {
        final bytes = await loader(asset);
        final name = '$base-$i';
        await (_registered[name] ??= _register(name, bytes));
        final m = parseFontMetrics(bytes);
        if (m.problem != null) {
          report(familyId, 'face ${face.assetId}: ${m.problem}');
        }
        out.add(StageFontFace(name: name, face: face, metrics: m.metrics));
      } catch (e) {
        report(familyId, 'could not load "${asset.uri}": $e');
      }
    }
    if (out.isEmpty) {
      _state[familyId] = _Load.failed;
    } else {
      _faces[familyId] = out;
      _state[familyId] = _Load.loaded;
    }
    for (final l in List.of(_listeners)) {
      l(familyId);
    }
  }

  static String _sanitize(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

  /// FNV-1a over the family's id and faces, as 8 hex digits.
  static String _hash(ir.FontFamily f) {
    final key = StringBuffer(f.id);
    for (final face in f.faces) {
      key.write('|${face.assetId}:${face.weight}:${face.italic}');
    }
    var h = 0x811c9dc5;
    for (final c in key.toString().codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}

/// Picks the face for [weight]/[italic] by CSS font matching: faces of the
/// requested style first (else all faces), then the face covering [weight],
/// else for 400–500 the nearest heavier face up to 500, then lighter, then
/// heavier; below 400 lighter then heavier; above 500 heavier then lighter.
StageFontFace? pickFace(List<StageFontFace> faces, int weight, bool italic) {
  if (faces.isEmpty) return null;
  var pool = faces.where((f) => f.italic == italic).toList();
  if (pool.isEmpty) pool = faces;
  final w = weight.toDouble();
  StageFontFace? best;
  double? bestKey;
  for (final f in pool) {
    final (lo, hi) = f.weightRange;
    double key;
    if (w >= lo && w <= hi) {
      key = 0;
    } else {
      final e = w < lo ? lo : hi; // the face's nearest weight
      final heavier = e > w;
      final d = (e - w).abs();
      if (w >= 400 && w <= 500) {
        key = heavier && e <= 500 ? d : (!heavier ? 1000 + d : 2000 + d);
      } else if (w < 400) {
        key = !heavier ? d : 1000 + d;
      } else {
        key = heavier ? d : 1000 + d;
      }
    }
    if (bestKey == null || key < bestKey) {
      best = f;
      bestKey = key;
    }
  }
  return best;
}
