import 'dart:math';

import '../document.dart';

/// The base62 alphabet used for document ids.
const String kBase62Alphabet =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Length of every generated id.
const int kIdLength = 10;

final RegExp _idPattern = RegExp(r'^[0-9A-Za-z]{10}$');

/// True when [id] has the shape of a generated id (10 base62 characters).
///
/// Ids written by hand (e.g. in demo files) are not required to match; this is
/// only a convenience for validation and tests.
bool isGeneratedId(String id) => _idPattern.hasMatch(id);

/// Generates short random base62 ids, unique within a document with
/// overwhelming probability (62^10 ≈ 8.4e17).
///
/// Every generator remembers what it has issued and never repeats it. A
/// document-aware generator ([IdGenerator.forDocument], [reserve]) also
/// avoids every id already in the document, retrying on collision, so new ids
/// are always unique within that document.
///
/// Inject a seeded [Random] for deterministic tests.
class IdGenerator {
  IdGenerator([Random? random]) : _random = random ?? Random.secure();

  /// A deterministic generator for tests and fixtures.
  IdGenerator.seeded(int seed) : _random = Random(seed);

  /// A generator that never issues an id already used in [doc] (any `id`,
  /// map key or reference of generated-id shape).
  IdGenerator.forDocument(StageDocument doc, {Random? random})
    : _random = random ?? Random.secure() {
    reserveJson(doc.toJson());
  }

  final Random _random;
  final Set<String> _used = <String>{};

  /// Number of ids reserved or issued so far.
  int get reservedCount => _used.length;

  /// Marks [ids] as taken.
  void reserve(Iterable<String> ids) => _used.addAll(ids);

  /// Marks every string value and map key in [json] that has the shape of a
  /// generated id as taken. Over-reserving is harmless.
  void reserveJson(Object? json) {
    switch (json) {
      case final String s:
        if (isGeneratedId(s)) _used.add(s);
      case final Map<Object?, Object?> m:
        for (final e in m.entries) {
          final k = e.key;
          if (k is String && isGeneratedId(k)) _used.add(k);
          reserveJson(e.value);
        }
      case final Iterable<Object?> l:
        l.forEach(reserveJson);
      default:
        break;
    }
  }

  /// Returns a new 10-character base62 id, different from every reserved or
  /// previously issued id.
  String next() {
    while (true) {
      final buffer = StringBuffer();
      for (var i = 0; i < kIdLength; i++) {
        buffer.write(kBase62Alphabet[_random.nextInt(kBase62Alphabet.length)]);
      }
      final id = buffer.toString();
      if (_used.add(id)) return id;
    }
  }
}
