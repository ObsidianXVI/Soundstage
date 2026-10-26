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

/// What the signed-in account may do (DECISIONS 26/10/26 "Invites").
enum CloudAccess {
  signedOut,

  /// Signed in, but the email is not verified yet.
  unverified,

  /// Verified, but not on the admin's invite list.
  notInvited,
  invited,
}

/// The current account's access, checked with the server: the user is
/// reloaded (a verification may have happened in another tab) and the
/// Firestore probe `members/{uid}` is readable only when invited.
Future<CloudAccess> accessOf(Cloud cloud) async {
  var user = cloud.auth.currentUser;
  if (user == null) return CloudAccess.signedOut;
  await user.reload();
  user = cloud.auth.currentUser;
  if (user == null) return CloudAccess.signedOut;
  if (!user.emailVerified) return CloudAccess.unverified;
  // The rules read email_verified from the token: refresh it once it flips.
  final claims = (await user.getIdTokenResult()).claims;
  if (claims?['email_verified'] != true) await user.getIdToken(true);
  try {
    await cloud.firestore
        .doc('members/${user.uid}')
        .get(const GetOptions(source: Source.server));
    return CloudAccess.invited;
  } on FirebaseException catch (e) {
    if (e.code == 'permission-denied') return CloudAccess.notInvited;
    rethrow;
  }
}

/// [CloudBackend] over Firebase.
class FirebaseCloudBackend implements CloudBackend {
  FirebaseCloudBackend(this._cloud);

  final Cloud _cloud;
  (String, String?)? _handle; // (uid, handle) once read

  FirebaseFirestore get _db => _cloud.firestore;

  @override
  String? get uid => _cloud.auth.currentUser?.uid;

  @override
  Future<String?> handle() async {
    final uid = this.uid;
    if (uid == null) return null;
    final cached = _handle;
    if (cached != null && cached.$1 == uid && cached.$2 != null) {
      return cached.$2;
    }
    final h = (await _db.doc('profiles/$uid').get()).data()?['handle'];
    _handle = (uid, h as String?);
    return h;
  }

  @override
  Future<void> claimHandle(String handle, {String name = ''}) async {
    final uid = this.uid;
    if (uid == null) throw const PublishException('Sign in first.');
    if (!isValidHandle(handle)) {
      throw const PublishException(
        'Use 3–30 lowercase letters, digits and dashes.',
      );
    }
    if ((await _db.doc('handles/$handle').get()).exists) {
      throw PublishException('@$handle is taken. Choose another.');
    }
    try {
      await (_db.batch()
            ..set(_db.doc('handles/$handle'), {
              'ownerId': uid,
              'name': name,
              'createdAt': FieldValue.serverTimestamp(),
            })
            ..set(_db.doc('profiles/$uid'), {'handle': handle, 'name': name}))
          .commit();
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw PublishException('@$handle is taken. Choose another.');
      }
      rethrow;
    }
    _handle = (uid, handle);
  }

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
  Future<void> deleteFolder(String prefix) async {
    Future<void> clear(Reference folder) async {
      final list = await folder.listAll();
      for (final item in list.items) {
        await item.delete();
      }
      for (final sub in list.prefixes) {
        await clear(sub);
      }
    }

    await clear(_cloud.storage.ref(prefix));
  }

  /// The document at [path]; a gated one (hidden by the rules from
  /// everyone but its owner) throws [GateRequired].
  Future<Map<String, Object?>?> _read(String path) async {
    try {
      return (await _db.doc(path).get()).data();
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw GateRequired(path);
      rethrow;
    }
  }

  @override
  Future<PublishedRecord?> published(PublishTarget target) async {
    final data = await _read(target.docPath);
    return data == null ? null : PublishedRecord.fromMap(data);
  }

  @override
  Future<void> setPublished(PublishTarget target, PublishedRecord record) => _db
      .doc(target.docPath)
      .set({...record.toMap(), 'updatedAt': FieldValue.serverTimestamp()});

  @override
  Future<PublishTarget?> publishedTargetOf(String storyId) async {
    final snap = await _db.doc('stories/$storyId').get();
    return PublishTarget.fromMap(snap.data()?['published']);
  }

  @override
  Future<SeriesRecord?> series(PublicationRef ref) async {
    final data = await _read(ref.docPath);
    return data == null ? null : SeriesRecord.fromMap(data);
  }

  @override
  Future<void> setSeries(PublicationRef ref, SeriesRecord record) => _db
      .doc(ref.docPath)
      .set({...record.toMap(), 'updatedAt': FieldValue.serverTimestamp()});

  @override
  Future<PublicationRef?> publicationOf(String projectId) async {
    final h = await handle();
    if (h == null) return null;
    final q = await _db
        .collection('sites/$h/publications')
        .where('ownerId', isEqualTo: uid)
        .where('projectId', isEqualTo: projectId)
        .limit(1)
        .get();
    return q.docs.isEmpty ? null : PublicationRef(h, q.docs.first.id);
  }

  @override
  Future<SiteListing?> site(String handle) async {
    final owner = (await _db.doc('handles/$handle').get()).data();
    if (owner == null) return null;
    // Only public work is listed (the rules allow no other list).
    Future<QuerySnapshot<Map<String, Object?>>> listed(String c) => _db
        .collection('sites/$handle/$c')
        .where('audience', isEqualTo: Audience.public.name)
        .get();
    final pubs = await listed('publications');
    final drafts = await listed('drafts');
    return SiteListing(
      handle: handle,
      name: (owner['name'] as String?) ?? '',
      publications: [
        for (final d in pubs.docs)
          _publicationEntry(handle, d.id, SeriesRecord.fromMap(d.data())),
      ],
      drafts: [
        for (final d in drafts.docs)
          _draftEntry(handle, d.id, PublishedRecord.fromMap(d.data())),
      ],
    );
  }

  @override
  Future<void> setStoryMeta(String storyId, Map<String, Object?> data) =>
      _db.doc('stories/$storyId').set({
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
}

SiteEntry _publicationEntry(String handle, String slug, SeriesRecord r) =>
    SiteEntry(
      route: PublicationRef(handle, slug).route,
      title: r.title.isEmpty ? slug : r.title,
      image: r.issues.firstOrNull?.image ?? '',
      issueCount: r.issues.length,
    );

SiteEntry _draftEntry(String handle, String slug, PublishedRecord r) =>
    SiteEntry(
      route: DraftTarget(handle, slug).route,
      title: r.title.isEmpty ? slug : r.title,
      description: r.description,
      image: r.image,
    );
