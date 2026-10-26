import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';
import 'app/cloud/cloud.dart';
import 'app/cloud/domains.dart';
import 'app/data/story_repository.dart';
import 'app/persistence/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Path URLs (/edit/abc), not hash URLs (/#/edit/abc). Hosting must rewrite
  // unknown paths to index.html (see tool/serve_release.mjs).
  usePathUrlStrategy();
  // The editor has its own context menus.
  if (kIsWeb) BrowserContextMenu.disableContextMenu().ignore();
  final (storage, cloud) = (await openAppStorage(), await openCloud());
  // An author's own domain shows only their published work (m7.md T7.5).
  final siteHandle = await domainHandle(cloud, Uri.base.host);
  runApp(
    ProviderScope(
      overrides: [
        appStorageProvider.overrideWithValue(storage),
        cloudProvider.overrideWithValue(cloud),
        siteHandleProvider.overrideWithValue(siteHandle),
        if (storage.repository case final repo?)
          storyRepositoryProvider.overrideWithValue(repo),
      ],
      child: SoundstageApp(siteHandle: siteHandle),
    ),
  );
}
