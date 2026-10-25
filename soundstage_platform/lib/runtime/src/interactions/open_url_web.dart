import 'package:web/web.dart' as web;

bool openUrl(String url, {required bool newTab}) {
  if (newTab) {
    web.window.open(url, '_blank', 'noopener,noreferrer');
  } else {
    web.window.location.assign(url);
  }
  return true;
}
