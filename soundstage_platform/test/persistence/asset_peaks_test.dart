// Waveform peaks in the asset record (m2.md "Audio lane"): computed once at
// upload, stored with the asset, computed lazily for assets without them.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/persistence/editor_asset_service.dart';
import 'package:soundstage_platform/app/persistence/local_asset_store.dart';
import 'package:soundstage_platform/app/persistence/records.dart';
import 'package:soundstage_platform/app/persistence/story_database.dart';
import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';

import 'contract.dart';

WaveformPeaks _peaks(List<int> v, double d) =>
    WaveformPeaks(Uint8List.fromList(v), d);

void main() {
  late MemoryStoryDatabase db;
  late int decodes;
  WaveformPeaks? Function() decoder = () => null;

  LocalAssetStore store() => LocalAssetStore(
    db,
    analyzer: FakeAnalyzer(),
    urls: FakeUrls(),
    peaksDecoder: (bytes) async {
      decodes++;
      return decoder();
    },
  );

  setUp(() {
    db = MemoryStoryDatabase();
    decodes = 0;
    decoder = () => _peaks([1, 2, 3], 0.03);
  });

  test(
    'upload decodes audio once and stores the peaks with the record',
    () async {
      final s = store();
      final a = await s.put(
        Uint8List.fromList([1]),
        'audio/mpeg',
        name: 'a.mp3',
      );
      expect(decodes, 1);
      final rec = await db.getAsset(a.id);
      expect(rec!.meta.peaks, [1, 2, 3]);
      // The analyzer found no duration, so the decode's duration is stored.
      expect(rec.meta.duration, 0.03);
      expect(a.duration, 0.03);
      // A request reads the stored peaks; nothing is decoded again.
      final p = await s.peaks(a.id);
      expect(p!.data, [1, 2, 3]);
      expect(decodes, 1);
    },
  );

  test('images and video are not decoded for peaks', () async {
    final s = store();
    final i = await s.put(Uint8List.fromList([1]), 'image/png');
    final v = await s.put(Uint8List.fromList([2]), 'video/mp4');
    expect(decodes, 0);
    expect(await s.peaks(i.id), isNull);
    expect(await s.peaks(v.id), isNull);
    expect(await s.peaks('missing'), isNull);
  });

  test('an undecodable file still uploads, with no peaks', () async {
    decoder = () => throw StateError('bad data');
    final s = store();
    final a = await s.put(Uint8List.fromList([1]), 'audio/mpeg');
    expect((await db.getAsset(a.id))!.meta.peaks, isNull);
    decoder = () => null;
    expect(await s.peaks(a.id), isNull);
  });

  test('an asset without peaks gets them on the first request', () async {
    // As stored before peaks existed.
    await db.putAsset(
      AssetRecord(
        const AssetMeta(
          id: 'old',
          mime: 'audio/mpeg',
          byteSize: 1,
          createdAt: 0,
          duration: 2,
        ),
        Uint8List.fromList([9]),
      ),
    );
    final s = store();
    final first = s.peaks('old');
    final second = s.peaks('old');
    expect((await first)!.data, [1, 2, 3]);
    expect((await second)!.data, [1, 2, 3]);
    // Concurrent callers share one decode.
    expect(decodes, 1);
    final rec = await db.getAsset('old');
    expect(rec!.meta.peaks, [1, 2, 3]);
    // The known duration wins over the decoded one.
    expect(rec.meta.duration, 2);
    expect((await s.peaks('old'))!.duration, 2);
    // A new store (a reload) finds them in the record.
    expect((await store().peaks('old'))!.data, [1, 2, 3]);
    expect(decodes, 1);
  });

  test('a failed lazy decode is retried on the next request', () async {
    await db.putAsset(
      AssetRecord(
        const AssetMeta(id: 'x', mime: 'audio/wav', byteSize: 1, createdAt: 0),
        Uint8List.fromList([9]),
      ),
    );
    final s = store();
    decoder = () => null;
    expect(await s.peaks('x'), isNull);
    decoder = () => _peaks([7], 0.01);
    expect((await s.peaks('x'))!.data, [7]);
    expect(decodes, 2);
  });

  test('replace recomputes the peaks', () async {
    final s = store();
    final a = await s.put(Uint8List.fromList([1]), 'audio/mpeg');
    decoder = () => _peaks([5, 5], 0.02);
    await s.replace(a.id, Uint8List.fromList([2]), 'audio/mpeg');
    expect((await s.peaks(a.id))!.data, [5, 5]);
  });

  test('the editor service exposes peaks and tolerates a full store', () async {
    final s = store();
    final a = await s.put(Uint8List.fromList([1]), 'audio/mpeg');
    expect((await LocalEditorAssetService(s).peaks(a.id))!.length, 3);
    expect(await const UnavailableAssetService().peaks(a.id), isNull);
  });
}
