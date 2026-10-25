import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';
import 'package:web/web.dart' as web;

import 'dominant_color.dart';
import 'records.dart';

const bool kHasBrowser = true;

web.Blob _blob(Uint8List bytes, String mime) =>
    web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));

String createObjectUrl(Uint8List bytes, String mime) =>
    web.URL.createObjectURL(_blob(bytes, mime));

void revokeObjectUrl(String url) => web.URL.revokeObjectURL(url);

/// Longest side of the canvas an image is downsampled to for its dominant
/// colour; the browser's own scaler does the averaging.
const int _kSampleSide = 32;

Future<AssetAnalysis> analyzeInBrowser(Uint8List bytes, String mime) async {
  if (mime.startsWith('image/')) return _analyzeImage(bytes, mime);
  if (mime.startsWith('audio/') || mime.startsWith('video/')) {
    return _analyzeMedia(bytes, mime);
  }
  return const AssetAnalysis();
}

Future<AssetAnalysis> _analyzeImage(Uint8List bytes, String mime) async {
  final web.ImageBitmap bitmap;
  try {
    bitmap = await web.window.createImageBitmap(_blob(bytes, mime)).toDart;
  } on Object {
    throw const UnsupportedAssetException('The image could not be decoded.');
  }
  try {
    final w = bitmap.width;
    final h = bitmap.height;
    final scale = _kSampleSide / (w > h ? w : h);
    final sw = (w * scale).round().clamp(1, _kSampleSide);
    final sh = (h * scale).round().clamp(1, _kSampleSide);
    final canvas = web.HTMLCanvasElement()
      ..width = sw
      ..height = sh;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    int? color;
    if (ctx != null) {
      ctx.drawImage(bitmap, 0, 0, sw, sh);
      final data = ctx.getImageData(0, 0, sw, sh).data.toDart;
      color = dominantColorOfRgba(
        Uint8List.view(data.buffer, data.offsetInBytes, data.length),
      );
    }
    return AssetAnalysis(width: w, height: h, dominantColor: color);
  } finally {
    bitmap.close();
  }
}

Future<AssetAnalysis> _analyzeMedia(Uint8List bytes, String mime) async {
  final isVideo = mime.startsWith('video/');
  final el =
      web.document.createElement(isVideo ? 'video' : 'audio')
          as web.HTMLMediaElement;
  final url = createObjectUrl(bytes, mime);
  final done = Completer<void>();
  el
    ..preload = 'metadata'
    ..muted = true;
  el.addEventListener(
    'loadedmetadata',
    ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS,
  );
  el.addEventListener(
    'error',
    ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS,
  );
  el.src = url;
  try {
    await done.future.timeout(const Duration(seconds: 8), onTimeout: () {});
    final d = el.duration;
    final duration = d.isFinite && d > 0 ? d : null;
    if (isVideo) {
      final v = el as web.HTMLVideoElement;
      return AssetAnalysis(
        width: v.videoWidth > 0 ? v.videoWidth : null,
        height: v.videoHeight > 0 ? v.videoHeight : null,
        duration: duration,
      );
    }
    return AssetAnalysis(duration: duration);
  } finally {
    el.removeAttribute('src');
    el.load();
    revokeObjectUrl(url);
  }
}

void downloadFile(String filename, Uint8List bytes, String mime) {
  final url = createObjectUrl(bytes, mime);
  final a = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  a.style.display = 'none';
  web.document.body!.append(a);
  a.click();
  a.remove();
  // Give the browser a moment to start the download before revoking.
  Timer(const Duration(seconds: 30), () => revokeObjectUrl(url));
}

Future<List<PickedFile>> pickFiles({
  String accept = '',
  bool multiple = false,
}) {
  final done = Completer<List<PickedFile>>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = accept
    ..multiple = multiple;
  input.addEventListener(
    'change',
    ((web.Event _) {
      unawaited(() async {
        try {
          final files = input.files;
          final out = <PickedFile>[];
          for (var i = 0; files != null && i < files.length; i++) {
            final f = files.item(i)!;
            final buffer = await f.arrayBuffer().toDart;
            out.add(PickedFile(f.name, buffer.toDart.asUint8List(), f.type));
          }
          if (!done.isCompleted) done.complete(out);
        } on Object catch (e) {
          if (!done.isCompleted) done.completeError(e);
        }
      }());
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!done.isCompleted) done.complete(const []);
    }).toJS,
  );
  input.click();
  return done.future;
}

void Function() onPageHide(void Function() callback) {
  final onVisibility = ((web.Event _) {
    if (web.document.visibilityState == 'hidden') callback();
  }).toJS;
  final onHide = ((web.Event _) => callback()).toJS;
  web.document.addEventListener('visibilitychange', onVisibility);
  web.window.addEventListener('pagehide', onHide);
  return () {
    web.document.removeEventListener('visibilitychange', onVisibility);
    web.window.removeEventListener('pagehide', onHide);
  };
}

/// The rate audio is decoded at for peaks. Web Audio resamples to its
/// context's rate while decoding, so a low rate keeps a ten-minute stereo
/// file near 80 MB instead of 210 MB; 10 ms buckets of 160 samples lose
/// nothing a waveform drawing shows.
const int _kPeaksSampleRate = 16000;

Future<WaveformPeaks?> decodePeaksInBrowser(Uint8List bytes) async {
  try {
    // An offline context decodes without an audio output or a user
    // gesture. `decodeAudioData` detaches its input, so it gets a copy.
    final ctx = web.OfflineAudioContext(1.toJS, 1, _kPeaksSampleRate);
    final copy = Uint8List.fromList(bytes);
    final buffer = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
    return computeWaveformPeaks([
      for (var c = 0; c < buffer.numberOfChannels; c++)
        buffer.getChannelData(c).toDart,
    ], buffer.sampleRate.round());
  } on Object {
    return null;
  }
}
