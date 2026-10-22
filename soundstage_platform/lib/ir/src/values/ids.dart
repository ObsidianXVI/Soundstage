import 'dart:math';

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
/// Inject a seeded [Random] for deterministic tests.
class IdGenerator {
  IdGenerator([Random? random]) : _random = random ?? Random.secure();

  /// A deterministic generator for tests and fixtures.
  IdGenerator.seeded(int seed) : _random = Random(seed);

  final Random _random;

  /// Returns a new 10-character base62 id.
  String next() {
    final buffer = StringBuffer();
    for (var i = 0; i < kIdLength; i++) {
      buffer.write(kBase62Alphabet[_random.nextInt(kBase62Alphabet.length)]);
    }
    return buffer.toString();
  }
}
