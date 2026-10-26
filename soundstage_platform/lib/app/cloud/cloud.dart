import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'publish.dart';

// The hosted backend (m4.md T4.1, DECISIONS 26/10/26 "GCP backend"):
// Firebase Auth, Firestore and Storage on project-soundstage. Configured at
// build time from the gitignored .env.firebase.json:
//
//   flutter build web --dart-define-from-file=.env.firebase.json
//
// Without that config the app runs local-only (cloud features hidden).
// FIREBASE_EMULATOR_HOST=127.0.0.1 points it at the local emulator suite.

const String _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const String _appId = String.fromEnvironment('FIREBASE_APP_ID');
const String _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
const String _authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
const String _bucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
const String _senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
const String _emulatorHost = String.fromEnvironment('FIREBASE_EMULATOR_HOST');

/// The build's Firebase options, or null for a local-only build.
FirebaseOptions? cloudOptionsFromEnvironment() {
  if (_apiKey.isEmpty || _appId.isEmpty || _projectId.isEmpty) return null;
  return const FirebaseOptions(
    apiKey: _apiKey,
    appId: _appId,
    projectId: _projectId,
    authDomain: _authDomain,
    storageBucket: _bucket,
    messagingSenderId: _senderId,
  );
}

/// The connected backend.
class Cloud {
  Cloud(this.auth, this.firestore, this.storage);

  final FirebaseAuth auth;
  final FirebaseFirestore firestore;
  final FirebaseStorage storage;

  late final CloudBackend backend = FirebaseCloudBackend(this);
}

/// Connects to Firebase when the build is configured; null otherwise or
/// when initialisation fails (the app stays usable offline).
Future<Cloud?> openCloud() async {
  final options = cloudOptionsFromEnvironment();
  if (options == null) return null;
  try {
    await Firebase.initializeApp(options: options);
    final cloud = Cloud(
      FirebaseAuth.instance,
      FirebaseFirestore.instance,
      FirebaseStorage.instance,
    );
    if (_emulatorHost.isNotEmpty) {
      await cloud.auth.useAuthEmulator(_emulatorHost, 9099);
      cloud.firestore.useFirestoreEmulator(_emulatorHost, 8085);
      await cloud.storage.useStorageEmulator(_emulatorHost, 9199);
    }
    return cloud;
  } on Object catch (e) {
    debugPrint('soundstage cloud: not available: $e');
    return null;
  }
}

/// Set in `main` from [openCloud]; null for a local-only build.
final cloudProvider = Provider<Cloud?>((ref) => null);

/// The signed-in author (null when signed out or local-only).
final authUserProvider = StreamProvider<User?>((ref) {
  final cloud = ref.watch(cloudProvider);
  if (cloud == null) return Stream.value(null);
  return cloud.auth.authStateChanges();
});

/// [CloudBackend] over Firebase.
class FirebaseCloudBackend implements CloudBackend {
  FirebaseCloudBackend(this._cloud);

  final Cloud _cloud;

  @override
  String? get uid => _cloud.auth.currentUser?.uid;

  @override
  Future<bool> exists(String path) async {
    try {
      await _cloud.storage.ref(path).getMetadata();
      return true;
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return false;
      rethrow;
    }
  }

  @override
  Future<void> upload(String path, Uint8List bytes, String mime) async {
    await _cloud.storage
        .ref(path)
        .putData(
          bytes,
          SettableMetadata(
            contentType: mime,
            // Published files never change (content-named assets, numbered
            // versions).
            cacheControl: 'public, max-age=31536000, immutable',
          ),
        );
  }

  @override
  String publicUrl(String path) {
    final bucket = _cloud.storage.bucket;
    final encoded = Uri.encodeComponent(path);
    if (_emulatorHost.isNotEmpty) {
      return 'http://$_emulatorHost:9199/v0/b/$bucket/o/$encoded?alt=media';
    }
    return 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/'
        '$encoded?alt=media';
  }

  @override
  Future<PublishedRecord?> published(String slug) async {
    final snap = await _cloud.firestore.doc('published/$slug').get();
    final data = snap.data();
    return data == null ? null : PublishedRecord.fromMap(data);
  }

  @override
  Future<void> setPublished(String slug, PublishedRecord record) => _cloud
      .firestore
      .doc('published/$slug')
      .set({...record.toMap(), 'updatedAt': FieldValue.serverTimestamp()});

  @override
  Future<void> setStoryMeta(String storyId, Map<String, Object?> data) =>
      _cloud.firestore.doc('stories/$storyId').set({
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
}
