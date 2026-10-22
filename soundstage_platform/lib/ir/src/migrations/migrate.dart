/// Stage document schema migrations (architecture §13).
library;

/// The schema version this build reads and writes.
const int kStageSchemaVersion = 1;

/// A pure function that upgrades a document's JSON by exactly one version.
typedef MigrationStep =
    Map<String, Object?> Function(Map<String, Object?> json);

/// Registered steps, keyed by the version they upgrade **from**: the step at
/// key `n` turns a v`n` document into v`n+1`. Empty at v1.
///
/// To add a step: create `v<N>_to_v<N+1>.dart` with a pure `Map → Map`
/// function, register it here, and bump [kStageSchemaVersion].
const Map<int, MigrationStep> kMigrationSteps = <int, MigrationStep>{};

/// Thrown when a document cannot be migrated.
class StageMigrationException implements Exception {
  const StageMigrationException(this.message);

  final String message;

  @override
  String toString() => 'StageMigrationException: $message';
}

/// Runs every registered step from the document's `schemaVersion` up to
/// [targetVersion] and returns the migrated JSON (with `schemaVersion` set to
/// [targetVersion]). The input map is not modified.
///
/// [steps] and [targetVersion] default to the registered steps and
/// [kStageSchemaVersion]; tests inject their own.
///
/// Throws [StageMigrationException] when `schemaVersion` is missing or not a
/// positive integer, newer than [targetVersion], or a step is missing.
Map<String, Object?> migrateDocumentJson(
  Map<String, Object?> json, {
  Map<int, MigrationStep> steps = kMigrationSteps,
  int targetVersion = kStageSchemaVersion,
}) {
  final raw = json['schemaVersion'];
  if (raw is! int || raw < 1) {
    throw StageMigrationException(
      'Document has no valid "schemaVersion" (found: ${raw ?? 'nothing'}).',
    );
  }
  if (raw > targetVersion) {
    throw StageMigrationException(
      'Document schemaVersion $raw is newer than the supported version '
      '$targetVersion. Update Soundstage to open it.',
    );
  }
  var current = Map<String, Object?>.of(json);
  for (var v = raw; v < targetVersion; v++) {
    final step = steps[v];
    if (step == null) {
      throw StageMigrationException(
        'No migration registered from schemaVersion $v to ${v + 1}.',
      );
    }
    current = Map<String, Object?>.of(step(current))..['schemaVersion'] = v + 1;
  }
  return current;
}
