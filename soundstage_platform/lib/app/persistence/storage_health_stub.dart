import 'records.dart';

/// Asks the browser not to evict this origin's data. Null when unsupported.
Future<bool?> requestPersistentStorage() async => null;

/// Browser usage, quota and persistence, or null when unsupported.
Future<StorageEstimate?> readStorageEstimate() async => null;
