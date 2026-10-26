// Where published work lives (DECISIONS 26/10/26 "Handles and URLs",
// m7.md T7.2). Every author has a handle; a one-off Draft publishes at
// `/@<handle>/s/<slug>`, a Project's publication at `/@<handle>/<pub>` and
// its issues at `/@<handle>/<pub>/<issue>`. Firestore keeps the records
// under `sites/<handle>/…`, Storage the files under
// `published/<uid>/<handle>/…`.

final RegExp _slugPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$');
final RegExp _handlePattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,28}[a-z0-9])$');

/// Handles kept for the site itself (also refused by the Firestore rules).
const Set<String> kReservedHandles = {
  'admin',
  'api',
  'help',
  'soundstage',
  'support',
  'www',
};

/// Publication slugs that would shadow a route under `/@<handle>/`.
const Set<String> kReservedPublications = {'s'};

/// Whether [slug] is a valid published link (lowercase letters, digits and
/// inner dashes; matches the Firestore rules).
bool isValidSlug(String slug) => _slugPattern.hasMatch(slug);

/// Whether [handle] is a valid, unreserved handle (3–30 characters).
bool isValidHandle(String handle) =>
    _handlePattern.hasMatch(handle) && !kReservedHandles.contains(handle);

/// Whether [slug] can name a publication.
bool isValidPublication(String slug) =>
    isValidSlug(slug) && !kReservedPublications.contains(slug);

/// A slug suggested by [title] (`My first story!` → `my-first-story`).
String slugFor(String title) {
  final s = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = s.length > 64
      ? s.substring(0, 64).replaceAll(RegExp(r'-+$'), '')
      : s;
  return cut.isEmpty ? 'story' : cut;
}

/// A handle suggested by an email (`Ada.Lovelace@x.org` → `ada-lovelace`).
String handleFor(String email) {
  var s = slugFor(email.split('@').first);
  if (s.length > 30) s = s.substring(0, 30).replaceAll(RegExp(r'-+$'), '');
  while (s.length < 3) {
    s = '${s}x';
  }
  return kReservedHandles.contains(s) ? '$s-1' : s;
}

/// Who can read a published story or publication (DECISIONS 26/10/26
/// "Audiences", m7.md T7.4).
enum Audience {
  /// Anyone; listed on the handle's page and in the sitemap.
  public('Public', 'Anyone can read it; it is listed on your page.'),

  /// Anyone with the link; not listed, not indexed.
  unlisted('Unlisted', 'Anyone with the link can read it; it is not listed.'),

  /// Anyone with the password.
  password('Password', 'Readers enter a password you choose.'),

  /// Signed-in readers whose email is on your list.
  readers('Readers', 'Readers sign in with an email on your list.');

  const Audience(this.label, this.description);

  final String label;
  final String description;

  /// Whether files are kept private and served through the gate.
  bool get gated => this == password || this == readers;

  static Audience parse(Object? name) =>
      values.where((a) => a.name == name).firstOrNull ?? public;
}

/// The URI form of a gated Storage object (resolved by the reader's pass).
const String kGatedScheme = 'gated:';

/// A project's publication (`/@<handle>/<slug>`).
class PublicationRef {
  const PublicationRef(this.handle, this.slug);

  final String handle;
  final String slug;

  String get docPath => 'sites/$handle/publications/$slug';
  String get route => '/@$handle/$slug';

  @override
  bool operator ==(Object other) =>
      other is PublicationRef && other.handle == handle && other.slug == slug;

  @override
  int get hashCode => Object.hash(handle, slug);

  @override
  String toString() => route;
}

/// Where one story is published.
sealed class PublishTarget {
  const PublishTarget(this.handle, this.slug);

  final String handle;

  /// The story's own slug (the last path segment).
  final String slug;

  /// The Firestore record.
  String get docPath;

  /// The reader's route on the site.
  String get route;

  /// The Storage folder of the author [uid]'s files for this story:
  /// `published/…`, or `gated/…` for a [gated] audience.
  String storagePrefix(String uid, {bool gated = false});

  /// The form kept in the story's metadata (`stories/{id}.published`).
  Map<String, Object?> toMap();

  /// The target in [m] (from [toMap]), or null.
  static PublishTarget? fromMap(Object? m) {
    if (m is! Map) return null;
    final handle = m['handle'];
    final slug = m['slug'];
    final pub = m['publication'];
    if (handle is! String || slug is! String) return null;
    return pub is String && pub.isNotEmpty
        ? IssueTarget(PublicationRef(handle, pub), slug)
        : DraftTarget(handle, slug);
  }
}

/// A one-off Draft (`/@<handle>/s/<slug>`).
class DraftTarget extends PublishTarget {
  const DraftTarget(super.handle, super.slug);

  @override
  String get docPath => 'sites/$handle/drafts/$slug';

  @override
  String get route => '/@$handle/s/$slug';

  @override
  String storagePrefix(String uid, {bool gated = false}) =>
      '${gated ? 'gated' : 'published'}/$uid/$handle/s/$slug';

  @override
  Map<String, Object?> toMap() => {'handle': handle, 'slug': slug};

  @override
  bool operator ==(Object other) =>
      other is DraftTarget && other.handle == handle && other.slug == slug;

  @override
  int get hashCode => Object.hash(handle, slug);
}

/// An issue of a publication (`/@<handle>/<pub>/<slug>`).
class IssueTarget extends PublishTarget {
  IssueTarget(this.publication, String slug) : super(publication.handle, slug);

  final PublicationRef publication;

  @override
  String get docPath => '${publication.docPath}/issues/$slug';

  @override
  String get route => '${publication.route}/$slug';

  @override
  String storagePrefix(String uid, {bool gated = false}) =>
      '${gated ? 'gated' : 'published'}/$uid/$handle/${publication.slug}/$slug';

  @override
  Map<String, Object?> toMap() => {
    'handle': handle,
    'publication': publication.slug,
    'slug': slug,
  };

  @override
  bool operator ==(Object other) =>
      other is IssueTarget &&
      other.publication == publication &&
      other.slug == slug;

  @override
  int get hashCode => Object.hash(publication, slug);
}
