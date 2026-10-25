import 'open_url_stub.dart'
    if (dart.library.js_interop) 'open_url_web.dart'
    as platform;

/// Opens [url] for an `openUrl` action: in a new tab when [newTab]. Only
/// http(s), mailto and tel links open (a story must not run `javascript:`
/// or reach other schemes). Returns whether it was opened.
bool openStageUrl(String url, {required bool newTab}) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme)) {
    return false;
  }
  return platform.openUrl(uri.toString(), newTab: newTab);
}
