import 'package:web/web.dart' as web;

/// Opens [path] of this app in a new browser tab.
void openInNewTab(String path) {
  web.window.open(path, '_blank');
}
