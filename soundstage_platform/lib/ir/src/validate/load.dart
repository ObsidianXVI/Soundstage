import 'dart:convert';

import '../diagnostics.dart';
import '../document.dart';
import 'validate.dart';

/// The outcome of [loadDocument].
///
/// `document` is null only when the input could not be parsed at all; then
/// `diagnostics` holds an `invalidDocument` error. Otherwise it is the parsed
/// document plus whatever [validateDocument] found (which may include errors:
/// the editor can still open a document with dangling references).
class LoadResult {
  const LoadResult({this.document, this.diagnostics = const []});

  final StageDocument? document;
  final List<IrDiagnostic> diagnostics;

  /// True when a document was parsed.
  bool get loaded => document != null;

  /// True when a document was parsed and has no error diagnostics.
  bool get clean => loaded && !hasErrors(diagnostics);
}

/// Loads a document: migrate, parse, validate (architecture §17.3).
///
/// [json] is a decoded JSON object, or a JSON string. **Never throws**:
/// malformed input, unsupported schema versions and parse failures all come
/// back as a failed [LoadResult] with an `invalidDocument` diagnostic.
LoadResult loadDocument(Object? json) {
  try {
    var input = json;
    if (input is String) input = jsonDecode(input);
    if (input is! Map) {
      return _failed('A story document must be a JSON object.');
    }
    final map = <String, Object?>{
      for (final e in input.entries) e.key.toString(): e.value,
    };
    final StageDocument doc;
    try {
      doc = StageDocument.fromJsonMigrating(map);
    } on Object catch (e) {
      return _failed('The document could not be read: $e');
    }
    try {
      return LoadResult(document: doc, diagnostics: validateDocument(doc));
    } on Object catch (e) {
      return LoadResult(
        document: doc,
        diagnostics: [
          IrDiagnostic(
            IrDiagnosticKind.invalidDocument,
            'Validation failed unexpectedly: $e',
            location: '',
          ),
        ],
      );
    }
  } on Object catch (e) {
    return _failed('The document could not be loaded: $e');
  }
}

LoadResult _failed(String message) => LoadResult(
  diagnostics: [
    IrDiagnostic(IrDiagnosticKind.invalidDocument, message, location: ''),
  ],
);
