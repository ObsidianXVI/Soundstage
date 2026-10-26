/// Rich text to put on the clipboard.
typedef RichClip = ({String html, String plain});

/// Not available off the web.
Future<void> copyRichText(Future<RichClip> content) async =>
    throw UnsupportedError('Copying rich text needs a browser.');
