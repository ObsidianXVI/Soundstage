import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';

void main() {
  // Path URLs (/edit/abc), not hash URLs (/#/edit/abc). Hosting must rewrite
  // unknown paths to index.html (see tool/serve_release.mjs).
  usePathUrlStrategy();
  // The editor has its own context menus.
  if (kIsWeb) BrowserContextMenu.disableContextMenu().ignore();
  runApp(const ProviderScope(child: SoundstageApp()));
}
